--!strict
--[[
	TrainRideController
	-------------------
	Renders moving trains smoothly and keeps the player with the train they
	are riding.

	THE PROBLEM
	-----------
	The train is an anchored rigid assembly moved by CFrame on the server (see
	TrainService for why). Two things follow from that:

	  - An anchored part imparts no velocity to what stands on it, so a player
	    standing in a moving carriage would be left behind.
	  - The server moves the train at its tick rate, and replicated CFrame
	    changes on anchored parts are not interpolated. Drawn as received, the
	    train visibly steps, and a passenger carried by those steps stutters.

	THE SOLUTION
	------------
	The server publishes, as attributes on the train model, where the line
	starts (OriginCFrame), how far along it the train is (Distance), how fast
	it is moving (Velocity) and when that sample was taken (SampleTime). Every
	frame, before the camera updates, this controller extrapolates the
	distance from that sample, blends out any prediction error over a few
	frames, and places the train locally. Each client therefore draws a train
	that moves continuously, whatever the network rate.

	A player riding the train is moved by exactly the change in the train's
	rendered pose since the previous frame. The client owns its character's
	physics, so the player's own walking happens on top of that delta and the
	result has no lag, no jitter and no sliding.

	CORRECTNESS DETAILS THAT MATTER
	-------------------------------
	  - "Aboard" is tested against the volume the train was built with
	    (VolumeSize and VolumeOffset attributes), in the train's local space.
	  - Entering and leaving are hysteretic, so standing in a doorway does not
	    flicker.
	  - Vertical velocity is preserved, so jumping inside a moving carriage
	    works and lands correctly.
	  - A player falling clear of the train is not carried, so jumping off a
	    moving train genuinely leaves you behind.
	  - The pose is reasserted in Stepped, before physics, in case replication
	    wrote the server's pose in between.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("LastSignal")

local Logger = require(Shared.Core.Logger)
local Net = require(Shared.Core.Net)

local log = Logger.new("TrainRideController")
local player = Players.LocalPlayer

local TrainRideController = {}

type Tracked = {
	rendered: number, -- distance currently drawn
	lastPose: CFrame?,
}

local tracked: { [Model]: Tracked } = {}
local riding: Model? = nil

-- How quickly a prediction error is blended out, per second. High enough
-- that a stop lands where the server says, low enough to hide a late packet.
local CORRECTION_RATE = 6
-- Errors beyond this are a teleport (a new run, a reset), not drift.
local SNAP_DISTANCE = 40

--------------------------------------------------------------------------

local function attribute<T>(model: Model, name: string, kind: string): T?
	local value = model:GetAttribute(name)
	if typeof(value) == kind then
		return value :: any
	end
	return nil
end

--- The distance the server's latest sample says the train is at now.
local function predictedDistance(model: Model): number?
	local distance = attribute(model, "Distance", "number") :: number?
	if not distance then
		return nil
	end
	local velocity = (attribute(model, "Velocity", "number") :: number?) or 0
	local sampleTime = (attribute(model, "SampleTime", "number") :: number?) or Workspace:GetServerTimeNow()
	local age = math.clamp(Workspace:GetServerTimeNow() - sampleTime, 0, 0.5)
	local predicted = distance + velocity * age
	-- Never extrapolate through a stop point: the server will not pass it.
	local stop = attribute(model, "StopDistance", "number") :: number?
	if stop and velocity > 0 and predicted > stop then
		predicted = stop
	end
	return math.max(predicted, 0)
end

local function poseFor(model: Model, distance: number): CFrame?
	local origin = attribute(model, "OriginCFrame", "CFrame") :: CFrame?
	if not origin then
		return nil
	end
	return origin * CFrame.new(0, 0, -distance)
end

local function rootOf(model: Model): BasePart?
	local root = model.PrimaryPart
	if root and root.Parent then
		return root
	end
	return nil
end

local function isInside(model: Model, pose: CFrame, point: Vector3, margin: number): boolean
	local size = attribute(model, "VolumeSize", "Vector3") :: Vector3?
	local offset = attribute(model, "VolumeOffset", "CFrame") :: CFrame?
	if not size or not offset then
		return false
	end
	local localPoint = (pose * offset):PointToObjectSpace(point)
	local half = size * 0.5
	return math.abs(localPoint.X) <= half.X + margin
		and math.abs(localPoint.Y) <= half.Y + margin
		and math.abs(localPoint.Z) <= half.Z + margin
end

--------------------------------------------------------------------------

--- Advances one train's rendered distance and returns its pose this frame
--- and the pose it had last frame.
local function advance(model: Model, state: Tracked, dt: number): (CFrame?, CFrame?)
	local target = predictedDistance(model)
	if not target then
		return nil, nil
	end
	local velocity = (attribute(model, "Velocity", "number") :: number?) or 0
	local rendered = state.rendered + velocity * dt
	local err = target - rendered
	if math.abs(err) > SNAP_DISTANCE then
		rendered = target
	else
		rendered += err * math.min(1, CORRECTION_RATE * dt)
	end
	state.rendered = rendered
	local pose = poseFor(model, rendered)
	local previous = state.lastPose
	state.lastPose = pose
	return pose, previous
end

local function carryCharacter(model: Model, pose: CFrame, previous: CFrame)
	local character = player.Character
	local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
	local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
	if not root or not root:IsA("BasePart") or not humanoid or humanoid.Health <= 0 then
		if riding == model then
			riding = nil
		end
		return
	end

	-- Hysteresis: a larger margin to stay aboard than to get aboard.
	local wasAboard = riding == model
	local inside = isInside(model, previous, root.Position, if wasAboard then 3 else 0)
	if inside and not wasAboard then
		riding = model
	elseif not inside and wasAboard then
		riding = nil
	end
	if riding ~= model then
		return
	end

	-- A seated passenger is welded to a seat on the train and already moves
	-- with it; carrying them as well would move them twice.
	local seat = humanoid.SeatPart
	if seat and seat:IsDescendantOf(model) then
		return
	end

	-- Falling clear of the train is not riding it.
	if humanoid.FloorMaterial == Enum.Material.Air and root.AssemblyLinearVelocity.Y < -8 then
		if not isInside(model, previous, root.Position - Vector3.new(0, 6, 0), 0) then
			riding = nil
			return
		end
	end

	local delta = pose * previous:Inverse()
	if delta.Position.Magnitude < 1e-5 then
		return
	end
	local velocity = root.AssemblyLinearVelocity
	root.CFrame = delta * root.CFrame
	root.AssemblyLinearVelocity = velocity
end

local function onRender(dt: number)
	for model, state in tracked do
		if not model.Parent then
			tracked[model] = nil
			continue
		end
		local root = rootOf(model)
		local pose, previous = advance(model, state, dt)
		if not root or not pose then
			continue
		end
		root.CFrame = pose
		if previous then
			carryCharacter(model, pose, previous)
		end
	end
end

-- Physics runs after rendering. Replication may have written the server's
-- pose in between, so the rendered pose is reasserted before the solver
-- sees the floor the character is standing on.
local function onStepped()
	for model, state in tracked do
		local root = rootOf(model)
		if root and state.lastPose then
			root.CFrame = state.lastPose
		end
	end
end

local function track(instance: Instance)
	if not instance:IsA("Model") or tracked[instance] then
		return
	end
	tracked[instance] = { rendered = predictedDistance(instance) or 0, lastPose = nil }
end

--------------------------------------------------------------------------

function TrainRideController.isAboard(): boolean
	return riding ~= nil
end

--- The train the local player is riding, if any.
function TrainRideController.ridingModel(): Model?
	return riding
end

--- The tunnel crossing. The server names where on the expedition train this
--- player should stand; the client, which owns its character, moves there,
--- and holds the character still until the train it is standing in has
--- streamed in, so nobody falls through a floor that has not arrived yet.
type Crossing = {
	relative: CFrame,
	model: Model?,
	origin: CFrame,
	distance: number,
	velocity: number,
	sampleTime: number,
}

local function crossToLine(crossing: Crossing)
	local character = player.Character
	local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
	local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
	if not root or not root:IsA("BasePart") or not humanoid then
		return
	end
	humanoid.Sit = false
	riding = nil

	-- Where the train is now: from the model once it has streamed in, and
	-- until then from the motion sample the server sent with the crossing.
	-- The train is rolling, so the character is held to the moving train,
	-- not to a fixed point it would be left behind at.
	local function trainPose(): (CFrame, boolean)
		local model = crossing.model
		if model and model.Parent and model.PrimaryPart then
			return model.PrimaryPart.CFrame, true
		end
		local age = Workspace:GetServerTimeNow() - crossing.sampleTime
		return crossing.origin * CFrame.new(0, 0, -(crossing.distance + crossing.velocity * age)), false
	end

	root.Anchored = true
	local deadline = os.clock() + 5
	repeat
		local pose, streamed = trainPose()
		root.CFrame = pose * crossing.relative
		root.AssemblyLinearVelocity = Vector3.zero
		if streamed then
			break
		end
		RunService.Heartbeat:Wait()
	until os.clock() > deadline
	root.Anchored = false
	local pose = trainPose()
	root.CFrame = pose * crossing.relative
	root.AssemblyLinearVelocity = Vector3.zero
end

function TrainRideController.start()
	Net.onClientEvent("CrossToLine", function(payload)
		if
			type(payload) ~= "table"
			or typeof(payload.relative) ~= "CFrame"
			or typeof(payload.origin) ~= "CFrame"
			or type(payload.distance) ~= "number"
			or type(payload.velocity) ~= "number"
			or type(payload.sampleTime) ~= "number"
		then
			return
		end
		crossToLine({
			relative = payload.relative,
			model = if typeof(payload.model) == "Instance" and payload.model:IsA("Model") then payload.model else nil,
			origin = payload.origin,
			distance = payload.distance,
			velocity = payload.velocity,
			sampleTime = payload.sampleTime,
		})
	end)

	for _, instance in CollectionService:GetTagged("Train") do
		track(instance)
	end
	CollectionService:GetInstanceAddedSignal("Train"):Connect(track)
	CollectionService:GetInstanceRemovedSignal("Train"):Connect(function(instance)
		if instance:IsA("Model") then
			tracked[instance] = nil
			if riding == instance then
				riding = nil
			end
		end
	end)

	-- Before the camera, so the first-person view is drawn from where the
	-- carried character actually is this frame.
	RunService:BindToRenderStep("LastSignalTrainRide", Enum.RenderPriority.Camera.Value - 1, onRender)
	RunService.Stepped:Connect(onStepped)

	player.CharacterAdded:Connect(function()
		-- A fresh character is not aboard until it is tested.
		riding = nil
	end)

	log.info("started")
end

return TrainRideController
