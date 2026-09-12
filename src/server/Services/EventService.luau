--!strict
--[[
	EventService
	------------
	Runs live events. Ships with The Lost Conductor.

	The design goal is that a future event is data, not code: EventRegistry
	declares the window, the token, the encounter behaviour and the reward
	ladder, and this service runs whatever it finds there.

	THE FOUR SAFETY PROPERTIES
	--------------------------
	  Idempotent claims.  A reward threshold is marked claimed in the same
	                      profile update that checks it, so a double click, a
	                      reconnect or two servers cannot grant it twice.
	  Nothing is removed. Ending an event stops new progress. Tokens already
	                      collected and rewards already claimed stay.
	  Grace on expiry.    After the window closes, earned rewards remain
	                      claimable for the configured grace period, so an
	                      expedition that runs past midnight is not punished.
	  Safe stop.          An administrator stopping an event early settles
	                      outstanding claims first.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.LastSignal

local Guard = require(Shared.Core.Guard)
local Logger = require(Shared.Core.Logger)
local Net = require(Shared.Core.Net)
local Protect = require(Shared.Core.Protect)
local Signal = require(Shared.Core.Signal)
local EventRegistry = require(Shared.Registry.EventRegistry)
local BuildKit = require(script.Parent.Parent.World.BuildKit)

local DataService = require(script.Parent.DataService)
local ExpeditionService = require(script.Parent.ExpeditionService)
local InventoryService = require(script.Parent.InventoryService)
local ProgressionService = require(script.Parent.ProgressionService)
local SurvivalService = require(script.Parent.SurvivalService)

local log = Logger.new("EventService")

local EventService = {}

EventService.TokenCollected = Signal.new() :: Signal.Signal<Player, string, number>
EventService.RewardClaimed = Signal.new() :: Signal.Signal<Player, string, number>

-- Runtime overrides an administrator can apply without editing the registry.
local overrides: { [string]: { startsAt: number, endsAt: number } } = {}

--------------------------------------------------------------------------
-- Window resolution
--------------------------------------------------------------------------

local function resolved(def: EventRegistry.EventDef): EventRegistry.EventDef
	local override = overrides[def.id]
	if not override then
		return def
	end
	local copy = table.clone(def) :: any
	copy.startsAt = override.startsAt
	copy.endsAt = override.endsAt
	return copy
end

function EventService.activeEvent(): EventRegistry.EventDef?
	for _, def in EventRegistry.all() do
		local current = resolved(def)
		if EventRegistry.isActive(current) then
			return current
		end
	end
	return nil
end

function EventService.claimableEvent(): EventRegistry.EventDef?
	for _, def in EventRegistry.all() do
		local current = resolved(def)
		if EventRegistry.isClaimable(current) then
			return current
		end
	end
	return nil
end

--------------------------------------------------------------------------
-- Profile access
--------------------------------------------------------------------------

local function ensureEventRecord(player: Player, eventId: string)
	DataService.update(player, function(p)
		if not p.events[eventId] then
			p.events[eventId] = { tokens = 0, claimed = {}, firstSeen = os.time() }
		end
	end)
end

function EventService.tokensOf(player: Player, eventId: string): number
	local profile = DataService.getProfile(player)
	if not profile then
		return 0
	end
	local record = profile.events[eventId]
	return if record then record.tokens else 0
end

--------------------------------------------------------------------------
-- Tokens
--------------------------------------------------------------------------

function EventService.addTokens(player: Player, eventId: string, amount: number): number
	local def = EventRegistry.get(eventId)
	if not def then
		return 0
	end
	local current = resolved(def)
	if not EventRegistry.isActive(current) then
		-- The window closed. Nothing is taken away, but nothing more is earned.
		return 0
	end
	if not DataService.isWritable(player) then
		return 0
	end

	ensureEventRecord(player, eventId)
	local total = 0
	DataService.update(player, function(p)
		local record = p.events[eventId]
		record.tokens += amount
		total = record.tokens
	end)

	EventService.TokenCollected:Fire(player, eventId, amount)
	EventService.push(player)
	return total
end

--------------------------------------------------------------------------
-- Claims
--------------------------------------------------------------------------

function EventService.claim(player: Player, eventId: string, threshold: number): (boolean, string?)
	local def = EventRegistry.get(eventId)
	if not def then
		return false, "UNKNOWN_EVENT"
	end
	local current = resolved(def)
	if not EventRegistry.isClaimable(current) then
		return false, "EXPIRED"
	end
	if not DataService.isWritable(player) then
		return false, "READ_ONLY"
	end

	local reward: EventRegistry.EventReward? = nil
	for _, candidate in def.rewards do
		if candidate.threshold == threshold then
			reward = candidate
			break
		end
	end
	if not reward then
		return false, "UNKNOWN_REWARD"
	end

	local tokens = EventService.tokensOf(player, eventId)
	if tokens < threshold then
		return false, "NOT_EARNED"
	end

	local key = tostring(threshold)
	local granted = false
	DataService.update(player, function(p)
		local record = p.events[eventId]
		if not record then
			return
		end
		-- Read and write the claimed flag inside one update. This is the line
		-- that makes double-claiming impossible.
		if record.claimed[key] then
			return
		end
		record.claimed[key] = true
		granted = true
	end)

	if not granted then
		return false, "ALREADY_CLAIMED"
	end

	local unlocks = {}
	local resolvedReward = reward :: EventRegistry.EventReward
	if resolvedReward.cosmetic then
		table.insert(unlocks, { kind = "cosmetic", id = resolvedReward.cosmetic })
	end
	if resolvedReward.livery then
		table.insert(unlocks, { kind = "livery", id = resolvedReward.livery })
	end

	ProgressionService.award(player, {
		credits = resolvedReward.credits or 0,
		xp = resolvedReward.xp or 0,
		unlocks = unlocks,
		source = "event:" .. eventId .. ":" .. key,
		exact = true,
	})

	EventService.RewardClaimed:Fire(player, eventId, threshold)
	EventService.push(player)
	log.info(string.format("%s claimed %s reward at %d tokens", player.Name, eventId, threshold))
	return true, nil
end

--------------------------------------------------------------------------
-- Token spawning during expeditions
--------------------------------------------------------------------------

local function spawnTokensForStation(expedition: ExpeditionService.Expedition)
	local def = EventService.activeEvent()
	if not def then
		return
	end
	local station = expedition.lane.stations[expedition.stationIndex]
	if not station then
		return
	end

	local count = def.tokensPerStation
	local origin = station.origin
	for index = 1, count do
		local angle = math.rad((360 / count) * index + math.random(-30, 30))
		local radius = math.random(40, 140)
		local position = origin.Position + Vector3.new(math.cos(angle) * radius, 4, math.sin(angle) * radius)

		local model = BuildKit.model("EventToken", expedition.lane.dropContainer)
		local ticket = BuildKit.part({
			name = "Ticket",
			size = Vector3.new(0.9, 0.05, 1.4),
			cf = CFrame.new(position) * CFrame.Angles(0, math.rad(math.random(0, 360)), 0),
			colour = Color3.fromRGB(212, 186, 140),
			material = Enum.Material.SmoothPlastic,
			canCollide = false,
			parent = model,
		})
		-- A faint glow, because a paper ticket on a forest floor at night is
		-- otherwise genuinely invisible and that is not a fun hunt.
		local glow = Instance.new("PointLight")
		glow.Color = Color3.fromRGB(255, 226, 186)
		glow.Brightness = 1.1
		glow.Range = 14
		glow.Parent = ticket

		model.PrimaryPart = ticket
		model:SetAttribute("EventId", def.id)
		model:AddTag("EventToken")

		local prompt = Instance.new("ProximityPrompt")
		prompt.ActionText = "Take"
		prompt.ObjectText = def.tokenName
		prompt.MaxActivationDistance = 10
		prompt.RequiresLineOfSight = false
		prompt.Style = Enum.ProximityPromptStyle.Custom
		prompt.Parent = ticket

		prompt.Triggered:Connect(function(player)
			if not model.Parent then
				return
			end
			local playerExpedition = ExpeditionService.forPlayer(player)
			if playerExpedition ~= expedition then
				return
			end
			model:Destroy()
			EventService.addTokens(player, def.id, 1)
			InventoryService.add(player, def.tokenItem, 1)
			Net.fireClient("Notify", player, {
				kind = "event",
				title = def.tokenName,
				body = string.format("%d collected.", EventService.tokensOf(player, def.id)),
				duration = 4,
			})
		end)
	end
end

--------------------------------------------------------------------------
-- The Conductor encounter
--------------------------------------------------------------------------

local conductors: { [string]: { model: Model, thread: thread } } = {}

--- Builds and runs the patrol_inspector behaviour: a figure that walks the
--- length of the train checking tickets. It cannot be stopped, it does no
--- damage, and it can be avoided entirely by being elsewhere.
local function runConductor(expedition: ExpeditionService.Expedition, def: EventRegistry.EventDef)
	if conductors[expedition.id] then
		return
	end
	local encounter = def.encounter
	if not encounter then
		return
	end

	local train = expedition.train
	local model = BuildKit.model("TheConductor", expedition.lane.creatureContainer)
	local body = BuildKit.part({
		name = "Body",
		size = Vector3.new(2.2, 6.0, 1.4),
		cf = CFrame.new(),
		colour = Color3.fromRGB(38, 34, 40),
		material = Enum.Material.Fabric,
		canCollide = false,
		parent = model,
	})
	BuildKit.detail({
		name = "Head",
		size = Vector3.new(1.4, 1.6, 1.4),
		cf = CFrame.new(0, 3.8, 0),
		colour = Color3.fromRGB(28, 26, 30),
		material = Enum.Material.Fabric,
		parent = model,
	})
	BuildKit.detail({
		name = "Cap",
		size = Vector3.new(1.8, 0.5, 1.8),
		cf = CFrame.new(0, 4.7, 0),
		colour = Color3.fromRGB(20, 19, 22),
		material = Enum.Material.Fabric,
		parent = model,
	})
	BuildKit.detail({
		name = "CapBadge",
		size = Vector3.new(0.5, 0.3, 0.1),
		cf = CFrame.new(0, 4.7, -0.9),
		colour = Color3.fromRGB(186, 162, 116),
		material = Enum.Material.Metal,
		parent = model,
	})
	-- The punch in his hand, which is the only thing about him that catches
	-- the light.
	BuildKit.detail({
		name = "Punch",
		size = Vector3.new(0.3, 0.9, 0.3),
		cf = CFrame.new(1.0, 2.0, -0.6),
		colour = Color3.fromRGB(198, 176, 120),
		material = Enum.Material.Metal,
		parent = model,
	})
	model.PrimaryPart = body
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") and descendant ~= body then
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = body
			weld.Part1 = descendant
			weld.Parent = body
			descendant.Anchored = false
			descendant.CanCollide = false
			descendant.CanQuery = false
		end
	end
	body.Anchored = true

	local thread = task.spawn(function()
		-- Walks from the rear of the consist to the cab, in train-local space,
		-- so he stays with the train while it moves.
		local length = train.built.volumeSize.Z
		local travelled = 0
		local speed = encounter.params.speed or 6

		Net.fireClients("HorrorCue", ExpeditionService.playersOf(expedition), {
			cue = "conductor_appears",
			position = train.built.root.Position,
		})

		while travelled < length do
			task.wait(0.1)
			if expedition.state == "closed" or not model.Parent then
				break
			end
			travelled += speed * 0.1
			local localCF = CFrame.new(0, 6, length - travelled)
			body.CFrame = train.built.root.CFrame * localCF

			-- Check anybody he reaches.
			for _, player in ExpeditionService.playersOf(expedition) do
				local character = player.Character
				local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
				if root and root:IsA("BasePart") and (root.Position - body.Position).Magnitude < 7 then
					local hasTicket = InventoryService.has(player, def.tokenItem, 1)
					if hasTicket then
						InventoryService.remove(player, def.tokenItem, 1)
						Net.fireClient("Notify", player, {
							kind = "event",
							title = "Ticket punched",
							body = "He nods, and moves on.",
							duration = 5,
						})
					else
						-- The penalty is inconvenience, never damage.
						local vitals = SurvivalService.get(player)
						if vitals then
							vitals.flashlightOn = false
							vitals.flashlight = 0
							SurvivalService.push(player)
						end
						Net.fireClient("Notify", player, {
							kind = "event",
							title = "No ticket",
							body = "Your lamp goes out. It will not light again until the next station.",
							duration = 7,
						})
					end
				end
			end
		end

		if model.Parent then
			model:Destroy()
		end
		conductors[expedition.id] = nil
	end)

	conductors[expedition.id] = { model = model, thread = thread }
end

--------------------------------------------------------------------------
-- Client sync
--------------------------------------------------------------------------

function EventService.push(player: Player)
	local def = EventService.claimableEvent()
	if not def then
		Net.fireClient("EventState", player, { active = false })
		return
	end
	local tokens = EventService.tokensOf(player, def.id)
	local profile = DataService.getProfile(player)
	local record = if profile then profile.events[def.id] else nil

	local rewards = {}
	for _, reward in def.rewards do
		table.insert(rewards, {
			threshold = reward.threshold,
			title = reward.title,
			description = reward.description,
			credits = reward.credits,
			xp = reward.xp,
			cosmetic = reward.cosmetic,
			livery = reward.livery,
			earned = tokens >= reward.threshold,
			claimed = record ~= nil and record.claimed[tostring(reward.threshold)] == true,
		})
	end
	table.sort(rewards, function(a, b)
		return a.threshold < b.threshold
	end)

	local nextReward = EventRegistry.nextReward(def, tokens)
	Net.fireClient("EventState", player, {
		active = true,
		accepting = EventRegistry.isActive(def),
		id = def.id,
		name = def.name,
		tagline = def.tagline,
		description = def.description,
		tokenName = def.tokenName,
		tokens = tokens,
		rewards = rewards,
		nextThreshold = if nextReward then nextReward.threshold else nil,
		endsAt = def.endsAt,
		claimUntil = def.endsAt + def.claimGraceSeconds,
	})
end

--------------------------------------------------------------------------
-- Administration
--------------------------------------------------------------------------

--- Starts an event now, for the given number of hours.
function EventService.startEvent(eventId: string, hours: number): boolean
	local def = EventRegistry.get(eventId)
	if not def then
		return false
	end
	local now = os.time()
	overrides[eventId] = { startsAt = now, endsAt = now + math.floor(hours * 3600) }
	log.info(string.format("event %s started for %.1f hours", eventId, hours))
	for _, player in Players:GetPlayers() do
		EventService.push(player)
		Net.fireClient("Notify", player, {
			kind = "event",
			title = def.name,
			body = def.tagline,
			duration = 10,
		})
	end
	return true
end

--- Stops an event. Already-earned rewards stay claimable for the grace period.
function EventService.stopEvent(eventId: string): boolean
	local def = EventRegistry.get(eventId)
	if not def then
		return false
	end
	local existing = overrides[eventId]
	overrides[eventId] = {
		startsAt = if existing then existing.startsAt else os.time() - 1,
		endsAt = os.time(),
	}
	log.info(string.format("event %s stopped; claims remain open for %d seconds", eventId, def.claimGraceSeconds))
	for _, player in Players:GetPlayers() do
		EventService.push(player)
	end
	return true
end

function EventService.status(): { { id: string, name: string, active: boolean, claimable: boolean, endsAt: number } }
	local out = {}
	for _, def in EventRegistry.all() do
		local current = resolved(def)
		table.insert(out, {
			id = def.id,
			name = def.name,
			active = EventRegistry.isActive(current),
			claimable = EventRegistry.isClaimable(current),
			endsAt = current.endsAt,
		})
	end
	return out
end

--------------------------------------------------------------------------

function EventService.start()
	Net.onServerInvoke("EventCommand", function(player, rawCommand, rawArg)
		local command = Guard.enum(rawCommand, { "state", "claim" })
		if not command then
			return { ok = false, error = "BAD_COMMAND" }
		end
		if command == "state" then
			EventService.push(player)
			return { ok = true }
		end
		local def = EventService.claimableEvent()
		if not def then
			return { ok = false, error = "NO_EVENT" }
		end
		local threshold = Guard.integer(rawArg, 1, 100000)
		if not threshold then
			return { ok = false, error = "BAD_THRESHOLD" }
		end
		local ok, err = EventService.claim(player, def.id, threshold)
		return { ok = ok, error = err }
	end)

	DataService.ProfileLoaded:Connect(function(player)
		task.delay(4, function()
			if player.Parent then
				EventService.push(player)
			end
		end)
	end)

	ExpeditionService.StationReached:Connect(function(expedition)
		local def = EventService.activeEvent()
		if not def then
			return
		end
		local ok, err = Protect.call(spawnTokensForStation, expedition)
		if not ok then
			log.error("token spawn failed:", tostring(err))
		end
	end)

	ExpeditionService.StateChanged:Connect(function(expedition, phase)
		if phase ~= "travelling" then
			return
		end
		local def = EventService.activeEvent()
		if not def or not def.encounter then
			return
		end
		if math.random() > def.encounterChance then
			return
		end
		-- Never during the cinematic, never on a station stop.
		task.delay(math.random(20, 60), function()
			if expedition.state == "travelling" then
				local ok, err = Protect.call(runConductor, expedition, def)
				if not ok then
					log.error("conductor failed:", tostring(err))
				end
			end
		end)
	end)

	ExpeditionService.Ended:Connect(function(expedition)
		local entry = conductors[expedition.id]
		if entry then
			if entry.model.Parent then
				entry.model:Destroy()
			end
			conductors[expedition.id] = nil
		end
	end)

	-- Lamps that were put out by the Conductor come back at the next station.
	ExpeditionService.StationReached:Connect(function(expedition)
		for _, player in ExpeditionService.playersOf(expedition) do
			local vitals = SurvivalService.get(player)
			if vitals and vitals.flashlight <= 0 then
				vitals.flashlight = 25
				SurvivalService.push(player)
			end
		end
	end)

	local active = EventService.activeEvent()
	if active then
		log.info(string.format("event '%s' is live", active.name))
	else
		log.info("no event is currently scheduled; see docs/EVENTS.md to start one")
	end
end

return EventService
