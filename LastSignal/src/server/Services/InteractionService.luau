--!strict
--[[
	InteractionService
	------------------
	Everything a player can walk up to and use.

	One remote, one validator, one place where "can this player do this right
	now" is decided. Searching a locker, throwing a breaker, fitting a valve,
	refuelling the train, picking up a dropped can and reading a recording all
	arrive here and are checked the same way:

	  the target exists, is in the world, and belongs to this player's lane
	  the player is alive and within reach of it
	  the action is valid for this target in its current state
	  any prerequisite item is genuinely held

	The client sends the target instance and an action name. It never sends an
	outcome, a quantity or a position, so there is nothing useful to forge.

	Held actions (searching, repairing, priming pumps) are tracked server-side
	with a start time and validated on completion, so a client cannot claim a
	nine-second repair finished instantly.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.LastSignal

local Balance = require(Shared.Config.Balance)
local Guard = require(Shared.Core.Guard)
local Logger = require(Shared.Core.Logger)
local Net = require(Shared.Core.Net)
local Signal = require(Shared.Core.Signal)
local ItemRegistry = require(Shared.Registry.ItemRegistry)
local RadioScript = require(Shared.Registry.RadioScript)
local StationRegistry = require(Shared.Registry.StationRegistry)

local ExpeditionService = require(script.Parent.ExpeditionService)
local InventoryService = require(script.Parent.InventoryService)
local ProgressionService = require(script.Parent.ProgressionService)
local TrainService = require(script.Parent.TrainService)
local WorldService = require(script.Parent.WorldService)

local log = Logger.new("InteractionService")

local InteractionService = {}

InteractionService.FixtureOperated = Signal.new() :: Signal.Signal<string, Player, BasePart>
InteractionService.NoiseMade = Signal.new() :: Signal.Signal<Vector3, number, Player?>
-- A RunTask hold finished: the player, the part, and whether a consumable
-- was spent to do it faster.
InteractionService.RunTaskDone = Signal.new() :: Signal.Signal<Player, BasePart, boolean>
-- Set by JourneyService: the earned Lineman's toolkit shortens night-run tasks.
InteractionService.holdScale = nil :: ((Player) -> number)?

local MAX_REACH = 12

--- Attributes come back as an unknown union, so every numeric read goes
--- through here rather than being cast at each call site.
local function numberAttribute(instance: Instance, name: string, default: number): number
	local value = instance:GetAttribute(name)
	if type(value) == "number" and value == value then
		return value
	end
	return default
end

--------------------------------------------------------------------------
-- Held actions
--------------------------------------------------------------------------

type HeldAction = {
	target: Instance,
	action: string,
	startedAt: number,
	duration: number,
	position: Vector3,
}

local held: { [number]: HeldAction } = {}

local function beginHold(player: Player, target: Instance, action: string, duration: number, position: Vector3)
	held[player.UserId] = {
		target = target,
		action = action,
		startedAt = os.clock(),
		duration = duration,
		position = position,
	}
	Net.fireClient("InteractResult", player, { ok = true, action = "hold_start", duration = duration, target = target })
end

--- Validates a completion claim. The server owns the clock, so a client that
--- reports finishing early is simply refused.
local function completeHold(player: Player, target: Instance, action: string): boolean
	local entry = held[player.UserId]
	if not entry then
		return false
	end
	if entry.target ~= target or entry.action ~= action then
		return false
	end
	-- A small tolerance absorbs network jitter, nothing more.
	if (os.clock() - entry.startedAt) < entry.duration - 0.25 then
		return false
	end
	local root = Guard.aliveRoot(player)
	-- Against where the target is now: a job on a moving train moves with
	-- the player, and the position at the start of the hold is left behind.
	local position = if entry.target:IsA("BasePart") then (entry.target :: BasePart).Position else entry.position
	if not root or not Guard.withinDistance(root.Position, position, MAX_REACH + 4) then
		return false
	end
	held[player.UserId] = nil
	return true
end

function InteractionService.cancelHold(player: Player)
	held[player.UserId] = nil
end

--------------------------------------------------------------------------
-- Loot
--------------------------------------------------------------------------

local function rollLootNode(node: BasePart, expedition: ExpeditionService.Expedition): { { id: string, quantity: number } }
	local lane = expedition.lane
	local contents: { { id: string, quantity: number } } = {}

	-- Find the node's declaration so guaranteed contents are honoured.
	local guaranteed: { string } = {}
	local tier = numberAttribute(node, "Tier", 1)
	local rolls = numberAttribute(node, "Rolls", 1)
	for _, station in lane.stations do
		for _, entry in station.lootNodes do
			if entry.part == node then
				guaranteed = entry.guaranteed
				tier = entry.tier
				rolls = entry.rolls
				break
			end
		end
	end

	local difficulty = require(Shared.Config.GameConfig).getDifficulty(expedition.difficulty)
	local scaling = Balance.crewScaling(expedition.crewSize)
	local rng = Random.new(os.clock() * 1000 % 1000000)

	for _, itemId in guaranteed do
		table.insert(contents, { id = itemId, quantity = 1 })
	end

	local effectiveRolls = math.max(0, math.floor(rolls * difficulty.lootRate * scaling.loot + 0.5))
	for _ = 1, effectiveRolls do
		local itemId = ItemRegistry.rollLoot(tier, rng)
		if itemId then
			local def = ItemRegistry.getOrFallback(itemId)
			local quantity = if def.stackSize > 1 then rng:NextInteger(1, math.min(3, def.stackSize)) else 1
			table.insert(contents, { id = itemId, quantity = quantity })
		end
	end

	return contents
end

--------------------------------------------------------------------------
-- Fixtures
--------------------------------------------------------------------------

local function fixtureStation(expedition: ExpeditionService.Expedition, fixture: BasePart): (WorldService.Lane?, any)
	for _, station in expedition.lane.stations do
		for id, candidate in station.fixtures do
			if candidate == fixture then
				return expedition.lane, station
			end
		end
	end
	return nil, nil
end

--- Powers a station's lights. Called when the breaker sequence completes.
local function powerStation(station: any, on: boolean)
	for _, light in station.lights do
		light.Enabled = on
	end
	for _, fixture in station.fixtures do
		fixture:SetAttribute("Powered", on)
	end
end

--- Runs the step logic for a sequence objective when its fixture is operated.
local function operateFixture(player: Player, expedition: ExpeditionService.Expedition, fixture: BasePart, station: any): (boolean, string?)
	local objectiveId = fixture:GetAttribute("Objective")
	local stepId = fixture:GetAttribute("Step")
	if type(objectiveId) ~= "string" then
		return false, "NO_OBJECTIVE"
	end

	local stationDef = StationRegistry.byId(station.stationId)
	if not stationDef then
		return false, "NO_STATION"
	end
	local objectiveDef: StationRegistry.ObjectiveDef? = nil
	for _, candidate in stationDef.objectives do
		if candidate.id == objectiveId then
			objectiveDef = candidate
			break
		end
	end
	if not objectiveDef then
		return false, "NO_OBJECTIVE"
	end
	local def = objectiveDef :: StationRegistry.ObjectiveDef

	local progress = expedition.objectives[objectiveId]
	if not progress or progress.complete then
		return false, "DONE"
	end

	-- Sequence objectives: only the current step's fixture responds.
	if def.kind == "sequence" then
		local step = ExpeditionService.currentStep(expedition, objectiveId)
		if not step or step.id ~= stepId then
			return false, "WRONG_STEP"
		end

		-- A step that needs an item consumes it here.
		if step.item then
			if not InventoryService.has(player, step.item, 1) then
				local itemDef = ItemRegistry.getOrFallback(step.item)
				return false, "NEEDS:" .. itemDef.name
			end
		end
		-- Generator steps need fuel. A jerry can is used if the player has one;
		-- otherwise fuel is siphoned from the crew's own locomotive, so a crew
		-- that already poured its can into the train is never stranded.
		local siphon = false
		if step.needsFuel and not InventoryService.has(player, "fuel_can", 1) then
			if expedition.train.fuel >= Balance.Train.fuelCanRestore * 0.6 + 5 then
				siphon = true
			else
				return false, "NEEDS:Jerry Can"
			end
		end

		-- A defend step is started with a short hold; its long timer then runs
		-- on its own while the crew holds the area. It used to be treated as
		-- one long hold, which meant standing on the key for minutes and the
		-- defend timer never ran at all.
		local isDefend = step.kind == "defend"
		local duration = if isDefend then 1.5 else (step.seconds or 2)
		local entry = held[player.UserId]
		if not entry or entry.target ~= fixture then
			beginHold(player, fixture, "operate", duration, fixture.Position)
			return true, "HOLD"
		end
		if not completeHold(player, fixture, "operate") then
			return false, "TOO_EARLY"
		end
		if isDefend then
			fixture:SetAttribute("State", "running")
			return true, "START_DEFEND"
		end

		if step.item then
			InventoryService.remove(player, step.item, 1)
		end
		if step.needsFuel then
			if siphon then
				expedition.train.fuel -= Balance.Train.fuelCanRestore * 0.6
				Net.fireClient("Notify", player, {
					kind = "info",
					title = "Fuel siphoned from the locomotive",
					body = "Nobody had a jerry can, so the generator was filled from the train.",
					duration = 6,
				})
			else
				InventoryService.remove(player, "fuel_can", 1)
			end
		end

		fixture:SetAttribute("State", "done")

		-- Side effects by fixture kind.
		local kind = fixture:GetAttribute("FixtureKind")
		if kind == "breaker" then
			powerStation(station, true)
			InteractionService.NoiseMade:Fire(fixture.Position, Balance.Threat.noisePerGenerator, player)
		elseif kind == "generator" then
			InteractionService.NoiseMade:Fire(fixture.Position, Balance.Threat.noisePerGenerator * 1.6, player)
		end

		ExpeditionService.advanceStep(expedition, objectiveId)
		return true, nil
	end

	-- Deliver objectives: bring an item to a fixture.
	if def.kind == "deliver" then
		local itemId = def.params.item
		if type(itemId) == "string" then
			if not InventoryService.has(player, itemId, 1) then
				return false, "NEEDS:" .. ItemRegistry.getOrFallback(itemId).name
			end
			local duration = def.params.seconds or 4
			local entry = held[player.UserId]
			if not entry or entry.target ~= fixture then
				beginHold(player, fixture, "operate", duration, fixture.Position)
				return true, "HOLD"
			end
			if not completeHold(player, fixture, "operate") then
				return false, "TOO_EARLY"
			end
			InventoryService.remove(player, itemId, 1)
			ExpeditionService.completeObjective(expedition, objectiveId)
			return true, nil
		end

		-- A powered station fuel point pumps from the station's own tank and
		-- fills the locomotive to the target. It used to demand a jerry can,
		-- and the halt's only guaranteed can is spent on its generator, so the
		-- objective could only be finished if the loot rolls were kind.
		if def.params.requiresPower and not fixture:GetAttribute("Powered") then
			return false, "NO_POWER"
		end
		local duration = 4
		local entry = held[player.UserId]
		if not entry or entry.target ~= fixture then
			beginHold(player, fixture, "operate", duration, fixture.Position)
			return true, "HOLD"
		end
		if not completeHold(player, fixture, "operate") then
			return false, "TOO_EARLY"
		end
		local target = def.params.targetFuel or 80
		local added = TrainService.addFuel(expedition.train, math.max(0, target - expedition.train.fuel))
		ProgressionService.addStat(player, "fuel_delivered", 1)
		ExpeditionService.completeObjective(expedition, objectiveId)
		Net.fireClient("InteractResult", player, { ok = true, action = "refuel", amount = added })
		return true, nil
	end

	-- Simultaneous objectives: levers that must be held together.
	if def.kind == "simultaneous" then
		local fixtures = def.params.holdFixtures or {}
		if table.find(fixtures, fixture.Name) then
			fixture:SetAttribute("State", "held")
			fixture:SetAttribute("HeldBy", player.UserId)
			fixture:SetAttribute("HeldAt", os.clock())

			-- Solo allowance: one lever stays held on a timer, so a single
			-- player can sprint between them. Without this the objective would
			-- simply be impossible alone, which the brief forbids.
			local soloTimer = def.params.soloTimerSeconds
			if expedition.crewSize == 1 and soloTimer then
				task.delay(soloTimer, function()
					if fixture:GetAttribute("HeldBy") == player.UserId then
						fixture:SetAttribute("State", "idle")
						fixture:SetAttribute("HeldBy", 0)
					end
				end)
			end

			-- Check whether every lever is held right now.
			local allHeld = true
			for _, fixtureId in fixtures do
				local other = station.fixtures[fixtureId]
				if not other or other:GetAttribute("State") ~= "held" then
					allHeld = false
					break
				end
			end
			if allHeld then
				for _, fixtureId in fixtures do
					local other = station.fixtures[fixtureId]
					if other then
						other:SetAttribute("State", "released")
					end
				end
				local thenFixture = station.fixtures[def.params.thenFixture]
				if thenFixture then
					thenFixture:SetAttribute("State", "ready")
				end
				Net.fireClients("Notify", ExpeditionService.playersOf(expedition), {
					kind = "objective",
					title = "Interlock released",
					body = "The loader controls are live.",
					duration = 6,
				})
			end
			return true, nil
		end

		-- The final fixture, live only once the interlock is released.
		if fixture.Name == def.params.thenFixture then
			if fixture:GetAttribute("State") ~= "ready" then
				return false, "INTERLOCK_NOT_RELEASED"
			end
			local duration = def.params.thenSeconds or 6
			local entry = held[player.UserId]
			if not entry or entry.target ~= fixture then
				beginHold(player, fixture, "operate", duration, fixture.Position)
				return true, "HOLD"
			end
			if not completeHold(player, fixture, "operate") then
				return false, "TOO_EARLY"
			end
			InteractionService.NoiseMade:Fire(fixture.Position, 10, player)
			ExpeditionService.completeObjective(expedition, objectiveId)
			return true, nil
		end
		return false, "NOT_PART_OF_OBJECTIVE"
	end

	-- Relay objectives: read a value in one place, enter it in another.
	if def.kind == "relay" then
		if fixture.Name == def.params.readerFixture then
			-- Reading the frame reveals the code to this player only.
			Net.fireClient("InteractResult", player, {
				ok = true,
				action = "read_code",
				code = expedition.leverCode,
				title = "Interlocking frame",
				body = "The diagram board reads:",
			})
			return true, nil
		end

		local leverFixtures = def.params.leverFixtures or {}
		local leverIndex = table.find(leverFixtures, fixture.Name)
		if leverIndex then
			local positions: number = def.params.positions or 3
			local current = numberAttribute(fixture, "Position", 1)
			local nextPosition = (current % positions) + 1
			fixture:SetAttribute("Position", nextPosition)

			-- Check the whole code.
			local correct = true
			for index, fixtureId in leverFixtures do
				local lever = station.fixtures[fixtureId]
				local value = if lever then numberAttribute(lever, "Position", 1) else 1
				if value ~= expedition.leverCode[index] then
					correct = false
					break
				end
			end

			if correct then
				ExpeditionService.completeObjective(expedition, objectiveId)
			else
				-- Wrong combinations are recoverable but noisy, which is the
				-- cost of guessing instead of communicating.
				InteractionService.NoiseMade:Fire(fixture.Position, def.params.wrongAttemptNoise or 8, player)
			end
			Net.fireClient("InteractResult", player, { ok = true, action = "lever", position = nextPosition })
			return true, nil
		end
		return false, "NOT_PART_OF_OBJECTIVE"
	end

	-- Plain operate objectives.
	if def.kind == "operate" then
		local duration = def.params.seconds or 2
		local entry = held[player.UserId]
		if duration > 0 then
			if not entry or entry.target ~= fixture then
				beginHold(player, fixture, "operate", duration, fixture.Position)
				return true, "HOLD"
			end
			if not completeHold(player, fixture, "operate") then
				return false, "TOO_EARLY"
			end
		end
		ExpeditionService.completeObjective(expedition, objectiveId)
		return true, nil
	end

	return false, "UNSUPPORTED"
end

--------------------------------------------------------------------------
-- Defend steps (pumps priming, mast power)
--------------------------------------------------------------------------

local defendTimers: { [string]: thread } = {}

--- Starts a timed hold-the-area step. Progress continues while at least one
--- crew member is alive near the fixture; it pauses otherwise rather than
--- failing, so a wipe-and-recover is survivable.
local function startDefend(expedition: ExpeditionService.Expedition, objectiveId: string, fixture: BasePart, seconds: number)
	local key = expedition.id .. ":" .. objectiveId
	if defendTimers[key] then
		return
	end
	defendTimers[key] = task.spawn(function()
		local elapsed = 0
		local progressState = expedition.objectives[objectiveId]
		while elapsed < seconds do
			task.wait(1)
			if expedition.state == "closed" then
				break
			end
			local anyoneNear = false
			for _, player in ExpeditionService.playersOf(expedition) do
				local root = Guard.aliveRoot(player)
				if root and Guard.withinDistance(root.Position, fixture.Position, 90) then
					anyoneNear = true
					break
				end
			end
			if anyoneNear then
				elapsed += 1
				if progressState then
					progressState.stepProgress = elapsed / seconds
				end
				ExpeditionService.fireRadio(expedition, "step_progress", {
					station = StationRegistry.byIndex(expedition.stationIndex) and (StationRegistry.byIndex(expedition.stationIndex) :: any).id,
					step = fixture:GetAttribute("Step"),
					fraction = elapsed / seconds,
				})
				if elapsed % 5 == 0 then
					ExpeditionService.push(expedition)
				end
			end
		end
		defendTimers[key] = nil
		if expedition.state ~= "closed" then
			ExpeditionService.advanceStep(expedition, objectiveId)
		end
	end)
end

--------------------------------------------------------------------------
-- Main handler
--------------------------------------------------------------------------

local function handleInteract(player: Player, rawTarget: any, rawAction: any)
	local action = Guard.enum(rawAction, {
		"search",
		"operate",
		"pickup",
		"read",
		"refuel_train",
		"repair_train",
		"store",
		"take",
		"door",
		"discover",
		"lobby",
		"sit",
		"run_task",
		"cancel",
	})
	if not action then
		return
	end

	if action == "cancel" then
		InteractionService.cancelHold(player)
		return
	end

	local target = Guard.instance(rawTarget, "Instance")
	if not target then
		return
	end

	local root = Guard.aliveRoot(player)
	if not root then
		Net.fireClient("InteractResult", player, { ok = false, error = "NOT_ALIVE" })
		return
	end

	-- Resolve a position to check reach against, whether the target is a part
	-- or a model.
	local targetPosition: Vector3
	if target:IsA("BasePart") then
		targetPosition = target.Position
	elseif target:IsA("Model") then
		targetPosition = target:GetPivot().Position
	else
		return
	end
	if not Guard.withinDistance(root.Position, targetPosition, MAX_REACH) then
		Net.fireClient("InteractResult", player, { ok = false, error = "TOO_FAR" })
		return
	end

	local expedition = ExpeditionService.forPlayer(player)

	----------------------------------------------------------------------
	-- Dropped items
	----------------------------------------------------------------------
	if action == "pickup" then
		local model = if target:IsA("Model") then target else target:FindFirstAncestorOfClass("Model")
		if not model or not model:HasTag("DroppedItem") then
			return
		end
		local itemId = model:GetAttribute("ItemId")
		local quantity = numberAttribute(model, "Quantity", 1)
		if type(itemId) ~= "string" then
			return
		end
		local added = InventoryService.add(player, itemId, quantity, expedition ~= nil and ExpeditionService.needsItem(expedition, itemId))
		if added <= 0 then
			Net.fireClient("InteractResult", player, { ok = false, error = "NO_SPACE" })
			return
		end
		if added >= quantity then
			model:Destroy()
		else
			model:SetAttribute("Quantity", quantity - added)
		end
		ProgressionService.addStat(player, "items_collected", added)
		if expedition then
			ExpeditionService.checkCollectSteps(expedition)
		end
		Net.fireClient("InteractResult", player, { ok = true, action = "pickup", itemId = itemId, quantity = added })
		return
	end

	----------------------------------------------------------------------
	-- Seats. Taken with a prompt rather than by touch, in the yard and on
	-- the line alike.
	----------------------------------------------------------------------
	if action == "sit" then
		if not target:IsA("Seat") or not (target:HasTag("TrainSeat") or target:HasTag("DriverSeat")) then
			return
		end
		if target:GetAttribute("SeatLocked") == true or target.Occupant then
			Net.fireClient("InteractResult", player, { ok = false, error = "OCCUPIED" })
			return
		end
		local character = player.Character
		local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
		if humanoid and not humanoid.SeatPart then
			-- Seats stay disabled until somebody chooses to sit: an enabled
			-- seat grabs anyone who brushes against it, which trapped players
			-- walking the aisles. Enabled for this sitting, disabled again when
			-- they get up.
			local seat = target :: Seat
			seat.Disabled = false
			seat:Sit(humanoid)
			local watch: RBXScriptConnection? = nil
			watch = seat:GetPropertyChangedSignal("Occupant"):Connect(function()
				if not seat.Occupant then
					seat.Disabled = true
					if watch then
						watch:Disconnect()
					end
				end
			end)
		end
		return
	end

	----------------------------------------------------------------------
	-- Lobby fixtures. These work without an expedition, which is the whole
	-- point: they are how a player reaches the crew panel and departs.
	----------------------------------------------------------------------
	if action == "lobby" then
		local panel: string? = nil
		if target:HasTag("CrewBoard") then
			panel = "crew"
		elseif target:HasTag("NoticeBoard") then
			panel = "quests"
		elseif target:HasTag("StoresCounter") then
			panel = "shop"
		elseif target:HasTag("WorkshopBench") then
			panel = "loadout"
		elseif target:HasTag("ArmoryRack") then
			panel = "armory"
		end
		if panel then
			Net.fireClient("InteractResult", player, { ok = true, action = "open_panel", panel = panel })
		end
		return
	end

	----------------------------------------------------------------------
	-- Everything below needs an expedition
	----------------------------------------------------------------------
	if not expedition then
		Net.fireClient("InteractResult", player, { ok = false, error = "NOT_ON_EXPEDITION" })
		return
	end
	if not target:IsDescendantOf(expedition.lane.root) and not target:IsDescendantOf(expedition.train.built.model) then
		-- The target is not in this crew's lane. This is the check that stops
		-- one crew reaching into another crew's world.
		Net.fireClient("InteractResult", player, { ok = false, error = "WRONG_LANE" })
		return
	end

	local part = target :: BasePart

	----------------------------------------------------------------------
	-- Loot nodes
	----------------------------------------------------------------------
	if action == "search" then
		if not part:HasTag("LootNode") then
			return
		end
		if part:GetAttribute("Searched") then
			Net.fireClient("InteractResult", player, { ok = false, error = "ALREADY_SEARCHED" })
			return
		end

		local duration = 1.8
		local entry = held[player.UserId]
		if not entry or entry.target ~= part then
			beginHold(player, part, "search", duration, part.Position)
			return
		end
		if not completeHold(player, part, "search") then
			return
		end

		part:SetAttribute("Searched", true)
		local contents = rollLootNode(part, expedition)
		local taken: { { id: string, quantity: number } } = {}
		local overflow: { { id: string, quantity: number } } = {}
		for _, stack in contents do
			local added = InventoryService.add(player, stack.id, stack.quantity, ExpeditionService.needsItem(expedition, stack.id))
			if added > 0 then
				table.insert(taken, { id = stack.id, quantity = added })
				ProgressionService.addStat(player, "items_collected", added)
			end
			if added < stack.quantity then
				table.insert(overflow, { id = stack.id, quantity = stack.quantity - added })
			end
		end

		-- Anything that did not fit is dropped at the container rather than
		-- destroyed, so a full inventory never loses loot.
		for _, stack in overflow do
			WorldService.buildDroppedItem(
				stack.id,
				stack.quantity,
				CFrame.new(part.Position + Vector3.new(math.random(-2, 2), 2, math.random(-2, 2))),
				expedition.lane.dropContainer
			)
		end

		-- Collecting story items counts for the optional objectives.
		for _, stack in taken do
			local def = ItemRegistry.get(stack.id)
			if def and def.effect then
				if def.effect.collectible == "dispatch_log" then
					ProgressionService.addStat(player, "records_found", stack.quantity)
				end
			end
		end

		-- Any active "collect anything" objective progresses.
		local station = StationRegistry.byIndex(expedition.stationIndex)
		if station then
			for _, def in station.objectives do
				local objectiveProgress = expedition.objectives[def.id]
				if objectiveProgress and not objectiveProgress.complete and def.kind == "collect" and def.params.anyItems then
					local total = 0
					for _, stack in taken do
						total += stack.quantity
					end
					if total > 0 then
						ExpeditionService.addObjectiveProgress(expedition, def.id, total)
					end
				end
			end
		end

		InteractionService.NoiseMade:Fire(part.Position, 2, player)
		ExpeditionService.checkCollectSteps(expedition)
		Net.fireClient("InteractResult", player, { ok = true, action = "search", contents = taken, overflow = #overflow })
		return
	end

	----------------------------------------------------------------------
	-- Station fixtures
	----------------------------------------------------------------------
	if action == "operate" then
		if not part:HasTag("StationFixture") then
			return
		end
		local _, station = fixtureStation(expedition, part)
		if not station then
			return
		end
		local ok, err = operateFixture(player, expedition, part, station)
		if ok and err == "HOLD" then
			return
		end
		if ok and err == "START_DEFEND" then
			local defendObjective = part:GetAttribute("Objective")
			local defendStep = if type(defendObjective) == "string" then ExpeditionService.currentStep(expedition, defendObjective) else nil
			if type(defendObjective) == "string" and defendStep then
				startDefend(expedition, defendObjective, part, defendStep.seconds or 60)
			end
			Net.fireClient("InteractResult", player, { ok = true, action = "defend_started", seconds = defendStep and defendStep.seconds })
			return
		end
		if not ok then
			Net.fireClient("InteractResult", player, { ok = false, error = err })
			return
		end

		InteractionService.FixtureOperated:Fire(expedition.id, player, part)
		Net.fireClient("InteractResult", player, { ok = true, action = "operate" })
		return
	end

	----------------------------------------------------------------------
	-- Train interactions
	----------------------------------------------------------------------
	if action == "refuel_train" then
		if not part:HasTag("TrainFuelPoint") then
			return
		end
		if not InventoryService.has(player, "fuel_can", 1) then
			Net.fireClient("InteractResult", player, { ok = false, error = "NEEDS:Jerry Can" })
			return
		end
		local duration = ItemRegistry.getOrFallback("fuel_can").useSeconds or 4.5
		local entry = held[player.UserId]
		if not entry or entry.target ~= part then
			beginHold(player, part, "refuel_train", duration, part.Position)
			return
		end
		if not completeHold(player, part, "refuel_train") then
			return
		end
		InventoryService.remove(player, "fuel_can", 1)
		local added = TrainService.addFuel(expedition.train, Balance.Train.fuelCanRestore)
		ProgressionService.addStat(player, "fuel_delivered", 1)
		-- A can poured into the locomotive counts towards any objective that
		-- asks for fuel delivered to the train (Tolbridge Camp). Nothing used
		-- to credit it, which made that station impossible to clear.
		local fuelStation = StationRegistry.byIndex(expedition.stationIndex)
		if fuelStation then
			for _, def in fuelStation.objectives do
				if def.kind == "collect" and def.params.item == "fuel_can" and def.params.deliverTo == "train_fuel_point" then
					ExpeditionService.addObjectiveProgress(expedition, def.id, 1)
				end
			end
		end
		Net.fireClient("InteractResult", player, { ok = true, action = "refuel", amount = added })
		return
	end

	if action == "run_task" then
		-- A night-run task (JourneyService): a held job on a part tagged
		-- RunTask, described entirely by its attributes, so an event can add
		-- one without this file knowing what the event is.
		if not part:HasTag("RunTask") then
			return
		end
		local blocked = part:GetAttribute("TaskBlocked")
		if type(blocked) == "string" and blocked ~= "" then
			Net.fireClient("InteractResult", player, { ok = false, error = "SAY:" .. blocked })
			return
		end
		local needs = part:GetAttribute("TaskNeeds")
		if type(needs) == "string" and needs ~= "" and not InventoryService.has(player, needs, 1) then
			Net.fireClient("InteractResult", player, { ok = false, error = "NEEDS:" .. ItemRegistry.getOrFallback(needs).name })
			return
		end
		local seconds = tonumber(part:GetAttribute("TaskSeconds")) or 3
		local fastItem = part:GetAttribute("TaskFastItem")
		if type(fastItem) == "string" and InventoryService.has(player, fastItem, 1) then
			seconds = tonumber(part:GetAttribute("TaskFastSeconds")) or seconds * 0.5
		end
		if InteractionService.holdScale then
			seconds *= InteractionService.holdScale(player)
		end
		local entry = held[player.UserId]
		if not entry or entry.target ~= part then
			beginHold(player, part, "run_task", seconds, part.Position)
			return
		end
		if not completeHold(player, part, "run_task") then
			return
		end
		local usedFast = type(fastItem) == "string" and part:GetAttribute("TaskFastConsumes") == true and InventoryService.has(player, fastItem, 1)
		if usedFast then
			InventoryService.remove(player, fastItem :: string, 1)
		end
		local noise = tonumber(part:GetAttribute("TaskNoise"))
		if noise then
			InteractionService.NoiseMade:Fire(part.Position, noise, player)
		end
		Net.fireClient("InteractResult", player, { ok = true, action = "run_task" })
		InteractionService.RunTaskDone:Fire(player, part, usedFast)
		return
	end

	if action == "repair_train" then
		if not part:HasTag("TrainRepairPoint") then
			return
		end
		if not InventoryService.has(player, "repair_kit", 1) then
			Net.fireClient("InteractResult", player, { ok = false, error = "NEEDS:Repair Kit" })
			return
		end
		local duration = ItemRegistry.getOrFallback("repair_kit").useSeconds or 7
		local entry = held[player.UserId]
		if not entry or entry.target ~= part then
			beginHold(player, part, "repair_train", duration, part.Position)
			return
		end
		if not completeHold(player, part, "repair_train") then
			return
		end
		InventoryService.remove(player, "repair_kit", 1)
		local restored = TrainService.repair(expedition.train, Balance.Train.repairKitRestore)
		ProgressionService.addStat(player, "condition_repaired", math.floor(restored))
		InteractionService.NoiseMade:Fire(part.Position, 4, player)
		Net.fireClient("InteractResult", player, { ok = true, action = "repair", amount = restored })
		return
	end

	if action == "door" then
		-- Any crew member can work a carriage door from the outside or the
		-- inside. Without this the only door control is in the cab, which means
		-- a crew that walks away from the train cannot get back in.
		local model = part:FindFirstAncestorOfClass("Model")
		if not part:HasTag("DoorLeaf") and not (model and model.Name == "CarriageDoor") then
			return
		end
		local ok, err = TrainService.applyControl(player, expedition.train, "doors", true)
		Net.fireClient("InteractResult", player, { ok = ok, error = err, action = "door" })
		return
	end

	if action == "store" or action == "take" then
		if not part:HasTag("SupplyRack") then
			return
		end
		Net.fireClient("InteractResult", player, {
			ok = true,
			action = "supply_rack",
			contents = InventoryService.trainStore(expedition.crewId),
		})
		return
	end

	----------------------------------------------------------------------
	-- Discoveries and recordings
	----------------------------------------------------------------------
	if action == "discover" then
		if not part:HasTag("Discovery") then
			return
		end
		local discoveryId = part:GetAttribute("DiscoveryId")
		if type(discoveryId) ~= "string" then
			return
		end
		if expedition.discoveriesFound[discoveryId] then
			return
		end
		local stationId = part:GetAttribute("StationId")
		local stationDef = if type(stationId) == "string" then StationRegistry.byId(stationId) else nil
		-- A discovery placed by a scripted moment carries its own words.
		local ownHint = part:GetAttribute("DiscoveryBody")
		local ownName = part:GetAttribute("DiscoveryTitle")
		local hint = if type(ownHint) == "string" then ownHint else ""
		local name = if type(ownName) == "string" then ownName else discoveryId
		if stationDef then
			for _, entry in stationDef.discoveries do
				if entry.id == discoveryId then
					hint = entry.hint
					name = entry.name
					break
				end
			end
		end
		ExpeditionService.recordDiscovery(expedition, player, discoveryId)
		Net.fireClient("InteractResult", player, { ok = true, action = "discover", title = name, body = hint })
		return
	end

	if action == "read" then
		-- A recorder in the player's inventory plays the station's recording.
		local stationDef = StationRegistry.byIndex(expedition.stationIndex)
		if not stationDef then
			return
		end
		local recordings = RadioScript.recordingsFor(stationDef.id)
		if #recordings == 0 then
			return
		end
		local pick: any = nil
		for _, recording in recordings do
			if not expedition.recordingsFound[recording.id] then
				pick = recording
				break
			end
		end
		pick = pick or recordings[1]
		ExpeditionService.recordRecording(expedition, player, pick.id)
		Net.fireClients("RadioMessage", ExpeditionService.playersOf(expedition), {
			id = pick.id,
			source = "recording",
			text = pick.text,
			duration = pick.duration,
			attribution = pick.title,
		})
		ProgressionService.award(player, { credits = pick.credits, xp = 20, source = "recording:" .. pick.id }, expedition.crewSize)
		return
	end
end

--------------------------------------------------------------------------

function InteractionService.start()
	Net.onServerEvent("Interact", handleInteract)

	-- Pings. The brief asks for readable coordination tools that do not depend
	-- on voice chat, and this is that: look at something, press the key, and
	-- everybody in your crew sees a marker on it.
	--
	-- The position is validated against the sender's own location so a client
	-- cannot drop a marker across the map, and it is only ever broadcast to the
	-- sender's own crew.
	Net.onServerEvent("Ping", function(player, rawPosition)
		local position = Guard.vector3(rawPosition, 1e6)
		local root = Guard.aliveRoot(player)
		if not position or not root then
			return
		end
		if not Guard.withinDistance(root.Position, position, 900) then
			return
		end

		local expedition = ExpeditionService.forPlayer(player)
		local audience = if expedition then ExpeditionService.playersOf(expedition) else { player }
		Net.fireClients("PingBroadcast", audience, {
			position = position,
			userId = player.UserId,
			name = player.DisplayName,
		})
	end)

	Players.PlayerRemoving:Connect(function(player)
		held[player.UserId] = nil
	end)

	-- Attach proximity prompts to every interactable the world builders tagged.
	-- Prompts are created on the server so the client cannot fabricate one for
	-- an object that has no behaviour.
	local function attachPrompt(instance: Instance, actionText: string, objectText: string, hold: number?, eyeLevel: boolean?)
		if not instance:IsA("BasePart") then
			return
		end
		if instance:FindFirstChildOfClass("ProximityPrompt") or instance:FindFirstChild("PromptAnchor") then
			return
		end
		-- Roblox only shows a prompt whose anchor is on screen. A tall board's
		-- centre sits above the eye line at arm's length, so its prompt never
		-- appeared unless the player happened to look up. Tall fixtures anchor
		-- the prompt near their lower edge instead, where a player looking at
		-- the fixture is actually looking. The client resolves the attachment
		-- back to the tagged part.
		local host: Instance = instance
		if eyeLevel and instance.Size.Y > 4 then
			local anchor = Instance.new("Attachment")
			anchor.Name = "PromptAnchor"
			anchor.Position = Vector3.new(0, -instance.Size.Y * 0.5 + 1.5, 0)
			anchor.Parent = instance
			host = anchor
		end
		local prompt = Instance.new("ProximityPrompt")
		prompt.ActionText = actionText
		prompt.ObjectText = objectText
		prompt.HoldDuration = hold or 0
		prompt.MaxActivationDistance = MAX_REACH - 2
		prompt.RequiresLineOfSight = false
		prompt.Style = Enum.ProximityPromptStyle.Custom
		prompt.Parent = host
	end

	local function wire(tag: string, actionText: string, objectText: string, eyeLevel: boolean?)
		for _, instance in CollectionService:GetTagged(tag) do
			attachPrompt(instance, actionText, objectText, nil, eyeLevel)
		end
		CollectionService:GetInstanceAddedSignal(tag):Connect(function(instance)
			attachPrompt(instance, actionText, objectText, nil, eyeLevel)
		end)
	end

	wire("LootNode", "Search", "")
	wire("StationFixture", "Use", "")
	wire("TrainFuelPoint", "Refuel", "Locomotive")
	wire("TrainRepairPoint", "Repair", "Locomotive")
	wire("SupplyRack", "Open", "Supply rack")
	wire("DroppedItem", "Take", "")
	wire("RadioSet", "Radio", "")
	wire("DoorLeaf", "Door", "")
	wire("TrainSeat", "Sit", "")
	wire("DriverSeat", "Drive", "")
	wire("RunTask", "Use", "")

	-- Lobby fixtures. Without these the crew board is scenery and the only way
	-- to start an expedition is to guess a keyboard shortcut, which is how the
	-- first build shipped and why nobody could find the train.
	wire("CrewBoard", "Form a crew", "Crew board", true)
	wire("NoticeBoard", "Read", "Notice board", true)
	wire("StoresCounter", "Use", "Phantom Exchange", true)
	wire("WorkshopBench", "Open loadout", "Workshop bench", true)
	wire("ArmoryRack", "Open armory", "Armory", true)

	log.info("started")
end

return InteractionService
