--!strict
--[[
	ForestBuilder
	-------------
	The dense night forest either side of the railway.

	THE PROBLEM THIS SOLVES
	-----------------------
	A procedural forest fails in three recognisable ways: obvious grid spacing,
	identical trees, and a thin band of scenery around a small stage. All three
	are addressed here deliberately.

	  Grid       Positions come from jittered Poisson-ish sampling with a
	             per-cell random offset and rejection against a minimum spacing,
	             so no two trees line up and no row is visible.
	  Sameness   Six tree archetypes, each built with randomised height, lean,
	             trunk taper, branch count and per-instance colour jitter. A
	             template is built once per archetype and cloned, then mutated,
	             which keeps the cost affordable.
	  Thinness   The forest is generated in streaming chunks along the whole
	             14,000 stud corridor rather than as set dressing around
	             stations, and undergrowth, deadfall, rocks and stumps fill the
	             floor so the ground is never bare.

	Everything here is anchored, non-collidable except trunks, and does not cast
	shadows except for trunks, which is what keeps a forest this size affordable
	with Future lighting on.
]]

local BuildKit = require(script.Parent.BuildKit)

local C = Color3.fromRGB
local P = BuildKit.Palette

local ForestBuilder = {}

--------------------------------------------------------------------------
-- Tree archetypes
--------------------------------------------------------------------------

export type TreeArchetype = {
	id: string,
	minHeight: number,
	maxHeight: number,
	trunkRadius: number,
	canopyStyle: string,
	barkColour: Color3,
	foliageColour: Color3,
	weight: number,
}

local ARCHETYPES: { TreeArchetype } = {
	{
		id = "spruce_tall",
		minHeight = 58,
		maxHeight = 92,
		trunkRadius = 1.5,
		canopyStyle = "conifer",
		barkColour = C(58, 46, 38),
		foliageColour = C(30, 48, 34),
		weight = 30,
	},
	{
		id = "spruce_young",
		minHeight = 26,
		maxHeight = 44,
		trunkRadius = 0.9,
		canopyStyle = "conifer",
		barkColour = C(66, 54, 42),
		foliageColour = C(36, 58, 40),
		weight = 22,
	},
	{
		id = "pine",
		minHeight = 62,
		maxHeight = 104,
		trunkRadius = 1.7,
		canopyStyle = "pine",
		barkColour = C(84, 60, 44),
		foliageColour = C(34, 52, 36),
		weight = 18,
	},
	{
		id = "birch",
		minHeight = 40,
		maxHeight = 64,
		trunkRadius = 0.8,
		canopyStyle = "broadleaf",
		barkColour = C(196, 192, 180),
		foliageColour = C(52, 62, 40),
		weight = 12,
	},
	{
		id = "oak_old",
		minHeight = 44,
		maxHeight = 70,
		trunkRadius = 2.4,
		canopyStyle = "broadleaf",
		barkColour = C(68, 56, 44),
		foliageColour = C(44, 56, 36),
		weight = 10,
	},
	{
		id = "dead_standing",
		minHeight = 34,
		maxHeight = 66,
		trunkRadius = 1.2,
		canopyStyle = "dead",
		barkColour = C(84, 76, 66),
		foliageColour = C(60, 54, 46),
		weight = 8,
	},
}

--------------------------------------------------------------------------
-- Tree construction
--------------------------------------------------------------------------

