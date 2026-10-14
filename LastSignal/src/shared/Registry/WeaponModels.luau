--!strict
--[[
	WeaponModels
	------------
	One builder for every weapon model in the game: the first-person viewmodel,
	the weapon in a character's hand that other players see, and the turntable
	preview in the armory. Building all three from the same function is what
	keeps them identical, so the thing you inspect in the armory is the thing
	you carry.

	Convention: the model's Root sits at the firing hand's grip, the weapon
	points along -Z, and +Y is up. Every part is welded to Root, unanchored, and
	non-colliding, so callers can pose the whole model by moving Root.

	Finishes recolour parts by role. "body" takes the finish body colour and
	material, "accent" takes the finish accent colour. Parts with a fixed role
	(lenses, glass, coils) never change, so a finish never hides what a weapon
	is doing.
]]

local WeaponRegistry = require(script.Parent.WeaponRegistry)

local C = Color3.fromRGB

local WeaponModels = {}

export type Finish = {
	body: Color3?,
	accent: Color3?,
	material: Enum.Material?,
}

export type Built = {
	model: Model,
	root: BasePart,
	muzzle: BasePart?,
	-- Parts that glow with the weapon's state: the Arc Rail Projector's
	-- capacitor and coils. Callers drive their colour and transparency.
	glow: { BasePart },
}

type Role = "body" | "grip" | "accent" | "fixed"

