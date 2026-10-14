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
local WeaponModels = require(Shared.Registry.WeaponModels)
local CosmeticRegistry = require(Shared.Registry.CosmeticRegistry)
local CollectionService = game:GetService("CollectionService")
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
local currentFinish: string? = nil
-- Arc Rail Projector: glowing parts, and when the trigger went down.
local glowParts: { BasePart } = {}
local chargeStartedAt: number? = nil

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

local function finishFor(): WeaponModels.Finish?
	local profile = StateController.profile()
	local id = if profile and profile.loadout then profile.loadout.finish else nil
	local def = if type(id) == "string" then CosmeticRegistry.get(id) else nil
	if not def or def.slot ~= "finish" then
		return nil
	end
	return { body = def.body, accent = def.accent, material = def.material }
end

--- The shared weapon model (WeaponModels) with a pair of hands on it, so the
--- weapon in first person is the same object the armory shows and other
--- players see in your hand.
local function buildViewmodel(def: WeaponRegistry.WeaponDef): (Model, BasePart, BasePart?, { BasePart })
	local built = WeaponModels.build(def, finishFor())
	local model = built.model
	model.Name = "Viewmodel_" .. def.id
	buildHands(model, C(196, 166, 138))
	for _, descendant in model:GetChildren() do
		if descendant:IsA("BasePart") and descendant.Anchored and descendant ~= built.root then
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = built.root
			weld.Part1 = descendant
			weld.Parent = built.root
			descendant.Anchored = false
		end
	end
	built.root.Anchored = true
	return model, built.root, built.muzzle, built.glow
end

--------------------------------------------------------------------------
-- Equipping--------------------------------------------------------------------------
-- Equipping
--------------------------------------------------------------------------

local function equip(weaponId: string?)
	local profile = StateController.profile()
	local finish = if profile and profile.loadout then profile.loadout.finish else nil
	if currentWeaponId == weaponId and currentFinish == finish then
		return
	end
	currentWeaponId = weaponId
	currentFinish = finish
	chargeStartedAt = nil
	glowParts = {}

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

	local model, root, flash, glow = buildViewmodel(def)
	model.Parent = Workspace.CurrentCamera
	viewmodel = model
	viewmodelRoot = root
	muzzle = flash
	glowParts = glow

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

local function aimRay(): (Vector3?, Vector3?)
	local camera = Workspace.CurrentCamera
	if not camera then
		return nil, nil
	end
	return camera.CFrame.Position, camera.CFrame.LookVector
end

local function canUseWeapon(): boolean
	return not (StateController.isDowned() or StateController.isDead() or StateController.ui("openPanel"))
end

--- Arc Rail Projector, trigger down: start charging, if it is not too hot.
local function startCharge()
	local def = if currentWeaponId then WeaponRegistry.get(currentWeaponId) else nil
	if not def or not def.arc or not canUseWeapon() then
		return
	end
	local weaponState = StateController.get("weapon")
	if weaponState and (weaponState.overheatRemaining or 0) > 0 then
		local AudioController = require(script.Parent.AudioController)
		AudioController.play(def.dryCue or "gun_dry")
		return
	end
	chargeStartedAt = os.clock()
	Net.fireServer("WeaponCharge")
	local AudioController = require(script.Parent.AudioController)
	AudioController.play("arc_charge")
end

--- Trigger up: discharge if the charge is full, otherwise let it bleed off.
local function releaseCharge()
	local def = if currentWeaponId then WeaponRegistry.get(currentWeaponId) else nil
	local started = chargeStartedAt
	chargeStartedAt = nil
	if not def or not def.arc or not started then
		return
	end
	if os.clock() - started < def.arc.chargeSeconds or not canUseWeapon() then
		return
	end
	local origin, direction = aimRay()
	if not origin or not direction then
		return
	end
	Net.fireServer("WeaponFire", origin, direction, nil, nil)
	muzzleFlash()
	local kick = def.viewmodel.recoilKick
	rotationSpring:impulse(Vector3.new(kick.X * 4, kick.Y * 4, kick.Z))
	positionSpring:impulse(Vector3.new(0, 0, 1.0))
	CameraController.shake(0.2, 0.2)