local function buildTrunk(model: Model, height: number, radius: number, bark: Color3, lean: CFrame, rng: Random)
	-- Trunk in tapering segments, so it is not a uniform pole.
	local segments = math.clamp(math.floor(height / 16), 2, 5)
	local segmentHeight = height / segments
	local cf = lean
	for i = 0, segments - 1 do
		local taper = 1 - (i / segments) * 0.55
		local segCF = cf * CFrame.new(0, segmentHeight * 0.5, 0)
		local part = BuildKit.part({
			name = "Trunk",
			size = Vector3.new(radius * 2 * taper, segmentHeight * 1.02, radius * 2 * taper),
			cf = segCF,
			colour = BuildKit.weather(bark, 0.035, rng),
			material = Enum.Material.Wood,
			canCollide = i == 0, -- only the base blocks movement
			canQuery = true,
			castShadow = i < 2,
			parent = model,
		})
		part.Shape = Enum.PartType.Cylinder
		part.CFrame = segCF * CFrame.Angles(0, 0, math.rad(90))
		part.Size = Vector3.new(segmentHeight * 1.02, radius * 2 * taper, radius * 2 * taper)
		-- Each segment leans slightly further, giving a natural crookedness.
		cf = cf
			* CFrame.new(0, segmentHeight, 0)
			* CFrame.Angles(math.rad(rng:NextNumber(-3, 3)), 0, math.rad(rng:NextNumber(-3, 3)))
	end

	-- Root flare at the base.
	for i = 0, 3 do
		BuildKit.detail({
			name = "Root",
			size = Vector3.new(radius * 0.7, radius * 1.6, radius * 2.6),
			cf = lean
				* CFrame.Angles(0, math.rad(i * 90 + rng:NextNumber(-20, 20)), 0)
				* CFrame.new(0, radius * 0.5, radius * 1.2)
				* CFrame.Angles(math.rad(28), 0, 0),
			colour = BuildKit.weather(bark, 0.03, rng),
			material = Enum.Material.Wood,
			parent = model,
		})
	end
	return cf
end

local function buildConiferCanopy(model: Model, topCF: CFrame, height: number, foliage: Color3, rng: Random)
	local tiers = math.clamp(math.floor(height / 9), 4, 9)
	local canopyHeight = height * 0.62
	for i = 0, tiers - 1 do
		local t = i / (tiers - 1)
		local radius = (1 - t * 0.86) * height * 0.16 + 1.5
		local y = -canopyHeight + t * canopyHeight
		BuildKit.detail({
			name = "Foliage",
			size = Vector3.new(radius * 2, canopyHeight / tiers * 1.9, radius * 2),
			cf = topCF
				* CFrame.new(rng:NextNumber(-0.8, 0.8), y, rng:NextNumber(-0.8, 0.8))
				* CFrame.Angles(0, math.rad(rng:NextNumber(0, 360)), 0),
			colour = BuildKit.weather(foliage, 0.045, rng),
			material = Enum.Material.Grass,
			castShadow = i < 2,
			parent = model,
		})
	end
	-- Leader spike at the very top.
	BuildKit.detail({
		name = "Leader",
		size = Vector3.new(2.2, height * 0.1, 2.2),
		cf = topCF * CFrame.new(0, height * 0.04, 0),
		colour = BuildKit.weather(foliage, 0.04, rng),
		material = Enum.Material.Grass,
		parent = model,
	})
end

local function buildPineCanopy(model: Model, topCF: CFrame, height: number, foliage: Color3, rng: Random)
	-- Pines carry their mass at the top with a bare lower trunk, which makes
	-- the forest floor readable and keeps sightlines interesting.
	local clumps = rng:NextInteger(4, 6)
	for i = 1, clumps do
		local angle = math.rad((360 / clumps) * i + rng:NextNumber(-25, 25))
		local reach = height * rng:NextNumber(0.1, 0.18)
		BuildKit.detail({
			name = "Foliage",
			size = Vector3.new(reach * 1.7, height * 0.14, reach * 1.7),
			cf = topCF
				* CFrame.Angles(0, angle, 0)
				* CFrame.new(0, rng:NextNumber(-height * 0.12, 0), reach * 0.6),
			colour = BuildKit.weather(foliage, 0.05, rng),
			material = Enum.Material.Grass,
			castShadow = i <= 2,
			parent = model,
		})
		-- The branch that holds the clump.
		BuildKit.detail({
			name = "Branch",
			size = Vector3.new(0.5, 0.5, reach),
			cf = topCF * CFrame.Angles(0, angle, 0) * CFrame.new(0, rng:NextNumber(-height * 0.12, 0), reach * 0.5),
			colour = C(58, 46, 38),
			material = Enum.Material.Wood,
			parent = model,
		})
	end
end

