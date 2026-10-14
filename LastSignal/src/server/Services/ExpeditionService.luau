--!strict
--[[
	ExpeditionService
	-----------------
	Runs an expedition from departure to ending.

	This is the orchestrator. It owns the state machine, the objective logic,
	the radio beats and the results, and it delegates everything else: the
	world to WorldService, the train to TrainService, loot to InteractionService,
	threat to HorrorDirector.

	STATE MACHINE
	-------------
	  preparing   lane claimed, world resetting, players still in the lobby
	  cinematic   opening sequence, synchronised, skippable
	  travelling  between stations, travel events fire here
	  onstation   stopped, objectives active
	  climax      final station, last objective running
	  ending      success or failure, results being shown
	  closed      torn down

	Every transition is one-way and guarded, so a late callback from a previous
	state cannot drag the expedition backwards.

	SAFETY PROPERTIES
	-----------------
	  - No player is ever left in a loading state: joining, dying, reconnecting
	    and the expedition ending all resolve to a definite place.
	  - Threat is suppressed during the cinematic, during loading and for a
	    grace period after every respawn and boarding, which is what makes
	    "no unavoidable deaths" a guarantee rather than a hope.
	  - Teardown always runs, including on failure, so a lane is never leaked.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.LastSignal

local Balance = require(Shared.Config.Balance)
local Format = require(Shared.Core.Format)
local GameConfig = require(Shared.Config.GameConfig)
local Guard = require(Shared.Core.Guard)
local Logger = require(Shared.Core.Logger)
local Maid = require(Shared.Core.Maid)
local Net = require(Shared.Core.Net)
local Protect = require(Shared.Core.Protect)
local Signal = require(Shared.Core.Signal)
local ItemRegistry = require(Shared.Registry.ItemRegistry)
local RadioScript = require(Shared.Registry.RadioScript)
local StationRegistry = require(Shared.Registry.StationRegistry)

local CrewService = require(script.Parent.CrewService)
local DepartureService = require(script.Parent.DepartureService)
local Prologue = require(script.Parent.Parent.World.Prologue)
local DataService = require(script.Parent.DataService)
local InventoryService = require(script.Parent.InventoryService)
local ProgressionService = require(script.Parent.ProgressionService)
local ShopService = require(script.Parent.ShopService)
local TrainService = require(script.Parent.TrainService)
local WorldService = require(script.Parent.WorldService)
local TrainBuilder = require(script.Parent.Parent.World.TrainBuilder)

local log = Logger.new("ExpeditionService")

local ExpeditionService = {}

export type ObjectiveProgress = {
	id: string,
	complete: boolean,
	progress: number,
	target: number,
	stepIndex: number,
	stepProgress: number,
	startedAt: number?,
}

export type Checkpoint = {
	stationIndex: number,
	distance: number,
	fuel: number,
	condition: number,
	inventories: { [number]: { { id: string, quantity: number } } },
}

export type Expedition = {
	id: string,
	crewId: string,
	lane: WorldService.Lane,
	train: TrainService.TrainState,
	difficulty: string,
	crewSize: number,

	state: string,
	stationIndex: number,
	objectives: { [string]: ObjectiveProgress },

	startedAt: number,
	endedAt: number?,
	success: boolean?,

	-- Per-run bookkeeping used by the results screen and the quest stats.
	stationsCleared: number,
	optionalCleared: number,
	revives: number,
	downs: number,
	shotsFired: number,
	falseInstructionsIgnored: number,
	falseInstructionsFollowed: number,
	discoveriesFound: { [string]: boolean },
	recordingsFound: { [string]: boolean },
	firedBeats: { [string]: boolean },
	silentAtStation: boolean,

	-- The generated code for the Ninety-Three relay puzzle, so it differs
	-- between runs and cannot be memorised.
	leverCode: { number },

	-- What a retry restores; see takeCheckpoint.
	checkpoint: Checkpoint?,
	retries: number,
	failedAt: number?,

	maid: Maid.Maid,
	members: { number }, -- user ids

	-- The stations this run stops at, in order. The story runs all five; a
	-- night run can take the Ninety-Three cut-off (JourneyService).
	route: { number },
	-- "story" or "nightrun". Set by JourneyService before the train leaves.
	mode: string,
}

local expeditions: { [string]: Expedition } = {}
local playerExpedition: { [number]: string } = {}
local nextExpeditionNumber = 0

ExpeditionService.StateChanged = Signal.new() :: Signal.Signal<Expedition, string>
ExpeditionService.ObjectiveCompleted = Signal.new() :: Signal.Signal<Expedition, string, boolean>
ExpeditionService.StationReached = Signal.new() :: Signal.Signal<Expedition, number>
ExpeditionService.Ended = Signal.new() :: Signal.Signal<Expedition, boolean>
ExpeditionService.ThreatEvent = Signal.new() :: Signal.Signal<Expedition, string, number>
-- Fired after a retry has reset the expedition to its checkpoint, for the
-- services that own vitals, creatures and threat.
ExpeditionService.Retried = Signal.new() :: Signal.Signal<Expedition>
-- Set by JourneyService: adds the night-run report to each player's results.
-- A hook rather than a require, because JourneyService depends on this file.
ExpeditionService.resultsExtra = nil :: ((Expedition, Player, boolean) -> any)?
-- Set by SignalService: the signal calls of the run, for the report.
ExpeditionService.resultsSignals = nil :: ((Expedition) -> any)?

--------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------

local function playersOf(expedition: Expedition): { Player }
	local out: { Player } = {}
	for _, userId in expedition.members do
		local player = Players:GetPlayerByUserId(userId)
		if player then
			table.insert(out, player)
		end
	end
	return out
end

ExpeditionService.playersOf = playersOf

local function broadcast(expedition: Expedition, remote: string, payload: any)
	Net.fireClients(remote, playersOf(expedition), payload)
end

local function notify(expedition: Expedition, kind: string, title: string, body: string, duration: number?)
	broadcast(expedition, "Notify", { kind = kind, title = title, body = body, duration = duration or 5 })
end

--- The next station on this run's route after the current one, if any.
function ExpeditionService.nextStationIndex(expedition: Expedition): number?
	local route = expedition.route
	if expedition.stationIndex <= 0 then
		return route[1]
	end
	for i, index in route do
		if index == expedition.stationIndex then
			return route[i + 1]
		end
	end
	-- Not on the route (should not happen): carry on in registry order.
	for _, index in route do
		if index > expedition.stationIndex then
			return index
		end
	end
	return nil
end

local function currentStation(expedition: Expedition): StationRegistry.StationDef?
	return StationRegistry.byIndex(expedition.stationIndex)
end

local function setState(expedition: Expedition, state: string)
	if expedition.state == state or expedition.state == "closed" then
		return
	end
	expedition.state = state
	log.info(string.format("expedition %s -> %s", expedition.id, state))

	-- Purchase prompts are blocked during moments where selling would be
	-- intrusive. This is the mechanism behind Monetization.PromptBlockedStates.
	local blockedBy: string? = nil
	if state == "cinematic" then
		blockedBy = "cinematic"
	elseif state == "climax" then
		blockedBy = "expedition_climax"
	elseif state == "preparing" then
		blockedBy = "loading"
	end
	for _, player in playersOf(expedition) do
		ShopService.setBlockedState(player, blockedBy)
	end

	ExpeditionService.StateChanged:Fire(expedition, state)
	ExpeditionService.push(expedition)
end

--------------------------------------------------------------------------
-- Radio
--------------------------------------------------------------------------

local radioBusyUntil: { [string]: number } = {}

--- Fires a radio beat if its trigger matches and it has not already fired.
function ExpeditionService.fireRadio(expedition: Expedition, trigger: string, params: { [string]: any }?)
	local now = os.clock()
	if (radioBusyUntil[expedition.id] or 0) > now then
		-- The radio is mid-transmission. Beats do not talk over each other;
		-- a lower-priority beat is simply dropped rather than queued forever.
		return
	end

	for _, beat in RadioScript.beatsFor(trigger) do
		if beat.once and expedition.firedBeats[beat.id] then
			continue
		end
		-- Match the beat's trigger parameters against the event's.
		local matches = true
		if beat.triggerParams then
			for key, expected in beat.triggerParams do
				if key == "fraction" then
					local actual = if params then params[key] else nil
					if type(actual) ~= "number" or actual < expected then
						matches = false
						break
					end
				elseif key == "requiresMimicry" then
					local station = currentStation(expedition)
					if not station or not station.threat.mimicryEnabled then
						matches = false
						break
					end
				else
					local actual = if params then params[key] else nil
					if actual ~= expected then
						matches = false
						break
					end
				end
			end
		end
		if not matches then
			continue
		end

		expedition.firedBeats[beat.id] = true
		radioBusyUntil[expedition.id] = now + RadioScript.beatDuration(beat)

		task.spawn(function()
			for _, line in beat.lines do
				if expedition.state == "closed" then
					return
				end
				broadcast(expedition, "RadioMessage", {
					id = line.id,
					source = line.source,
					text = line.text,
					duration = line.duration,
					cue = line.cue,
					-- The attribution the subtitle shows. A player relying on
					-- subtitles gets the same information the audio carries.
					attribution = if line.source == "dispatch" then "Dispatch" elseif line.source == "other" then "Unknown" else "Crew",
					isFalse = line.falseInstruction ~= nil,
				})
				if line.falseInstruction then
					-- Recorded so the results screen can report whether the crew
					-- was taken in, and so the "never fooled" milestone works.
					expedition.maid:Give(task.delay(line.duration + 25, function()
						-- If nothing acted on the instruction within the window,
						-- the crew is credited with ignoring it.
						if expedition.state ~= "closed" then
							expedition.falseInstructionsIgnored += 1
							for _, player in playersOf(expedition) do
								ProgressionService.addStat(player, "false_instructions_ignored", 1)
							end
						end
					end))
				end
				task.wait(line.duration + 0.4)
			end
		end)
		return
	end
end

--- Called when the crew demonstrably follows a false instruction.
function ExpeditionService.falseInstructionFollowed(expedition: Expedition, action: string)
	expedition.falseInstructionsFollowed += 1
	for _, player in playersOf(expedition) do
		ProgressionService.addStat(player, "false_instructions_followed", 1)
	end
	ExpeditionService.ThreatEvent:Fire(expedition, "false_instruction", 18)
	log.info(string.format("expedition %s followed a false instruction: %s", expedition.id, action))
end

--------------------------------------------------------------------------
-- Objectives
--------------------------------------------------------------------------

local function scaledTarget(expedition: Expedition, base: number): number
	local scaling = Balance.crewScaling(expedition.crewSize)
	return math.max(1, math.floor(base * scaling.objectiveQuantity + 0.5))
end

local function initialiseObjectives(expedition: Expedition, station: StationRegistry.StationDef)
	expedition.objectives = {}
	for _, def in station.objectives do
		local target = 1
		if def.kind == "collect" then
			target = scaledTarget(expedition, def.params.quantity or 1)
		elseif def.kind == "sequence" then
			target = #(def.params.steps or {})
		end
		expedition.objectives[def.id] = {
			id = def.id,
			complete = false,
			progress = 0,
			target = target,
			stepIndex = 1,
			stepProgress = 0,
		}
	end
	expedition.silentAtStation = true
end

local function objectiveDef(station: StationRegistry.StationDef, id: string): StationRegistry.ObjectiveDef?
	for _, def in station.objectives do
		if def.id == id then
			return def
		end
	end
	return nil
end

local function requirementsMet(expedition: Expedition, def: StationRegistry.ObjectiveDef): boolean
	if not def.requires then
		return true
	end
	for _, requiredId in def.requires do
		local progress = expedition.objectives[requiredId]
		if not progress or not progress.complete then
			return false
		end
	end
	return true
end

--- Marks an objective complete, awards it, and checks whether the station is
--- finished. Idempotent: completing twice grants once.
function ExpeditionService.completeObjective(expedition: Expedition, objectiveId: string)
	local station = currentStation(expedition)
	if not station then
		return
	end
	local progress = expedition.objectives[objectiveId]
	local def = objectiveDef(station, objectiveId)
	if not progress or not def or progress.complete then
		return
	end

	progress.complete = true
	progress.progress = progress.target

	local difficulty = GameConfig.getDifficulty(expedition.difficulty)
	for _, player in playersOf(expedition) do
		ProgressionService.award(player, {
			credits = math.floor(def.credits * difficulty.creditMultiplier),
			xp = math.floor(def.xp * difficulty.xpMultiplier),
			stats = if def.optional then { optional_objectives = 1 } else { unique_objectives_completed = 1 },
			source = "objective:" .. objectiveId,
		}, expedition.crewSize)
	end

	if def.optional then
		expedition.optionalCleared += 1
	end

	ExpeditionService.ThreatEvent:Fire(expedition, "objective_complete", Balance.Threat.objectiveCompleteRelief)
	ExpeditionService.ObjectiveCompleted:Fire(expedition, objectiveId, def.optional)
	ExpeditionService.fireRadio(expedition, "objective_complete", { station = station.id, objective = objectiveId })

	notify(expedition, "objective", "Objective complete", def.title, 5)
	ExpeditionService.push(expedition)

	-- Station complete when every required objective is done.
	local allRequired = true
	for _, candidate in station.objectives do
		if not candidate.optional then
			local candidateProgress = expedition.objectives[candidate.id]
			if not candidateProgress or not candidateProgress.complete then
				allRequired = false
				break
			end
		end
	end
	if allRequired then
		ExpeditionService.completeStation(expedition)
	end
end

--- Adds progress to a counting objective.
function ExpeditionService.addObjectiveProgress(expedition: Expedition, objectiveId: string, amount: number)
	local progress = expedition.objectives[objectiveId]
	if not progress or progress.complete then
		return
	end
	progress.progress = math.min(progress.target, progress.progress + amount)

	local station = currentStation(expedition)
	if station then
		local fraction = progress.progress / math.max(1, progress.target)
		ExpeditionService.fireRadio(expedition, "objective_progress", {
			station = station.id,
			objective = objectiveId,
			fraction = fraction,
		})
	end

	if progress.progress >= progress.target then
		ExpeditionService.completeObjective(expedition, objectiveId)
	else
		ExpeditionService.push(expedition)
	end
end

--- Advances a sequence objective to the next step.
function ExpeditionService.advanceStep(expedition: Expedition, objectiveId: string)
	local station = currentStation(expedition)
	if not station then
		return
	end
	local def = objectiveDef(station, objectiveId)
	local progress = expedition.objectives[objectiveId]
	if not def or not progress or progress.complete then
		return
	end
	local steps = def.params.steps or {}
	progress.stepIndex = math.min(#steps + 1, progress.stepIndex + 1)
	progress.stepProgress = 0
	progress.progress = progress.stepIndex - 1

	if progress.stepIndex > #steps then
		ExpeditionService.completeObjective(expedition, objectiveId)
	else
		local step = steps[progress.stepIndex]
		ExpeditionService.fireRadio(expedition, "step_start", { station = station.id, step = step.id })
		ExpeditionService.push(expedition)
	end
end

--- Advances any sequence objective whose current step is to collect an item
--- the crew now holds. Called whenever items are picked up. Nothing used to
--- do this, so "Find a ceramic fuse" at Marrow Halt could never complete and
--- the chapter could not be finished.
function ExpeditionService.checkCollectSteps(expedition: Expedition)
	local station = currentStation(expedition)
	if not station then
		return
	end
	for _ = 1, 4 do
		local advanced = false
		for _, def in station.objectives do
			local progress = expedition.objectives[def.id]
			if def.kind ~= "sequence" or not progress or progress.complete or not requirementsMet(expedition, def) then
				continue
			end
			local steps = def.params.steps or {}
			local step = steps[progress.stepIndex]
			if step and step.kind == "collect" and step.item then
				for _, player in playersOf(expedition) do
					if InventoryService.has(player, step.item, step.quantity or 1) then
						ExpeditionService.advanceStep(expedition, def.id)
						advanced = true
						break
					end
				end
			end
		end
		-- A step may be followed by another collect step already satisfied.
		if not advanced then
			return
		end
	end
end

--- Whether an incomplete objective at the current station needs this item.
--- Such items are always taken, even into a full inventory.
function ExpeditionService.needsItem(expedition: Expedition, itemId: string): boolean
	local station = currentStation(expedition)
	if not station then
		return false
	end
	for _, def in station.objectives do
		local progress = expedition.objectives[def.id]
		if def.optional or not progress or progress.complete then
			continue
		end
		if def.params.item == itemId then
			return true
		end
		for _, step in def.params.steps or {} do
			if step.item == itemId or (step.needsFuel and itemId == "fuel_can") then
				return true
			end
		end
	end
	return false
end

function ExpeditionService.currentStep(expedition: Expedition, objectiveId: string): StationRegistry.StepDef?
	local station = currentStation(expedition)
	if not station then
		return nil
	end
	local def = objectiveDef(station, objectiveId)
	local progress = expedition.objectives[objectiveId]
	if not def or not progress then
		return nil
	end
	local steps = def.params.steps
	if not steps then
		return nil
	end
	return steps[progress.stepIndex]
end

--------------------------------------------------------------------------
-- Station flow
--------------------------------------------------------------------------

function ExpeditionService.completeStation(expedition: Expedition)
	local station = currentStation(expedition)
	if not station then
		return
	end
	expedition.stationsCleared += 1

	local difficulty = GameConfig.getDifficulty(expedition.difficulty)
	for _, player in playersOf(expedition) do
		local stats: { [string]: number } = { stations_cleared = 1 }
		if expedition.silentAtStation then
			stats.silent_stations = 1
		end
		ProgressionService.award(player, {
			credits = math.floor(Balance.Economy.creditsPerStationCleared * difficulty.creditMultiplier),
			xp = math.floor(Balance.Economy.xpPerStationCleared * difficulty.xpMultiplier),
			stats = stats,
			source = "station:" .. station.id,
		}, expedition.crewSize)
	end

	ExpeditionService.fireRadio(expedition, "station_complete", { station = station.id })
	notify(expedition, "objective", station.name .. " clear", "Board the train and continue.", 7)

	-- The train is released to run to the next station on the route.
	local nextIndex = ExpeditionService.nextStationIndex(expedition)
	local nextStation = if nextIndex then StationRegistry.byIndex(nextIndex) else nil
	if nextStation then
		TrainService.setStopDistance(expedition.train, nextStation.distance)
		setState(expedition, "travelling")
	else
		-- Final station done: the chapter ends.
		ExpeditionService.finish(expedition, true)
	end
	ExpeditionService.push(expedition)
end

local function arriveAtStation(expedition: Expedition, index: number)
	local station = StationRegistry.byIndex(index)
	if not station then
		return
	end
	expedition.stationIndex = index
	initialiseObjectives(expedition, station)

	-- Power off, doors closed, lights dark: every station starts cold.
	setState(expedition, if station.index >= StationRegistry.count() then "climax" else "onstation")

	ExpeditionService.takeCheckpoint(expedition)
	ExpeditionService.StationReached:Fire(expedition, index)
	ExpeditionService.fireRadio(expedition, "station_approach", { station = station.id })
	notify(expedition, "info", station.name, station.subtitle, 7)
	ExpeditionService.push(expedition)
end

--------------------------------------------------------------------------
-- Checkpoints, failure and retry
--------------------------------------------------------------------------

-- How long the failure screen waits for a choice before retrying on its own.
local AUTO_RETRY_SECONDS = 30

--- Records what a retry restores: where the train stood, its fuel and
--- condition, and what everybody carried. Taken on reaching the line and on
--- arriving at each station, so a failure costs one station, never the run.
local function takeCheckpoint(expedition: Expedition)
	local inventories: { [number]: { { id: string, quantity: number } } } = {}
	for _, player in playersOf(expedition) do
		local inventory = InventoryService.get(player)
		if inventory then
			local copy = {}
			for _, stack in inventory.stacks do
				table.insert(copy, { id = stack.id, quantity = stack.quantity })
			end
			inventories[player.UserId] = copy
		end
	end
	expedition.checkpoint = {
		stationIndex = expedition.stationIndex,
		distance = expedition.train.distance,
		fuel = expedition.train.fuel,
		condition = expedition.train.condition,
		inventories = inventories,
	}
end

ExpeditionService.takeCheckpoint = takeCheckpoint

local function checkpointName(expedition: Expedition): string
	local checkpoint = expedition.checkpoint
	local station = if checkpoint then StationRegistry.byIndex(checkpoint.stationIndex) else nil
	return if station then station.name else "the start of the line"
end

--- The whole crew is dead. The run stops, and the crew chooses between
--- retrying from the last checkpoint and going back to the yard. Nothing
--- waits forever: with no choice made, it retries on its own.
function ExpeditionService.crewWiped(expedition: Expedition)
	if expedition.state == "failed" or expedition.state == "ending" or expedition.state == "closed" then
		return
	end
	setState(expedition, "failed")
	expedition.failedAt = os.clock()
	TrainService.setPilot(expedition.train, nil)
	expedition.train.throttle = 0
	expedition.train.serviceBrake = 1
	broadcast(expedition, "ExpeditionState", {
		state = "failed",
		id = expedition.id,
		stationName = checkpointName(expedition),
		autoRetrySeconds = AUTO_RETRY_SECONDS,
	})
	ExpeditionService.fireRadio(expedition, "expedition_failure")
	log.info(string.format("expedition %s failed; crew wiped", expedition.id))

	local failedAt = expedition.failedAt
	expedition.maid:Give(task.delay(AUTO_RETRY_SECONDS, function()
		if expedition.state == "failed" and expedition.failedAt == failedAt then
			ExpeditionService.retry(expedition)
		end
	end))
end

--- Puts the crew back at the last checkpoint: the station's objectives and
--- fixtures reset, the train where it stood with the fuel and condition it
--- had, everybody alive and carrying what they carried, threats cleared.
function ExpeditionService.retry(expedition: Expedition)
	if expedition.state ~= "failed" then
		return
	end
	local checkpoint = expedition.checkpoint
	if not checkpoint then
		ExpeditionService.finish(expedition, false)
		return
	end
	expedition.retries += 1

	-- The station itself.
	local index = checkpoint.stationIndex
	expedition.stationIndex = index
	-- Stations before the checkpoint stay cleared; the checkpoint station is
	-- played again, so it must not be counted twice.
	if index > 0 then
		expedition.stationsCleared = math.max(0, (table.find(expedition.route, index) or 1) - 1)
	end
	if index > 0 then
		WorldService.resetStation(expedition.lane, index)
		local station = StationRegistry.byIndex(index)
		if station then
			initialiseObjectives(expedition, station)
		end
	end
	expedition.lane.dropContainer:ClearAllChildren()

	-- The train.
	local train = expedition.train
	TrainService.place(train, checkpoint.distance)
	train.fuel = checkpoint.fuel
	train.condition = checkpoint.condition
	train.engineRunning = true
	train.overheating = false
	train.throttle = 0
	train.serviceBrake = 1
	train.direction = 1
	TrainService.applyLights(train)
	local nextStation = StationRegistry.byIndex(if index > 0 then index else 1)
	TrainService.setStopDistance(train, if index > 0 then checkpoint.distance else (nextStation and nextStation.distance))

	-- The crew: inventories restored, characters respawned aboard. Vitals,
	-- creatures and threat are reset by the services listening to Retried.
	for _, player in playersOf(expedition) do
		local stacks = checkpoint.inventories[player.UserId]
		if stacks then
			InventoryService.restore(player, stacks)
		end
		player:LoadCharacter()
		ExpeditionService.spawnIntoTrain(expedition, player)
	end

	ExpeditionService.Retried:Fire(expedition)
	local stationDef = StationRegistry.byIndex(index)
	setState(
		expedition,
		if index == 0 then "travelling" elseif stationDef and stationDef.index >= StationRegistry.count() then "climax" else "onstation"
	)
	notify(expedition, "info", "Back at " .. checkpointName(expedition), "The train is as you left it. Try another way.", 7)
	log.info(string.format("expedition %s retried from station %d (retry %d)", expedition.id, index, expedition.retries))
end

--------------------------------------------------------------------------
-- Client state
--------------------------------------------------------------------------

local function describe(expedition: Expedition): { [string]: any }
	local station = currentStation(expedition)
	local objectives = {}
	if station then
		for _, def in station.objectives do
			local progress = expedition.objectives[def.id]
			if progress and requirementsMet(expedition, def) then
				local stepText: string? = nil
				if def.kind == "sequence" then
					local steps = def.params.steps or {}
					local step = steps[progress.stepIndex]
					if step then
						stepText = step.text
					end
				end
				table.insert(objectives, {
					id = def.id,
					title = def.title,
					detail = def.detail,
					optional = def.optional,
					complete = progress.complete,
					progress = progress.progress,
					target = progress.target,
					stepText = stepText,
					stepProgress = progress.stepProgress,
				})
			end
		end
	end

	return {
		id = expedition.id,
		state = expedition.state,
		stationIndex = expedition.stationIndex,
		stationCount = #expedition.route,
		stationName = if station then station.name else nil,
		stationSubtitle = if station then station.subtitle else nil,
		difficulty = expedition.difficulty,
		objectives = objectives,
		elapsed = os.clock() - expedition.startedAt,
		crewSize = expedition.crewSize,
		storyClock = Format.storyClock((os.clock() - expedition.startedAt) / 60),
	}
end

function ExpeditionService.push(expedition: Expedition)
	broadcast(expedition, "ExpeditionState", describe(expedition))
end

--------------------------------------------------------------------------
-- Spawning players
--------------------------------------------------------------------------

local function spawnIntoTrain(expedition: Expedition, player: Player)
	local train = expedition.train

	-- Spawn in the cab, not the carriage.
	--
	-- The locomotive and the first carriage are separate vehicles with couplers
	-- between them and no interior gangway, which is prototypical but means a
	-- player who spawns in the carriage cannot reach the controls while the
	-- train is moving. Since driving is the only way an expedition progresses,
	-- spawning anywhere else made the game uncompletable.
	local anchor: CFrame
	local cabSeat = train.built.cab.driverSeat
	if cabSeat and cabSeat.Parent then
		anchor = cabSeat.CFrame * CFrame.new(0, 1, 4)
	else
		local carriage = train.built.carriages[1] or train.built.model
		anchor = carriage:GetPivot()
	end

	local function place(character: Model)
		local root = character:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then
			-- Spread arrivals so a crew of six does not stack inside one another.
			local offset = Vector3.new(math.random(-2, 2), 1, math.random(-2, 3))
			root.CFrame = anchor * CFrame.new(offset)
		end
	end

	if player.Character and player.Character.Parent then
		place(player.Character)
	else
		player.CharacterAdded:Once(function(character)
			task.wait(0.1)
			place(character)
		end)
		player:LoadCharacter()
	end
end

ExpeditionService.spawnIntoTrain = spawnIntoTrain

--------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------

function ExpeditionService.begin(crew: CrewService.Crew, members: { Player })
	nextExpeditionNumber += 1
	local id = string.format("exp_%d", nextExpeditionNumber)

	-- Tell the crew what is happening before anything slow starts, so nobody
	-- sits looking at an unexplained loading screen.
	for _, player in members do
		Net.fireClient("ExpeditionState", player, { state = "preparing", id = id, progress = 0, label = "Claiming the line" })
		ShopService.setBlockedState(player, "loading")
	end

	local lane = WorldService.claimLane(crew.id, function(fraction, label)
		for _, player in members do
			Net.fireClient("ExpeditionState", player, { state = "preparing", id = id, progress = fraction, label = label })
		end
	end)

	local function abandonStart(title: string, body: string, reason: string)
		for _, player in members do
			Net.fireClient("Notify", player, { kind = "error", title = title, body = body, duration = 10 })
			Net.fireClient("ExpeditionState", player, { state = "cancelled", id = id })
			ShopService.setBlockedState(player, nil)
		end
		CrewService.close(crew, reason)
	end

	if not lane then
		-- Every lane is busy. This is a real limit of single-place mode and the
		-- crew is told plainly rather than left waiting.
		abandonStart(
			"The line is occupied",
			string.format(
				"All %d expedition lines on this server are in use. Try another server, or wait for a crew to return.",
				GameConfig.MaxConcurrentExpeditions
			),
			"no lane available"
		)
		return
	end

	local leader = Players:GetPlayerByUserId(crew.leaderUserId)
	local leaderProfile = if leader then DataService.getProfile(leader) else nil
	local livery = if leaderProfile then leaderProfile.loadout.livery else nil
	local interior = if leaderProfile then leaderProfile.loadout.interior else nil

	-- The train at Platform 1 is the crew's train. If it is out on a run, the
	-- crew waits for the next one and is told so.
	for _, player in members do
		Net.fireClient("ExpeditionState", player, { state = "preparing", id = id, progress = 1, label = "Calling the train" })
	end
	local service = DepartureService.reserve(crew.id, crew.trainId, livery, interior, function(message)
		for _, player in members do
			Net.fireClient("Notify", player, { kind = "info", title = "Platform 1", body = message, duration = 8 })
		end
	end)
	if service then
		-- The 02:17 is an ordinary service until the rear carriage: people
		-- in the seats, visible from the platform and on the way aboard.
		Prologue.seatPassengers(service.train)
	end
	if not service then
		WorldService.releaseLane(lane)
		abandonStart(
			"No train is available",
			"No service reached Platform 1 in time. You are back in the yard; try departing again.",
			"no service"
		)
		return
	end
	local yard = service :: DepartureService.Service

	local memberIds: { number } = {}
	for _, player in members do
		table.insert(memberIds, player.UserId)
	end

	-- The expedition train waits inside the tunnel at the start of the line.
	-- It is the same type, livery and interior as the yard train, so the crew
	-- crosses into an identical carriage.
	local halfLength = TrainBuilder.lengthOf(yard.trainId) * 0.5
	local trainOrigin = CFrame.new(lane.origin + Vector3.new(0, 0, -halfLength))
	local train = TrainService.spawn(crew.id, yard.trainId, yard.liveryId, yard.interiorId, trainOrigin, lane.trainContainer, {
		doorsOpen = false,
	})

	local expedition: Expedition = {
		id = id,
		crewId = crew.id,
		lane = lane,
		train = train,
		difficulty = crew.difficulty,
		crewSize = #members,
		state = "preparing",
		stationIndex = 0,
		objectives = {},
		startedAt = os.clock(),
		stationsCleared = 0,
		optionalCleared = 0,
		revives = 0,
		downs = 0,
		shotsFired = 0,
		falseInstructionsIgnored = 0,
		falseInstructionsFollowed = 0,
		discoveriesFound = {},
		recordingsFound = {},
		firedBeats = {},
		silentAtStation = true,
		leverCode = { math.random(1, 3), math.random(1, 3), math.random(1, 3), math.random(1, 3) },
		checkpoint = nil,
		retries = 0,
		failedAt = nil,
		maid = Maid.new(),
		members = memberIds,
		route = (function()
			local all = {}
			for i = 1, StationRegistry.count() do
				table.insert(all, i)
			end
			return all
		end)(),
		mode = "story",
	}

	expeditions[id] = expedition
	crew.expeditionId = id
	TrainService.setSubscribers(crew.id, members)

	-- Carry capacity bonuses that a crew member shares with the whole crew.
	local sharedSlots, sharedWeight = 0, 0
	for _, player in members do
		local profile = DataService.getProfile(player)
		if profile then
			for productKey, count in profile.purchases.products do
				if count > 0 then
					local Monetization = require(Shared.Config.Monetization)
					local def = Monetization.get(productKey)
					if def and def.id > 0 and def.grants.sharedWithCrew then
						sharedSlots = math.max(sharedSlots, def.grants.inventorySlots or 0)
						sharedWeight = math.max(sharedWeight, def.grants.carryWeight or 0)
					end
				end
			end
		end
	end

	for _, player in members do
		playerExpedition[player.UserId] = id
		InventoryService.create(player, yard.trainId, sharedSlots, sharedWeight)
		InventoryService.bindCrewStore(crew.id, player)
		ProgressionService.addStat(player, "expeditions_started", 1)
		DataService.update(player, function(p)
			p.activeExpedition = { crewId = crew.id, stationIndex = 0, startedAt = os.time() }
		end)
		-- Starting kit, so nobody begins with nothing.
		InventoryService.add(player, "bandage", 2)
		InventoryService.add(player, "battery", 1)
	end

	InventoryService.configureDrops(lane.dropContainer, WorldService.buildDroppedItem)

	------------------------------------------------------------------
	-- Boarding: the crew walks onto the train at Platform 1.
	------------------------------------------------------------------
	setState(expedition, "boarding")
	local boardTarget = yard.train.built.carriages[1] or yard.train.built.model
	DepartureService.board(yard, function()
		return playersOf(expedition)
	end, function(missing, remaining)
		local names: { string } = {}
		for _, player in missing do
			table.insert(names, player.DisplayName)
		end
		broadcast(expedition, "Boarding", {
			state = "boarding",
			target = boardTarget,
			missing = names,
			remaining = remaining,
			total = #expedition.members,
		})
	end)
	if expedition.state == "closed" then
		DepartureService.release(yard)
		return
	end
	broadcast(expedition, "Boarding", { state = "aboard" })

	------------------------------------------------------------------
	-- Departure: doors close, the yard pilot takes the train out, and the
	-- opening sequence films it leaving.
	------------------------------------------------------------------
	DepartureService.depart(yard, expedition.members)
	setState(expedition, "cinematic")
	broadcast(expedition, "Cinematic", {
		action = "play",
		duration = GameConfig.CinematicSeconds,
		skippableAfter = GameConfig.CinematicSkippableAfter,
		trainModel = yard.train.built.model,
		trainCFrame = yard.train.built.root.CFrame,
		carriageModel = yard.train.built.carriages[1],
		driverUserId = members[1] and members[1].UserId or 0,
	})
	-- The passengers go between the bang and the look back down the aisle.
	-- Timed to the shots in CameraController; it happens even if the crew
	-- skipped the sequence, because it happens to the train, not the camera.
	task.delay(6.8, function()
		local rear = yard.train.built.carriages[#yard.train.built.carriages] or yard.train.built.model
		broadcast(expedition, "HorrorCue", { cue = "train_coupler", position = rear:GetPivot().Position })
		broadcast(expedition, "HorrorCue", { cue = "lights_flicker", position = yard.train.built.root.Position, seconds = 2.6 })
	end)
	task.delay(8.3, function()
		Prologue.vanish(yard.train)
	end)

	local platformDistance, tunnelDistance = DepartureService.lobbyGeometry()
	-- Start streaming the line in for each member while the train is still
	-- in the yard, so it is there when they arrive.
	DepartureService.waitForDistance(yard, platformDistance + (tunnelDistance - platformDistance) * 0.6, 60)
	local laneFocus = train.built.root.Position
	for _, player in playersOf(expedition) do
		task.spawn(function()
			pcall(function()
				player:RequestStreamAroundAsync(laneFocus, 6)
			end)
		end)
	end
	DepartureService.waitForDistance(yard, tunnelDistance, 45)
	if expedition.state == "closed" then
		DepartureService.retire(yard)
		return
	end

	------------------------------------------------------------------
	-- The tunnel: in the dark, the crew crosses from the yard train to the
	-- expedition train, standing exactly where they were.
	------------------------------------------------------------------
	broadcast(expedition, "ScreenFade", { action = "out", seconds = 0.6 })
	task.wait(0.75)
	ExpeditionService.crossToLine(expedition, yard)
	DepartureService.retire(yard)
	broadcast(expedition, "Cinematic", { action = "stop" })
	broadcast(expedition, "ScreenFade", { action = "in", seconds = 1.4 })
	ExpeditionService.arriveOnLine(expedition)

	log.info(string.format("expedition %s begun on lane %d with %d crew", id, lane.index, #members))
end

--- Moves every crew member from the yard train to the expedition train,
--- keeping each one's position and facing relative to the train. Anybody who
--- is somehow not aboard the yard train is put in the cab instead.
function ExpeditionService.crossToLine(expedition: Expedition, yard: DepartureService.Service)
	local yardRoot = yard.train.built.root.CFrame
	local train = expedition.train
	local lineRoot = train.built.root.CFrame
	-- Where each crew member stands, relative to the train rather than the
	-- world: the train is moving, so a world position is stale a moment later.
	local cabRelative = lineRoot:ToObjectSpace(train.built.cab.driverSeat.CFrame * CFrame.new(0, 1, 4))
	local relatives: { [Player]: CFrame } = {}

	-- The expedition train takes over the yard train's motion, so nothing
	-- jolts: it emerges from the tunnel still rolling and coasts to a stand.
	train.direction = 1
	train.speed = yard.train.speed
	train.throttle = 0
	train.serviceBrake = 0
	TrainService.publishMotion(train, true)
	local model = train.built.model
	local motion = {
		origin = train.origin,
		distance = train.distance,
		velocity = train.speed,
		sampleTime = workspace:GetServerTimeNow(),
	}

	for _, player in playersOf(expedition) do
		local character = player.Character
		local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
		local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
		if not character or not root or not root:IsA("BasePart") or not humanoid then
			spawnIntoTrain(expedition, player)
			continue
		end
		-- A seated passenger is welded into the yard train's anchored assembly,
		-- which takes the character out of its own client's control. Leave the
		-- seat before crossing.
		if humanoid.SeatPart then
			local weld = humanoid.SeatPart:FindFirstChild("SeatWeld")
			if weld then
				weld:Destroy()
			end
			humanoid.Sit = false
		end
		local relative = if TrainService.isInside(yard.train, root.Position, 3)
			then yardRoot:ToObjectSpace(character:GetPivot())
			else cabRelative
		relatives[player] = relative
		-- The client owns its character, so it makes the move itself, tracking
		-- the moving train until the train has streamed in around it. A move
		-- written only by the server was lost in testing when the character
		-- had just left a seat on the yard train.
		Net.fireClient("CrossToLine", player, {
			relative = relative,
			model = model,
			origin = motion.origin,
			distance = motion.distance,
			velocity = motion.velocity,
			sampleTime = motion.sampleTime,
		})
		character:PivotTo(lineRoot * relative)
	end

	-- Check that everybody is actually aboard, and put anyone who is not
	-- back in their place on the train from the server.
	task.delay(2.5, function()
		for player, relative in relatives do
			local character = player.Character
			if character and character.Parent and not TrainService.isInside(train, character:GetPivot().Position, 2) then
				log.warn(string.format("%s did not cross to the line; placing them from the server", player.Name))
				character:PivotTo(train.built.root.CFrame * relative)
			end
		end
	end)
end

--- The crew is on the line. Hand over to the travelling state and point the
--- crew at the cab.
function ExpeditionService.arriveOnLine(expedition: Expedition)
	if expedition.state == "closed" then
		return
	end
	TrainService.setStopDistance(expedition.train, StationRegistry.Stations[1].distance)
	-- Studio test hook: a server-set "StartAtStation" attribute on the crew
	-- leader starts the run just short of that station. Inert outside Studio.
	local leader = Players:GetPlayerByUserId(expedition.members[1] or 0)
	local startAt = if leader and game:GetService("RunService"):IsStudio() then tonumber(leader:GetAttribute("StartAtStation")) else nil
	local startStation = if startAt then StationRegistry.byIndex(startAt) else nil
	if startStation and startAt and startAt > 1 then
		TrainService.place(expedition.train, startStation.distance - 400)
		expedition.stationIndex = startAt - 1
		TrainService.setStopDistance(expedition.train, startStation.distance)
		log.warn(string.format("TEST: starting %s short of %s", expedition.id, startStation.name))
	end
	setState(expedition, "travelling")
	ExpeditionService.takeCheckpoint(expedition)

	-- The other side of the crossing: what is left, where the yard went,
	-- and who answers.
	Prologue.leaveBelongings(expedition.train)
	Prologue.placeNameboard(expedition.train, expedition.lane.dropContainer)
	notify(
		expedition,
		"info",
		"02:17, Up Main",
		"Every passenger is gone. The cab is at the front: take the driver's seat.",
		8
	)
	local function say(attribution: string, text: string, duration: number, source: string?)
		broadcast(expedition, "RadioMessage", { id = "prologue", source = source or "crew", text = text, duration = duration, attribution = attribution, isFalse = false })
	end
	local steps: { { at: number, run: () -> () } } = {
		{ at = 3, run = function() say("Driver", "Control, this is the zero two seventeen. My passengers are gone. All of them. Control, do you read?", 6) end },
		{ at = 10, run = function() say("Radio", "[Static. Nothing from Control.]", 4, "recording") end },
		{ at = 14, run = function() say("Driver", "That's our yard's nameboard. In the trees. Where's the yard?", 5) end },
		{ at = 20, run = function() ExpeditionService.fireRadio(expedition, "expedition_start") end },
		{ at = 23, run = function() broadcast(expedition, "Cinematic", { action = "title" }) end },
		{ at = 40, run = function() say("Driver", "That answered before I'd finished asking. And it said we're the last one out. Out of where?", 7) end },
	}
	for _, step in steps do
		task.delay(step.at, function()
			if expedition.state ~= "closed" then
				step.run()
			end
		end)
	end
end

local cinematicSkipVotes: { [string]: { [number]: boolean } } = {}

--- Ends the opening sequence's camera work early (a crew skip vote). The
--- departure itself carries on: the train is really moving, and the crew
--- rides the rest of it in first person.
function ExpeditionService.endCinematic(expedition: Expedition)
	if expedition.state ~= "cinematic" then
		return
	end
	broadcast(expedition, "Cinematic", { action = "stop" })
end

--------------------------------------------------------------------------
-- Ending
--------------------------------------------------------------------------

function ExpeditionService.finish(expedition: Expedition, success: boolean)
	if expedition.state == "ending" or expedition.state == "closed" then
		return
	end
	setState(expedition, "ending")
	expedition.success = success
	local endedAt = os.clock()
	expedition.endedAt = endedAt

	local difficulty = GameConfig.getDifficulty(expedition.difficulty)
	local elapsed = endedAt - expedition.startedAt

	ExpeditionService.fireRadio(expedition, if success then "expedition_success" else "expedition_failure")

	for _, player in playersOf(expedition) do
		local stats: { [string]: number } = {}
		if success then
			stats.expeditions_completed = 1
			if expedition.stationsCleared >= StationRegistry.count() and #expedition.route >= StationRegistry.count() then
				stats.full_line_runs = 1
			end
			if expedition.difficulty == "blackout" then
				stats.expeditions_completed_blackout = 1
			elseif expedition.difficulty == "derelict" then
				stats.expeditions_completed_derelict = 1
			end
			if expedition.crewSize >= 4 then
				stats.large_crew_completions = 1
			end
			if expedition.downs == 0 then
				stats.flawless_expeditions = 1
			end
			if expedition.falseInstructionsFollowed == 0 then
				stats.clean_signal_runs = 1
			end
		else
			stats.expeditions_failed = 1
		end

		local baseCredits = if success
			then Balance.Economy.creditsPerExpeditionComplete
			else math.floor(Balance.Economy.creditsPerExpeditionComplete * Balance.Economy.creditsFailurePenaltyFraction)
		local baseXp = if success then Balance.Economy.xpPerExpeditionComplete else math.floor(Balance.Economy.xpPerExpeditionComplete * 0.4)

		local result = ProgressionService.award(player, {
			credits = math.floor(baseCredits * difficulty.creditMultiplier),
			xp = math.floor(baseXp * difficulty.xpMultiplier),
			stats = stats,
			source = "expedition_end",
		}, expedition.crewSize)

		Net.fireClient("ExpeditionState", player, {
			state = "results",
			success = success,
			elapsed = elapsed,
			stationsCleared = expedition.stationsCleared,
			stationCount = #expedition.route,
			optionalCleared = expedition.optionalCleared,
			revives = expedition.revives,
			downs = expedition.downs,
			discoveries = (function()
				local n = 0
				for _ in expedition.discoveriesFound do
					n += 1
				end
				return n
			end)(),
			falseIgnored = expedition.falseInstructionsIgnored,
			falseFollowed = expedition.falseInstructionsFollowed,
			credits = result.credits,
			xp = result.xp,
			level = result.newLevel,
			levelsGained = result.levelsGained,
			difficulty = expedition.difficulty,
			journey = if ExpeditionService.resultsExtra then ExpeditionService.resultsExtra(expedition, player, success) else nil,
			signals = if ExpeditionService.resultsSignals then ExpeditionService.resultsSignals(expedition) else nil,
		})
	end

	-- Results are read, then the crew goes home. The delay is generous because
	-- being yanked out of a results screen is a bad last impression.
	expedition.maid:Give(task.delay(18, function()
		ExpeditionService.close(expedition)
	end))
end

function ExpeditionService.close(expedition: Expedition)
	if expedition.state == "closed" then
		return
	end
	expedition.state = "closed"

	local lobby = WorldService.getLobby()
	for _, player in playersOf(expedition) do
		playerExpedition[player.UserId] = nil
		InventoryService.destroy(player)
		ShopService.setBlockedState(player, nil)
		DataService.update(player, function(p)
			p.activeExpedition = {}
		end)
		-- Back to the yard. Respawning in the lobby is the definite resolution
		-- that stops anybody being stranded in an unloaded lane.
		if lobby then
			local spawnCF = lobby.spawnCFrames[math.random(1, #lobby.spawnCFrames)]
			if player.Character and player.Character.Parent then
				player.Character:PivotTo(spawnCF)
			else
				player.CharacterAdded:Once(function(character)
					task.wait(0.1)
					character:PivotTo(spawnCF)
				end)
				player:LoadCharacter()
			end
		end
		Net.fireClient("ExpeditionState", player, { state = "lobby" })
	end

	InventoryService.releaseCrewStore(expedition.crewId)
	TrainService.despawn(expedition.crewId)
	TrainService.setSubscribers(expedition.crewId, {})
	WorldService.releaseLane(expedition.lane)
	expedition.maid:Destroy()
	expeditions[expedition.id] = nil
	radioBusyUntil[expedition.id] = nil
	cinematicSkipVotes[expedition.id] = nil

	local crew = CrewService.crewById(expedition.crewId)
	if crew then
		CrewService.close(crew, "expedition ended")
	end

	ExpeditionService.Ended:Fire(expedition, expedition.success == true)
	log.info(string.format("expedition %s closed", expedition.id))
end

--------------------------------------------------------------------------
-- Accessors
--------------------------------------------------------------------------

function ExpeditionService.forPlayer(player: Player): Expedition?
	local id = playerExpedition[player.UserId]
	return if id then expeditions[id] else nil
end

function ExpeditionService.byId(id: string): Expedition?
	return expeditions[id]
end

function ExpeditionService.all(): { Expedition }
	local out = {}
	for _, expedition in expeditions do
		table.insert(out, expedition)
	end
	return out
end

--- Records a discovery once per expedition and awards it.
function ExpeditionService.recordDiscovery(expedition: Expedition, player: Player, discoveryId: string)
	if expedition.discoveriesFound[discoveryId] then
		return
	end
	expedition.discoveriesFound[discoveryId] = true
	DataService.update(player, function(p)
		p.discoveries[discoveryId] = true
	end)
	ProgressionService.award(player, {
		credits = Balance.Economy.creditsPerCollectible,
		xp = 25,
		stats = { discoveries_found = 1 },
		source = "discovery:" .. discoveryId,
	}, expedition.crewSize)
end

function ExpeditionService.recordRecording(expedition: Expedition, player: Player, recordingId: string)
	if expedition.recordingsFound[recordingId] then
		return
	end
	expedition.recordingsFound[recordingId] = true
	local wasNew = false
	DataService.update(player, function(p)
		if not p.recordings[recordingId] then
			p.recordings[recordingId] = true
			wasNew = true
		end
	end)
	if wasNew then
		local count = 0
		local profile = DataService.getProfile(player)
		if profile then
			for _ in profile.recordings do
				count += 1
			end
		end
		ProgressionService.setStatMax(player, "unique_recordings", count)
	end
	ProgressionService.addStat(player, "records_found", 1)
end

--- Called by CombatService: a gunshot at a station ends the silent bonus.
function ExpeditionService.noteWeaponFired(expedition: Expedition, loud: boolean)
	expedition.shotsFired += 1
	if loud then
		expedition.silentAtStation = false
	end
end

--------------------------------------------------------------------------

function ExpeditionService.start()
	CrewService.CrewDeparted:Connect(function(crew, members)
		task.spawn(function()
			local ok, err = Protect.call(ExpeditionService.begin, crew, members)
			if not ok then
				log.error("expedition start failed:", tostring(err))
				for _, player in members do
					Net.fireClient("Notify", player, {
						kind = "error",
						title = "The expedition could not start",
						body = "Something went wrong preparing the line. You have been returned to the yard.",
						duration = 10,
					})
					Net.fireClient("ExpeditionState", player, { state = "lobby" })
					ShopService.setBlockedState(player, nil)
				end
				CrewService.close(crew, "start failed")
			end
		end)
	end)

	-- Items also reach players through the supply rack and from crewmates,
	-- which do not pass through the pickup paths; a slow sweep catches those.
	task.spawn(function()
		while true do
			task.wait(1)
			for _, expedition in expeditions do
				if expedition.state == "onstation" or expedition.state == "climax" then
					Protect.call(ExpeditionService.checkCollectSteps, expedition)
				end
			end
		end
	end)

	-- Arrival at a station is driven by the train reaching its stop distance.
	TrainService.ArrivedAt:Connect(function(train, distance)
		for _, expedition in expeditions do
			if expedition.train == train then
				for index, station in StationRegistry.Stations do
					-- Only stations on this run's route are stops; the cut-off
					-- runs straight past Ninety-Three.
					if math.abs(station.distance - distance) < 2 and index ~= expedition.stationIndex and table.find(expedition.route, index) then
						arriveAtStation(expedition, index)
						break
					end
				end
				break
			end
		end
	end)

	-- A stalled train between stations is a failure state only when it cannot
	-- be recovered: with fuel in the supply rack, the crew can restart it.
	TrainService.Stalled:Connect(function(train, reason)
		for _, expedition in expeditions do
			if expedition.train == train then
				notify(
					expedition,
					"warning",
					if reason == "fuel" then "The engine has run dry" else "The engine has failed",
					if reason == "fuel" then "Refuel at the engine bay to restart." else "Repair at the engine bay to restart.",
					10
				)
				ExpeditionService.fireRadio(expedition, if reason == "fuel" then "train_low_fuel" else "train_low_condition")
				break
			end
		end
	end)

	Net.onServerEvent("CinematicSkip", function(player)
		local expedition = ExpeditionService.forPlayer(player)
		if not expedition or expedition.state ~= "cinematic" then
			return
		end
		local votes: { [number]: boolean } = cinematicSkipVotes[expedition.id] or {}
		cinematicSkipVotes[expedition.id] = votes
		votes[player.UserId] = true

		local count = 0
		for _ in votes do
			count += 1
		end
		local needed = math.ceil(#playersOf(expedition) / 2)
		broadcast(expedition, "Cinematic", { action = "skipvote", votes = count, needed = needed })
		if count >= needed then
			ExpeditionService.endCinematic(expedition)
		end
	end)

	Net.onServerInvoke("ExpeditionCommand", function(player, rawCommand)
		local command = Guard.enum(rawCommand, { "state", "abandon", "retry" })
		if not command then
			return { ok = false, error = "BAD_COMMAND" }
		end
		local expedition = ExpeditionService.forPlayer(player)
		if not expedition then
			return { ok = false, error = "NO_EXPEDITION" }
		end
		if command == "state" then
			return { ok = true, expedition = describe(expedition) }
		end
		if command == "retry" then
			if expedition.state ~= "failed" then
				return { ok = false, error = "NOT_FAILED" }
			end
			ExpeditionService.retry(expedition)
			return { ok = true }
		end
		-- Abandoning is per-player: it returns you to the lobby without ending
		-- the run for everybody else.
		playerExpedition[player.UserId] = nil
		InventoryService.destroy(player)
		local index = table.find(expedition.members, player.UserId)
		if index then
			table.remove(expedition.members, index)
		end
		ShopService.setBlockedState(player, nil)
		local lobby = WorldService.getLobby()
		local humanoid = if player.Character then player.Character:FindFirstChildOfClass("Humanoid") else nil
		if not humanoid or humanoid.Health <= 0 then
			-- A dead player respawns, and the spawn handler puts anybody not on
			-- an expedition in the yard.
			player:LoadCharacter()
		elseif lobby and player.Character then
			player.Character:PivotTo(lobby.spawnCFrames[1])
		end
		Net.fireClient("ExpeditionState", player, { state = "lobby" })
		if #expedition.members == 0 then
			ExpeditionService.close(expedition)
		end
		return { ok = true }
	end)

	Players.PlayerRemoving:Connect(function(player)
		local expedition = ExpeditionService.forPlayer(player)
		if not expedition then
			return
		end
		playerExpedition[player.UserId] = nil
		-- The member is kept in the list during the reconnect grace so their
		-- slot and their crew survive a dropped connection.
		task.delay(GameConfig.ReconnectGraceSeconds, function()
			if expedition.state == "closed" then
				return
			end
			if Players:GetPlayerByUserId(player.UserId) then
				return
			end
			local index = table.find(expedition.members, player.UserId)
			if index then
				table.remove(expedition.members, index)
			end
			if #expedition.members == 0 then
				ExpeditionService.close(expedition)
			end
		end)
	end)

	-- Reconnecting mid-expedition puts the player back with their crew.
	Players.PlayerAdded:Connect(function(player)
		task.wait(1)
		for _, expedition in expeditions do
			if table.find(expedition.members, player.UserId) and expedition.state ~= "closed" then
				playerExpedition[player.UserId] = expedition.id
				InventoryService.create(player, expedition.train.def.id)
				InventoryService.bindCrewStore(expedition.crewId, player)
				spawnIntoTrain(expedition, player)
				Net.fireClient("Notify", player, {
					kind = "info",
					title = "Welcome back",
					body = "You have rejoined your crew. Your inventory did not survive the disconnect.",
					duration = 8,
				})
				ExpeditionService.push(expedition)
				break
			end
		end
	end)

	log.info("started")
end

return ExpeditionService
