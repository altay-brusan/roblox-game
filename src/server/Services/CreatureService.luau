--!strict
--[[
	CreatureService
	---------------
	The Signal-Eater: its body, its senses and its behaviour.

	IDENTITY
	--------
	Tall, thin, and wrong in the joints. It moves on four long limbs with a
	body slung between them, low to the ground, so its silhouette against the
	trees reads as an animal until it stands up, and then it does not. It has
	no face; the head is a smooth cowl with a cluster of antennae where a face
	should be. That is the identity: it is shaped like something that listens.

	It is named for what it does. It eats signals. It learns sounds it hears
	repeatedly and reproduces them: a saw, a radio callsign, a crew member's
	voice. The mimicry in RadioScript is this creature, not a separate system.

	BEHAVIOUR
	---------
	A four-state machine, driven by hearing first and sight second:

	  patrol       moves along the line, slow, indifferent
	  investigate  walks to a heard position, looks around, gives up
	  hunt         has a target, pursues, loses interest without stimulus
	  retreat      driven off, leaves and does not return for a while

	COUNTERPLAY, WHICH IS THE POINT
	-------------------------------
	It cannot be killed. Damage fills a drive-off meter instead of a health
	bar, so weapons matter without turning the forest into a shooting range.
	It will not enter a lit carriage. The train horn drives it back at close
	range. A burning flare denies an area. Breaking line of sight and staying
	quiet makes it lose you. Every one of those is available on the first run
	with no unlocks and no purchases.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.LastSignal

local Balance = require(Shared.Config.Balance)
local GameConfig = require(Shared.Config.GameConfig)
local Logger = require(Shared.Core.Logger)
local Net = require(Shared.Core.Net)
local Protect = require(Shared.Core.Protect)
local Signal = require(Shared.Core.Signal)
local BuildKit = require(script.Parent.Parent.World.BuildKit)

local ExpeditionService = require(script.Parent.ExpeditionService)
local ProgressionService = require(script.Parent.ProgressionService)
local SurvivalService = require(script.Parent.SurvivalService)

local log = Logger.new("CreatureService")

local C = Color3.fromRGB

local CreatureService = {}

export type Creature = {
	id: string,
	expeditionId: string,
	model: Model,
	root: BasePart,
	limbs: { BasePart },
	head: BasePart,

	state: string, -- "patrol" | "investigate" | "hunt" | "retreat"
	stateSince: number,
	position: Vector3,
	facing: Vector3,
	speed: number,

	targetUserId: number?,
	investigatePoint: Vector3?,
	lastHeardAt: number,
	lastSeenTargetAt: number,

	driveOffMeter: number,
	retreatUntil: number,
	deniedZones: { { position: Vector3, radius: number, until_: number } },

	lastAttackAt: number,
	lastCallAt: number,
	-- Sounds it has heard often enough to imitate.
	learnedCues: { [string]: number },
}

local creatures: { [string]: Creature } = {}
local nextCreatureNumber = 0

CreatureService.Spawned = Signal.new() :: Signal.Signal<Creature>
CreatureService.Retreated = Signal.new() :: Signal.Signal<Creature, string>
CreatureService.Attacked = Signal.new() :: Signal.Signal<Creature, Player>

--------------------------------------------------------------------------
-- Body
--------------------------------------------------------------------------

local function buildBody(parent: Instance): (Model, BasePart, BasePart, { BasePart })
	local model = BuildKit.model("SignalEater", nil)
	local shell = C(38, 40, 44)
	local darker = C(24, 25, 28)

	-- Torso: slung low and horizontal, not upright. This is the silhouette.
	local root = BuildKit.part({
		name = "Torso",
		size = Vector3.new(3.2, 3.0, 7.0),
		cf = CFrame.new(),
		colour = shell,
		material = Enum.Material.Slate,
		canCollide = false,
		parent = model,
	})
	BuildKit.detail({
		name = "Spine",
		size = Vector3.new(0.7, 1.2, 7.6),
		cf = CFrame.new(0, 1.6, 0),
		colour = darker,
		material = Enum.Material.Slate,
		parent = model,
	})
	-- Ribbing along the flanks, which catches a flashlight beam and makes the
	-- shape readable at the edge of the light.
	for i = -2, 2 do
		for _, side in { -1, 1 } do
			BuildKit.detail({
				name = "Rib",
				size = Vector3.new(0.4, 2.6, 0.35),
				cf = CFrame.new(side * 1.5, 0.2, i * 1.3) * CFrame.Angles(0, 0, math.rad(side * 14)),
				colour = darker,
				material = Enum.Material.Slate,
				parent = model,
			})
		end
	end

	-- Head: a smooth cowl with no face, and an antenna cluster instead.
	local head = BuildKit.part({
		name = "Head",
		size = Vector3.new(2.0, 1.8, 2.8),
		cf = CFrame.new(0, 0.8, -4.4),
		colour = shell,
		material = Enum.Material.Slate,
		canCollide = false,
		parent = model,
	})
	BuildKit.detail({
		name = "Cowl",
		size = Vector3.new(2.3, 1.2, 1.6),
		cf = CFrame.new(0, 1.2, -4.0),
		colour = darker,
		material = Enum.Material.Slate,
		parent = model,
	})
	for i = 1, 7 do
		local angle = math.rad(-60 + i * 20)
		BuildKit.detail({
			name = "Antenna",
			size = Vector3.new(0.12, 0.12, 2.4 - math.abs(i - 4) * 0.3),
			cf = CFrame.new(0, 1.4, -5.0) * CFrame.Angles(math.rad(-25), angle, 0) * CFrame.new(0, 0, -1.2),
			colour = C(70, 66, 60),
			material = Enum.Material.Metal,
			parent = model,
		})
	end

	-- Four long limbs, each in three segments, folded high above the body.
	local limbs: { BasePart } = {}
	for _, side in { -1, 1 } do
		for _, front in { -1, 1 } do
			local shoulder = CFrame.new(side * 1.4, 0.8, front * 2.6)
			local upper = BuildKit.detail({
				name = "LimbUpper",
				size = Vector3.new(0.6, 5.2, 0.6),
				cf = shoulder * CFrame.new(side * 1.2, 2.2, 0) * CFrame.Angles(0, 0, math.rad(side * -22)),
				colour = darker,
				material = Enum.Material.Slate,
				parent = model,
			})
			local lower = BuildKit.detail({
				name = "LimbLower",
				size = Vector3.new(0.5, 5.6, 0.5),
				cf = shoulder * CFrame.new(side * 2.6, -1.4, front * 0.4) * CFrame.Angles(math.rad(front * 12), 0, math.rad(side * 16)),
				colour = darker,
				material = Enum.Material.Slate,
				parent = model,
			})
			BuildKit.detail({
				name = "Foot",
				size = Vector3.new(0.5, 0.4, 1.8),
				cf = shoulder * CFrame.new(side * 3.2, -4.2, front * 0.8),
				colour = C(18, 19, 21),
				material = Enum.Material.Slate,
				parent = model,
			})
			table.insert(limbs, upper)
			table.insert(limbs, lower)
		end
	end

	model.PrimaryPart = root
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") and descendant ~= root then
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = root
			weld.Part1 = descendant
			weld.Parent = root
			descendant.Anchored = false
			descendant.CanCollide = false
			descendant.CanQuery = false
		end
	end
	root.Anchored = true
	model:AddTag("Creature")
	model.Parent = parent

	return model, root, head, limbs
end

--------------------------------------------------------------------------
-- Senses
--------------------------------------------------------------------------

local function canSee(creature: Creature, position: Vector3): boolean
	local delta = position - creature.position
	local distance = delta.Magnitude
	if distance > Balance.Creature.sightRadius then
		return false
	end
	if distance < 6 then
		return true
	end
	local forward = creature.facing
	local angle = math.deg(math.acos(math.clamp(forward:Dot(delta.Unit), -1, 1)))
	return angle <= Balance.Creature.sightAngle * 0.5
end

--- Whether a position is inside a zone the creature refuses to enter: a lit
--- train, or an area denied by a burning flare.
local function isDenied(creature: Creature, position: Vector3): boolean
	for _, zone in creature.deniedZones do
		if os.clock() < zone.until_ and (position - zone.position).Magnitude < zone.radius then
			return true
		end
	end
	return false
end

local function pruneZones(creature: Creature)
	for index = #creature.deniedZones, 1, -1 do
		if os.clock() >= creature.deniedZones[index].until_ then
			table.remove(creature.deniedZones, index)
		end
	end
end

--------------------------------------------------------------------------
-- Spawning
--------------------------------------------------------------------------

function CreatureService.spawn(expedition: ExpeditionService.Expedition, position: Vector3): Creature
	nextCreatureNumber += 1
	local model, root, head, limbs = buildBody(expedition.lane.creatureContainer)
	root.CFrame = CFrame.new(position)

	local creature: Creature = {
		id = string.format("creature_%d", nextCreatureNumber),
		expeditionId = expedition.id,
		model = model,
		root = root,
		head = head,
		limbs = limbs,
		state = "patrol",
		stateSince = os.clock(),
		position = position,
		facing = Vector3.new(0, 0, -1),
		speed = Balance.Creature.patrolSpeed,
		targetUserId = nil,
		investigatePoint = nil,
		lastHeardAt = 0,
		lastSeenTargetAt = 0,
		driveOffMeter = 0,
		retreatUntil = 0,
		deniedZones = {},
		lastAttackAt = 0,
		lastCallAt = 0,
		learnedCues = {},
	}

	creatures[creature.id] = creature
	CreatureService.Spawned:Fire(creature)
	log.info(string.format("spawned %s for expedition %s", creature.id, expedition.id))
	return creature
end

function CreatureService.despawnFor(expeditionId: string)
	for id, creature in creatures do
		if creature.expeditionId == expeditionId then
			creature.model:Destroy()
			creatures[id] = nil
		end
	end
end

function CreatureService.forExpedition(expeditionId: string): { Creature }
	local out: { Creature } = {}
	for _, creature in creatures do
		if creature.expeditionId == expeditionId then
			table.insert(out, creature)
		end
	end
	return out
end

function CreatureService.count(expeditionId: string): number
	return #CreatureService.forExpedition(expeditionId)
end

--------------------------------------------------------------------------
-- Stimuli
--------------------------------------------------------------------------

--- A noise anywhere in the world. Loud enough and close enough, the creature
--- goes to look. This is the primary sense and the primary counterplay:
--- staying quiet genuinely works.
function CreatureService.hearNoise(expeditionId: string, position: Vector3, loudness: number)
	for _, creature in CreatureService.forExpedition(expeditionId) do
		if creature.state == "retreat" then
			continue
		end
		local distance = (position - creature.position).Magnitude
		local radius = Balance.Creature.hearingRadius * math.clamp(loudness / 14, 0.2, 2.5)
		if distance <= radius then
			creature.lastHeardAt = os.clock()
			creature.investigatePoint = position
			if creature.state == "patrol" then
				creature.state = "investigate"
				creature.stateSince = os.clock()
			end
		end
	end
end

--- Damage does not kill. It fills the drive-off meter, and a full meter sends
--- the creature away for a while.
function CreatureService.applyDamage(creature: Creature, amount: number, by: Player?)
	creature.driveOffMeter += amount
	if creature.driveOffMeter >= Balance.Creature.damageToDriveOff then
		CreatureService.driveOff(creature, "damage", by)
	elseif creature.state == "patrol" then
		creature.state = "investigate"
		creature.investigatePoint = creature.position
		creature.stateSince = os.clock()
	end
end

function CreatureService.driveOff(creature: Creature, reason: string, by: Player?)
	if creature.state == "retreat" then
		return
	end
	creature.state = "retreat"
	creature.stateSince = os.clock()
	creature.retreatUntil = os.clock() + Balance.Creature.drivenOffSeconds
	creature.driveOffMeter = 0
	creature.targetUserId = nil

	local expedition = ExpeditionService.byId(creature.expeditionId)
	if expedition then
		Net.fireClients("HorrorCue", ExpeditionService.playersOf(expedition), {
			cue = "creature_repelled",
			position = creature.position,
		})
		if by then
			ProgressionService.addStat(by, "creature_repelled", 1)
		else
			for _, player in ExpeditionService.playersOf(expedition) do
				ProgressionService.addStat(player, "creature_repelled", 1)
			end
		end
	end
	CreatureService.Retreated:Fire(creature, reason)
end

--- The horn. Drives it back at close range and makes it flinch further out.
function CreatureService.hearHorn(expeditionId: string, position: Vector3)
	for _, creature in CreatureService.forExpedition(expeditionId) do
		local distance = (position - creature.position).Magnitude
		if distance <= Balance.Creature.hornRepelRadius then
			CreatureService.driveOff(creature, "horn", nil)
		elseif distance <= Balance.Train.hornNoiseRadius then
			-- Outside repel range the horn is still just a very loud noise, so
			-- using it carelessly calls the thing towards you.
			CreatureService.hearNoise(expeditionId, position, Balance.Threat.noisePerHorn)
		end
	end
end

--- A flare, a burning brazier or a lit carriage: ground it will not cross.
function CreatureService.denyArea(expeditionId: string, position: Vector3, radius: number, seconds: number)
	for _, creature in CreatureService.forExpedition(expeditionId) do
		table.insert(creature.deniedZones, { position = position, radius = radius, until_ = os.clock() + seconds })
		-- If it is standing in the new zone, it leaves immediately.
		if (creature.position - position).Magnitude < radius then
			creature.state = "investigate"
			creature.investigatePoint = creature.position + (creature.position - position).Unit * (radius + 30)
			creature.stateSince = os.clock()
		end
	end
end

--- Sounds the creature hears repeatedly become sounds it can imitate.
function CreatureService.learnCue(expeditionId: string, cue: string)
	for _, creature in CreatureService.forExpedition(expeditionId) do
		creature.learnedCues[cue] = (creature.learnedCues[cue] or 0) + 1
	end
end

function CreatureService.knownCues(expeditionId: string): { string }
	local out: { string } = {}
	for _, creature in CreatureService.forExpedition(expeditionId) do
		for cue, count in creature.learnedCues do
			if count >= 3 and not table.find(out, cue) then
				table.insert(out, cue)
			end
		end
	end
	return out
end

--------------------------------------------------------------------------
-- Behaviour
--------------------------------------------------------------------------

local function nearestTarget(creature: Creature, expedition: ExpeditionService.Expedition): (Player?, Vector3?, number)
	local best: Player? = nil
	local bestPosition: Vector3? = nil
	local bestDistance = math.huge
	for _, player in ExpeditionService.playersOf(expedition) do
		local state = SurvivalService.get(player)
		if not state or state.state == "dead" then
			continue
		end
		local character = player.Character
		local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
		if root and root:IsA("BasePart") then
			local distance = (root.Position - creature.position).Magnitude
			if distance < bestDistance then
				bestDistance = distance
				best = player
				bestPosition = root.Position
			end
		end
	end
	return best, bestPosition, bestDistance
end

local function moveTowards(creature: Creature, destination: Vector3, dt: number)
	local delta = destination - creature.position
	local flat = Vector3.new(delta.X, 0, delta.Z)
	if flat.Magnitude < 1 then
		return
	end
	local direction = flat.Unit

	-- Refuse to walk into denied ground. Rather than pathfinding around it,
	-- the creature sidesteps: it is not meant to be clever, it is meant to be
	-- consistent, so players can learn what it will and will not do.
	local step = direction * creature.speed * dt
	local candidate = creature.position + step
	if isDenied(creature, candidate) then
		local sidestep = Vector3.new(-direction.Z, 0, direction.X)
		candidate = creature.position + sidestep * creature.speed * dt
		if isDenied(creature, candidate) then
			return
		end
	end

	creature.position = candidate
	creature.facing = direction

	-- Sit it on the ground. A raycast down keeps it on terrain and on station
	-- floors without needing a Humanoid or pathfinding.
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { creature.model }
	local hit = workspace:Raycast(creature.position + Vector3.new(0, 60, 0), Vector3.new(0, -200, 0), params)
	local groundY = if hit then hit.Position.Y else creature.position.Y
	creature.position = Vector3.new(creature.position.X, groundY + 4.5, creature.position.Z)

	creature.root.CFrame = CFrame.lookAt(creature.position, creature.position + creature.facing)
end

local function stepCreature(creature: Creature, dt: number)
	local expedition = ExpeditionService.byId(creature.expeditionId)
	if not expedition or expedition.state == "closed" then
		creature.model:Destroy()
		creatures[creature.id] = nil
		return
	end

	pruneZones(creature)

	-- The train is denied ground while its interior lights are on. This is the
	-- shelter promise: a lit carriage is safe, and going dark is what makes it
	-- stop being safe.
	local train = expedition.train
	if train.interiorLights and train.engineRunning then
		local trainPosition = train.built.root.Position
		local alreadyDenied = false
		for _, zone in creature.deniedZones do
			if zone.position == trainPosition then
				alreadyDenied = true
				break
			end
		end
		if not alreadyDenied then
			table.insert(creature.deniedZones, {
				position = trainPosition,
				radius = 40,
				until_ = os.clock() + 2,
			})
		end
	end

	local now = os.clock()
	local target, targetPosition, targetDistance = nearestTarget(creature, expedition)

	if creature.state == "retreat" then
		creature.speed = Balance.Creature.chaseSpeed
		-- Walk away from the crew, then go quiet until the timer expires.
		if targetPosition then
			local away = creature.position + (creature.position - targetPosition).Unit * 100
			moveTowards(creature, away, dt)
		end
		if now >= creature.retreatUntil then
			creature.state = "patrol"
			creature.stateSince = now
		end
		return
	end

	if creature.state == "hunt" then
		creature.speed = Balance.Creature.chaseSpeed
		local hunted = if creature.targetUserId then Players:GetPlayerByUserId(creature.targetUserId) else nil
		local huntedState = if hunted then SurvivalService.get(hunted) else nil
		local huntedCharacter = if hunted then hunted.Character else nil
		local huntedRoot = if huntedCharacter then huntedCharacter:FindFirstChild("HumanoidRootPart") else nil

		if not hunted or not huntedRoot or not huntedRoot:IsA("BasePart") or not huntedState or huntedState.state == "dead" then
			creature.state = "investigate"
			creature.stateSince = now
			creature.targetUserId = nil
			return
		end

		local huntedPosition = (huntedRoot :: BasePart).Position
		if canSee(creature, huntedPosition) then
			creature.lastSeenTargetAt = now
		end

		-- Losing it requires breaking line of sight and then staying quiet.
		if (now - creature.lastSeenTargetAt) > Balance.Creature.loseInterestSeconds and (now - creature.lastHeardAt) > Balance.Creature.loseInterestSeconds then
			creature.state = "investigate"
			creature.investigatePoint = huntedPosition
			creature.stateSince = now
			creature.targetUserId = nil
			return
		end
		if (now - creature.stateSince) > Balance.Creature.chaseSeconds and (now - creature.lastSeenTargetAt) > 3 then
			creature.state = "patrol"
			creature.stateSince = now
			creature.targetUserId = nil
			return
		end

		if isDenied(creature, huntedPosition) then
			-- The target reached shelter. It circles rather than giving up
			-- immediately, which is what makes shelter feel earned.
			local orbit = huntedPosition + (creature.position - huntedPosition).Unit * 55
			moveTowards(creature, orbit, dt)
			return
		end

		moveTowards(creature, huntedPosition, dt)

		local distance = (huntedPosition - creature.position).Magnitude
		if distance <= Balance.Creature.attackRange and (now - creature.lastAttackAt) >= Balance.Creature.attackCooldown then
			creature.lastAttackAt = now
			SurvivalService.damage(hunted, Balance.Creature.attackDamage, "creature")
			Net.fireClients("HorrorCue", ExpeditionService.playersOf(expedition), {
				cue = "creature_attack",
				position = creature.position,
			})
			CreatureService.Attacked:Fire(creature, hunted)
		end
		return
	end

	if creature.state == "investigate" then
		creature.speed = Balance.Creature.investigateSpeed
		local point = creature.investigatePoint
		if point then
			moveTowards(creature, point, dt)
			if (creature.position - point).Magnitude < 8 then
				creature.investigatePoint = nil
			end
		end

		-- Acquire a target if one is visible from here.
		if target and targetPosition and canSee(creature, targetPosition) and not isDenied(creature, targetPosition) then
			creature.state = "hunt"
			creature.stateSince = now
			creature.targetUserId = target.UserId
			creature.lastSeenTargetAt = now
			Net.fireClients("HorrorCue", ExpeditionService.playersOf(expedition), {
				cue = "creature_chase",
				position = creature.position,
				targetUserId = target.UserId,
			})
			return
		end

		if (now - creature.stateSince) > Balance.Creature.investigateSeconds then
			creature.state = "patrol"
			creature.stateSince = now
		end
		return
	end

	-- patrol
	creature.speed = Balance.Creature.patrolSpeed
	if target and targetPosition and targetDistance < Balance.Creature.sightRadius and canSee(creature, targetPosition) and not isDenied(creature, targetPosition) then
		creature.state = "hunt"
		creature.stateSince = now
		creature.targetUserId = target.UserId
		creature.lastSeenTargetAt = now
		return
	end

	-- Drift along the railway, staying at the edge of where the crew is.
	local drift = creature.position + creature.facing * 40
	if math.random() < 0.02 then
		local angle = math.rad(math.random(0, 360))
		drift = creature.position + Vector3.new(math.cos(angle), 0, math.sin(angle)) * 60
	end
	moveTowards(creature, drift, dt)

	-- The occasional distant call, which is most of what players actually
	-- experience of this creature.
	if (now - creature.lastCallAt) > 45 and math.random() < 0.02 then
		creature.lastCallAt = now
		Net.fireClients("HorrorCue", ExpeditionService.playersOf(expedition), {
			cue = "creature_distant",
			position = creature.position,
		})
	end
end

--------------------------------------------------------------------------

function CreatureService.start()
	local accumulator = 0
	local interval = 1 / GameConfig.CreatureTickRate
	game:GetService("RunService").Heartbeat:Connect(function(dt)
		accumulator += dt
		if accumulator < interval then
			return
		end
		local step = accumulator
		accumulator = 0
		for id, creature in creatures do
			local ok, err = Protect.call(stepCreature, creature, step)
			if not ok then
				log.error(string.format("creature %s step failed: %s", id, tostring(err)))
			end
		end
	end)

	ExpeditionService.Ended:Connect(function(expedition)
		CreatureService.despawnFor(expedition.id)
	end)

	log.info("started")
end

return CreatureService
