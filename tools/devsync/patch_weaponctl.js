const fs = require("fs");
const f = "client/Controllers/WeaponController.luau";
let s = fs.readFileSync(f, "utf8");
function rep(a, b) { if (!s.includes(a)) throw new Error("missing " + a.slice(0, 70)); s = s.replace(a, b); }
function cut(startMarker, endMarker, replacement) {
	const a = s.indexOf(startMarker), b = s.indexOf(endMarker);
	if (a < 0 || b < 0 || b < a) throw new Error("cut " + startMarker.slice(0, 40));
	s = s.slice(0, a) + replacement + s.slice(b);
}

rep(`local WeaponRegistry = require(Shared.Registry.WeaponRegistry)`, `local WeaponRegistry = require(Shared.Registry.WeaponRegistry)
local WeaponModels = require(Shared.Registry.WeaponModels)
local CosmeticRegistry = require(Shared.Registry.CosmeticRegistry)
local CollectionService = game:GetService("CollectionService")`);

rep(`local currentWeaponId: string? = nil`, `local currentWeaponId: string? = nil
local currentFinish: string? = nil
-- Arc Rail Projector: glowing parts, and when the trigger went down.
local glowParts: { BasePart } = {}
local chargeStartedAt: number? = nil`);

// The viewmodel is the shared model plus hands.
cut(`local function buildViewmodel(def: WeaponRegistry.WeaponDef): (Model, BasePart, BasePart?)`, `--------------------------------------------------------------------------
-- Equipping`, `local function finishFor(): WeaponModels.Finish?
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
-- Equipping`);

rep(`local function equip(weaponId: string?)
	if currentWeaponId == weaponId then
		return
	end
	currentWeaponId = weaponId`, `local function equip(weaponId: string?)
	local profile = StateController.profile()
	local finish = if profile and profile.loadout then profile.loadout.finish else nil
	if currentWeaponId == weaponId and currentFinish == finish then
		return
	end
	currentWeaponId = weaponId
	currentFinish = finish
	chargeStartedAt = nil
	glowParts = {}`);
rep(`	local model, root, flash = buildViewmodel(def)
	model.Parent = Workspace.CurrentCamera
	viewmodel = model
	viewmodelRoot = root
	muzzle = flash`, `	local model, root, flash, glow = buildViewmodel(def)
	model.Parent = Workspace.CurrentCamera
	viewmodel = model
	viewmodelRoot = root
	muzzle = flash
	glowParts = glow`);

// Arc firing: press starts a charge (told to the server), release fires.
rep(`local function tryFire()
	local weaponId = currentWeaponId`, `local function aimRay(): (Vector3, Vector3)?
	local camera = Workspace.CurrentCamera
	if not camera then
		return nil
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
	local weaponId = currentWeaponId`);

rep(`	local now = os.clock()
	if (now - lastFiredAt) < def.fireInterval then
		return
	end
	lastFiredAt = now`, `	if def.arc then
		-- Charged weapons fire on release, not on press.
		return
	end
	local now = os.clock()
	if (now - lastFiredAt) < def.fireInterval then
		return
	end
	lastFiredAt = now`);

// Capacitor glow follows the charge; the coils glow with heat.
rep(`	root.CFrame = camera.CFrame
		* CFrame.new(position + sway)
		* CFrame.Angles(rotation.X, rotation.Y, rotation.Z)
end`, `	local shake = Vector3.zero
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
end`);

// Input: arc charge on press, release on release.
rep(`		if actionId == "fire" then
			firing = pressed
			if pressed then
				tryFire()
			end`, `		if actionId == "fire" then
			firing = pressed
			if pressed then
				startCharge()
				tryFire()
			else
				releaseCharge()
			end`);

// Re-equip when the finish changes in the loadout.
rep(`		if key == "weapon" and type(value) == "table" then
			equip(value.equipped)`, `		if key == "weapon" and type(value) == "table" then
			equip(value.equipped)
		elseif key == "profile" and currentWeaponId then
			equip(currentWeaponId)`);

// Effects for the premium weapons.
rep(`		elseif payload.kind == "flare" and payload.position then`, `		elseif payload.kind == "arc" and typeof(payload.origin) == "Vector3" and typeof(payload.direction) == "Vector3" then
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
		elseif payload.kind == "flare" and payload.position then`);

fs.writeFileSync(f, s);
console.log("ok");
