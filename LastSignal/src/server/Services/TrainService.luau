--!strict
--[[
	TrainService
	------------
	Drives the train: movement, cab controls, lights, doors, fuel and condition.

	MOVEMENT MODEL
	--------------
	The train is a welded rigid assembly on an anchored root (see TrainBuilder).
	This service integrates speed on a fixed tick and writes the root CFrame.
	It does not use physics forces, constraints or a PrismaticConstraint, and
	that is deliberate: rolling stock driven by Roblox physics with six players
	walking around inside it produces jitter, stretched welds and passengers
	falling through floors, every time. A kinematically driven rigid body has
	none of those failure modes and is also far cheaper.

	Passengers ride by reference frame. Each tick the server publishes the
	train's CFrame and the delta since the last tick; clients apply that delta
	to their own character while it is inside the train volume. The client owns
	its character's physics, so the result is smooth at any framerate. See
	TrainRideController.

	AUTHORITY
	---------
	One driver at a time, and only while seated in the driver's seat. Control
	inputs are validated against that, rate limited by Net, and clamped. A
	client cannot set speed directly; it can only move the levers.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Shared = ReplicatedStorage.LastSignal

local Balance = require(Shared.Config.Balance)
local GameConfig = require(Shared.Config.GameConfig)
local Guard = require(Shared.Core.Guard)
local Logger = require(Shared.Core.Logger)
local Net = require(Shared.Core.Net)
local Protect = require(Shared.Core.Protect)
local Signal = require(Shared.Core.Signal)
local TrainRegistry = require(Shared.Registry.TrainRegistry)
local TrainBuilder = require(script.Parent.Parent.World.TrainBuilder)

local log = Logger.new("TrainService")

local TrainService = {}

export type TrainState = {
	crewId: string,
	built: TrainBuilder.BuiltTrain,
	def: TrainRegistry.TrainDef,

	-- Kinematics --------------------------------------------------------
	distance: number, -- studs travelled from the lane origin
	speed: number, -- studs per second, always >= 0
	direction: number, -- 1 forward, -1 reverse, 0 neutral
	throttle: number, -- 0 .. notches
	serviceBrake: number, -- 0 .. 1
	emergencyBrake: boolean,
	wheelAngle: number,

	-- Resources ----------------------------------------------------------
	fuel: number,
	condition: number,
	overheating: boolean,
	coolantUntil: number,

	-- Systems --------------------------------------------------------------
	headlights: boolean,
	cabinLights: boolean,
	interiorLights: boolean,
	wipers: boolean,
	doorsOpen: boolean,
	engineRunning: boolean,

	-- Authority --------------------------------------------------------------
	driverUserId: number?,

	-- Where the train is allowed to travel to. The expedition sets this to the
	-- next station so the train cannot be driven past the chapter.
	targetDistance: number,
	stopDistance: number?,

	-- Where distance zero is. The pose is always origin * (0, 0, -distance).
	origin: CFrame,

	-- True while train protection is braking for a stop.
	protectionBraking: boolean,

	-- A yard service train is worked by the yard pilot, not by players: it
	-- drives itself to a target speed and refuses driver and door controls.
	pilot: Pilot?,
	isService: boolean,

	-- Bookkeeping.
	lastTick: number,
	lastCFrame: CFrame,
	emergencyBrakeCooldown: { [number]: number },
	doorCooldown: { [number]: number },
}

export type Pilot = {
	targetSpeed: number,
	acceleration: number,
}

export type SpawnOptions = {
	-- Doors open on arrival. Defaults to true, which is how a train waits.
	doorsOpen: boolean?,
	-- A yard service train worked by the yard pilot.
	service: boolean?,
}

local trains: { [string]: TrainState } = {}

TrainService.SpeedChanged = Signal.new() :: Signal.Signal<TrainState, number>
TrainService.EmergencyBrake = Signal.new() :: Signal.Signal<TrainState, Player?>
TrainService.HornSounded = Signal.new() :: Signal.Signal<TrainState, Player?>
TrainService.Stalled = Signal.new() :: Signal.Signal<TrainState, string>
TrainService.ArrivedAt = Signal.new() :: Signal.Signal<TrainState, number>
TrainService.DoorsToggled = Signal.new() :: Signal.Signal<TrainState, boolean>

--------------------------------------------------------------------------
-- Creation
--------------------------------------------------------------------------

function TrainService.spawn(
	crewId: string,
	trainId: string,
	liveryId: string?,
	interiorId: string?,
	originCF: CFrame,
	parent: Instance,
	options: SpawnOptions?
): TrainState
	local opts: SpawnOptions = options or {}
	local def = TrainRegistry.getOrStarter(trainId)
	local built = TrainBuilder.build(trainId, liveryId, interiorId, originCF, parent, 20217)

	local state: TrainState = {
		crewId = crewId,
		built = built,
		def = def,
		distance = 0,
		speed = 0,
		direction = 0,
		throttle = 0,
		serviceBrake = 1, -- parked with the brake on, which is how a train sits
		emergencyBrake = false,
		wheelAngle = 0,
		fuel = Balance.Train.maxFuel * 0.55,
		condition = Balance.Train.maxCondition,
		overheating = false,
		coolantUntil = 0,
		headlights = true,
		cabinLights = true,
		interiorLights = true,
		wipers = false,
		doorsOpen = if opts.doorsOpen == nil then true else opts.doorsOpen,
		engineRunning = true,
		driverUserId = nil,
		targetDistance = 0,
		stopDistance = nil,
		origin = originCF,
		protectionBraking = false,
		pilot = nil,
		isService = opts.service == true,
		lastTick = os.clock(),
		lastCFrame = originCF,
		emergencyBrakeCooldown = {},
		doorCooldown = {},
	}

	trains[crewId] = state
	TrainService.publishMotion(state, true)
	TrainService.applyLights(state)
	TrainService.applyDoors(state, true)
	log.info(string.format("spawned %s for crew %s (%d parts)", def.name, crewId, built.partCount))
	return state
end

function TrainService.despawn(crewId: string)
	local state = trains[crewId]
	if not state then
		return
	end
	state.built.model:Destroy()
	trains[crewId] = nil
end

function TrainService.get(crewId: string): TrainState?
	return trains[crewId]
end

--------------------------------------------------------------------------
-- Presentation helpers
--------------------------------------------------------------------------

function TrainService.applyLights(state: TrainState)
	-- Condition failures cut lighting before they cut motion, because a train
	-- going dark is a better warning than a train stopping.
	local failing = state.condition < Balance.Train.conditionFailureThreshold
	local powered = state.engineRunning

	for _, spot in state.built.headlights do
		spot.Enabled = powered and state.headlights
		spot.Brightness = if failing then 2.6 else 4.5
	end
	for _, light in state.built.cabinLights do
		light.Enabled = powered and state.cabinLights
	end
	for _, light in state.built.interiorLights do
		light.Enabled = powered and state.interiorLights
	end
	for _, light in state.built.tailLights do
		light.Enabled = powered
	end

	-- Lens emissive follows the lamp, so the headlight reads as on from outside.
	for _, descendant in state.built.model:GetDescendants() do
		if descendant:IsA("BasePart") and descendant:HasTag("HeadlampLens") then
			descendant.Material = if (powered and state.headlights) then Enum.Material.Neon else Enum.Material.SmoothPlastic
		end
	end
end

local DOOR_OPEN_ANGLE = math.rad(105)

--- Swings every door of a built train open or closed. Doors are articulated
--- joints (see TrainBuilder), so this moves the leaves and nothing else.
function TrainService.setDoorsPose(built: TrainBuilder.BuiltTrain, open: boolean, immediate: boolean?)
	local target = if open then DOOR_OPEN_ANGLE else 0
	for _, door in built.doors do
		local hinge = door.hinge
		-- A new request supersedes a swing still in progress.
		local token = (tonumber(hinge:GetAttribute("SwingToken")) or 0) + 1
		hinge:SetAttribute("SwingToken", token)
		local from = tonumber(hinge:GetAttribute("OpenAngle")) or 0
		if immediate or from == target then
			hinge:SetAttribute("OpenAngle", target)
			TrainBuilder.pose(hinge, CFrame.Angles(0, target, 0))
			continue
		end
		local duration = Balance.Train.doorOpenSeconds
		task.spawn(function()
			local elapsed = 0
			while elapsed < duration do
				elapsed += task.wait()
				if hinge:GetAttribute("SwingToken") ~= token or not hinge.Parent then
					return
				end
				-- Ease out, so a pneumatic door does not snap.
				local alpha = 1 - (1 - math.clamp(elapsed / duration, 0, 1)) ^ 3
				local angle = from + (target - from) * alpha
				hinge:SetAttribute("OpenAngle", angle)
				TrainBuilder.pose(hinge, CFrame.Angles(0, angle, 0))
			end
		end)
	end
end

function TrainService.applyDoors(state: TrainState, immediate: boolean?)
	TrainService.setDoorsPose(state.built, state.doorsOpen, immediate)
	TrainService.DoorsToggled:Fire(state, state.doorsOpen)
end

local function applyGauges(state: TrainState)
	local cab = state.built.cab
	local function setNeedle(needle: BasePart, fraction: number)
		-- Needles sweep 240 degrees, which is what a real dial does. The needle
		-- is an articulated joint, so only it moves; and it is only rewritten
		-- when it would visibly move, to keep replication quiet.
		local angle = math.rad(-120 + math.clamp(fraction, 0, 1) * 240)
		local last = tonumber(needle:GetAttribute("NeedleAngle"))
		if last and math.abs(last - angle) < math.rad(0.75) then
			return
		end
		needle:SetAttribute("NeedleAngle", angle)
		TrainBuilder.pose(needle, CFrame.Angles(0, angle, 0))
	end

	setNeedle(cab.speedNeedle, state.speed / (Balance.Train.maxSpeed * state.def.handling.maxSpeedMultiplier))
	setNeedle(cab.fuelNeedle, state.fuel / Balance.Train.maxFuel)
	setNeedle(cab.conditionNeedle, state.condition / Balance.Train.maxCondition)
end

--------------------------------------------------------------------------
-- Simulation
--------------------------------------------------------------------------

local function targetAcceleration(state: TrainState): number
	local handling = state.def.handling
	local pilot = state.pilot
	if pilot then
		-- The pilot drives smoothly to its target speed and coasts above it.
		-- Train protection still applies on top, so a piloted train always
		-- draws up at its stop point.
		if state.speed < pilot.targetSpeed - 0.5 then
			return pilot.acceleration
		elseif state.speed > pilot.targetSpeed + 0.5 then
			return -Balance.Train.serviceBrakeDeceleration * 0.4
		end
		return 0
	end
	if state.emergencyBrake then
		return -Balance.Train.emergencyBrakeDeceleration * handling.brakingMultiplier
	end
	if state.serviceBrake > 0.01 then
		return -Balance.Train.serviceBrakeDeceleration * handling.brakingMultiplier * state.serviceBrake
	end
	if state.direction == 0 or state.throttle <= 0 or not state.engineRunning then
		return -Balance.Train.coastDeceleration
	end
	return Balance.Train.accelerationPerNotch * state.throttle * handling.accelerationMultiplier
end

local function maxSpeedFor(state: TrainState): number
	if state.direction < 0 then
		return Balance.Train.reverseMaxSpeed
	end
	local base = Balance.Train.maxSpeed * state.def.handling.maxSpeedMultiplier
	-- A damaged train cannot reach full speed. This is the mechanical failure
	-- the brief asks for: it changes how you play rather than just ticking down.
	if state.condition < Balance.Train.conditionFailureThreshold then
		base *= 0.6
	end
	if state.overheating then
		base *= 0.5
	end
	return base
end

--- Publishes the motion sample TrainRideController extrapolates from. Only
--- written while something changes, so a parked train costs no bandwidth.
function TrainService.publishMotion(state: TrainState, force: boolean?)
	local model = state.built.model
	local velocity = if state.direction ~= 0 then state.speed * state.direction else 0
	local moving = math.abs(velocity) > 1e-3
	local wasMoving = model:GetAttribute("Velocity") ~= 0
	if force then
		model:SetAttribute("OriginCFrame", state.origin)
	end
	if force or moving or wasMoving then
		model:SetAttribute("Distance", state.distance)
		model:SetAttribute("Velocity", velocity)
		model:SetAttribute("SampleTime", workspace:GetServerTimeNow())
	end
	model:SetAttribute("StopDistance", state.stopDistance)
end

local function step(state: TrainState, dt: number)
	local handling = state.def.handling

	-- Speed integration.
	local acceleration = targetAcceleration(state)
	state.speed = math.max(0, state.speed + acceleration * dt)
	state.speed = math.min(state.speed, maxSpeedFor(state))

	-- Train protection. Approaching a stop point, speed is held to the curve
	-- from which the train can still draw up at it, and the train brakes
	-- itself, firmly but not violently, when the driver comes in too fast.
	state.protectionBraking = false
	local stop = state.stopDistance
	if stop and state.direction > 0 then
		local remaining = math.max(0, stop - state.distance)
		local curve = math.sqrt(2 * Balance.Train.stationApproachDeceleration * remaining) + 1.5
		if state.speed > curve then
			-- Protection cuts traction as it brakes, as the real thing does;
			-- otherwise an open throttle cancels the braking out.
			state.throttle = 0
			state.speed = math.max(curve, state.speed - Balance.Train.emergencyBrakeDeceleration * dt)
			state.protectionBraking = true
		end
	end

	-- A train with the doors open does not move above a crawl, which removes
	-- the entire class of "somebody drove off while I was boarding" problems
	-- without taking control away from the driver.
	if state.doorsOpen then
		state.speed = math.min(state.speed, Balance.Train.boardingSpeedLimit)
	end

	-- Fuel. Idle drain plus a distance-proportional burn.
	if state.engineRunning then
		local burn = Balance.Train.fuelIdleDrainPerSecond * dt
		burn += state.speed * dt * Balance.Train.fuelPerStudAtFullSpeed * handling.fuelUseMultiplier
		state.fuel = math.max(0, state.fuel - burn)
		if state.fuel <= 0 then
			state.engineRunning = false
			state.throttle = 0
			TrainService.applyLights(state)
			TrainService.Stalled:Fire(state, "fuel")
		end
	end

	-- Condition drift, faster under load and when overheating.
	local drift = (Balance.Train.conditionDriftPerMinute / 60) * handling.conditionDriftMultiplier * dt
	if state.speed > maxSpeedFor(state) * 0.85 then
		drift *= 1.6
	end
	if state.overheating then
		drift *= 2.2
	end
	state.condition = math.max(0, state.condition - drift / math.max(0.2, handling.damageResistance))
	if state.condition <= 0 and state.engineRunning then
		state.engineRunning = false
		state.throttle = 0
		TrainService.applyLights(state)
		TrainService.Stalled:Fire(state, "condition")
	end

	-- Movement along the line.
	if state.speed > 0.01 and state.direction ~= 0 then
		local delta = state.speed * dt * state.direction
		local nextDistance = state.distance + delta

		-- A stop point is a hard limit, not a suggestion. The train decelerates
		-- into it and never passes it, which is what stops a crew from driving
		-- through a station or off the end of the built world.
		local limit = state.stopDistance
		if limit and nextDistance >= limit then
			nextDistance = limit
			state.speed = 0
			state.throttle = 0
			state.serviceBrake = 1
			TrainService.ArrivedAt:Fire(state, limit)
		end
		nextDistance = math.clamp(nextDistance, 0, GameConfig.TrackLength)
		state.distance = nextDistance

		-- Wheel rotation, derived from distance so it never drifts out of sync
		-- with actual movement.
		local radius = state.def.build.wheelRadius
		state.wheelAngle = (state.wheelAngle + delta / radius) % (math.pi * 2)
	end

	-- Write the pose, and publish the motion sample clients render from.
	local root = state.built.root
	state.lastCFrame = root.CFrame
	root.CFrame = state.origin * CFrame.new(0, 0, -state.distance)
	TrainService.publishMotion(state)

	applyGauges(state)
end

--------------------------------------------------------------------------
-- Driver authority
--------------------------------------------------------------------------

local function isDriver(state: TrainState, player: Player): boolean
	if state.driverUserId ~= player.UserId then
		return false
	end
	-- Seat occupancy is the authority, so leaving the seat gives up control
	-- immediately without needing a separate release action.
	local seat = state.built.cab.driverSeat
	local occupant = seat.Occupant
	if not occupant then
		return false
	end
	local character = occupant.Parent
	return character ~= nil and Players:GetPlayerFromCharacter(character) == player
end

--- Claims the controls. Refused when somebody else is already driving.
function TrainService.claimDriver(state: TrainState, player: Player): (boolean, string?)
	if state.isService then
		return false, "SERVICE_TRAIN"
	end
	local seat = state.built.cab.driverSeat
	local occupant = seat.Occupant
	if not occupant then
		return false, "NOT_SEATED"
	end
	local character = occupant.Parent
	if not character or Players:GetPlayerFromCharacter(character) ~= player then
		return false, "NOT_SEATED"
	end
	if state.driverUserId and state.driverUserId ~= player.UserId then
		local current = Players:GetPlayerByUserId(state.driverUserId)
		-- A driver who left the seat or the game releases control automatically.
		if current and isDriver(state, current) then
			return false, "OCCUPIED"
		end
	end
	state.driverUserId = player.UserId
	return true, nil
end

function TrainService.releaseDriver(state: TrainState, player: Player)
	if state.driverUserId == player.UserId then
		state.driverUserId = nil
		-- Leaving the controls applies the brake. A train left rolling with
		-- nobody at the desk is a griefing tool, not a feature.
		state.throttle = 0
		state.serviceBrake = 1
	end
end

--------------------------------------------------------------------------
-- Control inputs
--------------------------------------------------------------------------

local CONTROLS = {
	"throttle",
	"brake",
	"emergency",
	"reverser",
	"horn",
	"headlights",
	"cabin_lights",
	"interior_lights",
	"wipers",
	"doors",
	"start_engine",
}

function TrainService.applyControl(player: Player, state: TrainState, control: string, value: any): (boolean, string?)
	if state.isService then
		-- The yard pilot works this train; passengers ride it.
		return false, "SERVICE_TRAIN"
	end
	if not isDriver(state, player) then
		-- Doors are the exception: any crew member can work a carriage door
		-- from inside, which is how boarding works with one driver.
		if control ~= "doors" then
			return false, "NOT_DRIVER"
		end
	end

	if control == "throttle" then
		local notch = Guard.integer(value, 0, Balance.Train.notches)
		if not notch then
			return false, "BAD_VALUE"
		end
		if not state.engineRunning then
			return false, "ENGINE_OFF"
		end
		state.throttle = notch
		if notch > 0 then
			state.serviceBrake = 0
			state.emergencyBrake = false
		end
		return true, nil
	elseif control == "brake" then
		local amount = Guard.number(value, 0, 1)
		if not amount then
			return false, "BAD_VALUE"
		end
		state.serviceBrake = amount
		if amount > 0 then
			state.throttle = 0
		end
		return true, nil
	elseif control == "emergency" then
		local now = os.clock()
		local last = state.emergencyBrakeCooldown[player.UserId] or -math.huge
		if now - last < Balance.AntiGrief.emergencyBrakeCooldown then
			return false, "COOLDOWN"
		end
		state.emergencyBrakeCooldown[player.UserId] = now
		state.emergencyBrake = true
		state.throttle = 0
		state.condition = math.max(0, state.condition - Balance.Train.emergencyBrakeConditionCost)
		TrainService.EmergencyBrake:Fire(state, player)
		-- The emergency brake releases itself once stopped, as a real one does
		-- after the reservoir recharges.
		task.delay(4, function()
			if trains[state.crewId] == state then
				state.emergencyBrake = false
			end
		end)
		return true, nil
	elseif control == "reverser" then
		local dir = Guard.integer(value, -1, 1)
		if not dir then
			return false, "BAD_VALUE"
		end
		-- The reverser cannot be moved while rolling. That is both prototypical
		-- and stops instant direction flips being used as a brake.
		if state.speed > 1.5 then
			return false, "STILL_MOVING"
		end
		state.direction = dir
		return true, nil
	elseif control == "horn" then
		TrainService.HornSounded:Fire(state, player)
		return true, nil
	elseif control == "headlights" then
		state.headlights = not state.headlights
		TrainService.applyLights(state)
		return true, nil
	elseif control == "cabin_lights" then
		state.cabinLights = not state.cabinLights
		TrainService.applyLights(state)
		return true, nil
	elseif control == "interior_lights" then
		state.interiorLights = not state.interiorLights
		TrainService.applyLights(state)
		return true, nil
	elseif control == "wipers" then
		state.wipers = not state.wipers
		return true, nil
	elseif control == "doors" then
		local now = os.clock()
		local last = state.doorCooldown[player.UserId] or -math.huge
		if now - last < Balance.AntiGrief.doorToggleCooldown then
			return false, "COOLDOWN"
		end
		state.doorCooldown[player.UserId] = now
		if state.speed > Balance.Train.boardingSpeedLimit then
			return false, "MOVING"
		end
		state.doorsOpen = not state.doorsOpen
		TrainService.applyDoors(state)
		return true, nil
	elseif control == "start_engine" then
		if state.engineRunning then
			return false, "ALREADY_RUNNING"
		end
		if state.fuel <= 0 then
			return false, "NO_FUEL"
		end
		if state.condition <= 0 then
			return false, "NO_CONDITION"
		end
		state.engineRunning = true
		TrainService.applyLights(state)
		return true, nil
	end

	return false, "UNKNOWN_CONTROL"
end

--------------------------------------------------------------------------
-- Resources
--------------------------------------------------------------------------

function TrainService.addFuel(state: TrainState, amount: number): number
	local before = state.fuel
	state.fuel = math.clamp(state.fuel + amount, 0, Balance.Train.maxFuel)
	return state.fuel - before
end

function TrainService.repair(state: TrainState, amount: number): number
	local before = state.condition
	state.condition = math.clamp(state.condition + amount, 0, Balance.Train.maxCondition)
	TrainService.applyLights(state)
	return state.condition - before
end

function TrainService.applyCoolant(state: TrainState, seconds: number)
	state.coolantUntil = os.clock() + seconds
	state.overheating = false
end

function TrainService.setOverheating(state: TrainState, overheating: boolean)
	if overheating and os.clock() < state.coolantUntil then
		return
	end
	state.overheating = overheating
end

--- Puts a train at a distance along its line, at rest. Used to stand a
--- train at a platform without driving it there.
function TrainService.place(state: TrainState, distance: number)
	state.distance = distance
	state.speed = 0
	state.built.root.CFrame = state.origin * CFrame.new(0, 0, -distance)
	TrainService.publishMotion(state, true)
end

--- Hands the train to the yard pilot (or takes it back with nil). The pilot
--- drives forward to the target speed at the given acceleration.
function TrainService.setPilot(state: TrainState, targetSpeed: number?, acceleration: number?)
	if targetSpeed then
		state.pilot = { targetSpeed = targetSpeed, acceleration = acceleration or 1.5 }
		state.direction = 1
		state.serviceBrake = 0
		state.emergencyBrake = false
		state.throttle = 0
	else
		state.pilot = nil
	end
end

--- Whether a world position is inside the train, using the volume the
--- builder recorded. The same test TrainRideController uses on the client.
function TrainService.isInside(state: TrainState, position: Vector3, margin: number?): boolean
	local localPoint = (state.built.root.CFrame * state.built.volumeOffset):PointToObjectSpace(position)
	local half = state.built.volumeSize * 0.5
	local m = margin or 0
	return math.abs(localPoint.X) <= half.X + m and math.abs(localPoint.Y) <= half.Y + m and math.abs(localPoint.Z) <= half.Z + m
end

--- Sets the next hard stop. The expedition uses this to hold the train at a
--- station until its objectives are done.
function TrainService.setStopDistance(state: TrainState, distance: number?)
	state.stopDistance = distance
end

--------------------------------------------------------------------------
-- Client sync
--------------------------------------------------------------------------

local function describe(state: TrainState): { [string]: any }
	return {
		crewId = state.crewId,
		trainId = state.def.id,
		distance = state.distance,
		speed = state.speed,
		maxSpeed = maxSpeedFor(state),
		direction = state.direction,
		throttle = state.throttle,
		notches = Balance.Train.notches,
		serviceBrake = state.serviceBrake,
		emergencyBrake = state.emergencyBrake,
		fuel = state.fuel,
		maxFuel = Balance.Train.maxFuel,
		condition = state.condition,
		maxCondition = Balance.Train.maxCondition,
		engineRunning = state.engineRunning,
		overheating = state.overheating,
		headlights = state.headlights,
		cabinLights = state.cabinLights,
		interiorLights = state.interiorLights,
		wipers = state.wipers,
		doorsOpen = state.doorsOpen,
		driverUserId = state.driverUserId,
		wheelAngle = state.wheelAngle,
		-- The pose and the delta, which is what the client ride controller and
		-- the wheel animation need.
		cframe = state.built.root.CFrame,
		stopDistance = state.stopDistance,
		protectionBraking = state.protectionBraking,
	}
end

TrainService.describe = describe

--------------------------------------------------------------------------

local subscribers: { [string]: { Player } } = {}

function TrainService.setSubscribers(crewId: string, players: { Player })
	subscribers[crewId] = players
end

function TrainService.start()
	Net.onServerEvent("TrainControl", function(player, rawControl, rawValue)
		local control = Guard.enum(rawControl, CONTROLS)
		if not control then
			return
		end
		-- The player's train is the one for their crew; a client cannot name
		-- another crew's train.
		for _, state in trains do
			if state.driverUserId == player.UserId or control == "doors" then
				-- Confirm membership by proximity to the train, which also
				-- prevents a lobby player operating a train in a lane.
				local root = Guard.aliveRoot(player)
				if root then
					local distance = (root.Position - state.built.root.Position).Magnitude
					if distance < 400 then
						TrainService.applyControl(player, state, control, rawValue)
						return
					end
				end
			end
		end
	end)

	Net.onServerInvoke("TrainCommand", function(player, rawCommand)
		local command = Guard.enum(rawCommand, { "claim_driver", "release_driver", "state" })
		if not command then
			return { ok = false, error = "BAD_COMMAND" }
		end
		for _, state in trains do
			local seat = state.built.cab.driverSeat
			local occupant = seat.Occupant
			local character = if occupant then occupant.Parent else nil
			if character and Players:GetPlayerFromCharacter(character) == player then
				if command == "claim_driver" then
					local ok, err = TrainService.claimDriver(state, player)
					return { ok = ok, error = err, train = describe(state) }
				elseif command == "release_driver" then
					TrainService.releaseDriver(state, player)
					return { ok = true }
				else
					return { ok = true, train = describe(state) }
				end
			end
		end
		return { ok = false, error = "NOT_AT_CONTROLS" }
	end)

	-- Fixed-rate simulation. Running on a timer rather than per frame keeps CPU
	-- predictable and makes the physics identical regardless of server load.
	local accumulator = 0
	local tickInterval = 1 / GameConfig.TrainTickRate
	RunService.Heartbeat:Connect(function(dt)
		accumulator += dt
		if accumulator < tickInterval then
			return
		end
		local stepDelta = accumulator
		accumulator = 0

		for crewId, state in trains do
			local ok, err = Protect.call(step, state, stepDelta)
			if not ok then
				log.error(string.format("train step failed for %s: %s", crewId, tostring(err)))
			end

			-- Release a driver who left their seat or the game.
			if state.driverUserId then
				local driver = Players:GetPlayerByUserId(state.driverUserId)
				if not driver or not isDriver(state, driver) then
					state.driverUserId = nil
					state.throttle = 0
					state.serviceBrake = 1
				end
			end

			local audience = subscribers[crewId]
			if audience then
				Net.fireClients("TrainState", audience, describe(state))
			end
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		for _, state in trains do
			if state.driverUserId == player.UserId then
				TrainService.releaseDriver(state, player)
			end
		end
	end)

	log.info("started")
end

return TrainService
