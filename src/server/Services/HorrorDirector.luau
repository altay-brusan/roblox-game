--!strict
--[[
	HorrorDirector
	--------------
	Decides what frightening thing happens, and when.

	THE PROBLEM IT SOLVES
	---------------------
	Horror on a timer stops working after about ten minutes, because players
	learn the timer. Horror at random stops working sooner, because random
	means "sometimes three in a row and then nothing for five minutes". Both
	produce the same complaint: the scares feel cheap.

	So this director schedules against a threat value the players themselves
	drive, with cooldowns that guarantee quiet, escalation bands that stop a
	loud event firing during a calm stretch, and repetition control so the same
	beat never lands twice in a row.

	THREAT
	------
	A 0-100 value per expedition, raised by noise, by being away from the train,
	by being alone, and by time; lowered by completing objectives and by simply
	being quiet. It is never shown to players as a number: they read it through
	the ambience, the music bed and how often something moves at the treeline.

	HARD RAILS
	----------
	Nothing schedules during the cinematic, during loading, during the results,
	or within the immunity window after a respawn or a boarding. Those are
	checked before any event is considered, which is what makes "no unavoidable
	deaths during loading, cinematics or respawns" a property of the system
	rather than a promise.

	ADDING AN EVENT
	---------------
	Add a table to EVENTS. It declares its band, its cooldown, whether it needs
	the crew inside or outside the train, and a `run` function. Nothing else in
	the project needs to change.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.LastSignal

local Balance = require(Shared.Config.Balance)
local GameConfig = require(Shared.Config.GameConfig)
local Logger = require(Shared.Core.Logger)
local Net = require(Shared.Core.Net)
local Protect = require(Shared.Core.Protect)
local Signal = require(Shared.Core.Signal)
local StationRegistry = require(Shared.Registry.StationRegistry)

local CreatureService = require(script.Parent.CreatureService)
local ExpeditionService = require(script.Parent.ExpeditionService)
local InteractionService = require(script.Parent.InteractionService)
local SurvivalService = require(script.Parent.SurvivalService)
local TrainService = require(script.Parent.TrainService)

local log = Logger.new("HorrorDirector")

local HorrorDirector = {}

export type DirectorState = {
	expeditionId: string,
	threat: number,
	band: number,
	lastEventAt: number,
	lastEventId: string?,
	calmUntil: number,
	eventCooldowns: { [string]: number },
	firedScriptedBeats: { [string]: boolean },
	creaturesSpawned: boolean,
}

local states: { [string]: DirectorState } = {}

HorrorDirector.EventFired = Signal.new() :: Signal.Signal<string, string>
HorrorDirector.BandChanged = Signal.new() :: Signal.Signal<string, number>

--------------------------------------------------------------------------
-- Event catalogue
--------------------------------------------------------------------------

export type DirectorEvent = {
	id: string,
	name: string,
	-- Lowest threat band this may fire in. Band 0 events are atmosphere.
	minBand: number,
	maxBand: number?,
	cooldown: number,
	-- "inside" requires the crew in the train, "outside" requires them out of
	-- it, nil means either.
	requires: string?,
	-- Whether the creature must be active at this station.
	needsCreature: boolean?,
	weight: number,
	run: (expedition: ExpeditionService.Expedition, state: DirectorState) -> boolean,
}

local function playersInside(expedition: ExpeditionService.Expedition): ({ Player }, { Player })
	local inside: { Player } = {}
	local outside: { Player } = {}
	local train = expedition.train
	local volumeCF = train.built.root.CFrame * train.built.volumeOffset
	local half = train.built.volumeSize * 0.5

	for _, player in ExpeditionService.playersOf(expedition) do
		local character = player.Character
		local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
		if root and root:IsA("BasePart") then
			local localPoint = volumeCF:PointToObjectSpace(root.Position)
			if math.abs(localPoint.X) <= half.X and math.abs(localPoint.Y) <= half.Y and math.abs(localPoint.Z) <= half.Z then
				table.insert(inside, player)
			else
				table.insert(outside, player)
			end
		end
	end
	return inside, outside
end

HorrorDirector.playersInside = playersInside

local function cue(expedition: ExpeditionService.Expedition, players: { Player }, cueName: string, position: Vector3?, extra: { [string]: any }?)
	local payload: { [string]: any } = { cue = cueName, position = position }
	if extra then
		for key, value in extra do
			payload[key] = value
		end
	end
	Net.fireClients("HorrorCue", players, payload)
end

local EVENTS: { DirectorEvent } = {
	{
		id = "footsteps_outside",
		name = "Footsteps on the ballast",
		minBand = 1,
		cooldown = 150,
		requires = "inside",
		weight = 14,
		run = function(expedition)
			local inside = playersInside(expedition)
			if #inside == 0 then
				return false
			end
			local train = expedition.train
			local side = if math.random() < 0.5 then 1 else -1
			local position = train.built.root.Position + Vector3.new(side * 9, 0, math.random(-30, 30))
			cue(expedition, inside, "footsteps_outside", position)
			return true
		end,
	},
	{
		id = "distant_silhouette",
		name = "Something at the treeline",
		minBand = 1,
		cooldown = 130,
		requires = "outside",
		weight = 16,
		run = function(expedition)
			local _, outside = playersInside(expedition)
			if #outside == 0 then
				return false
			end
			local subject = outside[math.random(1, #outside)]
			local character = subject.Character
			local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
			if not root or not root:IsA("BasePart") then
				return false
			end
			-- Placed behind the player and at the edge of readable distance, so
			-- it is seen on the turn rather than shoved into the face.
			local behind = (root :: BasePart).CFrame * CFrame.new(math.random(-30, 30), 0, 70)
			cue(expedition, { subject }, "silhouette", behind.Position, { duration = 2.2 })
			return true
		end,
	},
	{
		id = "lights_flicker",
		name = "Localised electrical failure",
		minBand = 1,
		cooldown = 160,
		weight = 12,
		run = function(expedition)
			local train = expedition.train
			local players = ExpeditionService.playersOf(expedition)
			cue(expedition, players, "lights_flicker", train.built.root.Position, { seconds = 3.5 })
			-- Actually cut the lights, rather than only playing a client effect.
			local wasOn = train.interiorLights
			train.interiorLights = false
			TrainService.applyLights(train)
			task.delay(3.5, function()
				train.interiorLights = wasOn
				TrainService.applyLights(train)
			end)
			return true
		end,
	},
	{
		id = "door_moves",
		name = "A door that was closed",
		minBand = 2,
		cooldown = 200,
		requires = "inside",
		weight = 10,
		run = function(expedition)
			local inside = playersInside(expedition)
			if #inside == 0 then
				return false
			end
			local train = expedition.train
			if train.doorsOpen then
				return false
			end
			-- One carriage door swings open, then closes again.
			local doors = train.built.doors
			if #doors == 0 then
				return false
			end
			local door = doors[math.random(1, #doors)]
			local closed = door.model:GetAttribute("ClosedCFrame")
			if typeof(closed) ~= "CFrame" then
				return false
			end
			door.model:PivotTo((closed :: CFrame) * CFrame.Angles(0, math.rad(70), 0))
			cue(expedition, inside, "door_moves", door.hinge.Position)
			task.delay(9, function()
				if expedition.state ~= "closed" then
					door.model:PivotTo(closed :: CFrame)
				end
			end)
			return true
		end,
	},
	{
		id = "mimic_call",
		name = "A familiar sound, not quite right",
		minBand = 2,
		cooldown = 190,
		needsCreature = true,
		weight = 12,
		run = function(expedition)
			local station = StationRegistry.byIndex(expedition.stationIndex)
			if not station or not station.threat.mimicryEnabled then
				return false
			end
			local _, outside = playersInside(expedition)
			if #outside == 0 then
				return false
			end
			local subject = outside[math.random(1, #outside)]
			local character = subject.Character
			local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
			if not root or not root:IsA("BasePart") then
				return false
			end
			local away = (root :: BasePart).CFrame * CFrame.new(math.random(-50, 50), 0, -math.random(40, 90))
			cue(expedition, { subject }, "creature_mimic", away.Position)
			return true
		end,
	},
	{
		id = "false_radio",
		name = "Not the dispatcher",
		minBand = 2,
		cooldown = 240,
		weight = 11,
		run = function(expedition)
			local station = StationRegistry.byIndex(expedition.stationIndex)
			if not station or not station.threat.mimicryEnabled then
				return false
			end
			ExpeditionService.fireRadio(expedition, "threat_band", { band = 3, requiresMimicry = true })
			return true
		end,
	},
	{
		id = "evidence",
		name = "Evidence of a visitor",
		minBand = 1,
		cooldown = 210,
		requires = "outside",
		weight = 9,
		run = function(expedition)
			local _, outside = playersInside(expedition)
			if #outside == 0 then
				return false
			end
			local subject = outside[math.random(1, #outside)]
			local character = subject.Character
			local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
			if not root or not root:IsA("BasePart") then
				return false
			end
			cue(expedition, { subject }, "evidence", (root :: BasePart).Position, {
				variant = ({ "prints", "scratches", "disturbed" })[math.random(1, 3)],
			})
			return true
		end,
	},
	{
		id = "creature_approach",
		name = "It comes to look",
		minBand = 3,
		cooldown = 180,
		needsCreature = true,
		weight = 15,
		run = function(expedition)
			local list = CreatureService.forExpedition(expedition.id)
			if #list == 0 then
				return false
			end
			local _, outside = playersInside(expedition)
			if #outside == 0 then
				return false
			end
			local subject = outside[math.random(1, #outside)]
			local character = subject.Character
			local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
			if not root or not root:IsA("BasePart") then
				return false
			end
			-- Sends the creature to investigate, rather than teleporting it on
			-- top of anybody. It still has to walk there, and it can still be
			-- avoided, which is what keeps the encounter fair.
			CreatureService.hearNoise(expedition.id, (root :: BasePart).Position, 20)
			return true
		end,
	},
	{
		id = "hunt",
		name = "It has your scent",
		minBand = 3,
		cooldown = 260,
		needsCreature = true,
		requires = "outside",
		weight = 10,
		run = function(expedition)
			local list = CreatureService.forExpedition(expedition.id)
			if #list == 0 then
				return false
			end
			local _, outside = playersInside(expedition)
			if #outside == 0 then
				return false
			end
			local creature = list[1]
			local subject = outside[math.random(1, #outside)]
			creature.state = "hunt"
			creature.targetUserId = subject.UserId
			creature.stateSince = os.clock()
			creature.lastSeenTargetAt = os.clock()
			cue(expedition, ExpeditionService.playersOf(expedition), "creature_chase", creature.position, {
				targetUserId = subject.UserId,
			})
			return true
		end,
	},
}

--------------------------------------------------------------------------
-- Threat
--------------------------------------------------------------------------

local function bandFor(threat: number): number
	local bands = Balance.Threat.bands
	local band = 0
	for index, floor in bands do
		if threat >= floor then
			band = index - 1
		end
	end
	return band
end

function HorrorDirector.addThreat(expeditionId: string, amount: number)
	local state = states[expeditionId]
	if not state then
		return
	end
	local expedition = ExpeditionService.byId(expeditionId)
	local difficulty = GameConfig.getDifficulty(if expedition then expedition.difficulty else nil)
	state.threat = math.clamp(state.threat + amount * (if amount > 0 then difficulty.threatRate else 1), 0, 100)

	local newBand = bandFor(state.threat)
	if newBand ~= state.band then
		state.band = newBand
		HorrorDirector.BandChanged:Fire(expeditionId, newBand)
		if expedition then
			-- The client uses the band to pick its music and ambience bed. The
			-- number itself is never rendered.
			Net.fireClients("HorrorCue", ExpeditionService.playersOf(expedition), { cue = "band", band = newBand })
		end
	end
end

function HorrorDirector.threatOf(expeditionId: string): number
	local state = states[expeditionId]
	return if state then state.threat else 0
end

--------------------------------------------------------------------------
-- Rails
--------------------------------------------------------------------------

--- Every reason the director must stay silent. Checked before anything else.
local function suppressed(expedition: ExpeditionService.Expedition): boolean
	local phase = expedition.state
	if phase == "preparing" or phase == "ending" or phase == "closed" then
		return true
	end
	if phase == "cinematic" and Balance.Threat.blockedDuringCinematic then
		return true
	end

	-- If every living crew member is still inside their immunity window, the
	-- crew has just respawned or boarded and is not a valid target yet.
	local anyVulnerable = false
	for _, player in ExpeditionService.playersOf(expedition) do
		local vitals = SurvivalService.get(player)
		if vitals and vitals.state == "alive" and os.clock() >= vitals.immuneUntil then
			anyVulnerable = true
			break
		end
	end
	return not anyVulnerable
end

--------------------------------------------------------------------------
-- Scheduling
--------------------------------------------------------------------------

local function chooseEvent(expedition: ExpeditionService.Expedition, state: DirectorState): DirectorEvent?
	local now = os.clock()
	local station = StationRegistry.byIndex(expedition.stationIndex)
	local creatureActive = station ~= nil and station.threat.creatureActive
	local inside, outside = playersInside(expedition)

	local candidates: { DirectorEvent } = {}
	local totalWeight = 0

	for _, event in EVENTS do
		if event.minBand > state.band then
			continue
		end
		if event.maxBand and event.maxBand < state.band then
			continue
		end
		if (state.eventCooldowns[event.id] or 0) > now then
			continue
		end
		-- Never the same event twice running, regardless of cooldown.
		if state.lastEventId == event.id then
			continue
		end
		if event.needsCreature and not creatureActive then
			continue
		end
		if event.requires == "inside" and #inside == 0 then
			continue
		end
		if event.requires == "outside" and #outside == 0 then
			continue
		end
		table.insert(candidates, event)
		totalWeight += event.weight
	end

	if #candidates == 0 or totalWeight <= 0 then
		return nil
	end

	local roll = math.random() * totalWeight
	for _, event in candidates do
		roll -= event.weight
		if roll <= 0 then
			return event
		end
	end
	return candidates[#candidates]
end

local function tickExpedition(expedition: ExpeditionService.Expedition, state: DirectorState, dt: number)
	local station = StationRegistry.byIndex(expedition.stationIndex)

	-- Passive threat accumulation.
	local inside, outside = playersInside(expedition)
	local delta = -Balance.Threat.decayPerSecond * dt
	delta += #outside * Balance.Threat.perSecondAwayFromTrain * dt
	if #outside == 1 and #inside == 0 then
		delta += Balance.Threat.perSecondAlone * dt
	end
	-- Every station has a baseline the threat drifts towards.
	local baseline = if station then station.threat.baseline else Balance.Threat.baseline
	if state.threat < baseline then
		delta += (baseline - state.threat) * 0.06 * dt
	end
	HorrorDirector.addThreat(expedition.id, delta)

	-- Creature presence follows the station's declaration.
	if station and station.threat.creatureActive then
		local scaling = Balance.crewScaling(expedition.crewSize)
		local wanted = scaling.creatureCount
		local existing = CreatureService.count(expedition.id)
		if existing < wanted then
			-- Spawned well away from the crew, at the edge of the clearing, so
			-- nothing ever appears on top of a player.
			local origin = StationRegistry.originFor(station, expedition.lane.origin)
			local angle = math.rad(math.random(0, 360))
			local spawnAt = origin + Vector3.new(math.cos(angle), 0, math.sin(angle)) * (station.layout.radius * 0.9)
			CreatureService.spawn(expedition, spawnAt + Vector3.new(0, 6, 0))
		end
	elseif CreatureService.count(expedition.id) > 0 and station and not station.threat.creatureActive then
		CreatureService.despawnFor(expedition.id)
	end

	if suppressed(expedition) then
		return
	end

	local now = os.clock()
	if now < state.calmUntil then
		return
	end
	if (now - state.lastEventAt) < Balance.Threat.globalCooldown then
		return
	end

	-- Above the global cooldown, the chance of firing scales with threat, so a
	-- calm crew gets long quiet stretches and a loud one gets pressure.
	local pressure = math.clamp(state.threat / 100, 0, 1)
	if math.random() > (0.08 + pressure * 0.35) then
		return
	end

	local event = chooseEvent(expedition, state)
	if not event then
		return
	end

	local ok, fired = Protect.call(event.run, expedition, state)
	if not ok then
		log.error(string.format("event %s failed: %s", event.id, tostring(fired)))
		return
	end
	if fired ~= true then
		return
	end

	state.lastEventAt = now
	state.lastEventId = event.id
	state.eventCooldowns[event.id] = now + math.max(event.cooldown, Balance.Threat.perEventCooldown)
	HorrorDirector.EventFired:Fire(expedition.id, event.id)
	log.debug(string.format("expedition %s: %s (threat %.0f, band %d)", expedition.id, event.id, state.threat, state.band))
end

--------------------------------------------------------------------------
-- Scripted beats
--------------------------------------------------------------------------

--- A station's scripted beat fires once, when its first objective completes.
--- These are the authored moments; everything else is the director.
local function fireScriptedBeat(expedition: ExpeditionService.Expedition, beat: string)
	local state = states[expedition.id]
	if not state or state.firedScriptedBeats[beat] then
		return
	end
	state.firedScriptedBeats[beat] = true
	local players = ExpeditionService.playersOf(expedition)

	if beat == "first_call" then
		-- The chapter's first indication that anything is out there.
		task.delay(3, function()
			if expedition.state ~= "closed" then
				local far = expedition.train.built.root.Position + Vector3.new(math.random(-400, 400), 0, -math.random(300, 600))
				cue(expedition, players, "creature_distant", far)
			end
		end)
	elseif beat == "first_sighting" then
		cue(expedition, players, "silhouette", expedition.train.built.root.Position + Vector3.new(120, 0, -80), { duration = 3 })
	elseif beat == "false_dispatcher" then
		ExpeditionService.fireRadio(expedition, "threat_band", { band = 3, requiresMimicry = true })
	elseif beat == "bridge_siege" then
		-- The pumps step is the chapter's set piece: threat is pushed hard and
		-- the creature is committed, but the crew has flares, the horn and the
		-- train, all of which work.
		HorrorDirector.addThreat(expedition.id, 35)
		local list = CreatureService.forExpedition(expedition.id)
		if #list > 0 then
			list[1].state = "investigate"
			list[1].investigatePoint = expedition.train.built.root.Position
			list[1].stateSince = os.clock()
		end
	elseif beat == "finale" then
		HorrorDirector.addThreat(expedition.id, 45)
		cue(expedition, players, "creature_near", expedition.train.built.root.Position)
	end
end

--------------------------------------------------------------------------

function HorrorDirector.start()
	ExpeditionService.StateChanged:Connect(function(expedition, phase)
		if phase == "cinematic" and not states[expedition.id] then
			states[expedition.id] = {
				expeditionId = expedition.id,
				threat = Balance.Threat.baseline,
				band = 0,
				lastEventAt = os.clock(),
				lastEventId = nil,
				calmUntil = os.clock() + 60,
				eventCooldowns = {},
				firedScriptedBeats = {},
				creaturesSpawned = false,
			}
		end
	end)

	ExpeditionService.Ended:Connect(function(expedition)
		states[expedition.id] = nil
	end)

	ExpeditionService.StationReached:Connect(function(expedition, index)
		local state = states[expedition.id]
		local station = StationRegistry.byIndex(index)
		if not state or not station then
			return
		end
		-- Arriving at a station resets the pressure to that station's baseline
		-- and buys a short calm, so the first minute on a platform is always
		-- yours to orient in.
		state.threat = math.max(state.threat * 0.5, station.threat.baseline)
		state.calmUntil = os.clock() + 25
	end)

	ExpeditionService.ObjectiveCompleted:Connect(function(expedition, _objectiveId, optional)
		if optional then
			return
		end
		local station = StationRegistry.byIndex(expedition.stationIndex)
		if station and station.threat.scriptedBeat then
			fireScriptedBeat(expedition, station.threat.scriptedBeat)
		end
		-- Genuine relief after a real accomplishment.
		local state = states[expedition.id]
		if state then
			state.calmUntil = math.max(state.calmUntil, os.clock() + 20)
		end
	end)

	ExpeditionService.ThreatEvent:Connect(function(expedition, _kind, amount)
		HorrorDirector.addThreat(expedition.id, amount)
	end)

	-- Noise sources feed both the threat meter and the creature's hearing.
	InteractionService.NoiseMade:Connect(function(position, loudness, player)
		local expedition = if player then ExpeditionService.forPlayer(player) else nil
		if not expedition then
			return
		end
		HorrorDirector.addThreat(expedition.id, loudness * 0.4)
		CreatureService.hearNoise(expedition.id, position, loudness)
	end)

	TrainService.EmergencyBrake:Connect(function(train, player)
		local expedition = if player then ExpeditionService.forPlayer(player) else nil
		if not expedition then
			return
		end
		HorrorDirector.addThreat(expedition.id, Balance.Threat.noisePerEmergencyBrake)
		CreatureService.hearNoise(expedition.id, train.built.root.Position, Balance.Threat.noisePerEmergencyBrake)
	end)

	TrainService.HornSounded:Connect(function(train, player)
		local expedition = if player then ExpeditionService.forPlayer(player) else nil
		if not expedition then
			return
		end
		CreatureService.hearHorn(expedition.id, train.built.root.Position)
		CreatureService.learnCue(expedition.id, "train_horn")
	end)

	SurvivalService.Downed:Connect(function(player)
		local expedition = ExpeditionService.forPlayer(player)
		if not expedition then
			return
		end
		-- A down is already the worst moment; the director backs off so the
		-- rescue is about the rescue.
		local state = states[expedition.id]
		if state then
			state.calmUntil = math.max(state.calmUntil, os.clock() + 30)
		end
	end)

	-- After the creature is driven off, enforce real quiet. Relief is what
	-- makes the next encounter land.
	CreatureService.Retreated:Connect(function(creature)
		local state = states[creature.expeditionId]
		if state then
			state.calmUntil = math.max(state.calmUntil, os.clock() + Balance.Threat.postEncounterCalm)
			state.threat = math.max(0, state.threat - 25)
		end
	end)

	local accumulator = 0
	local interval = 1 / GameConfig.DirectorTickRate
	game:GetService("RunService").Heartbeat:Connect(function(dt)
		accumulator += dt
		if accumulator < interval then
			return
		end
		local step = accumulator
		accumulator = 0
		for expeditionId, state in states do
			local expedition = ExpeditionService.byId(expeditionId)
			if expedition then
				local ok, err = Protect.call(tickExpedition, expedition, state, step)
				if not ok then
					log.error("director tick failed:", tostring(err))
				end
			else
				states[expeditionId] = nil
			end
		end
	end)

	log.info(string.format("started with %d events", #EVENTS))
end

HorrorDirector.Events = EVENTS

return HorrorDirector