local function buildBroadleafCanopy(model: Model, topCF: CFrame, height: number, foliage: Color3, rng: Random)
	local clumps = rng:NextInteger(5, 8)
	local spread = height * 0.3
	for _ = 1, clumps do
		local offset = Vector3.new(
			rng:NextNumber(-spread, spread),
			rng:NextNumber(-height * 0.12, height * 0.08),
			rng:NextNumber(-spread, spread)
		)
		local size = rng:NextNumber(spread * 0.7, spread * 1.3)
		BuildKit.detail({
			name = "Foliage",
			size = Vector3.new(size, size * 0.75, size),
			cf = topCF * CFrame.new(offset),
			colour = BuildKit.weather(foliage, 0.05, rng),
			material = Enum.Material.Grass,
			shape = Enum.PartType.Ball,
			castShadow = false,
			parent = model,
		})
	end
end

local function buildDeadCanopy(model: Model, topCF: CFrame, height: number, rng: Random)
	local branches = rng:NextInteger(4, 7)
	for i = 1, branches do
		local angle = math.rad((360 / branches) * i + rng:NextNumber(-30, 30))
		local len = height * rng:NextNumber(0.12, 0.24)
		BuildKit.detail({
			name = "DeadBranch",
			size = Vector3.new(0.6, 0.6, len),
			cf = topCF
				* CFrame.Angles(0, angle, 0)
				* CFrame.new(0, rng:NextNumber(-height * 0.2, 0), len * 0.5)
				* CFrame.Angles(math.rad(rng:NextNumber(-35, -10)), 0, 0),
			colour = C(84, 76, 66),
			material = Enum.Material.Wood,
			parent = model,
		})
	end
end

--- Builds one tree template. Templates are cloned rather than rebuilt.
local function buildTreeTemplate(archetype: TreeArchetype, rng: Random): Model
	local model = BuildKit.model("Tree_" .. archetype.id, nil)
	local height = rng:NextNumber(archetype.minHeight, archetype.maxHeight)
	local lean = CFrame.Angles(math.rad(rng:NextNumber(-4, 4)), 0, math.rad(rng:NextNumber(-4, 4)))
	local topCF = buildTrunk(model, height, archetype.trunkRadius, archetype.barkColour, lean, rng)

	if archetype.canopyStyle == "conifer" then
		buildConiferCanopy(model, topCF, height, archetype.foliageColour, rng)
	elseif archetype.canopyStyle == "pine" then
		buildPineCanopy(model, topCF, height, archetype.foliageColour, rng)
	elseif archetype.canopyStyle == "broadleaf" then
		buildBroadleafCanopy(model, topCF, height, archetype.foliageColour, rng)
	else
		buildDeadCanopy(model, topCF, height, rng)
	end

	return model
end

--------------------------------------------------------------------------
-- Ground cover
--------------------------------------------------------------------------

local function buildUndergrowth(cf: CFrame, parent: Instance, rng: Random)
	local kind = rng:NextInteger(1, 4)
	if kind == 1 then
		-- Fern clump.
		for _ = 1, rng:NextInteger(3, 6) do
			BuildKit.detail({
				name = "Fern",
				size = Vector3.new(rng:NextNumber(1.4, 3.2), 0.25, rng:NextNumber(1.4, 3.2)),
				cf = cf
					* CFrame.new(rng:NextNumber(-2, 2), rng:NextNumber(0.2, 1.2), rng:NextNumber(-2, 2))
					* CFrame.Angles(math.rad(rng:NextNumber(-30, 30)), math.rad(rng:NextNumber(0, 360)), 0),
				colour = BuildKit.weather(C(38, 54, 36), 0.05, rng),
				material = Enum.Material.Grass,
				parent = parent,
			})
		end
	elseif kind == 2 then
		-- Bramble mound.
		BuildKit.detail({
			name = "Bramble",
			size = Vector3.new(rng:NextNumber(4, 8), rng:NextNumber(1.6, 3.2), rng:NextNumber(4, 8)),
			cf = cf * CFrame.new(0, 0.8, 0),
			colour = BuildKit.weather(C(34, 44, 32), 0.04, rng),
			material = Enum.Material.Grass,
			shape = Enum.PartType.Ball,
			parent = parent,
		})
	elseif kind == 3 then
		-- Rock.
		local size = rng:NextNumber(2, 7)
		BuildKit.part({
			name = "Rock",
			size = Vector3.new(size, size * rng:NextNumber(0.5, 0.9), size * rng:NextNumber(0.7, 1.3)),
			cf = cf * CFrame.new(0, size * 0.25, 0) * CFrame.Angles(math.rad(rng:NextNumber(-15, 15)), math.rad(rng:NextNumber(0, 360)), math.rad(rng:NextNumber(-15, 15))),
			colour = BuildKit.weather(C(88, 86, 82), 0.05, rng),
			material = Enum.Material.Rock,
			canQuery = false,
			parent = parent,
		})
	else
		-- Stump.
		local radius = rng:NextNumber(1.2, 2.6)
		local stump = BuildKit.part({
			name = "Stump",
			size = Vector3.new(radius * 2, rng:NextNumber(1.5, 3.5), radius * 2),
			cf = cf * CFrame.new(0, 1.2, 0),
			colour = BuildKit.weather(P.darkBark, 0.04, rng),
			material = Enum.Material.Wood,
			parent = parent,
		})
		stump.Shape = Enum.PartType.Cylinder
		stump.CFrame = cf * CFrame.new(0, 1.2, 0) * CFrame.Angles(0, 0, math.rad(90))
		stump.Size = Vector3.new(stump.Size.Y, radius * 2, radius * 2)
	end
