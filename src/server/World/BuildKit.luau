--!strict
--[[
	BuildKit
	--------
	Construction primitives for every piece of geometry in LAST SIGNAL.

	WHY THE WORLD IS BUILT IN CODE
	------------------------------
	This project ships no third-party meshes or textures. Importing somebody
	else's model because it appeared in a search result is exactly what the
	brief forbids, and this project has no way to license, verify or attribute
	assets on the operator's behalf. So every object is built from Roblox
	primitives at runtime, out of parts, wedges, cylinders and the standard
	material set, which are the assets Roblox already licenses to you.

	That constraint is a real one and it shows: these are detailed constructed
	objects, not sculpted meshes. What it buys is a world with no licensing
	risk, no download weight, and geometry the operator can edit. docs/ASSETS.md
	records exactly this, and describes where to drop in real meshes later
	without touching gameplay code.

	PERFORMANCE RULES BAKED INTO THIS FILE
	--------------------------------------
	  - Everything static is Anchored and CanTouch = false. Touch events on
	    scenery are the single biggest avoidable server cost in Roblox.
	  - Small decorative parts get CanCollide = false and CanQuery = false, so
	    they cost nothing for physics or raycasts.
	  - Repeated geometry is built once and cloned, never rebuilt per instance.
	  - Nothing built here uses a script inside the model. All behaviour lives
	    in services, so a model can be deleted without breaking logic.
]]

local BuildKit = {}

local C = Color3.fromRGB

--------------------------------------------------------------------------
-- Primitives
--------------------------------------------------------------------------

export type PartProps = {
	name: string?,
	size: Vector3,
	cfrmame: CFrame?,
	cf: CFrame?,
	colour: Color3?,
	material: Enum.Material?,
	transparency: number?,
	reflectance: number?,
	shape: Enum.PartType?,
	anchored: boolean?,
	canCollide: boolean?,
	canQuery: boolean?,
	castShadow: boolean?,
	parent: Instance?,
}

--- The base constructor. Every other helper funnels through this so the
--- performance defaults above are applied exactly once, in one place.
function BuildKit.part(props: PartProps): Part
	local p = Instance.new("Part")
	p.Name = props.name or "Part"
	p.Size = props.size
	p.CFrame = props.cf or props.cfrmame or CFrame.new()
	p.Color = props.colour or C(128, 128, 128)
	p.Material = props.material or Enum.Material.SmoothPlastic
	p.Transparency = props.transparency or 0
	p.Reflectance = props.reflectance or 0
	p.Anchored = if props.anchored == nil then true else props.anchored
	p.CanCollide = if props.canCollide == nil then true else props.canCollide
	p.CanQuery = if props.canQuery == nil then true else props.canQuery
	p.CanTouch = false
	p.CastShadow = if props.castShadow == nil then true else props.castShadow
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	if props.shape then
		p.Shape = props.shape
	end
	if props.parent then
		p.Parent = props.parent
	end
	return p
end

--- Decorative detail: no collision, no raycast hits, no shadow. Use for
--- rivets, trim strips, small pipework and anything a player cannot interact
--- with. Hundreds of these are affordable; hundreds of collidable parts are not.
function BuildKit.detail(props: PartProps): Part
	local merged: PartProps = table.clone(props)
	merged.canCollide = false
	merged.canQuery = false
	merged.castShadow = if props.castShadow == nil then false else props.castShadow
	return BuildKit.part(merged)
end

function BuildKit.wedge(props: PartProps): WedgePart
	local p = Instance.new("WedgePart")
	p.Name = props.name or "Wedge"
	p.Size = props.size
	p.CFrame = props.cf or CFrame.new()
	p.Color = props.colour or C(128, 128, 128)
	p.Material = props.material or Enum.Material.SmoothPlastic
	p.Transparency = props.transparency or 0
	p.Anchored = if props.anchored == nil then true else props.anchored
	p.CanCollide = if props.canCollide == nil then true else props.canCollide
	p.CanQuery = if props.canQuery == nil then true else props.canQuery
	p.CanTouch = false
	p.CastShadow = if props.castShadow == nil then true else props.castShadow
	if props.parent then
		p.Parent = props.parent
	end
	return p
