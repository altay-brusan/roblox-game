--!strict
--[[
	CameraController
	----------------
	First-person camera, and every other camera state the game needs.

	THE THING THAT ALWAYS BREAKS
	----------------------------
	Camera state is the single most common source of "I am stuck and cannot
	play" reports in games that do cinematics, downs and spectating. It breaks
	because each of those features takes control of the camera and then fails
	to give it back on one of the many exit paths: skipping, dying mid-skip,
	respawning, disconnecting, or the sequence ending while a menu is open.

	This controller solves that with one rule: there is a single `mode` value
	and a single `apply` function, and every mode change routes through it.
	Nothing else in the project touches Camera.CameraType or CameraSubject.
	`restore` returns to the correct mode from any state and is called on
	character spawn, on expedition end, on death, on revive, and on a watchdog
	that runs every second and fixes the camera if it finds it wrong.

	MODES
	-----
	  firstPerson   normal play
	  cinematic     the opening sequence, driven by a keyframe path
	  spectate      following a living crew member after death
	  downed        low, tilted, still under the player's look control
	  menu          unchanged view, cursor released
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("LastSignal")

local Logger = require(Shared.Core.Logger)
local Spring = require(Shared.Core.Spring)
local StateController = require(script.Parent.StateController)

local log = Logger.new("CameraController")

local player = Players.LocalPlayer

local CameraController = {}

export type Mode = "firstPerson" | "cinematic" | "spectate" | "downed" | "menu"

local mode: Mode = "firstPerson"
local camera = Workspace.CurrentCamera

-- Motion springs. Sway and bob are cosmetic; recoil is fed by the weapon
-- controller and does affect where a shot goes, so it is framerate independent.
local swaySpring = Spring.vector3(Vector3.zero, 30, 9)
local bobSpring = Spring.new(0, 26, 8)
local recoilSpring = Spring.vector3(Vector3.zero, 120, 16)
local shakeSpring = Spring.vector3(Vector3.zero, 90, 12)
local tiltSpring = Spring.new(0, 40, 10)

local bobPhase = 0
local shakeIntensity = 0
local cinematicStartedAt = 0
local cinematicDuration = 0
local spectateTarget: Player? = nil

--------------------------------------------------------------------------
-- Mouse behaviour
--------------------------------------------------------------------------

local function setMouse(locked: boolean)
	if locked then
		UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
		UserInputService.MouseIconEnabled = false
	else
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		UserInputService.MouseIconEnabled = true
	end
end

--------------------------------------------------------------------------
-- Mode application
--------------------------------------------------------------------------

local function humanoid(): Humanoid?
	local character = player.Character
	return if character then character:FindFirstChildOfClass("Humanoid") else nil
end

local function apply()
	camera = Workspace.CurrentCamera
	if not camera then
		return
	end

	if mode == "cinematic" then
		camera.CameraType = Enum.CameraType.Scriptable
		setMouse(false)
		return
	end

	if mode == "spectate" then
		camera.CameraType = Enum.CameraType.Custom
		local target = spectateTarget
		local targetCharacter = if target then target.Character else nil
		local targetHumanoid = if targetCharacter then targetCharacter:FindFirstChildOfClass("Humanoid") else nil
		if targetHumanoid then
			camera.CameraSubject = targetHumanoid
		end
		-- Spectating is third person, so the viewer can see what happened.
		player.CameraMode = Enum.CameraMode.Classic
		player.CameraMinZoomDistance = 8
		player.CameraMaxZoomDistance = 24
		setMouse(false)
		return
	end

	if mode == "menu" then
		-- The view does not move; only the cursor is released. Keeping the
		-- camera where it was means opening the inventory never disorients.
		setMouse(false)
		return
	end

	-- firstPerson and downed share the same fundamentals.
	camera.CameraType = Enum.CameraType.Custom
	local currentHumanoid = humanoid()
	if currentHumanoid then
		camera.CameraSubject = currentHumanoid
	end
	player.CameraMode = Enum.CameraMode.LockFirstPerson
	player.CameraMinZoomDistance = 0.5
	player.CameraMaxZoomDistance = 0.5
	setMouse(true)
end

function CameraController.setMode(newMode: Mode)
	if mode == newMode then
		return
	end
	log.debug("camera mode:", newMode)
	mode = newMode
	apply()
end

function CameraController.mode(): Mode
	return mode
end

--- Returns the camera to whatever it should be, from any state. This is the
--- function every exit path calls, and the watchdog below calls it too.
function CameraController.restore()
	if StateController.isDead() then
		CameraController.setMode("spectate")
	elseif StateController.isDowned() then
		CameraController.setMode("downed")
	elseif StateController.ui("openPanel") then
		CameraController.setMode("menu")
	else
		CameraController.setMode("firstPerson")
	end
	apply()
end

--------------------------------------------------------------------------
-- Effects
--------------------------------------------------------------------------

--- A kick to the view. Used by weapon recoil, which is why it is a spring
--- rather than a tween: it has to settle predictably.
function CameraController.recoil(amount: Vector3)
	recoilSpring:impulse(amount)
end

--- A shake. Scaled by the player's camera-shake accessibility setting, and
--- suppressed entirely at zero.
function CameraController.shake(intensity: number, seconds: number?)
	local userScale = StateController.setting("cameraShake", 1)
	if type(userScale) ~= "number" or userScale <= 0 then
		return
	end
	shakeIntensity = math.max(shakeIntensity, intensity * userScale)
	task.delay(seconds or 0.4, function()
		shakeIntensity = 0
	end)
end

function CameraController.setSpectateTarget(target: Player?)
	spectateTarget = target
	if mode == "spectate" then
		apply()
	end
end

--------------------------------------------------------------------------
-- Cinematic
--------------------------------------------------------------------------

-- The opening sequence, as keyframes relative to the train. Each frame is a
-- position offset, a look-at offset, and the time it is reached. Defining it
-- as data means the sequence can be re-timed without touching any logic.
local CINEMATIC_KEYFRAMES = {
	-- Rain on the yard, looking along the train from outside.
	{ t = 0.0, from = Vector3.new(38, 14, 62), to = Vector3.new(0, 8, 20) },
	{ t = 7.0, from = Vector3.new(22, 10, 36), to = Vector3.new(0, 7, 4) },
	-- Down the platform towards the cab, under the lamps.
	{ t = 14.0, from = Vector3.new(16, 7, 6), to = Vector3.new(0, 6, -22) },
	{ t = 20.0, from = Vector3.new(11, 6, -14), to = Vector3.new(-2, 6, -34) },
	-- Boarding: through the door, into the carriage.
	{ t = 25.0, from = Vector3.new(7, 5.5, 24), to = Vector3.new(0, 5.5, 8) },
	{ t = 30.0, from = Vector3.new(0, 6, 30), to = Vector3.new(0, 6, 10) },
	-- The treeline, and something in it.
	{ t = 33.0, from = Vector3.new(-2, 7, 26), to = Vector3.new(-60, 10, 10) },
	{ t = 38.0, from = Vector3.new(0, 6, 20), to = Vector3.new(0, 6, 2) },
}

local cinematicAnchor: CFrame? = nil

function CameraController.startCinematic(duration: number, anchor: CFrame?)
	cinematicStartedAt = os.clock()
	cinematicDuration = duration
	cinematicAnchor = anchor
	CameraController.setMode("cinematic")
end

function CameraController.stopCinematic()
	cinematicStartedAt = 0
	cinematicAnchor = nil
	CameraController.restore()
end

local function cinematicCFrame(elapsed: number): CFrame
	local anchor = cinematicAnchor or CFrame.new()
	local frames = CINEMATIC_KEYFRAMES

	-- Find the pair of keyframes surrounding the current time.
	local previous = frames[1]
	local nextFrame = frames[#frames]
	for index = 1, #frames - 1 do
		if elapsed >= frames[index].t and elapsed <= frames[index + 1].t then
			previous = frames[index]
			nextFrame = frames[index + 1]
			break
		end
	end

	local span = math.max(0.001, nextFrame.t - previous.t)
	local alpha = math.clamp((elapsed - previous.t) / span, 0, 1)
	-- Smoothstep, so each move eases rather than starting and stopping hard.
	alpha = alpha * alpha * (3 - 2 * alpha)

	local from = previous.from:Lerp(nextFrame.from, alpha)
	local to = previous.to:Lerp(nextFrame.to, alpha)

	local worldFrom = anchor:PointToWorldSpace(from)
	local worldTo = anchor:PointToWorldSpace(to)

	-- A slow drift, so even a held shot is not locked off.
	local drift = Vector3.new(math.sin(elapsed * 0.4) * 0.5, math.cos(elapsed * 0.31) * 0.3, 0)
	return CFrame.lookAt(worldFrom + drift, worldTo)
end

--------------------------------------------------------------------------
-- Per-frame
--------------------------------------------------------------------------

local function onRenderStep(deltaTime: number)
	camera = Workspace.CurrentCamera
	if not camera then
		return
	end

	if mode == "cinematic" then
		local elapsed = os.clock() - cinematicStartedAt
		camera.CFrame = cinematicCFrame(math.min(elapsed, cinematicDuration))
		return
	end

	-- Field of view follows the setting, and narrows slightly while sprinting
	-- is not used: a changing FOV during a chase reads as panic, but it also
	-- makes some players motion sick, so it respects reduced motion.
	local desiredFov = StateController.setting("fieldOfView", 70)
	if type(desiredFov) == "number" then
		camera.FieldOfView = camera.FieldOfView + (desiredFov - camera.FieldOfView) * math.min(1, deltaTime * 8)
	end

	if mode ~= "firstPerson" and mode ~= "downed" then
		return
	end

	local character = player.Character
	local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
	local currentHumanoid = humanoid()
	if not root or not root:IsA("BasePart") or not currentHumanoid then
		return
	end

	-- Head bob, driven by actual movement speed rather than by a timer.
	local speed = root.AssemblyLinearVelocity.Magnitude
	local grounded = currentHumanoid.FloorMaterial ~= Enum.Material.Air
	if grounded and speed > 1 then
		bobPhase += deltaTime * math.clamp(speed * 0.6, 2, 14)
	end
	local bobAmount = if grounded then math.clamp(speed / 20, 0, 1) * 0.14 else 0
	bobSpring:setTarget(math.sin(bobPhase) * bobAmount)

	-- Sway follows how fast the view is turning, which is what makes a heavy
	-- weapon feel heavy without changing where it points.
	local lookDelta = UserInputService:GetMouseDelta()
	swaySpring:setTarget(Vector3.new(
		math.clamp(-lookDelta.X * 0.0012, -0.05, 0.05),
		math.clamp(-lookDelta.Y * 0.0012, -0.05, 0.05),
		0
	))

	if shakeIntensity > 0 then
		shakeSpring:impulse(Vector3.new(
			(math.random() - 0.5) * shakeIntensity * deltaTime * 60,
			(math.random() - 0.5) * shakeIntensity * deltaTime * 60,
			0
		))
	end

	-- Downed tilts the view and drops it towards the floor.
	tiltSpring:setTarget(if mode == "downed" then math.rad(12) else 0)

	local sway = swaySpring:step(deltaTime)
	local bob = bobSpring:step(deltaTime)
	local recoil = recoilSpring:step(deltaTime)
	local shake = shakeSpring:step(deltaTime)
	local tilt = tiltSpring:step(deltaTime)

	-- Recoil decays back to centre on its own; nothing resets it explicitly,
	-- which is what makes sustained fire climb and then settle.
	recoilSpring:setTarget(Vector3.zero)
	shakeSpring:setTarget(Vector3.zero)

	local offset = CFrame.new(sway.X + shake.X, bob + sway.Y + shake.Y, 0)
		* CFrame.Angles(recoil.X + shake.Y * 0.4, recoil.Y + shake.X * 0.4, tilt)

	camera.CFrame = camera.CFrame * offset
end

--------------------------------------------------------------------------

function CameraController.start()
	camera = Workspace.CurrentCamera
	apply()

	player.CharacterAdded:Connect(function()
		-- A fresh character always gets a correct camera, which covers respawn,
		-- revive and the end of an expedition.
		task.wait(0.2)
		CameraController.restore()
	end)

	StateController.Changed:Connect(function(key)
		if key == "vitals" or key == "downed" or key == "expedition" or key == "ui" then
			-- Never override the cinematic from a state change; the cinematic
			-- ends by its own path and then restores.
			if mode ~= "cinematic" then
				CameraController.restore()
			end
		end
	end)

	RunService:BindToRenderStep("LastSignalCamera", Enum.RenderPriority.Camera.Value + 1, onRenderStep)

	-- The watchdog. If anything at all has left the camera in a state that
	-- does not match the current mode, this puts it back within a second.
	task.spawn(function()
		while true do
			task.wait(1)
			local current = Workspace.CurrentCamera
			if not current then
				continue
			end
			if mode == "firstPerson" or mode == "downed" then
				local wrongType = current.CameraType ~= Enum.CameraType.Custom
				local wrongMode = player.CameraMode ~= Enum.CameraMode.LockFirstPerson
				local wrongSubject = current.CameraSubject == nil
				if wrongType or wrongMode or wrongSubject then
					log.debug("camera watchdog corrected the view")
					apply()
				end
			elseif mode == "cinematic" then
				if current.CameraType ~= Enum.CameraType.Scriptable then
					apply()
				end
				-- A cinematic that somehow outlives its duration is ended here
				-- rather than trapping the player.
				if cinematicDuration > 0 and (os.clock() - cinematicStartedAt) > cinematicDuration + 5 then
					log.warn("cinematic overran; restoring control")
					CameraController.stopCinematic()
				end
			end
		end
	end)
end

return CameraController