function WeaponModels.build(def: WeaponRegistry.WeaponDef, finish: Finish?): Built
	local model = Instance.new("Model")
	model.Name = "Weapon_" .. def.id

	local spec = def.model
	local bodyColour: Color3 = (finish and finish.body) or spec.colour or C(80, 80, 84)
	local bodyMaterial: Enum.Material = (finish and finish.material) or spec.material or Enum.Material.Metal
	local gripColour: Color3 = spec.gripColour or C(60, 44, 36)
	local accentColour: Color3 = (finish and finish.accent) or spec.accentColour or C(150, 120, 64)
	local length: number = spec.length or 1.5
	local glow: { BasePart } = {}

	local root = Instance.new("Part")
	root.Name = "Root"
	root.Size = Vector3.new(0.2, 0.2, 0.2)
	root.Transparency = 1
	root.CanCollide = false
	root.CanQuery = false
	root.CanTouch = false
	root.Massless = true
	root.Parent = model
	model.PrimaryPart = root

	local function part(name: string, size: Vector3, cf: CFrame, role: Role, colour: Color3?, material: Enum.Material?, shape: Enum.PartType?): BasePart
		local p = Instance.new("Part")
		p.Name = name
		p.Size = size
		p.CFrame = cf
		if role == "body" then
			p.Color = bodyColour
			p.Material = bodyMaterial
		elseif role == "grip" then
			p.Color = colour or gripColour
			p.Material = material or Enum.Material.Wood
		elseif role == "accent" then
			p.Color = accentColour
			p.Material = Enum.Material.Metal
		else
			p.Color = colour or C(40, 40, 42)
			p.Material = material or Enum.Material.Metal
		end
		if shape then
			p.Shape = shape
		end
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.CastShadow = false
		p.Massless = true
		p.Parent = model
		return p
	end

	-- A cylinder that lies along the weapon's length (Roblox cylinders run
	-- along X, so they are turned a quarter onto Z).
	local function tube(name: string, diameter: number, tubeLength: number, cf: CFrame, role: Role, colour: Color3?, material: Enum.Material?): BasePart
		return part(name, Vector3.new(tubeLength, diameter, diameter), cf * CFrame.Angles(0, math.rad(90), 0), role, colour, material, Enum.PartType.Cylinder)
	end

	local muzzleAt: CFrame? = nil
	local id = def.id

	if def.kind == "melee" then
		local shape = spec.shape
		if shape == "axe" then
			part("Haft", Vector3.new(0.22, 0.22, length), CFrame.new(0, -0.1, -length * 0.4), "grip")
			part("Head", Vector3.new(0.24, 0.9, 0.7), CFrame.new(0, 0.2, -length * 0.85), "body")
			part("Blade", Vector3.new(0.12, 1.1, 0.4), CFrame.new(0, 0.2, -length * 0.95), "fixed", C(160, 164, 168))
		elseif shape == "crowbar" then
			part("Shaft", Vector3.new(0.16, 0.16, length), CFrame.new(0, -0.1, -length * 0.4), "body")
			part("Claw", Vector3.new(0.16, 0.5, 0.34), CFrame.new(0, 0.06, -length * 0.85) * CFrame.Angles(math.rad(35), 0, 0), "body")
		else
			part("Shaft", Vector3.new(0.18, 0.18, length), CFrame.new(0, -0.1, -length * 0.4), "body")
			part("Jaw", Vector3.new(0.34, 0.5, 0.5), CFrame.new(0, 0.02, -length * 0.82), "body")
			part("Grip", Vector3.new(0.22, 0.22, 0.6), CFrame.new(0, -0.1, 0.1), "grip", C(60, 44, 36), Enum.Material.Fabric)
		end
	elseif id == "nightwatch_carbine" then
		-- Railway-security pattern: a squat enamelled receiver with brass
		-- bands, a short ventilated shroud, a box magazine forward of the
		-- grip, a folding stock, and the thing nobody else carries: a
		-- signal-lamp clamped under the barrel with a green lens.
		part("Receiver", Vector3.new(0.3, 0.42, 1.05), CFrame.new(0, 0, -0.35), "body")
		part("TopRail", Vector3.new(0.14, 0.06, 0.9), CFrame.new(0, 0.24, -0.35), "fixed", C(36, 36, 38))
		part("RearSight", Vector3.new(0.18, 0.14, 0.12), CFrame.new(0, 0.33, 0.02), "fixed", C(36, 36, 38))
		part("Grip", Vector3.new(0.24, 0.6, 0.32), CFrame.new(0, -0.4, 0.1) * CFrame.Angles(math.rad(-16), 0, 0), "grip")
		part("Trigger", Vector3.new(0.06, 0.18, 0.08), CFrame.new(0, -0.24, -0.06), "fixed")
		part("TriggerGuard", Vector3.new(0.06, 0.04, 0.34), CFrame.new(0, -0.34, -0.08), "accent")
		part("Magazine", Vector3.new(0.2, 0.62, 0.3), CFrame.new(0, -0.5, -0.5) * CFrame.Angles(math.rad(12), 0, 0), "fixed", C(30, 30, 32))
		part("MagazineBase", Vector3.new(0.24, 0.06, 0.34), CFrame.new(0, -0.81, -0.57) * CFrame.Angles(math.rad(12), 0, 0), "accent")
		part("Stock", Vector3.new(0.12, 0.3, 0.75), CFrame.new(0, -0.08, 0.55), "body")
		part("StockPad", Vector3.new(0.22, 0.42, 0.1), CFrame.new(0, -0.1, 0.95), "grip", C(44, 36, 30), Enum.Material.Fabric)
		local shroud = tube("Shroud", 0.3, 0.75, CFrame.new(0, 0.02, -1.25), "body")
		for i = -1, 1 do
			part("Vent", Vector3.new(0.32, 0.05, 0.12), shroud.CFrame * CFrame.Angles(0, math.rad(-90), 0) * CFrame.new(0, 0.1, i * 0.22), "fixed", C(18, 18, 20))
		end
		tube("Band", 0.34, 0.06, CFrame.new(0, 0.02, -0.92), "accent")
		tube("Band", 0.34, 0.06, CFrame.new(0, 0.02, -1.58), "accent")
		tube("Barrel", 0.14, 0.4, CFrame.new(0, 0.02, -1.8), "fixed", C(34, 34, 36))
		part("FrontSight", Vector3.new(0.05, 0.14, 0.05), CFrame.new(0, 0.22, -1.6), "fixed")
		-- The signal-lamp.
		part("LampClamp", Vector3.new(0.1, 0.16, 0.18), CFrame.new(0, -0.17, -1.2), "accent")
		tube("LampBody", 0.22, 0.38, CFrame.new(0, -0.3, -1.25), "body")
		tube("LampLens", 0.18, 0.04, CFrame.new(0, -0.3, -1.45), "fixed", C(90, 255, 140), Enum.Material.Neon)
		muzzleAt = CFrame.new(0, 0.02, -2.02)
	elseif id == "arc_projector" then
		-- Industrial, not a gun: a battery box, a ceramic insulator barrel
		-- wound with copper, a glass capacitor along the top that glows as it
		-- charges, and two contact prongs where a muzzle would be.
		part("BatteryBox", Vector3.new(0.5, 0.55, 0.8), CFrame.new(0, -0.15, 0.2), "body")
		part("HazardStripe", Vector3.new(0.52, 0.1, 0.82), CFrame.new(0, 0.05, 0.2), "fixed", C(214, 170, 40), Enum.Material.SmoothPlastic)
		part("Grip", Vector3.new(0.24, 0.58, 0.32), CFrame.new(0, -0.55, -0.15) * CFrame.Angles(math.rad(-10), 0, 0), "grip", C(34, 30, 28), Enum.Material.Fabric)
		part("Trigger", Vector3.new(0.06, 0.18, 0.1), CFrame.new(0, -0.35, -0.32), "fixed")
		part("ForeGrip", Vector3.new(0.18, 0.48, 0.22), CFrame.new(0, -0.38, -0.95), "grip", C(34, 30, 28), Enum.Material.Fabric)
		tube("Insulator", 0.32, 1.2, CFrame.new(0, 0, -0.85), "fixed", C(214, 208, 192), Enum.Material.SmoothPlastic)
		for i = 0, 4 do
			local coil = tube("Coil", 0.4, 0.07, CFrame.new(0, 0, -0.4 - i * 0.22), "fixed", C(184, 112, 60), Enum.Material.Metal)
			table.insert(glow, coil)
		end
		local capacitor = tube("Capacitor", 0.2, 0.95, CFrame.new(0, 0.32, -0.55), "fixed", C(70, 180, 255), Enum.Material.Glass)
		capacitor.Transparency = 0.25
		table.insert(glow, capacitor)
		part("CapacitorCap", Vector3.new(0.24, 0.24, 0.08), CFrame.new(0, 0.32, -0.05), "accent")
		part("CapacitorCap", Vector3.new(0.24, 0.24, 0.08), CFrame.new(0, 0.32, -1.05), "accent")
		part("Cable", Vector3.new(0.08, 0.08, 0.7), CFrame.new(0.22, 0.1, -0.2) * CFrame.Angles(0, math.rad(8), 0), "fixed", C(24, 24, 24), Enum.Material.Rubber)
		for _, side in { -1, 1 } do
			part("Prong", Vector3.new(0.07, 0.07, 0.42), CFrame.new(side * 0.12, 0, -1.6) * CFrame.Angles(0, math.rad(-side * 8), 0), "accent")
		end
		muzzleAt = CFrame.new(0, 0, -1.85)
	elseif id == "flare_launcher" then
		-- Signal orange, a brass four-chamber drum, a stubby wide bore and a
		-- folding ladder sight for lobbing flares high over the trees.
		part("Frame", Vector3.new(0.3, 0.4, 0.75), CFrame.new(0, 0, -0.2), "body")
		part("Grip", Vector3.new(0.26, 0.62, 0.34), CFrame.new(0, -0.42, 0.1) * CFrame.Angles(math.rad(-14), 0, 0), "grip")
		part("Trigger", Vector3.new(0.06, 0.18, 0.1), CFrame.new(0, -0.24, -0.08), "fixed")
		tube("Drum", 0.62, 0.5, CFrame.new(0, -0.02, -0.55), "accent")
		for i = 0, 3 do
			local a = math.rad(45 + i * 90)
			tube("Chamber", 0.16, 0.52, CFrame.new(math.cos(a) * 0.19, -0.02 + math.sin(a) * 0.19, -0.55), "fixed", C(30, 26, 22))
		end
		tube("Bore", 0.4, 0.75, CFrame.new(0, 0.02, -1.15), "body")
		tube("BoreLip", 0.46, 0.08, CFrame.new(0, 0.02, -1.52), "accent")
		part("ForeGrip", Vector3.new(0.2, 0.42, 0.24), CFrame.new(0, -0.36, -1.0), "grip")
		part("LadderSight", Vector3.new(0.16, 0.36, 0.05), CFrame.new(0, 0.38, -0.25) * CFrame.Angles(math.rad(-25), 0, 0), "fixed", C(36, 36, 38))
		part("Stencil", Vector3.new(0.31, 0.1, 0.4), CFrame.new(0, 0.12, -0.2), "fixed", C(240, 236, 220), Enum.Material.SmoothPlastic)
		muzzleAt = CFrame.new(0, 0.02, -1.58)
	else
		-- The original firearms share a receiver, a grip and a barrel,
		-- differing in proportion and the details hung off them.
		part("Receiver", Vector3.new(0.28, 0.4, length * 0.45), CFrame.new(0, -0.05, -length * 0.18), "body")
		part("Grip", Vector3.new(0.24, 0.62, 0.34), CFrame.new(0, -0.42, 0.12) * CFrame.Angles(math.rad(-14), 0, 0), "grip")
		part("Trigger", Vector3.new(0.08, 0.2, 0.1), CFrame.new(0, -0.24, -0.05), "fixed")
		local barrelLength = length * 0.55
		local barrel = part("Barrel", Vector3.new(0.16, 0.16, barrelLength), CFrame.new(0, 0.02, -length * 0.45 - barrelLength * 0.35), "body")
		if id == "shotgun" then
			part("SecondBarrel", Vector3.new(0.16, 0.16, barrelLength), barrel.CFrame * CFrame.new(0.18, 0, 0), "body")
			part("Forend", Vector3.new(0.4, 0.28, barrelLength * 0.5), barrel.CFrame * CFrame.new(0.09, -0.12, 0.3), "grip")
		elseif id == "rifle" then
			part("Stock", Vector3.new(0.24, 0.42, 0.9), CFrame.new(0, -0.14, 0.55), "grip")
			part("Bolt", Vector3.new(0.12, 0.12, 0.5), CFrame.new(0.18, 0.1, -0.1), "fixed", C(150, 150, 154))
			part("BoltHandle", Vector3.new(0.1, 0.28, 0.1), CFrame.new(0.26, 0.02, 0.02), "fixed", C(150, 150, 154))
			part("Sight", Vector3.new(0.06, 0.16, 0.06), CFrame.new(0, 0.24, -length * 0.6), "fixed")
		elseif id == "revolver" then
			part("Cylinder", Vector3.new(0.3, 0.3, 0.34), CFrame.new(0, -0.02, -0.18), "fixed", C(70, 70, 74))
			part("Hammer", Vector3.new(0.07, 0.16, 0.12), CFrame.new(0, 0.18, 0.08), "fixed", C(50, 50, 52))
		elseif id == "flare_gun" then
			part("WideBarrel", Vector3.new(0.3, 0.3, barrelLength * 0.7), barrel.CFrame * CFrame.new(0, 0, 0.1), "body")
		end
		part("FrontSight", Vector3.new(0.05, 0.12, 0.05), barrel.CFrame * CFrame.new(0, 0.14, -barrelLength * 0.45), "fixed")
		muzzleAt = barrel.CFrame * CFrame.new(0, 0, -barrelLength * 0.5)
	end

	local muzzle: BasePart? = nil
	if muzzleAt then
		local flash = part("Muzzle", Vector3.new(0.1, 0.1, 0.1), muzzleAt, "fixed", C(255, 220, 150), Enum.Material.Neon)
		flash.Transparency = 1
		muzzle = flash
	end

	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") and descendant ~= root then
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = root
			weld.Part1 = descendant
			weld.Parent = root
		end
	end

	return { model = model, root = root, muzzle = muzzle, glow = glow }
end

return WeaponModels