end

function BuildKit.cylinder(props: PartProps): Part
	local merged: PartProps = table.clone(props)
	merged.shape = Enum.PartType.Cylinder
	return BuildKit.part(merged)
end

function BuildKit.sphere(props: PartProps): Part
	local merged: PartProps = table.clone(props)
	merged.shape = Enum.PartType.Ball
	return BuildKit.part(merged)
end

--- A rounded-corner box built from a block plus cylinders. Used for tank
--- bodies, lamp housings and anything that should not read as a cube.
function BuildKit.roundedBox(cf: CFrame, size: Vector3, radius: number, props: PartProps, parent: Instance): Model
	local model = Instance.new("Model")
	model.Name = props.name or "RoundedBox"

	local core = BuildKit.part({
		name = "Core",
		size = Vector3.new(size.X, size.Y - radius * 2, size.Z),
		cf = cf,
		colour = props.colour,
		material = props.material,
		parent = model,
	})
	core.Name = "Core"

	for _, sign in { 1, -1 } do
		BuildKit.part({
			name = "Cap",
			size = Vector3.new(size.X - radius * 0.1, radius * 2, size.Z),
			cf = cf * CFrame.new(0, sign * (size.Y * 0.5 - radius), 0),
			colour = props.colour,
			material = props.material,
			parent = model,
		})
	end
	model.Parent = parent
	return model
end

--------------------------------------------------------------------------
-- Composite detail helpers
--------------------------------------------------------------------------

--- A run of rivets along a line. The single cheapest way to make a flat metal
--- panel read as fabricated rather than extruded.
function BuildKit.rivetStrip(startCF: CFrame, length: number, spacing: number, radius: number, colour: Color3, parent: Instance)
	local count = math.max(2, math.floor(length / spacing))
	local step = length / (count - 1)
	for i = 0, count - 1 do
		BuildKit.detail({
			name = "Rivet",
			size = Vector3.new(radius * 2, radius * 2, radius * 2),
			cf = startCF * CFrame.new(0, 0, -i * step),
			colour = colour,
			material = Enum.Material.Metal,
			shape = Enum.PartType.Ball,
			parent = parent,
		})
	end
end

--- A tubular handrail: two uprights and a top rail, with optional mid rail.
function BuildKit.handrail(baseCF: CFrame, length: number, height: number, colour: Color3, parent: Instance, midRail: boolean?)
	local thickness = 0.18
	BuildKit.detail({
		name = "RailTop",
		size = Vector3.new(thickness, thickness, length),
		cf = baseCF * CFrame.new(0, height, 0),
		colour = colour,
		material = Enum.Material.Metal,
		parent = parent,
	})
	if midRail then
		BuildKit.detail({
			name = "RailMid",
			size = Vector3.new(thickness, thickness, length),
			cf = baseCF * CFrame.new(0, height * 0.55, 0),
			colour = colour,
			material = Enum.Material.Metal,
			parent = parent,
		})
	end
	local posts = math.max(2, math.floor(length / 8) + 1)
	for i = 0, posts - 1 do
		local z = -length * 0.5 + (length / (posts - 1)) * i
		BuildKit.detail({
			name = "RailPost",
			size = Vector3.new(thickness, height, thickness),
			cf = baseCF * CFrame.new(0, height * 0.5, z),
			colour = colour,
			material = Enum.Material.Metal,
			parent = parent,
		})
	end
end