end

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

	if def.arc then
		-- Charged weapons fire on release, not on press.
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

	local shake = Vector3.zero
	if def.arc and #glowParts > 0 then
		local charge = if chargeStartedAt then math.clamp((os.clock() - chargeStartedAt) / def.arc.chargeSeconds, 0, 1) else 0
		local weaponState = StateController.get("weapon")
		local heat = if weaponState and type(weaponState.heat) == "number" then weaponState.heat / 100 else 0
		local hot = weaponState and (weaponState.overheatRemaining or 0) > 0
		for _, part in glowParts do
			if part.Name == "Capacitor" then
				part.Color = C(70, 180, 255):Lerp(C(220, 250, 255), charge)
				part.Material = if charge > 0.05 then Enum.Material.Neon else Enum.Material.Glass
			else
				part.Color = C(184, 112, 60):Lerp(C(255, 70, 30), if hot then 1 else heat * 0.8)
				part.Material = if hot or heat > 0.5 then Enum.Material.Neon else Enum.Material.Metal
			end
		end
		if charge > 0 then
			-- A full charge hums in the hands.
			shake = Vector3.new((math.random() - 0.5) * 0.012, (math.random() - 0.5) * 0.012, 0) * charge
		end
	end

	root.CFrame = camera.CFrame
		* CFrame.new(position + sway + shake)
		* CFrame.Angles(rotation.X, rotation.Y, rotation.Z)
end

--------------------------------------------------------------------------
-- Premium weapon effects
--------------------------------------------------------------------------

local function neon(name: string, size: Vector3, cf: CFrame, colour: Color3, transparency: number): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.CFrame = cf
	p.Color = colour
	p.Material = Enum.Material.Neon
	p.Transparency = transparency
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Parent = Workspace
	return p
end

--- A jagged arc between two points: a few neon segments that flicker out.
local function lightning(from: Vector3, to: Vector3)
	local points = { from }
	local segments = 6
	for i = 1, segments - 1 do
		local t = i / segments
		local jitter = Vector3.new(math.random() - 0.5, math.random() - 0.5, math.random() - 0.5) * 1.6
		table.insert(points, from:Lerp(to, t) + jitter)
	end
	table.insert(points, to)
	local parts: { Part } = {}
	for i = 1, #points - 1 do
		local a, b = points[i], points[i + 1]
		local d = (b - a).Magnitude
		table.insert(parts, neon("Arc", Vector3.new(0.12, 0.12, d), CFrame.lookAt(a:Lerp(b, 0.5), b), C(170, 230, 255), 0))
	end
	local glow = neon("ArcLight", Vector3.new(0.2, 0.2, 0.2), CFrame.new(to), C(170, 230, 255), 1)
	local light = Instance.new("PointLight")
	light.Color = C(150, 210, 255)
	light.Brightness = 8
	light.Range = 30
	light.Parent = glow
	table.insert(parts, glow)
	task.spawn(function()
		for step = 1, 5 do
			task.wait(0.03)
			for _, p in parts do
				if p.Name == "Arc" then
					p.Transparency = step * 0.2
				end
			end
			light.Brightness = 8 - step * 1.6
		end
		for _, p in parts do
			p:Destroy()
		end
	end)
end

--- A label over a creature saying what the arc did to it. Resistance has to
--- be visible, or a player will think the weapon simply missed.
local function stunLabel(position: Vector3, stunned: number)
	local anchor = neon("StunLabel", Vector3.new(0.2, 0.2, 0.2), CFrame.new(position + Vector3.new(0, 7, 0)), C(0, 0, 0), 1)
	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.fromOffset(160, 36)
	gui.AlwaysOnTop = true
	gui.Parent = anchor
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.TextSize = 20
	label.TextStrokeTransparency = 0.4
	label.TextColor3 = if stunned > 0 then C(170, 230, 255) else C(255, 150, 120)
	label.Text = if stunned > 0 then string.format("STUNNED %.1fs", stunned) else "RESISTED"
	label.Parent = gui
	task.delay(1.6, function()
		anchor:Destroy()
	end)
end