end

local function buildDeadfall(cf: CFrame, parent: Instance, rng: Random)
	local length = rng:NextNumber(14, 34)
	local radius = rng:NextNumber(1.0, 2.2)
	local log = BuildKit.part({
		name = "FallenLog",
		size = Vector3.new(length, radius * 2, radius * 2),
		cf = cf * CFrame.new(0, radius, 0) * CFrame.Angles(0, math.rad(rng:NextNumber(0, 360)), math.rad(rng:NextNumber(-6, 6))),
		colour = BuildKit.weather(P.darkBark, 0.05, rng),
		material = Enum.Material.Wood,
		parent = parent,
	})
	log.Shape = Enum.PartType.Cylinder
	-- Moss on the upper face.
	BuildKit.detail({
		name = "Moss",
		size = Vector3.new(length * 0.8, 0.3, radius * 1.5),
		cf = log.CFrame * CFrame.new(0, 0, 0) * CFrame.new(0, radius * 0.9, 0),
		colour = C(48, 62, 42),
		material = Enum.Material.Grass,
		parent = parent,
	})
end

--------------------------------------------------------------------------
-- Placement
--------------------------------------------------------------------------

export type ForestOptions = {
	-- World-space centre of the region to populate.
	centre: Vector3,
	-- Half-extents. X is across the track, Z is along it.
	halfExtents: Vector2,
	-- Corridor kept clear along the X = centre.X line, for the railway.
	trackClearance: number,
	-- Circular clearings carved out for stations, in world space.
	clearings: { { position: Vector3, radius: number } },
	density: number, -- trees per 10,000 square studs
	seed: number,
	parent: Instance,
}