--- A pipe run with elbow joints. Takes a list of local points.
function BuildKit.pipeRun(originCF: CFrame, points: { Vector3 }, diameter: number, colour: Color3, parent: Instance)
	for i = 1, #points - 1 do
		local a = points[i]
		local b = points[i + 1]
		local delta = b - a
		local length = delta.Magnitude
		if length > 0.05 then
			local mid = a + delta * 0.5
			BuildKit.detail({
				name = "Pipe",
				size = Vector3.new(diameter, diameter, length),
				cf = originCF * CFrame.new(mid) * CFrame.lookAt(Vector3.zero, delta.Unit).Rotation,
				colour = colour,
				material = Enum.Material.Metal,
				parent = parent,
			})
		end
		-- Elbow sphere at each interior joint so corners do not show a gap.
		if i > 1 then
			BuildKit.detail({
				name = "Elbow",
				size = Vector3.new(diameter * 1.15, diameter * 1.15, diameter * 1.15),
				cf = originCF * CFrame.new(a),
				colour = colour,
				material = Enum.Material.Metal,
				shape = Enum.PartType.Ball,
				parent = parent,
			})
		end
	end
end

--- A louvred vent panel.
function BuildKit.vent(cf: CFrame, width: number, height: number, colour: Color3, parent: Instance)
	local frame = BuildKit.detail({
		name = "VentFrame",
		size = Vector3.new(0.16, height, width),
		cf = cf,
		colour = colour,
		material = Enum.Material.Metal,
		parent = parent,
	})
	frame.Name = "VentFrame"
	local slats = math.max(3, math.floor(height / 0.45))
	local step = (height - 0.3) / (slats - 1)
	local darker = Color3.new(colour.R * 0.45, colour.G * 0.45, colour.B * 0.45)
	for i = 0, slats - 1 do
		BuildKit.detail({
			name = "Slat",
			size = Vector3.new(0.22, 0.14, width - 0.3),
			cf = cf * CFrame.new(0.05, -height * 0.5 + 0.15 + i * step, 0) * CFrame.Angles(0, 0, math.rad(22)),
			colour = darker,
			material = Enum.Material.Metal,
			parent = parent,
		})
	end
end

--- A mesh grille made from crossing bars. Used on radiator faces and windows
--- that should read as barred rather than glazed.
function BuildKit.grille(cf: CFrame, width: number, height: number, spacing: number, colour: Color3, parent: Instance)
	local bars = math.max(2, math.floor(width / spacing))
	for i = 0, bars do
		BuildKit.detail({
			name = "GrilleBar",
			size = Vector3.new(0.1, height, 0.1),
			cf = cf * CFrame.new(0, 0, -width * 0.5 + (width / bars) * i),
			colour = colour,
			material = Enum.Material.Metal,
			parent = parent,
		})
	end
	local rows = math.max(2, math.floor(height / spacing))
	for i = 0, rows do
		BuildKit.detail({
			name = "GrilleBar",
			size = Vector3.new(0.09, 0.09, width),
			cf = cf * CFrame.new(0, -height * 0.5 + (height / rows) * i, 0),
			colour = colour,
			material = Enum.Material.Metal,
			parent = parent,
		})
	end
end

--- A climbable ladder. Rungs are collidable and tagged so the movement system
--- can offer a climb prompt; stiles are decoration.
function BuildKit.ladder(baseCF: CFrame, height: number, width: number, colour: Color3, parent: Instance): Model
	local model = Instance.new("Model")
	model.Name = "Ladder"
	for _, sign in { 1, -1 } do
		BuildKit.detail({
			name = "Stile",
			size = Vector3.new(0.16, height, 0.16),
			cf = baseCF * CFrame.new(sign * width * 0.5, height * 0.5, 0),
			colour = colour,
			material = Enum.Material.Metal,
			parent = model,
		})
	end
	local rungs = math.max(2, math.floor(height / 1.4))
	for i = 0, rungs do
		local rung = BuildKit.part({
			name = "Rung",
			size = Vector3.new(width, 0.14, 0.14),
			cf = baseCF * CFrame.new(0, 0.6 + (height - 1.0) / rungs * i, 0),
			colour = colour,
			material = Enum.Material.Metal,
			canCollide = false,
			castShadow = false,
			parent = model,
		})
		rung:AddTag("LadderRung")
	end
	model.Parent = parent
	return model
