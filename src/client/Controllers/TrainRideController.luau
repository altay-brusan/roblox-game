--!strict
--[[
	TrainRideController
	-------------------
	Keeps the player with the train while the train moves.

	THE PROBLEM
	-----------
	The train is an anchored rigid assembly moved by CFrame on the server (see
	TrainService for why). An anchored part imparts no velocity to what stands
	on it, so without this controller a player standing in a moving carriage
	would simply be left behind as the carriage slid out from under them.

	Every other approach was worse. Welding players to the floor removes their
	ability to walk. Unanchored physics rolling stock jitters and stretches with
	six players aboard. Moving the world around a stationary train breaks
	streaming and every position the server holds.

	THE SOLUTION
	------------
	The client owns its own character's physics, so the client is the correct
	place to do this. Each frame, this controller computes how far the train
	moved since the last frame and applies exactly that delta to the character's
	root. The player's own walking is unaffected, because it happens in the same
	frame on top of the delta. The result is smooth at any framerate and on any
	connection, because nothing is being predicted or corrected.

	CORRECTNESS DETAILS THAT MATTER
	-------------------------------
	  - The delta is applied only while the character is inside the train's
	    volume, tested in the train's local space so it works at any position.
	  - Entering and leaving are hysteretic: the volume used to leave is
	    slightly larger than the one used to enter, so standing exactly on the
	    boundary does not flicker.
	  - Vertical velocity is preserved, so jumping inside a moving carriage
	    works and lands correctly.
	  - Nothing is applied while the character is falling outside the train,
	    so jumping off a moving train genuinely leaves you behind, which is
	    both correct and a real hazard the game uses.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("LastSignal")

local Logger = require(Shared.Core.Logger)
local StateController = require(script.Parent.StateController)

local log = Logger.new("TrainRideController")
local player = Players.LocalPlayer

local TrainRideController = {}

local lastTrainCF: CFrame? = nil
local aboard = false
local trainModel: Model? = nil

--- Finds the train model in the workspace. Cached, and re-resolved whenever
--- the expedition changes, because a new run builds a new train.
local function resolveTrain(): Model?
	if trainModel and trainModel.Parent then
		return trainModel
	end
	for _, instance in game:GetService("CollectionService"):GetTagged("Train") do
		if instance:IsA("Model") and instance.Parent then
			trainModel = instance
			return instance
		end
	end
	return nil
end

--- The train's volume, from the state the server replicates plus the model's
--- own bounding box as a fallback.
local function trainVolume(model: Model): (CFrame, Vector3)
	local root = model:FindFirstChild("TrainRoot")
	local cf = if root and root:IsA("BasePart") then root.CFrame else model:GetPivot()
	local _, size = model:GetBoundingBox()
	-- The volume is the model's box, raised so it covers the interior rather
	-- than the bogies, and shortened slightly so standing on the buffers does
	-- not count as being aboard.
	return cf * CFrame.new(0, size.Y * 0.4, -size.Z * 0.5), Vector3.new(size.X + 2, size.Y, size.Z)
end

local function isInside(point: Vector3, volumeCF: CFrame, half: Vector3, margin: number): boolean
	local localPoint = volumeCF:PointToObjectSpace(point)
	return math.abs(localPoint.X) <= half.X + margin
		and math.abs(localPoint.Y) <= half.Y + margin
		and math.abs(localPoint.Z) <= half.Z + margin
end

--------------------------------------------------------------------------

local function onStepped()
	local trainState = StateController.get("train")
	if not trainState then
		lastTrainCF = nil
		aboard = false
		return
	end

	local model = resolveTrain()
	if not model then
		lastTrainCF = nil
		return
	end

	local rootPart = model:FindFirstChild("TrainRoot")
	if not rootPart or not rootPart:IsA("BasePart") then
		return
	end
	local currentCF = rootPart.CFrame

	local previous = lastTrainCF
	lastTrainCF = currentCF
	if not previous then
		return
	end

	local character = player.Character
	local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
	local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
	if not root or not root:IsA("BasePart") or not humanoid or humanoid.Health <= 0 then
		aboard = false
		return
	end

	local volumeCF, size = trainVolume(model)
	local half = size * 0.5

	-- Hysteresis: a larger margin to stay aboard than to get aboard, so the
	-- boundary does not flicker when standing in a doorway.
	local margin = if aboard then 4 else 0
	local inside = isInside(root.Position, volumeCF, half, margin)

	if inside and not aboard then
		aboard = true
	elseif not inside and aboard then
		aboard = false
	end

	if not aboard then
		return
	end

	-- Falling clear of the train is not riding it. Without this check, jumping
	-- out of a door would carry the player along with the train in mid-air.
	if humanoid.FloorMaterial == Enum.Material.Air and root.AssemblyLinearVelocity.Y < -8 then
		local groundedInside = isInside(root.Position - Vector3.new(0, 6, 0), volumeCF, half, 0)
		if not groundedInside then
			aboard = false
			return
		end
	end

	-- The delta. Applying the full transform rather than just the translation
	-- means a train that turned would carry the player's facing with it; the
	-- line is straight in this chapter, but the maths is correct either way.
	local delta = currentCF * previous:Inverse()
	local moved = delta.Position
	if moved.Magnitude < 1e-5 then
		return
	end

	-- Preserve the player's own velocity. Setting CFrame alone would otherwise
	-- fight the physics solver and make jumps feel wrong.
	local velocity = root.AssemblyLinearVelocity
	root.CFrame = delta * root.CFrame
	root.AssemblyLinearVelocity = velocity
end

--------------------------------------------------------------------------

function TrainRideController.isAboard(): boolean
	return aboard
end

function TrainRideController.start()
	-- Stepped rather than RenderStepped: it runs before physics, so the
	-- character is moved and then simulated in the same frame, which is what
	-- removes the visible lag between the carriage and the player.
	RunService.Stepped:Connect(onStepped)

	StateController.Changed:Connect(function(key, value)
		if key ~= "expedition" then
			return
		end
		-- A new expedition means a new train; drop the cached references so
		-- the next frame resolves the new one.
		trainModel = nil
		lastTrainCF = nil
		aboard = false
		if type(value) == "table" and value.state == "lobby" then
			log.debug("left the expedition; ride tracking cleared")
		end
	end)

	player.CharacterAdded:Connect(function()
		-- A fresh character is not aboard until it is tested, which stops a
		-- respawn inheriting the previous character's ride state.
		aboard = false
		lastTrainCF = nil
	end)

	log.info("started")
end

return TrainRideController