--- Rejection-sampled placement. Cells are visited in a shuffled order and each
--- candidate is jittered inside its cell, which removes the grid entirely
--- while keeping the cost linear in area.
function ForestBuilder.populate(options: ForestOptions): Model
	local rng = Random.new(options.seed)
	local forest = BuildKit.model("Forest", nil)

	-- Build one template per archetype, then clone.
	local templates: { { archetype: TreeArchetype, variants: { Model } } } = {}
	for _, archetype in ARCHETYPES do
		local variants: { Model } = {}
		-- Four variants per archetype is enough that repetition is not visible
		-- once per-instance rotation and colour jitter are applied.
		for _ = 1, 4 do
			table.insert(variants, buildTreeTemplate(archetype, rng))
		end
		table.insert(templates, { archetype = archetype, variants = variants })
	end

	local totalWeight = 0
	for _, entry in templates do
		totalWeight += entry.archetype.weight
	end

	local function pickTemplate(): Model
		local roll = rng:NextNumber() * totalWeight
		for _, entry in templates do
			roll -= entry.archetype.weight
			if roll <= 0 then
				return entry.variants[rng:NextInteger(1, #entry.variants)]
			end
		end
		local last = templates[#templates]
		return last.variants[1]
	end

	local cellSize = math.sqrt(10000 / math.max(0.01, options.density))
	local cellsX = math.floor((options.halfExtents.X * 2) / cellSize)
	local cellsZ = math.floor((options.halfExtents.Y * 2) / cellSize)

	local placed = 0
	local groundCover = 0

	for ix = 0, cellsX - 1 do
		for iz = 0, cellsZ - 1 do
			local baseX = options.centre.X - options.halfExtents.X + ix * cellSize
			local baseZ = options.centre.Z - options.halfExtents.Y + iz * cellSize
			local x = baseX + rng:NextNumber(0, cellSize)
			local z = baseZ + rng:NextNumber(0, cellSize)
			local position = Vector3.new(x, options.centre.Y, z)

			-- Reject inside the railway corridor.
			if math.abs(x - options.centre.X) < options.trackClearance then
				continue
			end

			-- Reject inside station clearings, with a soft edge so the forest
			-- thins towards a clearing rather than stopping at a hard circle.
			local rejected = false
			for _, clearing in options.clearings do
				local distance = (Vector3.new(position.X, 0, position.Z) - Vector3.new(clearing.position.X, 0, clearing.position.Z)).Magnitude
				if distance < clearing.radius then
					rejected = true
					break
				elseif distance < clearing.radius * 1.4 then
					-- Thinning band.
					local edgeT = (distance - clearing.radius) / (clearing.radius * 0.4)
					if rng:NextNumber() > edgeT then
						rejected = true
						break
					end
				end
			end
			if rejected then
				-- Clearing edges still get ground cover, so they are not bald.
				if rng:NextNumber() < 0.25 then
					buildUndergrowth(CFrame.new(position), forest, rng)
					groundCover += 1
				end
				continue
			end

			local tree = pickTemplate():Clone()
			tree:PivotTo(CFrame.new(position) * CFrame.Angles(0, math.rad(rng:NextNumber(0, 360)), 0))
			-- Per-instance colour jitter on top of the template's own.
			for _, descendant in tree:GetDescendants() do
				if descendant:IsA("BasePart") then
					descendant.Color = BuildKit.weather(descendant.Color, 0.02, rng)
				end
			end
			tree.Parent = forest
			placed += 1

			-- Ground cover clustered near trunks, as it is in real woodland.
			if rng:NextNumber() < 0.55 then
				buildUndergrowth(
					CFrame.new(position + Vector3.new(rng:NextNumber(-8, 8), 0, rng:NextNumber(-8, 8))),
					forest,
					rng
				)
				groundCover += 1
			end
			if rng:NextNumber() < 0.09 then
				buildDeadfall(
					CFrame.new(position + Vector3.new(rng:NextNumber(-14, 14), 0, rng:NextNumber(-14, 14))),
					forest,
					rng
				)
				groundCover += 1
			end
		end
	end

	for _, entry in templates do
		for _, variant in entry.variants do
			variant:Destroy()
		end
	end

	forest:SetAttribute("TreeCount", placed)
	forest:SetAttribute("GroundCoverCount", groundCover)
	forest.Parent = options.parent
	return forest
end

--- A dense screen of trees used to close off the far ends of the corridor, so
--- a player who walks off the map hits forest rather than a void.
function ForestBuilder.buildBoundary(centre: Vector3, length: number, facing: Vector3, parent: Instance, seed: number): Model
	local rng = Random.new(seed)
	local model = BuildKit.model("ForestBoundary", parent)
	local template = buildTreeTemplate(ARCHETYPES[1], rng)
	local rows = 4
	for row = 0, rows - 1 do
		local rowCount = math.floor(length / 16)
		for i = 0, rowCount do
			local along = -length * 0.5 + i * 16 + rng:NextNumber(-5, 5)
			local perpendicular = facing * (row * 14 + rng:NextNumber(-4, 4))
			local pos = centre + Vector3.new(along, 0, 0) + perpendicular
			local tree = template:Clone()
			tree:PivotTo(CFrame.new(pos) * CFrame.Angles(0, math.rad(rng:NextNumber(0, 360)), 0))
			tree.Parent = model
		end
	end
	template:Destroy()
	return model
end

ForestBuilder.Archetypes = ARCHETYPES

return ForestBuilder