end

--- Corrugated sheeting, for shed walls and roofs. Built as one flat panel plus
--- ribs so a large wall is two dozen parts rather than two hundred.
function BuildKit.corrugated(cf: CFrame, width: number, height: number, colour: Color3, parent: Instance)
	BuildKit.part({
		name = "Sheet",
		size = Vector3.new(0.3, height, width),
		cf = cf,
		colour = colour,
		material = Enum.Material.CorrodedMetal,
		parent = parent,
	})
	local ribs = math.max(3, math.floor(width / 1.6))
	local darker = Color3.new(colour.R * 0.8, colour.G * 0.8, colour.B * 0.8)
	for i = 0, ribs do
		BuildKit.detail({
			name = "Rib",
			size = Vector3.new(0.14, height, 0.22),
			cf = cf * CFrame.new(0.2, 0, -width * 0.5 + (width / ribs) * i),
			colour = darker,
			material = Enum.Material.CorrodedMetal,
			parent = parent,
		})
	end
end

--------------------------------------------------------------------------
-- Openings
--------------------------------------------------------------------------

--- A window: frame, glass and a sill. Glass is non-collidable and
--- non-queryable so it never blocks a raycast or a bullet.
function BuildKit.window(cf: CFrame, width: number, height: number, frameColour: Color3, parent: Instance, broken: boolean?)
	local t = 0.14
	local function frameMember(size: Vector3, offset: CFrame)
		BuildKit.detail({
			name = "Frame",
			size = size,
			cf = cf * offset,
			colour = frameColour,
			material = Enum.Material.Metal,
			parent = parent,
		})
	end
	frameMember(Vector3.new(t, height, 0.3), CFrame.new(0, 0, -width * 0.5))
	frameMember(Vector3.new(t, height, 0.3), CFrame.new(0, 0, width * 0.5))
	frameMember(Vector3.new(t, 0.3, width), CFrame.new(0, height * 0.5, 0))
	frameMember(Vector3.new(t, 0.3, width), CFrame.new(0, -height * 0.5, 0))
	if not broken then
		local glass = BuildKit.detail({
			name = "Glass",
			size = Vector3.new(0.06, height - 0.3, width - 0.3),
			cf = cf,
			colour = C(150, 170, 185),
			material = Enum.Material.Glass,
			transparency = 0.72,
			reflectance = 0.12,
			parent = parent,
		})
		glass.Name = "Glass"
	else
		-- Broken windows keep a few shards so the opening still reads as glazed.
		for i = 1, 4 do
			BuildKit.detail({
				name = "Shard",
				size = Vector3.new(0.06, math.random(20, 60) / 100, math.random(20, 70) / 100),
				cf = cf
					* CFrame.new(0, height * 0.5 - 0.3 - i * 0.15, (i - 2.5) * width * 0.22)
					* CFrame.Angles(math.rad(math.random(-12, 12)), 0, math.rad(math.random(-20, 20))),
				colour = C(150, 170, 185),
				material = Enum.Material.Glass,
				transparency = 0.6,
				parent = parent,
			})
		end
	end
end