--- The launcher's flare: bursts high, drifts down slowly, lights the ground
--- around it, and outlines any creature underneath it for the whole crew.
local function skyFlare(position: Vector3, landing: Vector3, seconds: number, revealRadius: number)
	local flare = neon("SkyFlare", Vector3.new(0.9, 0.9, 0.9), CFrame.new(position), C(255, 110, 70), 0)
	flare.Shape = Enum.PartType.Ball
	local light = Instance.new("PointLight")
	light.Color = C(255, 140, 100)
	light.Brightness = 4
	light.Range = 60
	light.Shadows = true
	light.Parent = flare
	-- One light cannot reach past 60 studs, so the ground glow is spread over
	-- four more around the landing point.
	local spill: { Part } = {}
	for i = 0, 3 do
		local a = i * math.pi / 2
		local p = neon("FlareSpill", Vector3.new(0.2, 0.2, 0.2), CFrame.new(landing + Vector3.new(math.cos(a) * 40, 14, math.sin(a) * 40)), C(0, 0, 0), 1)
		local l = Instance.new("PointLight")
		l.Color = C(255, 140, 100)
		l.Brightness = 1.6
		l.Range = 45
		l.Parent = p
		table.insert(spill, p)
	end
	local highlights: { [Model]: Highlight } = {}
	local born = os.clock()
	task.spawn(function()
		while os.clock() - born < seconds do
			local t = (os.clock() - born) / seconds
			flare.CFrame = CFrame.new(position:Lerp(landing + Vector3.new(0, 4, 0), t))
			light.Brightness = 4 * (1 - t * 0.5) * (0.85 + math.random() * 0.15)
			for _, creature in CollectionService:GetTagged("Creature") do
				if creature:IsA("Model") then
					local pivot = creature:GetPivot().Position
					local near = Vector3.new(pivot.X - landing.X, 0, pivot.Z - landing.Z).Magnitude <= revealRadius
					if near and not highlights[creature] then
						local h = Instance.new("Highlight")
						h.FillColor = C(255, 120, 60)
						h.FillTransparency = 0.75
						h.OutlineColor = C(255, 190, 140)
						h.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
						h.Parent = creature
						highlights[creature] = h
					elseif not near and highlights[creature] then
						highlights[creature]:Destroy()
						highlights[creature] = nil
					end
				end
			end
			task.wait(0.1)
		end
		for _, h in highlights do
			h:Destroy()
		end
		flare:Destroy()
		for _, p in spill do
			p:Destroy()
		end
	end)
end

--------------------------------------------------------------------------

function WeaponController.start()
	InputController.Action:Connect(function(actionId, pressed)
		if actionId == "fire" then
			firing = pressed
			if pressed then
				startCharge()
				tryFire()
			else
				releaseCharge()
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
		elseif key == "profile" and currentWeaponId then
			equip(currentWeaponId)
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
		elseif payload.kind == "arc" and typeof(payload.origin) == "Vector3" and typeof(payload.direction) == "Vector3" then
			local AudioController = require(script.Parent.AudioController)
			AudioController.play("arc_discharge", { position = payload.origin })
			local from = payload.origin + payload.direction * 1.5 - Vector3.new(0, 0.4, 0)
			local struck = if type(payload.struck) == "table" then payload.struck else {}
			if #struck == 0 then
				-- Nothing in reach: the arc grounds out at the end of its range.
				lightning(from, payload.origin + payload.direction * (tonumber(payload.range) or 26))
				lightning(from, payload.origin + payload.direction * (tonumber(payload.range) or 26) * 0.7)
			end
			for _, hit in struck do
				if type(hit) == "table" and typeof(hit.position) == "Vector3" then
					lightning(from, hit.position + Vector3.new(0, 2, 0))
					lightning(from, hit.position + Vector3.new(0, 4, 0))
					stunLabel(hit.position, tonumber(hit.stunned) or 0)
					AudioController.play("arc_impact", { position = hit.position })
				end
			end
		elseif payload.kind == "skyflare" and typeof(payload.position) == "Vector3" and typeof(payload.landing) == "Vector3" then
			local AudioController = require(script.Parent.AudioController)
			AudioController.play("flare_burst", { position = payload.position })
			skyFlare(payload.position, payload.landing, math.clamp(tonumber(payload.seconds) or 20, 1, 40), tonumber(payload.revealRadius) or 100)
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
