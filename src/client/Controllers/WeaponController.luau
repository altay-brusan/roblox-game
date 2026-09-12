--!strict
--[[
	WeaponController
	----------------
	The first-person viewmodel, the firing input, and the local effects.

	WHAT IS LOCAL AND WHAT IS AUTHORITATIVE
	---------------------------------------
	The viewmodel, the muzzle flash, the tracer, the shell ejection and the
	recoil animation are all local. They exist so the weapon feels immediate at
	any ping. None of them decide anything.

	The shot itself is a request: origin, direction, and what the client's own
	raycast believes it hit. The server re-checks all of it. If the server
	disagrees, nothing happens and the client simply played an effect, which is
	the correct outcome: a wrong prediction should never be able to hurt
	anything.

	THE VIEWMODEL
	-------------
	Built from primitives per weapon, from the model block in WeaponRegistry,
	and parented to the camera. Hands are included, because a first-person
	weapon floating with no arms is the single most common thing that makes a
	Roblox shooter look unfinished.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("LastSignal")

local Logger = require(Shared.Core.Logger)
local Net = require(Shared.Core.Net)
local Spring = require(Shared.Core.Spring)
local WeaponRegistry = require(Shared.Registry.WeaponRegistry)
local CameraController = require(script.Parent.CameraController)
local InputController = require(script.Parent.InputController)
local StateController = require(script.Parent.StateController)

local log = Logger.new("WeaponController")
local player = Players.LocalPlayer

local WeaponController = {}

local viewmodel: Model? = nil
local viewmodelRoot: BasePart? = nil
local muzzle: BasePart? = nil
local currentWeaponId: string? = nil

local firing = false
local aiming = false
local lastFiredAt = 0

local positionSpring = Spring.vector3(Vector3.zero, 60, 12)
local rotationSpring = Spring.vector3(Vector3.zero, 60, 12)

--------------------------------------------------------------------------
-- Viewmodel construction
--------------------------------------------------------------------------

local C = Color3.fromRGB

local function makePart(name: string, size: Vector3, cf: CFrame, colour: Color3, material: Enum.Material, parent: Instance): BasePart
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = cf
	part.Color = colour
	part.Material = material
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	-- Viewmodel parts must not be lit by the world's shadows or they flicker
	-- as the train passes lamps.
	part.Parent = parent
	return part
end

local function buildHands(parent: Instance, skin: Color3)
	-- Two simple forearms, angled into the grip. They read correctly at the
	-- bottom of the screen and cost four parts.
	for _, side in { -1, 1 } do
		makePart(
			"Forearm",
			Vector3.new(0.42, 0.42, 1.8),
			CFrame.new(side * 0.42, -0.32, 0.7) * CFrame.Angles(math.rad(-12), math.rad(side * 6), 0),
			skin,
			Enum.Material.SmoothPlastic,
			parent
		)
		makePart(
			"Hand",
			Vector3.new(0.38, 0.34, 0.5),
			CFrame.new(side * 0.34, -0.22, -0.1),
			skin,
			Enum.Material.SmoothPlastic,
			parent
		)
	end
end

local function buildViewmodel(def: WeaponRegistry.WeaponDef): (Model, BasePart, BasePart?)
	local model = Instance.new("Model")
	model.Name = "Viewmodel_" .. def.id

	local root = makePart("Root", Vector3.new(0.2, 0.2, 0.2), CFrame.new(), C(0, 0, 0), Enum.Material.SmoothPlastic, model)
	root.Transparency = 1

	local spec = def.model
	local bodyColour = spec.colour or C(80, 80, 84)
	local gripColour = spec.gripColour or C(60, 44, 36)
	local material = spec.material or Enum.Material.Metal
	local length = spec.length or 1.5
	local muzzlePart: BasePart? = nil

	buildHands(model, C(196, 166, 138))

	if def.kind == "melee" then
		local shape = spec.shape
		if shape == "axe" then
			makePart("Haft", Vector3.new(0.22, 0.22, length), CFrame.new(0, -0.1, -length * 0.4), bodyColour, Enum.Material.Wood, model)
			makePart("Head", Vector3.new(0.24, 0.9, 0.7), CFrame.new(0, 0.2, -length * 0.85), spec.headColour or C(112, 116, 120), Enum.Material.Metal, model)
			makePart("Blade", Vector3.new(0.12, 1.1, 0.4), CFrame.new(0, 0.2, -length * 0.95), C(160, 164, 168), Enum.Material.Metal, model)
		elseif shape == "crowbar" then
			makePart("Shaft", Vector3.new(0.16, 0.16, length), CFrame.new(0, -0.1, -length * 0.4), bodyColour, material, model)
			makePart("Claw", Vector3.new(0.16, 0.5, 0.34), CFrame.new(0, 0.06, -length * 0.85) * CFrame.Angles(math.rad(35), 0, 0), bodyColour, material, model)
		else
			makePart("Shaft", Vector3.new(0.18, 0.18, length), CFrame.new(0, -0.1, -length * 0.4), bodyColour, material, model)
			makePart("Jaw", Vector3.new(0.34, 0.5, 0.5), CFrame.new(0, 0.02, -length * 0.82), bodyColour, material, model)
			makePart("Grip", Vector3.new(0.22, 0.22, 0.6), CFrame.new(0, -0.1, 0.1), gripColour, Enum.Material.Fabric, model)
		end
	else
		-- Firearms share a receiver, a grip and a barrel, differing in
		-- proportion and in the details hung off them.
		makePart("Receiver", Vector3.new(0.28, 0.4, length * 0.45), CFrame.new(0, -0.05, -length * 0.18), bodyColour, material, model)
		makePart("Grip", Vector3.new(0.24, 0.62, 0.34), CFrame.new(0, -0.42, 0.12) * CFrame.Angles(math.rad(-14), 0, 0), gripColour, Enum.Material.Wood, model)
		makePart("Trigger", Vector3.new(0.08, 0.2, 0.1), CFrame.new(0, -0.24, -0.05), C(40, 40, 42), Enum.Material.Metal, model)

		local barrelLength = length * 0.55
		local barrel = makePart(
			"Barrel",
			Vector3.new(0.16, 0.16, barrelLength),
			CFrame.new(0, 0.02, -length * 0.45 - barrelLength * 0.35),
			bodyColour,
			Enum.Material.Metal,
			model
		)

		if def.id == "shotgun" then
			makePart("SecondBarrel", Vector3.new(0.16, 0.16, barrelLength), barrel.CFrame * CFrame.new(0.18, 0, 0), bodyColour, Enum.Material.Metal, model)
			makePart("Forend", Vector3.new(0.4, 0.28, barrelLength * 0.5), barrel.CFrame * CFrame.new(0.09, -0.12, 0.3), gripColour, Enum.Material.Wood, model)
		elseif def.id == "rifle" then
			makePart("Stock", Vector3.new(0.24, 0.42, 0.9), CFrame.new(0, -0.14, 0.55), gripColour, Enum.Material.Wood, model)
			makePart("Bolt", Vector3.new(0.12, 0.12, 0.5), CFrame.new(0.18, 0.1, -0.1), C(150, 150, 154), Enum.Material.Metal, model)
			makePart("BoltHandle", Vector3.new(0.1, 0.28, 0.1), CFrame.new(0.26, 0.02, 0.02), C(150, 150, 154), Enum.Material.Metal, model)
			makePart("Sight", Vector3.new(0.06, 0.16, 0.06), CFrame.new(0, 0.24, -length * 0.6), C(40, 40, 42), Enum.Material.Metal, model)
		elseif def.id == "revolver" then
			makePart("Cylinder", Vector3.new(0.3, 0.3, 0.34), CFrame.new(0, -0.02, -0.18), C(70, 70, 74), Enum.Material.Metal, model)
			makePart("Hammer", Vector3.new(0.07, 0.16, 0.12), CFrame.new(0, 0.18, 0.08), C(50, 50, 52), Enum.Material.Metal, model)
		elseif def.id == "flare_gun" then
			makePart("WideBarrel", Vector3.new(0.3, 0.3, barrelLength * 0.7), barrel.CFrame * CFrame.new(0, 0, 0.1), bodyColour, Enum.Material.SmoothPlastic, model)
		end

		-- Front sight, so there is something to line up with.
		makePart("FrontSight", Vector3.new(0.05, 0.12, 0.05), barrel.CFrame * CFrame.new(0, 0.14, -barrelLength * 0.45), C(40, 40, 42), Enum.Material.Metal, model)

		local flash = makePart(
			"Muzzle",
			Vector3.new(0.1, 0.1, 0.1),
			barrel.CFrame * CFrame.new(0, 0, -barrelLength * 0.5),
			C(255, 220, 150),
			Enum.Material.Neon,
			model
		)
		flash.Transparency = 1
		muzzlePart = flash
	end

	-- Weld everything to the root so the model can be posed as one object.
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") and descendant ~= root then
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = root
			weld.Part1 = descendant
			weld.Parent = root
			descendant.Anchored = false
		end
	end
	root.Anchored = true

	return model, root, muzzlePart
end

--------------------------------------------------------------------------
-- Equipping
--------------------------------------------------------------------------

local function equip(weaponId: string?)
	if currentWeaponId == weaponId then
		return
	end
	currentWeaponId = weaponId

	if viewmodel then
		viewmodel:Destroy()
		viewmodel = nil
		viewmodelRoot = nil
		muzzle = nil
	end
	if not weaponId then
		return
	end

	local def = WeaponRegistry.get(weaponId)
	if not def then
		return
	end

	local model, root, flash = buildViewmodel(def)
	model.Parent = Workspace.CurrentCamera
	viewmodel = model
	viewmodelRoot = root
	muzzle = flash

	-- The equip animation is a spring impulse rather than a keyframe sequence,
	-- so it settles correctly even if the weapon is swapped mid-animation.
	positionSpring:reset(def.viewmodel.restOffset - Vector3.new(0, 1.2, 0))
	positionSpring:setTarget(def.viewmodel.restOffset)
	rotationSpring:reset(Vector3.new(math.rad(-30), 0, 0))
	rotationSpring:setTarget(Vector3.zero)

	log.debug("equipped", weaponId)
end

--------------------------------------------------------------------------
-- Effects
--------------------------------------------------------------------------

local function muzzleFlash()
	local flash = muzzle
	if not flash then
		return
	end
	flash.Transparency = 0
	local existing = flash:FindFirstChildOfClass("PointLight")
	local resolved: PointLight
	if existing then
		resolved = existing
	else
		resolved = Instance.new("PointLight")
		resolved.Color = C(255, 214, 150)
		resolved.Range = 30
		resolved.Parent = flash
	end
	resolved.Brightness = 6
	resolved.Enabled = true
	task.delay(0.05, function()
		flash.Transparency = 1
		resolved.Enabled = false
	end)
end

local function tracer(from: Vector3, to: Vector3)
	local delta = to - from
	if delta.Magnitude < 1 then
		return
	end
	local beam = Instance.new("Part")
	beam.Name = "Tracer"
	beam.Size = Vector3.new(0.08, 0.08, delta.Magnitude)
	beam.CFrame = CFrame.lookAt(from + delta * 0.5, to)
	beam.Color = C(255, 226, 170)
	beam.Material = Enum.Material.Neon
	beam.Anchored = true
	beam.CanCollide = false
	beam.CanQuery = false
	beam.CanTouch = false
	beam.CastShadow = false
	beam.Transparency = 0.35
	beam.Parent = Workspace

	task.spawn(function()
		for step = 1, 6 do
			task.wait(0.02)
			beam.Transparency = 0.35 + step * 0.11
		end
		beam:Destroy()
	end)
end

local function impact(position: Vector3, normal: Vector3)
	local mark = Instance.new("Part")
	mark.Name = "Impact"
	mark.Size = Vector3.new(0.3, 0.3, 0.1)
	mark.CFrame = CFrame.lookAt(position + normal * 0.05, position + normal)
	mark.Color = C(40, 38, 36)
	mark.Material = Enum.Material.Slate
	mark.Anchored = true
	mark.CanCollide = false
	mark.CanQuery = false
	mark.CanTouch = false
	mark.CastShadow = false
	mark.Parent = Workspace
	task.delay(8, function()
		mark:Destroy()
	end)
end

--------------------------------------------------------------------------
-- Firing
--------------------------------------------------------------------------

local function tryFire()
	local weaponId = currentWeaponId
	if not weaponId then
		return
	end
	local def = WeaponRegistry.get(weaponId)
	if not def then
		return
	end
	if StateController.isDowned() or StateController.isDead() then
		return
	end
	if StateController.ui("openPanel") then
		return
	end

	local weaponState = StateController.get("weapon")
	if weaponState and weaponState.reloading then
		return
	end

	local now = os.clock()
	if (now - lastFiredAt) < def.fireInterval then
		return
	end
	lastFiredAt = now

	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	local origin = camera.CFrame.Position
	local direction = camera.CFrame.LookVector

	if def.kind == "melee" then
		Net.fireServer("MeleeSwing", direction)
		rotationSpring:impulse(Vector3.new(math.rad(-40), math.rad(18), 0))
		positionSpring:impulse(Vector3.new(0, 0, -1.2))
		return
	end

	if weaponState and (weaponState.magazine or 0) <= 0 then
		-- Dry fire. The server would refuse anyway; this is the audible tell.
		local AudioController = require(script.Parent.AudioController)
		AudioController.play(def.dryCue or "gun_dry")
		return
	end

	-- Spread is applied locally and sent as the actual direction, so the
	-- server validates against the same line the client drew.
	local spread = math.rad(def.spreadDegrees or 1) * (if aiming then (def.aimSpreadMultiplier or 0.4) else 1)
	local pellets = def.pellets or 1

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local character = player.Character
	local filtered: { Instance } = {}
	if character then
		table.insert(filtered, character)
	end
	if viewmodel then
		table.insert(filtered, viewmodel)
	end
	params.FilterDescendantsInstances = filtered

	for _ = 1, pellets do
		local jitter = Vector3.new(
			(math.random() - 0.5) * 2 * spread,
			(math.random() - 0.5) * 2 * spread,
			0
		)
		local shotDirection = (CFrame.lookAt(Vector3.zero, direction) * CFrame.Angles(jitter.Y, jitter.X, 0)).LookVector
		local result = Workspace:Raycast(origin, shotDirection * def.range, params)

		local hitPosition = if result then result.Position else origin + shotDirection * def.range
		tracer(origin + camera.CFrame.RightVector * 0.4 - camera.CFrame.UpVector * 0.2, hitPosition)
		if result then
			impact(result.Position, result.Normal)
		end

		Net.fireServer("WeaponFire", origin, shotDirection, if result then result.Instance else nil, hitPosition)
	end

	muzzleFlash()

	-- Recoil. The camera kick is what actually moves the aim, and it is a
	-- spring so sustained fire climbs and then settles predictably.
	local kick = def.viewmodel.recoilKick
	rotationSpring:impulse(Vector3.new(kick.X * 4, kick.Y * 4, kick.Z))
	positionSpring:impulse(Vector3.new(0, 0, 0.8))
	CameraController.recoil(Vector3.new(
		math.rad(def.recoilVertical or 2) * -0.5,
		math.rad((math.random() - 0.5) * 2 * (def.recoilHorizontal or 0.5)),
		0
	))
	CameraController.shake(0.12, 0.15)
end

--------------------------------------------------------------------------
-- Per-frame
--------------------------------------------------------------------------

local function onRenderStep(deltaTime: number)
	local root = viewmodelRoot
	local weaponId = currentWeaponId
	if not root or not weaponId then
		return
	end
	local def = WeaponRegistry.get(weaponId)
	local camera = Workspace.CurrentCamera
	if not def or not camera then
		return
	end

	-- Hide the viewmodel whenever it would be wrong to see it.
	local hidden = StateController.isDowned()
		or StateController.isDead()
		or StateController.ui("cinematic") == true
		or StateController.ui("openPanel") ~= nil
	local model = viewmodel
	if model then
		for _, descendant in model:GetDescendants() do
			if descendant:IsA("BasePart") and descendant.Name ~= "Root" and descendant.Name ~= "Muzzle" then
				descendant.LocalTransparencyModifier = if hidden then 1 else 0
			end
		end
	end
	if hidden then
		return
	end

	positionSpring:setTarget(if aiming then def.viewmodel.aimOffset else def.viewmodel.restOffset)

	local position = positionSpring:step(deltaTime)
	local rotation = rotationSpring:step(deltaTime)
	rotationSpring:setTarget(Vector3.zero)

	-- Sway from view movement, scaled per weapon so the rifle feels heavier
	-- than the revolver.
	local lookDelta = UserInputService:GetMouseDelta()
	local swayScale = def.viewmodel.swayScale * (if aiming then 0.3 else 1)
	local sway = Vector3.new(
		math.clamp(-lookDelta.X * 0.0006 * swayScale, -0.08, 0.08),
		math.clamp(-lookDelta.Y * 0.0006 * swayScale, -0.08, 0.08),
		0
	)

	root.CFrame = camera.CFrame
		* CFrame.new(position + sway)
		* CFrame.Angles(rotation.X, rotation.Y, rotation.Z)
end

--------------------------------------------------------------------------

function WeaponController.start()
	InputController.Action:Connect(function(actionId, pressed)
		if actionId == "fire" then
			firing = pressed
			if pressed then
				tryFire()
			end
		elseif actionId == "aim" then
			aiming = pressed
		elseif actionId == "reload" and pressed then
			Net.fireServer("WeaponReload")
		end
	end)

	StateController.Changed:Connect(function(key, value)
		if key == "weapon" and type(value) == "table" then
			equip(value.equipped)
		elseif key == "expedition" and type(value) == "table" then
			if value.state == "lobby" or value.state == "results" then
				equip(nil)
			end
		end
	end)

	Net.onClientEvent("WeaponEffect", function(payload)
		if type(payload) ~= "table" then
			return
		end
		-- Other players' shots: a tracer from their position, so a gunshot is
		-- locatable by sight as well as by sound.
		if payload.kind == "fire" and payload.userId ~= player.UserId and payload.origin and payload.hitPosition then
			tracer(payload.origin, payload.hitPosition)
		elseif payload.kind == "flare" and payload.position then
			-- A burning flare denies ground; it needs to be unmistakable.
			local flare = Instance.new("Part")
			flare.Name = "Flare"
			flare.Size = Vector3.new(0.5, 0.5, 0.5)
			flare.CFrame = CFrame.new(payload.position)
			flare.Color = C(255, 120, 70)
			flare.Material = Enum.Material.Neon
			flare.Anchored = true
			flare.CanCollide = false
			flare.CanQuery = false
			flare.Parent = Workspace

			local light = Instance.new("PointLight")
			light.Color = C(255, 120, 70)
			light.Brightness = 5
			light.Range = 60
			light.Shadows = true
			light.Parent = flare

			task.delay(payload.seconds or 24, function()
				flare:Destroy()
			end)
		end
	end)

	-- Automatic fire is not used by any weapon in this project, but holding
	-- the button on a semi-automatic still re-fires at the weapon's interval,
	-- which is what players expect.
	RunService.Heartbeat:Connect(function()
		if firing then
			tryFire()
		end
	end)

	RunService:BindToRenderStep("LastSignalViewmodel", Enum.RenderPriority.Camera.Value + 2, onRenderStep)

	player.CharacterAdded:Connect(function()
		-- Re-parent the viewmodel: a new camera is created with a new character.
		task.wait(0.3)
		local model = viewmodel
		if model and Workspace.CurrentCamera then
			model.Parent = Workspace.CurrentCamera
		end
	end)

	log.info("started")
end

return WeaponController