--- A hinged door as its own Model with a PrimaryPart at the hinge, so
--- DoorService can swing it by rotating the model rather than tweening parts.
function BuildKit.door(
	hingeCF: CFrame,
	width: number,
	height: number,
	thickness: number,
	colour: Color3,
	material: Enum.Material,
	parent: Instance
): Model
	local model = Instance.new("Model")
	model.Name = "Door"

	local hinge = BuildKit.part({
		name = "Hinge",
		size = Vector3.new(0.2, 0.2, 0.2),
		cf = hingeCF,
		transparency = 1,
		canCollide = false,
		canQuery = false,
		castShadow = false,
		parent = model,
	})

	local leaf = BuildKit.part({
		name = "Leaf",
		size = Vector3.new(thickness, height, width),
		cf = hingeCF * CFrame.new(0, height * 0.5, -width * 0.5),
		colour = colour,
		material = material,
		parent = model,
	})

	-- Handle, so the door reads as openable before you get the prompt.
	BuildKit.detail({
		name = "Handle",
		size = Vector3.new(thickness + 0.2, 0.12, 0.5),
		cf = hingeCF * CFrame.new(0, height * 0.48, -width * 0.85),
		colour = C(168, 150, 110),
		material = Enum.Material.Metal,
		parent = model,
	})

	model.PrimaryPart = hinge
	leaf:AddTag("DoorLeaf")
	model.Parent = parent
	return model
end

--------------------------------------------------------------------------
-- Lighting
--------------------------------------------------------------------------

--- A practical light: a visible fitting plus the light source. Every light in
--- this game has a visible source, because an unexplained pool of light in a
--- horror game reads as a bug.
function BuildKit.lamp(
	cf: CFrame,
	kind: string,
	colour: Color3,
	brightness: number,
	range: number,
	parent: Instance
): (Part, Light)
	local housingColour = C(48, 50, 54)
	local housing: Part
	local light: Light

	if kind == "pendant" then
		BuildKit.detail({
			name = "Flex",
			size = Vector3.new(0.08, 1.2, 0.08),
			cf = cf * CFrame.new(0, 0.6, 0),
			colour = housingColour,
			material = Enum.Material.Metal,
			parent = parent,
		})
		BuildKit.detail({
			name = "Shade",
			size = Vector3.new(1.4, 0.5, 1.4),
			cf = cf * CFrame.new(0, 0.2, 0),
			colour = C(184, 178, 162),
			material = Enum.Material.Metal,
			parent = parent,
		})
		housing = BuildKit.detail({
			name = "Bulb",
			size = Vector3.new(0.42, 0.42, 0.42),
			cf = cf,
			colour = colour,
			material = Enum.Material.Neon,
			shape = Enum.PartType.Ball,
			parent = parent,
		})
		local point = Instance.new("PointLight")
		point.Color = colour
		point.Brightness = brightness
		point.Range = range
		point.Shadows = true
		point.Parent = housing
		light = point
	elseif kind == "flood" then
		BuildKit.detail({
			name = "Bracket",
			size = Vector3.new(0.24, 0.8, 0.24),
			cf = cf * CFrame.new(0, 0.5, 0),
			colour = housingColour,
			material = Enum.Material.Metal,
			parent = parent,
		})
		housing = BuildKit.detail({
			name = "FloodBody",
			size = Vector3.new(1.1, 0.9, 1.6),
			cf = cf,
			colour = housingColour,
			material = Enum.Material.Metal,
			parent = parent,
		})
		BuildKit.detail({
			name = "Lens",
			size = Vector3.new(0.2, 0.7, 1.4),
			cf = cf * CFrame.new(-0.6, 0, 0),
			colour = colour,
			material = Enum.Material.Neon,
			parent = parent,
		})
		local spot = Instance.new("SpotLight")
		spot.Color = colour
		spot.Brightness = brightness
		spot.Range = range
		spot.Angle = 78
		spot.Face = Enum.NormalId.Left
		spot.Shadows = true
		spot.Parent = housing
		light = spot
	elseif kind == "strip" then
		housing = BuildKit.detail({
			name = "StripBody",
			size = Vector3.new(0.3, 0.3, 6),
			cf = cf,
			colour = C(190, 190, 186),
			material = Enum.Material.SmoothPlastic,
			parent = parent,
		})
		BuildKit.detail({
			name = "Diffuser",
			size = Vector3.new(0.22, 0.16, 5.6),
			cf = cf * CFrame.new(0, -0.16, 0),
			colour = colour,
			material = Enum.Material.Neon,
			parent = parent,
		})
		local surface = Instance.new("SurfaceLight")
		surface.Color = colour
		surface.Brightness = brightness
		surface.Range = range
		surface.Angle = 120
		surface.Face = Enum.NormalId.Bottom
		surface.Parent = housing
		light = surface
	else -- "bulkhead", the default
		housing = BuildKit.detail({
			name = "BulkheadBody",
			size = Vector3.new(0.5, 0.9, 0.9),
			cf = cf,
			colour = housingColour,
			material = Enum.Material.Metal,
			parent = parent,
		})
		BuildKit.detail({
			name = "Lens",
			size = Vector3.new(0.24, 0.62, 0.62),
			cf = cf * CFrame.new(-0.3, 0, 0),
			colour = colour,
			material = Enum.Material.Neon,
			parent = parent,
		})
		BuildKit.grille(cf * CFrame.new(-0.36, 0, 0), 0.7, 0.7, 0.22, housingColour, parent)
		local point = Instance.new("PointLight")
		point.Color = colour
		point.Brightness = brightness
		point.Range = range
		point.Shadows = true
		point.Parent = housing
		light = point
	end

	housing:AddTag("PracticalLight")
	return housing, light
end

--------------------------------------------------------------------------
-- Materials and wear
--------------------------------------------------------------------------

BuildKit.Palette = {
	rustedSteel = C(112, 74, 52),
	paintedSteel = C(88, 94, 98),
	darkSteel = C(46, 48, 52),
	galvanised = C(150, 154, 158),
	brass = C(172, 138, 70),
	concrete = C(132, 130, 124),
	weatheredConcrete = C(108, 106, 100),
	sleeper = C(64, 52, 42),
	ballast = C(96, 92, 86),
	bark = C(72, 58, 46),
	darkBark = C(52, 42, 34),
	foliage = C(38, 56, 40),
	deepFoliage = C(28, 44, 32),
	soil = C(52, 44, 36),
	planking = C(104, 84, 60),
	weatheredPlank = C(88, 78, 64),
	glass = C(150, 170, 185),
	canvas = C(122, 112, 90),
}

--- Applies a subtle per-instance colour jitter. Identical parts across a
--- forest or a row of buildings are the main thing that makes a procedural
--- world look procedural, and this is the cheapest fix.
function BuildKit.weather(colour: Color3, amount: number, rng: Random): Color3
	local jitter = function()
		return (rng:NextNumber() - 0.5) * 2 * amount
	end
	return Color3.new(
		math.clamp(colour.R + jitter(), 0, 1),
		math.clamp(colour.G + jitter(), 0, 1),
		math.clamp(colour.B + jitter(), 0, 1)
	)
end

--- Streaks of rust down a painted surface. Applied to large metal faces on
--- the train and on station buildings.
function BuildKit.rustStreaks(cf: CFrame, width: number, height: number, count: number, rng: Random, parent: Instance)
	for _ = 1, count do
		local w = rng:NextNumber(0.12, 0.4)
		local h = rng:NextNumber(height * 0.2, height * 0.75)
		BuildKit.detail({
			name = "Streak",
			size = Vector3.new(0.05, h, w),
			cf = cf
				* CFrame.new(0, height * 0.5 - h * 0.5 - rng:NextNumber(0, height * 0.2), rng:NextNumber(-width * 0.5, width * 0.5)),
			colour = BuildKit.weather(BuildKit.Palette.rustedSteel, 0.06, rng),
			material = Enum.Material.CorrodedMetal,
			transparency = 0.25,
			parent = parent,
		})
	end
end

--------------------------------------------------------------------------
-- Model helpers
--------------------------------------------------------------------------

function BuildKit.model(name: string, parent: Instance?): Model
	local model = Instance.new("Model")
	model.Name = name
	if parent then
		model.Parent = parent
	end
	return model
end

--- Welds every BasePart in a model to the given root, then unanchors them.
--- Used for objects that must move as one rigid body, such as dropped items.
function BuildKit.weldAssembly(model: Model, root: BasePart)
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") and descendant ~= root then
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = root
			weld.Part1 = descendant
			weld.Parent = root
			descendant.Anchored = false
		end
	end
	root.Anchored = false
end

--- Sets the whole model anchored, which is the default for scenery.
function BuildKit.anchorAll(model: Model)
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
		end
	end
end

--- Counts parts, so builders can report their cost and the performance budget
--- in docs/PERFORMANCE.md can be checked rather than guessed.
function BuildKit.countParts(instance: Instance): number
	local n = 0
	for _, descendant in instance:GetDescendants() do
		if descendant:IsA("BasePart") then
			n += 1
		end
	end
	return n
end

--- Adds a ProximityPrompt configured to this project's conventions: short
--- hold, generous distance, and no floating billboard.
function BuildKit.prompt(
	parent: BasePart,
	actionText: string,
	objectText: string,
	holdDuration: number?,
	maxDistance: number?
): ProximityPrompt
	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = actionText
	prompt.ObjectText = objectText
	prompt.HoldDuration = holdDuration or 0
	prompt.MaxActivationDistance = maxDistance or 9
	prompt.RequiresLineOfSight = false
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.GamepadKeyCode = Enum.KeyCode.ButtonX
	prompt.Style = Enum.ProximityPromptStyle.Custom
	prompt.Parent = parent
	return prompt
end

--------------------------------------------------------------------------
-- Track
--------------------------------------------------------------------------

--- Builds a straight run of railway: ballast shoulder, sleepers and two rails.
--- Sleepers are cloned from a single template, which keeps a 14,000 stud line
--- affordable.
function BuildKit.trackSection(originCF: CFrame, length: number, parent: Instance, rng: Random): Model
	local model = BuildKit.model("Track", parent)
	local gauge = 9.4

	-- Ballast shoulder as two long parts rather than many small ones.
	BuildKit.part({
		name = "Ballast",
		size = Vector3.new(26, 1.6, length),
		cf = originCF * CFrame.new(0, -0.8, -length * 0.5),
		colour = BuildKit.Palette.ballast,
		material = Enum.Material.Slate,
		parent = model,
	})

	local sleeperTemplate = BuildKit.part({
		name = "Sleeper",
		size = Vector3.new(14, 0.7, 1.8),
		cf = CFrame.new(),
		colour = BuildKit.Palette.sleeper,
		material = Enum.Material.WoodPlanks,
		canQuery = false,
		castShadow = false,
	})

	local spacing = 3.2
	local count = math.floor(length / spacing)
	for i = 0, count - 1 do
		local sleeper = sleeperTemplate:Clone()
		sleeper.CFrame = originCF
			* CFrame.new(0, 0.15, -i * spacing - spacing * 0.5)
			* CFrame.Angles(0, math.rad(rng:NextNumber(-1.2, 1.2)), 0)
		sleeper.Color = BuildKit.weather(BuildKit.Palette.sleeper, 0.05, rng)
		sleeper.Parent = model
	end
	sleeperTemplate:Destroy()

	for _, side in { -1, 1 } do
		BuildKit.part({
			name = "Rail",
			size = Vector3.new(0.9, 0.9, length),
			cf = originCF * CFrame.new(side * gauge * 0.5, 0.85, -length * 0.5),
			colour = C(102, 96, 88),
			material = Enum.Material.Metal,
			reflectance = 0.08,
			castShadow = false,
			parent = model,
		})
		-- Rail head, the shiny worn strip on top.
		BuildKit.detail({
			name = "RailHead",
			size = Vector3.new(0.5, 0.12, length),
			cf = originCF * CFrame.new(side * gauge * 0.5, 1.32, -length * 0.5),
			colour = C(168, 166, 160),
			material = Enum.Material.Metal,
			reflectance = 0.3,
			parent = model,
		})
	end

	return model
end

return BuildKit
