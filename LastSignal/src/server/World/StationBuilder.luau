--!strict
--[[
	StationBuilder
	--------------
	Builds a station from its StationRegistry layout block.

	Every building marked `interior = true` gets a genuine walkable inside:
	floor, lined walls, ceiling, its own practical lighting, props, and the
	number of entrances the spec asks for. Walls are built as segments around
	door and window openings, so an opening is a real gap you can walk through
	rather than a decal on a solid box.

	Fixtures and loot nodes are built as tagged, promptable objects. This module
	only builds geometry and tags it; InteractionService and ObjectiveService
	give it behaviour. Nothing built here contains a script.
]]

local BuildKit = require(script.Parent.BuildKit)
local StationRegistry = require(game:GetService("ReplicatedStorage").LastSignal.Registry.StationRegistry)

local C = Color3.fromRGB
local P = BuildKit.Palette

local StationBuilder = {}

export type BuiltStation = {
	model: Model,
	stationId: string,
	origin: CFrame,
	fixtures: { [string]: BasePart },
	lootNodes: { { part: BasePart, kind: string, tier: number, rolls: number, guaranteed: { string } } },
	landmarks: { [string]: Vector3 },
	lights: { Light },
	doors: { Model },
	-- Set true once power is restored; used by the lighting logic.
	poweredLights: { Light },
	discoveries: { { id: string, part: BasePart } },
	partCount: number,
}

--------------------------------------------------------------------------
-- Shared building pieces
--------------------------------------------------------------------------

--- Builds a wall with rectangular openings cut out of it, as segments.
--- `openings` are in wall-local coordinates: { alongOffset, bottom, width, height }.
local function segmentedWall(
	cf: CFrame,
	length: number,
	height: number,
	thickness: number,
	colour: Color3,
	material: Enum.Material,
	openings: { { along: number, bottom: number, width: number, height: number } },
	parent: Instance
)
	-- Sort openings along the wall and build the solid runs between them.
	local sorted = table.clone(openings)
	table.sort(sorted, function(a, b)
		return a.along < b.along
	end)

	local cursor = -length * 0.5
	for _, opening in sorted do
		local openingStart = opening.along - opening.width * 0.5
		local openingEnd = opening.along + opening.width * 0.5
		if openingStart > cursor then
			local runLength = openingStart - cursor
			BuildKit.part({
				name = "Wall",
				size = Vector3.new(thickness, height, runLength),
				cf = cf * CFrame.new(0, height * 0.5, cursor + runLength * 0.5),
				colour = colour,
				material = material,
				parent = parent,
			})
		end
		-- Lintel above the opening.
		local lintelHeight = height - (opening.bottom + opening.height)
		if lintelHeight > 0.1 then
			BuildKit.part({
				name = "Lintel",
				size = Vector3.new(thickness, lintelHeight, opening.width),
				cf = cf * CFrame.new(0, opening.bottom + opening.height + lintelHeight * 0.5, opening.along),
				colour = colour,
				material = material,
				parent = parent,
			})
		end
		-- Sill below, for windows that do not reach the floor.
		if opening.bottom > 0.1 then
			BuildKit.part({
				name = "Sill",
				size = Vector3.new(thickness, opening.bottom, opening.width),
				cf = cf * CFrame.new(0, opening.bottom * 0.5, opening.along),
				colour = colour,
				material = material,
				parent = parent,
			})
		end
		cursor = openingEnd
	end
	if cursor < length * 0.5 then
		local runLength = length * 0.5 - cursor
		BuildKit.part({
			name = "Wall",
			size = Vector3.new(thickness, height, runLength),
			cf = cf * CFrame.new(0, height * 0.5, cursor + runLength * 0.5),
			colour = colour,
			material = material,
			parent = parent,
		})
	end
end

local function pitchedRoof(cf: CFrame, width: number, length: number, rise: number, colour: Color3, parent: Instance)
	for _, side in { -1, 1 } do
		BuildKit.wedge({
			name = "RoofPitch",
			size = Vector3.new(width * 0.5 + 0.6, rise, length + 1.2),
			cf = cf * CFrame.new(side * width * 0.25, rise * 0.5, 0) * CFrame.Angles(0, math.rad(if side > 0 then 0 else 180), 0),
			colour = colour,
			material = Enum.Material.Slate,
			parent = parent,
		})
	end
	-- Ridge and barge boards.
	BuildKit.detail({
		name = "Ridge",
		size = Vector3.new(1.0, 0.5, length + 1.6),
		cf = cf * CFrame.new(0, rise, 0),
		colour = C(58, 54, 50),
		material = Enum.Material.Slate,
		parent = parent,
	})
end

--- Standard interior treatment: lined walls, floor, ceiling and a practical light.
local function fitInterior(
	cf: CFrame,
	size: Vector3,
	wallColour: Color3,
	floorColour: Color3,
	lampColour: Color3,
	parent: Instance,
	lights: { Light },
	rng: Random
)
	BuildKit.part({
		name = "InteriorFloor",
		size = Vector3.new(size.X - 1.2, 0.4, size.Z - 1.2),
		cf = cf * CFrame.new(0, 0.2, 0),
		colour = floorColour,
		material = Enum.Material.WoodPlanks,
		parent = parent,
	})
	BuildKit.part({
		name = "Ceiling",
		size = Vector3.new(size.X - 1.0, 0.4, size.Z - 1.0),
		cf = cf * CFrame.new(0, size.Y - 0.2, 0),
		colour = wallColour,
		material = Enum.Material.Plaster,
		parent = parent,
	})
	-- Skirting, which is a cheap detail that reads strongly indoors.
	for _, side in { -1, 1 } do
		BuildKit.detail({
			name = "Skirting",
			size = Vector3.new(0.2, 0.8, size.Z - 1.2),
			cf = cf * CFrame.new(side * (size.X * 0.5 - 0.7), 0.8, 0),
			colour = C(70, 58, 46),
			material = Enum.Material.Wood,
			parent = parent,
		})
	end

	local count = math.max(1, math.floor(size.Z / 18))
	for i = 0, count - 1 do
		local z = -size.Z * 0.3 + i * (size.Z * 0.6 / math.max(1, count - 1))
		local _, light = BuildKit.lamp(
			cf * CFrame.new(0, size.Y - 1.6, if count == 1 then 0 else z),
			if rng:NextNumber() < 0.5 then "pendant" else "bulkhead",
			lampColour,
			0.9,
			34,
			parent
		)
		light.Enabled = false -- stations start dark until powered
		table.insert(lights, light)
	end
end

--------------------------------------------------------------------------
-- Building kinds
--------------------------------------------------------------------------

type BuildContext = {
	parent: Instance,
	lights: { Light },
	doors: { Model },
	rng: Random,
}

local function buildPlatform(cf: CFrame, size: Vector3, ctx: BuildContext)
	BuildKit.part({
		name = "PlatformDeck",
		size = Vector3.new(size.X, size.Y, size.Z),
		cf = cf * CFrame.new(0, size.Y * 0.5, 0),
		colour = P.weatheredConcrete,
		material = Enum.Material.Concrete,
		parent = ctx.parent,
	})
	-- Platform edge with the white safety line.
	for _, side in { -1, 1 } do
		BuildKit.detail({
			name = "PlatformEdge",
			size = Vector3.new(1.0, size.Y + 0.1, size.Z),
			cf = cf * CFrame.new(side * (size.X * 0.5 - 0.5), size.Y * 0.5, 0),
			colour = C(58, 56, 52),
			material = Enum.Material.Concrete,
			parent = ctx.parent,
		})
		BuildKit.detail({
			name = "SafetyLine",
			size = Vector3.new(0.8, 0.08, size.Z),
			cf = cf * CFrame.new(side * (size.X * 0.5 - 1.8), size.Y + 0.02, 0),
			colour = C(198, 194, 182),
			material = Enum.Material.Concrete,
			parent = ctx.parent,
		})
	end
	-- Lamp posts down the platform, unlit until the station has power.
	local posts = math.max(2, math.floor(size.Z / 40))
	for i = 0, posts - 1 do
		local z = -size.Z * 0.5 + 20 + i * ((size.Z - 40) / math.max(1, posts - 1))
		local postCF = cf * CFrame.new(0, size.Y, z)
		BuildKit.detail({
			name = "LampPost",
			size = Vector3.new(0.6, 14, 0.6),
			cf = postCF * CFrame.new(0, 7, 0),
			colour = C(52, 56, 54),
			material = Enum.Material.Metal,
			parent = ctx.parent,
		})
		local _, light = BuildKit.lamp(postCF * CFrame.new(0, 13.4, 0), "flood", C(214, 226, 255), 2.2, 46, ctx.parent)
		light.Enabled = false
		table.insert(ctx.lights, light)
	end
end

local function buildEnclosure(
	cf: CFrame,
	size: Vector3,
	spec: StationRegistry.BuildingSpec,
	wallColour: Color3,
	wallMaterial: Enum.Material,
	roofKind: string,
	ctx: BuildContext
)
	local halfX, halfZ = size.X * 0.5, size.Z * 0.5
	local storeys = spec.storey or 1
	local storeyHeight = size.Y / storeys

	-- Long walls with window openings; short walls with doors.
	for _, side in { -1, 1 } do
		local openings = {}
		local windowCount = math.max(2, math.floor(size.Z / 12))
		for i = 0, windowCount - 1 do
			local along = -halfZ + (size.Z / (windowCount + 1)) * (i + 1)
			table.insert(openings, { along = along, bottom = 4.0, width = 5.0, height = 4.5 })
		end
		segmentedWall(
			cf * CFrame.new(side * halfX, 0, 0),
			size.Z,
			size.Y,
			0.8,
			wallColour,
			wallMaterial,
			openings,
			ctx.parent
		)
		for _, opening in openings do
			BuildKit.window(
				cf * CFrame.new(side * halfX, opening.bottom + opening.height * 0.5, opening.along),
				opening.width - 0.4,
				opening.height - 0.4,
				C(68, 62, 54),
				ctx.parent,
				ctx.rng:NextNumber() < 0.35
			)
		end
	end

	local entrancesLeft = spec.entrances
	for _, endSign in { -1, 1 } do
		local openings = {}
		if entrancesLeft > 0 then
			table.insert(openings, { along = 0, bottom = 0, width = 7.0, height = 9.0 })
			entrancesLeft -= 1
		end
		segmentedWall(
			cf * CFrame.new(0, 0, endSign * halfZ) * CFrame.Angles(0, math.rad(90), 0),
			size.X,
			size.Y,
			0.8,
			wallColour,
			wallMaterial,
			openings,
			ctx.parent
		)
		if #openings > 0 then
			local door = BuildKit.door(
				cf * CFrame.new(-3.2, 0, endSign * halfZ) * CFrame.Angles(0, math.rad(if endSign > 0 then 0 else 180), 0),
				6.4,
				8.8,
				0.35,
				C(78, 62, 46),
				Enum.Material.Wood,
				ctx.parent
			)
			table.insert(ctx.doors, door)
		end
	end

	-- Side entrances beyond the two ends.
	while entrancesLeft > 0 do
		local side = if entrancesLeft % 2 == 0 then 1 else -1
		local door = BuildKit.door(
			cf * CFrame.new(side * halfX, 0, halfZ * 0.4) * CFrame.Angles(0, math.rad(if side > 0 then 90 else -90), 0),
			6.0,
			8.6,
			0.35,
			C(78, 62, 46),
			Enum.Material.Wood,
			ctx.parent
		)
		table.insert(ctx.doors, door)
		entrancesLeft -= 1
	end

	-- Upper floors get a real deck and a stair.
	for floor = 1, storeys - 1 do
		BuildKit.part({
			name = "UpperFloor",
			size = Vector3.new(size.X - 1.6, 0.5, size.Z - 1.6),
			cf = cf * CFrame.new(0, storeyHeight * floor, 0),
			colour = C(84, 70, 54),
			material = Enum.Material.WoodPlanks,
			parent = ctx.parent,
		})
		-- Stair well opening, built by simply leaving the last bay clear.
		BuildKit.part({
			name = "StairFlight",
			size = Vector3.new(4.5, 0.5, storeyHeight * 1.8),
			cf = cf
				* CFrame.new(halfX - 4, storeyHeight * (floor - 0.5), halfZ - storeyHeight)
				* CFrame.Angles(math.rad(-34), 0, 0),
			colour = C(84, 70, 54),
			material = Enum.Material.WoodPlanks,
			parent = ctx.parent,
		})
		for step = 0, 9 do
			BuildKit.detail({
				name = "Tread",
				size = Vector3.new(4.4, 0.25, 1.1),
				cf = cf
					* CFrame.new(
						halfX - 4,
						storeyHeight * (floor - 1) + 1 + step * (storeyHeight / 10),
						halfZ - 2 - step * (storeyHeight * 1.5 / 10)
					),
				colour = C(96, 80, 62),
				material = Enum.Material.WoodPlanks,
				parent = ctx.parent,
			})
		end
	end

	-- Roof.
	if roofKind == "pitched" then
		pitchedRoof(cf * CFrame.new(0, size.Y, 0), size.X, size.Z, size.X * 0.28, C(64, 60, 56), ctx.parent)
	elseif roofKind == "corrugated" then
		BuildKit.corrugated(
			cf * CFrame.new(0, size.Y + 0.4, 0) * CFrame.Angles(0, 0, math.rad(90)),
			size.Z,
			size.X,
			C(96, 92, 84),
			ctx.parent
		)
	else
		BuildKit.part({
			name = "FlatRoof",
			size = Vector3.new(size.X + 1.2, 0.7, size.Z + 1.2),
			cf = cf * CFrame.new(0, size.Y + 0.35, 0),
			colour = C(62, 60, 58),
			material = Enum.Material.Concrete,
			parent = ctx.parent,
		})
		-- Parapet.
		for _, side in { -1, 1 } do
			BuildKit.detail({
				name = "Parapet",
				size = Vector3.new(0.6, 1.6, size.Z + 1.2),
				cf = cf * CFrame.new(side * (size.X * 0.5 + 0.3), size.Y + 1.2, 0),
				colour = C(70, 68, 64),
				material = Enum.Material.Concrete,
				parent = ctx.parent,
			})
		end
	end

	if spec.interior then
		fitInterior(cf, size, C(150, 142, 124), C(74, 62, 48), C(255, 232, 186), ctx.parent, ctx.lights, ctx.rng)
	end
end

local function buildWaterTower(cf: CFrame, size: Vector3, ctx: BuildContext)
	local legHeight = size.Y * 0.62
	for i = 0, 3 do
		local angle = math.rad(i * 90 + 45)
		BuildKit.part({
			name = "TowerLeg",
			size = Vector3.new(1.2, legHeight, 1.2),
			cf = cf * CFrame.Angles(0, angle, 0) * CFrame.new(0, legHeight * 0.5, size.X * 0.36),
			colour = C(74, 62, 52),
			material = Enum.Material.Metal,
			parent = ctx.parent,
		})
	end
	-- Cross bracing.
	for i = 0, 3 do
		local angle = math.rad(i * 90)
		BuildKit.detail({
			name = "Brace",
			size = Vector3.new(0.5, 0.5, size.X * 0.85),
			cf = cf * CFrame.Angles(0, angle, 0) * CFrame.new(0, legHeight * 0.55, 0) * CFrame.Angles(math.rad(24), 0, 0),
			colour = C(74, 62, 52),
			material = Enum.Material.Metal,
			parent = ctx.parent,
		})
	end
	local tank = BuildKit.cylinder({
		name = "Tank",
		size = Vector3.new(size.Y - legHeight, size.X, size.X),
		cf = cf * CFrame.new(0, legHeight + (size.Y - legHeight) * 0.5, 0) * CFrame.Angles(0, 0, math.rad(90)),
		colour = C(82, 70, 58),
		material = Enum.Material.CorrodedMetal,
		parent = ctx.parent,
	})
	BuildKit.rivetStrip(tank.CFrame * CFrame.new(0, size.X * 0.5, -size.X * 0.4), size.X * 0.8, 1.6, 0.16, C(58, 50, 44), ctx.parent)
	-- Filler spout.
	BuildKit.detail({
		name = "Spout",
		size = Vector3.new(1.4, 6.0, 1.4),
		cf = cf * CFrame.new(size.X * 0.5, legHeight + 2, 0) * CFrame.Angles(0, 0, math.rad(28)),
		colour = C(68, 58, 50),
		material = Enum.Material.Metal,
		parent = ctx.parent,
	})
	BuildKit.ladder(cf * CFrame.new(size.X * 0.4, 0, size.X * 0.4), legHeight + 4, 2.2, C(70, 66, 60), ctx.parent)
end

local function buildSignalTower(cf: CFrame, size: Vector3, spec: StationRegistry.BuildingSpec, ctx: BuildContext)
	local baseHeight = size.Y * 0.62
	-- Brick base with a door.
	segmentedWall(
		cf * CFrame.new(0, 0, size.Z * 0.5) * CFrame.Angles(0, math.rad(90), 0),
		size.X,
		baseHeight,
		0.9,
		C(112, 74, 62),
		Enum.Material.Brick,
		{ { along = 0, bottom = 0, width = 6.0, height = 8.5 } },
		ctx.parent
	)
	for _, side in { -1, 1 } do
		segmentedWall(
			cf * CFrame.new(side * size.X * 0.5, 0, 0),
			size.Z,
			baseHeight,
			0.9,
			C(112, 74, 62),
			Enum.Material.Brick,
			{},
			ctx.parent
		)
	end
	segmentedWall(
		cf * CFrame.new(0, 0, -size.Z * 0.5) * CFrame.Angles(0, math.rad(90), 0),
		size.X,
		baseHeight,
		0.9,
		C(112, 74, 62),
		Enum.Material.Brick,
		{},
		ctx.parent
	)
	local door = BuildKit.door(
		cf * CFrame.new(-3.0, 0, size.Z * 0.5),
		6.0,
		8.4,
		0.35,
		C(72, 58, 44),
		Enum.Material.Wood,
		ctx.parent
	)
	table.insert(ctx.doors, door)

	-- Operating floor: a glazed box on top, which is the whole point of a
	-- signal box. It has to be legible from the ground and lit from inside.
	BuildKit.part({
		name = "OperatingFloor",
		size = Vector3.new(size.X + 2, 0.6, size.Z + 2),
		cf = cf * CFrame.new(0, baseHeight, 0),
		colour = C(88, 72, 56),
		material = Enum.Material.WoodPlanks,
		parent = ctx.parent,
	})
	local upper = size.Y - baseHeight
	for _, side in { -1, 1 } do
		-- Fully glazed long sides: a low panel and a tall window band.
		BuildKit.part({
			name = "GlazingPanel",
			size = Vector3.new(0.5, 3.0, size.Z + 2),
			cf = cf * CFrame.new(side * (size.X * 0.5 + 1), baseHeight + 1.5, 0),
			colour = C(78, 62, 46),
			material = Enum.Material.Wood,
			parent = ctx.parent,
		})
		local panes = 4
		for i = 0, panes - 1 do
			BuildKit.window(
				cf * CFrame.new(side * (size.X * 0.5 + 1), baseHeight + 3 + (upper - 4) * 0.5, -size.Z * 0.5 + (size.Z + 2) / panes * (i + 0.5) - 1),
				(size.Z + 2) / panes - 0.6,
				upper - 4.5,
				C(78, 62, 46),
				ctx.parent
			)
		end
		BuildKit.part({
			name = "GlazingHeader",
			size = Vector3.new(0.5, 1.2, size.Z + 2),
			cf = cf * CFrame.new(side * (size.X * 0.5 + 1), size.Y - 0.6, 0),
			colour = C(78, 62, 46),
			material = Enum.Material.Wood,
			parent = ctx.parent,
		})
	end
	for _, endSign in { -1, 1 } do
		segmentedWall(
			cf * CFrame.new(0, baseHeight, endSign * (size.Z * 0.5 + 1)) * CFrame.Angles(0, math.rad(90), 0),
			size.X + 2,
			upper,
			0.5,
			C(78, 62, 46),
			Enum.Material.Wood,
			{},
			ctx.parent
		)
	end
	pitchedRoof(cf * CFrame.new(0, size.Y, 0), size.X + 3, size.Z + 3, 4, C(58, 54, 50), ctx.parent)

	-- External stair up to the operating floor, which is how signal boxes work.
	for step = 0, 13 do
		BuildKit.part({
			name = "Tread",
			size = Vector3.new(4.0, 0.3, 1.4),
			cf = cf * CFrame.new(size.X * 0.5 + 4, 1 + step * (baseHeight / 14), size.Z * 0.5 - step * 1.5),
			colour = C(88, 76, 62),
			material = Enum.Material.WoodPlanks,
			parent = ctx.parent,
		})
	end
	BuildKit.handrail(
		cf * CFrame.new(size.X * 0.5 + 6, baseHeight * 0.5, size.Z * 0.5 - 9) * CFrame.Angles(math.rad(-40), 0, 0),
		22,
		3.2,
		C(70, 66, 60),
		ctx.parent
	)

	if spec.interior then
		-- Operating floor interior: the interlocking frame is a fixture, but
		-- the room around it is built here.
		BuildKit.part({
			name = "DiagramBoard",
			size = Vector3.new(0.4, 5.0, 14.0),
			cf = cf * CFrame.new(-size.X * 0.5 - 0.4, baseHeight + upper * 0.62, 0),
			colour = C(46, 52, 48),
			material = Enum.Material.SmoothPlastic,
			parent = ctx.parent,
		})
		BuildKit.detail({
			name = "DiagramLine",
			size = Vector3.new(0.1, 0.3, 12.0),
			cf = cf * CFrame.new(-size.X * 0.5 - 0.62, baseHeight + upper * 0.62, 0),
			colour = C(214, 208, 190),
			material = Enum.Material.Neon,
			parent = ctx.parent,
		})
		local _, light = BuildKit.lamp(
			cf * CFrame.new(0, size.Y - 1.6, 0),
			"pendant",
			C(255, 226, 172),
			1.0,
			30,
			ctx.parent
		)
		light.Enabled = false
		table.insert(ctx.lights, light)
	end
end

local function buildLiftBridge(cf: CFrame, size: Vector3, ctx: BuildContext)
	-- Two piers, an approach span, and a raised lifting span.
	for _, side in { -1, 1 } do
		BuildKit.part({
			name = "Pier",
			size = Vector3.new(size.X * 0.5, size.Y * 0.5, 18),
			cf = cf * CFrame.new(0, size.Y * 0.25 - 20, side * size.Z * 0.3),
			colour = P.weatheredConcrete,
			material = Enum.Material.Concrete,
			parent = ctx.parent,
		})
		-- Lifting tower.
		for _, x in { -1, 1 } do
			BuildKit.part({
				name = "TowerLeg",
				size = Vector3.new(3.0, size.Y, 3.0),
				cf = cf * CFrame.new(x * size.X * 0.45, size.Y * 0.5 - 12, side * size.Z * 0.3),
				colour = C(72, 76, 80),
				material = Enum.Material.Metal,
				parent = ctx.parent,
			})
		end
		BuildKit.part({
			name = "TowerHead",
			size = Vector3.new(size.X, 4.0, 5.0),
			cf = cf * CFrame.new(0, size.Y - 12, side * size.Z * 0.3),
			colour = C(66, 70, 74),
			material = Enum.Material.Metal,
			parent = ctx.parent,
		})
		-- Counterweight, hanging where it should be for a raised span.
		BuildKit.part({
			name = "Counterweight",
			size = Vector3.new(size.X * 0.7, 8, 8),
			cf = cf * CFrame.new(0, size.Y - 26, side * size.Z * 0.3),
			colour = C(58, 58, 60),
			material = Enum.Material.Concrete,
			parent = ctx.parent,
		})
		for _, x in { -1, 1 } do
			BuildKit.detail({
				name = "Cable",
				size = Vector3.new(0.4, 16, 0.4),
				cf = cf * CFrame.new(x * size.X * 0.35, size.Y - 20, side * size.Z * 0.3),
				colour = C(48, 48, 50),
				material = Enum.Material.Metal,
				parent = ctx.parent,
			})
		end
	end

	-- Fixed approach spans at deck level.
	for _, side in { -1, 1 } do
		BuildKit.part({
			name = "ApproachSpan",
			size = Vector3.new(size.X * 0.8, 2.5, size.Z * 0.26),
			cf = cf * CFrame.new(0, -18, side * (size.Z * 0.42)),
			colour = C(80, 84, 88),
			material = Enum.Material.Metal,
			parent = ctx.parent,
		})
		-- Truss sides.
		for _, x in { -1, 1 } do
			for i = 0, 7 do
				BuildKit.detail({
					name = "TrussMember",
					size = Vector3.new(0.7, 9, 0.7),
					cf = cf
						* CFrame.new(x * size.X * 0.4, -13.5, side * (size.Z * 0.42) - size.Z * 0.12 + i * (size.Z * 0.033))
						* CFrame.Angles(math.rad(if i % 2 == 0 then 34 else -34), 0, 0),
					colour = C(74, 78, 82),
					material = Enum.Material.Metal,
					parent = ctx.parent,
				})
			end
		end
	end

	-- The raised lifting span itself, sitting up between the towers.
	local span = BuildKit.part({
		name = "LiftSpan",
		size = Vector3.new(size.X * 0.8, 2.5, size.Z * 0.3),
		cf = cf * CFrame.new(0, size.Y - 34, 0),
		colour = C(86, 90, 94),
		material = Enum.Material.Metal,
		parent = ctx.parent,
	})
	span:AddTag("LiftSpan")
	span.Name = "LiftSpan"
	for _, x in { -1, 1 } do
		BuildKit.detail({
			name = "SpanTruss",
			size = Vector3.new(0.8, 7, size.Z * 0.3),
			cf = cf * CFrame.new(x * size.X * 0.4, size.Y - 30.5, 0),
			colour = C(80, 84, 88),
			material = Enum.Material.Metal,
			parent = ctx.parent,
		})
	end
	-- Warning lights on the raised span, which is the visual that reads from
	-- the approach and tells the crew what the problem is before the radio does.
	for _, x in { -1, 1 } do
		local lamp = BuildKit.detail({
			name = "SpanWarning",
			size = Vector3.new(1.0, 1.0, 1.0),
			cf = cf * CFrame.new(x * size.X * 0.42, size.Y - 27, 0),
			colour = C(220, 70, 50),
			material = Enum.Material.Neon,
			parent = ctx.parent,
		})
		local light = Instance.new("PointLight")
		light.Color = C(220, 70, 50)
		light.Brightness = 2.5
		light.Range = 60
		light.Parent = lamp
		table.insert(ctx.lights, light)
	end
end

local function buildMast(cf: CFrame, size: Vector3, ctx: BuildContext)
	local height = size.Y
	-- Lattice mast: four legs plus bracing, tapering with height.
	local segments = 10
	for seg = 0, segments - 1 do
		local t = seg / segments
		local radius = size.X * 0.5 * (1 - t * 0.62)
		local y = height * t
		local segHeight = height / segments
		for i = 0, 3 do
			local angle = math.rad(i * 90 + 45)
			BuildKit.detail({
				name = "MastLeg",
				size = Vector3.new(1.0, segHeight * 1.05, 1.0),
				cf = cf * CFrame.Angles(0, angle, 0) * CFrame.new(0, y + segHeight * 0.5, radius),
				colour = C(96, 84, 70),
				material = Enum.Material.Metal,
				parent = ctx.parent,
			})
			BuildKit.detail({
				name = "MastBrace",
				size = Vector3.new(0.5, 0.5, radius * 1.5),
				cf = cf * CFrame.Angles(0, angle + math.rad(45), 0) * CFrame.new(0, y + segHeight * 0.5, 0) * CFrame.Angles(math.rad(30), 0, 0),
				colour = C(92, 80, 66),
				material = Enum.Material.Metal,
				parent = ctx.parent,
			})
		end
		-- Aviation warning lamp every few segments.
		if seg % 3 == 2 then
			local lamp = BuildKit.detail({
				name = "MastLamp",
				size = Vector3.new(1.2, 1.2, 1.2),
				cf = cf * CFrame.new(0, y, 0),
				colour = C(220, 70, 50),
				material = Enum.Material.Neon,
				parent = ctx.parent,
			})
			local light = Instance.new("PointLight")
			light.Color = C(220, 70, 50)
			light.Brightness = 2
			light.Range = 50
			light.Parent = lamp
			table.insert(ctx.lights, light)
		end
	end
	-- Dishes and yagis near the top.
	for i = 0, 2 do
		BuildKit.cylinder({
			name = "Dish",
			size = Vector3.new(1.2, 9 - i * 2, 9 - i * 2),
			cf = cf * CFrame.new(0, height * (0.62 + i * 0.1), 0) * CFrame.Angles(0, math.rad(i * 60), math.rad(90)),
			colour = C(180, 176, 168),
			material = Enum.Material.Metal,
			canCollide = false,
			parent = ctx.parent,
		})
	end
	BuildKit.ladder(cf * CFrame.new(size.X * 0.32, 0, 0), height * 0.7, 2.4, C(88, 82, 74), ctx.parent)
	-- Guy wires anchoring the mast, which is what sells its scale.
	for i = 0, 2 do
		local angle = math.rad(i * 120)
		BuildKit.detail({
			name = "GuyWire",
			size = Vector3.new(0.3, height * 0.9, 0.3),
			cf = cf * CFrame.Angles(0, angle, 0) * CFrame.new(0, height * 0.42, height * 0.3) * CFrame.Angles(math.rad(36), 0, 0),
			colour = C(60, 60, 62),
			material = Enum.Material.Metal,
			parent = ctx.parent,
		})
	end
end

--------------------------------------------------------------------------
-- Fixtures
--------------------------------------------------------------------------

local function buildFixture(spec: StationRegistry.FixtureSpec, cf: CFrame, ctx: BuildContext): BasePart
	local kind = spec.kind
	local anchor: BasePart

	if kind == "generator" then
		anchor = BuildKit.part({
			name = "Generator",
			size = Vector3.new(5.5, 4.5, 9.0),
			cf = cf * CFrame.new(0, 2.25, 0),
			colour = C(96, 100, 88),
			material = Enum.Material.Metal,
			parent = ctx.parent,
		})
		BuildKit.detail({
			name = "GenRadiator",
			size = Vector3.new(5.2, 3.6, 0.8),
			cf = anchor.CFrame * CFrame.new(0, 0.2, -4.4),
			colour = C(72, 76, 68),
			material = Enum.Material.Metal,
			parent = ctx.parent,
		})
		BuildKit.grille(anchor.CFrame * CFrame.new(0, 0.2, -4.8) * CFrame.Angles(0, math.rad(90), 0), 4.6, 3.2, 0.5, C(50, 52, 48), ctx.parent)
		BuildKit.cylinder({
			name = "GenExhaust",
			size = Vector3.new(4.0, 1.1, 1.1),
			cf = anchor.CFrame * CFrame.new(1.8, 3.0, 2.0) * CFrame.Angles(0, 0, math.rad(90)),
			colour = C(46, 42, 40),
			material = Enum.Material.CorrodedMetal,
			canCollide = false,
			parent = ctx.parent,
		})
		BuildKit.detail({
			name = "GenControlPanel",
			size = Vector3.new(0.5, 2.0, 2.4),
			cf = anchor.CFrame * CFrame.new(2.9, 0.8, 1.0),
			colour = C(56, 58, 60),
			material = Enum.Material.Metal,
			parent = ctx.parent,
		})
		BuildKit.detail({
			name = "GenPullCord",
			size = Vector3.new(0.16, 1.6, 0.16),
			cf = anchor.CFrame * CFrame.new(2.9, 0.2, 2.6),
			colour = C(150, 130, 90),
			material = Enum.Material.Fabric,
			parent = ctx.parent,
		})
	elseif kind == "fusebox" then
		anchor = BuildKit.part({
			name = "Fusebox",
			size = Vector3.new(0.9, 4.0, 3.0),
			cf = cf * CFrame.new(0, 6.0, 0),
			colour = C(62, 66, 60),
			material = Enum.Material.Metal,
			parent = ctx.parent,
		})
		for i = 0, 5 do
			BuildKit.detail({
				name = "FuseWay",
				size = Vector3.new(0.4, 0.55, 0.55),
				cf = anchor.CFrame * CFrame.new(-0.6, 1.3 - math.floor(i / 3) * 1.0, -0.8 + (i % 3) * 0.8),
				colour = if i == 4 then C(90, 60, 50) else C(196, 186, 158),
				material = Enum.Material.Concrete,
				parent = ctx.parent,
			})
		end
	elseif kind == "breaker" then
		anchor = BuildKit.part({
			name = "Breaker",
			size = Vector3.new(1.1, 5.5, 3.6),
			cf = cf * CFrame.new(0, 5.5, 0),
			colour = C(54, 58, 56),
			material = Enum.Material.Metal,
			parent = ctx.parent,
		})
		BuildKit.detail({
			name = "BreakerHandle",
			size = Vector3.new(1.4, 1.8, 0.5),
			cf = anchor.CFrame * CFrame.new(-0.9, -1.2, 0),
			colour = C(178, 48, 42),
			material = Enum.Material.SmoothPlastic,
			parent = ctx.parent,
		})
		BuildKit.detail({
			name = "BreakerLamp",
			size = Vector3.new(0.3, 0.5, 0.5),
			cf = anchor.CFrame * CFrame.new(-0.62, 1.8, 0),
			colour = C(120, 40, 36),
			material = Enum.Material.Neon,
			parent = ctx.parent,
		})
	elseif kind == "lever" then
		anchor = BuildKit.part({
			name = "GroundLever",
			size = Vector3.new(2.6, 1.4, 3.6),
			cf = cf * CFrame.new(0, 0.7, 0),
			colour = C(64, 62, 58),
			material = Enum.Material.Metal,
			parent = ctx.parent,
		})
		BuildKit.detail({
			name = "LeverArm",
			size = Vector3.new(0.4, 5.0, 0.4),
			cf = anchor.CFrame * CFrame.new(0, 2.6, 0.6) * CFrame.Angles(math.rad(22), 0, 0),
			colour = C(150, 60, 52),
			material = Enum.Material.Metal,
			parent = ctx.parent,
		})
		BuildKit.detail({
			name = "LeverGrip",
			size = Vector3.new(0.7, 1.2, 0.7),
			cf = anchor.CFrame * CFrame.new(0, 5.0, 1.4),
			colour = C(40, 40, 42),
			material = Enum.Material.SmoothPlastic,
			parent = ctx.parent,
		})
		-- Position plate, so a player can see which way it is set.
		BuildKit.detail({
			name = "LeverPlate",
			size = Vector3.new(0.2, 1.4, 3.0),
			cf = anchor.CFrame * CFrame.new(1.4, 1.2, 0),
			colour = C(196, 186, 158),
			material = Enum.Material.SmoothPlastic,
			parent = ctx.parent,
		})
	elseif kind == "controls" then
		anchor = BuildKit.part({
			name = "ControlPanel",
			size = Vector3.new(1.2, 4.4, 4.0),
			cf = cf * CFrame.new(0, 3.6, 0),
			colour = C(58, 62, 60),
			material = Enum.Material.Metal,
			parent = ctx.parent,
		})
		BuildKit.detail({
			name = "PanelFace",
			size = Vector3.new(0.3, 3.0, 3.4),
			cf = anchor.CFrame * CFrame.new(-0.7, 0.2, 0) * CFrame.Angles(0, 0, math.rad(12)),
			colour = C(76, 80, 78),
			material = Enum.Material.Metal,
			parent = ctx.parent,
		})
		for i = 0, 2 do
			BuildKit.detail({
				name = "PanelLamp",
				size = Vector3.new(0.3, 0.45, 0.45),
				cf = anchor.CFrame * CFrame.new(-0.9, 1.0, -1.0 + i * 1.0),
				colour = C(90, 80, 50),
				material = Enum.Material.Neon,
				parent = ctx.parent,
			})
		end
		BuildKit.detail({
			name = "PanelLegs",
			size = Vector3.new(1.0, 3.2, 0.6),
			cf = anchor.CFrame * CFrame.new(0, -3.6, 0),
			colour = C(50, 52, 50),
			material = Enum.Material.Metal,
			parent = ctx.parent,
		})
	elseif kind == "fuel_point" then
		anchor = BuildKit.part({
			name = "FuelPoint",
			size = Vector3.new(3.0, 7.0, 3.0),
			cf = cf * CFrame.new(0, 3.5, 0),
			colour = C(118, 92, 56),
			material = Enum.Material.CorrodedMetal,
			parent = ctx.parent,
		})
		BuildKit.detail({
			name = "PumpHead",
			size = Vector3.new(3.2, 2.0, 3.2),
			cf = anchor.CFrame * CFrame.new(0, 4.0, 0),
			colour = C(96, 76, 48),
			material = Enum.Material.Metal,
			parent = ctx.parent,
		})
		BuildKit.pipeRun(
			anchor.CFrame,
			{ Vector3.new(0, 3.5, 1.4), Vector3.new(0, 2.0, 3.5), Vector3.new(0, -2.0, 4.5) },
			0.5,
			C(60, 58, 56),
			ctx.parent
		)
		BuildKit.detail({
			name = "Nozzle",
			size = Vector3.new(0.7, 1.6, 0.7),
			cf = anchor.CFrame * CFrame.new(0, -2.4, 4.6),
			colour = C(140, 60, 50),
			material = Enum.Material.Metal,
			parent = ctx.parent,
		})
	elseif kind == "interlocking_frame" then
		anchor = BuildKit.part({
			name = "InterlockingFrame",
			size = Vector3.new(3.0, 2.0, 16.0),
			cf = cf * CFrame.new(0, 1.0, 0),
			colour = C(72, 70, 66),
			material = Enum.Material.Metal,
			parent = ctx.parent,
		})
		-- A bank of tall painted levers, which is what a frame actually is.
		for i = 0, 11 do
			local colour = if i % 3 == 0 then C(160, 52, 46) elseif i % 3 == 1 then C(52, 100, 60) else C(60, 70, 120)
			BuildKit.detail({
				name = "FrameLever",
				size = Vector3.new(0.4, 6.5, 0.4),
				cf = anchor.CFrame * CFrame.new(0, 3.4, -7.0 + i * 1.3) * CFrame.Angles(math.rad(if i % 2 == 0 then 16 else -8), 0, 0),
				colour = colour,
				material = Enum.Material.Metal,
				parent = ctx.parent,
			})
			BuildKit.detail({
				name = "FrameLeverNumber",
				size = Vector3.new(0.5, 0.6, 0.6),
				cf = anchor.CFrame * CFrame.new(0, 1.4, -7.0 + i * 1.3),
				colour = C(206, 200, 182),
				material = Enum.Material.SmoothPlastic,
				parent = ctx.parent,
			})
		end
	elseif kind == "relay_bay" then
		anchor = BuildKit.part({
			name = "RelayBay",
			size = Vector3.new(2.0, 7.0, 6.0),
			cf = cf * CFrame.new(0, 3.5, 0),
			colour = C(66, 70, 74),
			material = Enum.Material.Metal,
			parent = ctx.parent,
		})
		for row = 0, 3 do
			for col = 0, 2 do
				BuildKit.detail({
					name = "RelayUnit",
					size = Vector3.new(0.6, 1.2, 1.5),
					cf = anchor.CFrame * CFrame.new(-1.0, 2.4 - row * 1.5, -1.8 + col * 1.8),
					colour = if row == 2 and col == 1 then C(120, 50, 44) else C(84, 88, 92),
					material = Enum.Material.Metal,
					parent = ctx.parent,
				})
			end
		end
	elseif kind == "stores_cage" then
		anchor = BuildKit.part({
			name = "StoresCage",
			size = Vector3.new(6.0, 8.0, 8.0),
			cf = cf * CFrame.new(0, 4.0, 0),
			colour = C(74, 78, 76),
			material = Enum.Material.Metal,
			transparency = 0.75,
			parent = ctx.parent,
		})
		BuildKit.grille(cf * CFrame.new(-3.0, 4.0, 0) * CFrame.Angles(0, math.rad(90), 0), 7.6, 7.6, 0.9, C(74, 78, 76), ctx.parent)
		BuildKit.grille(cf * CFrame.new(3.0, 4.0, 0) * CFrame.Angles(0, math.rad(90), 0), 7.6, 7.6, 0.9, C(74, 78, 76), ctx.parent)
	elseif kind == "hydraulics" then
		anchor = BuildKit.part({
			name = "HydraulicHead",
			size = Vector3.new(5.0, 6.0, 5.0),
			cf = cf * CFrame.new(0, 3.0, 0),
			colour = C(84, 72, 52),
			material = Enum.Material.Metal,
			parent = ctx.parent,
		})
		BuildKit.pipeRun(
			anchor.CFrame,
			{ Vector3.new(-2.5, 1.5, 0), Vector3.new(-5, 1.5, 0), Vector3.new(-5, -2.5, 0) },
			0.8,
			C(120, 90, 60),
			ctx.parent
		)
		BuildKit.detail({
			name = "ValveSeat",
			size = Vector3.new(1.6, 1.6, 1.6),
			cf = anchor.CFrame * CFrame.new(0, 2.2, -2.6),
			colour = C(60, 56, 50),
			material = Enum.Material.Metal,
			parent = ctx.parent,
		})
		BuildKit.detail({
			name = "PressureGauge",
			size = Vector3.new(1.4, 1.4, 0.4),
			cf = anchor.CFrame * CFrame.new(1.6, 2.0, -2.5),
			colour = C(206, 200, 182),
			material = Enum.Material.SmoothPlastic,
			parent = ctx.parent,
		})
	elseif kind == "transmitter" then
		anchor = BuildKit.part({
			name = "Transmitter",
			size = Vector3.new(4.0, 9.0, 7.0),
			cf = cf * CFrame.new(0, 4.5, 0),
			colour = C(60, 64, 62),
			material = Enum.Material.Metal,
			parent = ctx.parent,
		})
		for i = 0, 3 do
			BuildKit.detail({
				name = "ValveHolder",
				size = Vector3.new(0.8, 1.8, 0.8),
				cf = anchor.CFrame * CFrame.new(-1.8, 2.5 - i * 1.6, -2.0),
				colour = if i == 1 then C(90, 60, 52) else C(196, 186, 160),
				material = if i == 1 then Enum.Material.Metal else Enum.Material.Glass,
				transparency = if i == 1 then 0 else 0.35,
				parent = ctx.parent,
			})
		end
		BuildKit.detail({
			name = "MeterBank",
			size = Vector3.new(0.4, 3.0, 5.0),
			cf = anchor.CFrame * CFrame.new(-2.1, -2.0, 0),
			colour = C(48, 50, 48),
			material = Enum.Material.Metal,
			parent = ctx.parent,
		})
	else
		anchor = BuildKit.part({
			name = spec.kind,
			size = Vector3.new(3, 3, 3),
			cf = cf * CFrame.new(0, 1.5, 0),
			colour = C(90, 90, 92),
			material = Enum.Material.Metal,
			parent = ctx.parent,
		})
	end

	anchor.Name = spec.id
	anchor:AddTag("StationFixture")
	anchor:SetAttribute("FixtureKind", spec.kind)
	if spec.objective then
		anchor:SetAttribute("Objective", spec.objective)
	end
	if spec.step then
		anchor:SetAttribute("Step", spec.step)
	end
	return anchor
end

--------------------------------------------------------------------------
-- Loot containers
--------------------------------------------------------------------------

local function buildLootNode(node: StationRegistry.LootNode, cf: CFrame, ctx: BuildContext): BasePart
	local anchor: BasePart
	local kind = node.kind

	if kind == "locker" then
		anchor = BuildKit.part({
			name = "Locker",
			size = Vector3.new(3.0, 8.0, 4.5),
			cf = cf * CFrame.new(0, 4.0, 0),
			colour = C(76, 90, 84),
			material = Enum.Material.Metal,
			parent = ctx.parent,
		})
		for i = 0, 1 do
			BuildKit.detail({
				name = "LockerDoor",
				size = Vector3.new(0.3, 7.6, 2.1),
				cf = anchor.CFrame * CFrame.new(-1.6, 0, -1.1 + i * 2.2),
				colour = C(82, 96, 90),
				material = Enum.Material.Metal,
				parent = ctx.parent,
			})
			BuildKit.detail({
				name = "LockerHandle",
				size = Vector3.new(0.3, 1.0, 0.2),
				cf = anchor.CFrame * CFrame.new(-1.85, 0, -0.2 + i * 2.2),
				colour = C(150, 150, 152),
				material = Enum.Material.Metal,
				parent = ctx.parent,
			})
			BuildKit.grille(anchor.CFrame * CFrame.new(-1.8, 3.0, -1.1 + i * 2.2) * CFrame.Angles(0, math.rad(90), 0), 1.6, 0.9, 0.22, C(60, 70, 66), ctx.parent)
		end
	elseif kind == "crate" then
		anchor = BuildKit.part({
			name = "Crate",
			size = Vector3.new(4.4, 3.6, 4.4),
			cf = cf * CFrame.new(0, 1.8, 0),
			colour = C(112, 92, 64),
			material = Enum.Material.WoodPlanks,
			parent = ctx.parent,
		})
		for _, side in { -1, 1 } do
			BuildKit.detail({
				name = "CrateBatten",
				size = Vector3.new(4.6, 0.3, 0.35),
				cf = anchor.CFrame * CFrame.new(0, side * 1.3, 2.25),
				colour = C(88, 70, 48),
				material = Enum.Material.Wood,
				parent = ctx.parent,
			})
		end
		BuildKit.detail({
			name = "CrateLid",
			size = Vector3.new(4.6, 0.35, 4.6),
			cf = anchor.CFrame * CFrame.new(0, 1.9, 0),
			colour = C(100, 82, 56),
			material = Enum.Material.WoodPlanks,
			parent = ctx.parent,
		})
	elseif kind == "shelf" then
		anchor = BuildKit.part({
			name = "Shelving",
			size = Vector3.new(2.4, 8.0, 9.0),
			cf = cf * CFrame.new(0, 4.0, 0),
			colour = C(84, 80, 72),
			material = Enum.Material.Metal,
			transparency = 1,
			canCollide = false,
			parent = ctx.parent,
		})
		for i = 0, 3 do
			BuildKit.part({
				name = "Shelf",
				size = Vector3.new(2.4, 0.25, 9.0),
				cf = anchor.CFrame * CFrame.new(0, -3.2 + i * 2.1, 0),
				colour = C(88, 84, 76),
				material = Enum.Material.Metal,
				parent = ctx.parent,
			})
		end
		for _, side in { -1, 1 } do
			for _, zSide in { -1, 1 } do
				BuildKit.detail({
					name = "ShelfUpright",
					size = Vector3.new(0.3, 8.0, 0.3),
					cf = anchor.CFrame * CFrame.new(side * 1.0, 0, zSide * 4.3),
					colour = C(74, 70, 64),
					material = Enum.Material.Metal,
					parent = ctx.parent,
				})
			end
		end
	elseif kind == "cabinet" then
		anchor = BuildKit.part({
			name = "Cabinet",
			size = Vector3.new(2.6, 5.0, 5.0),
			cf = cf * CFrame.new(0, 2.5, 0),
			colour = C(96, 76, 54),
			material = Enum.Material.Wood,
			parent = ctx.parent,
		})
		for i = 0, 2 do
			BuildKit.detail({
				name = "Drawer",
				size = Vector3.new(0.3, 1.3, 4.5),
				cf = anchor.CFrame * CFrame.new(-1.4, 1.5 - i * 1.6, 0),
				colour = C(108, 86, 60),
				material = Enum.Material.Wood,
				parent = ctx.parent,
			})
			BuildKit.detail({
				name = "DrawerPull",
				size = Vector3.new(0.25, 0.25, 1.2),
				cf = anchor.CFrame * CFrame.new(-1.6, 1.5 - i * 1.6, 0),
				colour = C(160, 140, 96),
				material = Enum.Material.Metal,
				parent = ctx.parent,
			})
		end
	elseif kind == "toolboard" then
		anchor = BuildKit.part({
			name = "ToolBoard",
			size = Vector3.new(0.5, 6.0, 9.0),
			cf = cf * CFrame.new(0, 6.0, 0),
			colour = C(92, 74, 54),
			material = Enum.Material.Wood,
			parent = ctx.parent,
		})
		-- Painted tool silhouettes, the detail that makes a tool board readable.
		for i = 0, 4 do
			BuildKit.detail({
				name = "ToolShadow",
				size = Vector3.new(0.1, 2.6, 0.7),
				cf = anchor.CFrame * CFrame.new(-0.3, 0.4, -3.4 + i * 1.7) * CFrame.Angles(math.rad(ctx.rng:NextNumber(-8, 8)), 0, 0),
				colour = C(52, 42, 32),
				material = Enum.Material.SmoothPlastic,
				parent = ctx.parent,
			})
		end
	elseif kind == "body" then
		-- A body is a story object first and a container second. It is built as
		-- a slumped shape with a coat and a scattered kit, not as a gore prop.
		anchor = BuildKit.part({
			name = "Remains",
			size = Vector3.new(3.2, 1.6, 5.0),
			cf = cf * CFrame.new(0, 0.8, 0) * CFrame.Angles(0, 0, math.rad(8)),
			colour = C(58, 56, 50),
			material = Enum.Material.Fabric,
			parent = ctx.parent,
		})
		BuildKit.detail({
			name = "Coat",
			size = Vector3.new(3.6, 0.6, 4.0),
			cf = anchor.CFrame * CFrame.new(0, 0.9, 0.4),
			colour = C(48, 52, 46),
			material = Enum.Material.Fabric,
			parent = ctx.parent,
		})
		BuildKit.detail({
			name = "Satchel",
			size = Vector3.new(1.8, 1.2, 2.2),
			cf = anchor.CFrame * CFrame.new(1.4, 0.6, -1.6),
			colour = C(84, 68, 46),
			material = Enum.Material.Fabric,
			parent = ctx.parent,
		})
		BuildKit.detail({
			name = "FallenLamp",
			size = Vector3.new(0.8, 0.8, 1.4),
			cf = anchor.CFrame * CFrame.new(-1.8, 0.4, 1.8) * CFrame.Angles(0, math.rad(40), 0),
			colour = C(64, 66, 70),
			material = Enum.Material.SmoothPlastic,
			parent = ctx.parent,
		})
	else
		anchor = BuildKit.part({
			name = "Container",
			size = Vector3.new(3, 3, 3),
			cf = cf * CFrame.new(0, 1.5, 0),
			colour = C(100, 100, 100),
			material = Enum.Material.Metal,
			parent = ctx.parent,
		})
	end

	anchor:AddTag("LootNode")
	anchor:SetAttribute("LootKind", kind)
	anchor:SetAttribute("Tier", node.tier)
	anchor:SetAttribute("Rolls", node.rolls)
	anchor:SetAttribute("Searched", false)
	return anchor
end

--------------------------------------------------------------------------
-- Public
--------------------------------------------------------------------------

function StationBuilder.build(def: StationRegistry.StationDef, originCF: CFrame, parent: Instance, seed: number): BuiltStation
	local rng = Random.new(seed)
	local model = BuildKit.model("Station_" .. def.id, nil)
	local ctx: BuildContext = { parent = model, lights = {}, doors = {}, rng = rng }

	-- Ground pad so the clearing reads as compacted earth rather than grass.
	BuildKit.part({
		name = "Ground",
		size = Vector3.new(def.layout.radius * 2, 1.2, def.layout.radius * 2),
		cf = originCF * CFrame.new(0, -0.6, 0),
		colour = P.soil,
		material = Enum.Material.Ground,
		parent = model,
	})

	for _, spec in def.layout.buildings do
		local cf = originCF * CFrame.new(spec.position) * CFrame.Angles(0, math.rad(spec.rotation), 0)
		local kind = spec.kind

		if kind == "platform" then
			buildPlatform(cf, spec.size, ctx)
		elseif kind == "water_tower" then
			buildWaterTower(cf, spec.size, ctx)
		elseif kind == "signal_tower" then
			buildSignalTower(cf, spec.size, spec, ctx)
		elseif kind == "lift_bridge" then
			buildLiftBridge(cf, spec.size, ctx)
		elseif kind == "mast" then
			buildMast(cf, spec.size, ctx)
		elseif kind == "log_stack" then
			-- Stacked timber, which doubles as cover and as a climbable route.
			local logsPerRow = math.floor(spec.size.X / 3.2)
			local rows = math.floor(spec.size.Y / 3.0)
			for row = 0, rows - 1 do
				for i = 0, logsPerRow - 1 - row do
					local log = BuildKit.part({
						name = "Log",
						size = Vector3.new(spec.size.Z, 2.8, 2.8),
						cf = cf * CFrame.new(-spec.size.X * 0.5 + 1.6 + (i + row * 0.5) * 3.1, 1.5 + row * 2.7, 0),
						colour = BuildKit.weather(P.darkBark, 0.05, rng),
						material = Enum.Material.Wood,
						parent = model,
					})
					log.Shape = Enum.PartType.Cylinder
				end
			end
		elseif kind == "loader" then
			-- Tracked timber loader with a raised grab.
			BuildKit.part({
				name = "LoaderBody",
				size = spec.size * Vector3.new(1, 0.5, 0.6),
				cf = cf * CFrame.new(0, spec.size.Y * 0.35, 0),
				colour = C(150, 124, 44),
				material = Enum.Material.Metal,
				parent = model,
			})
			for _, side in { -1, 1 } do
				BuildKit.part({
					name = "Track",
					size = Vector3.new(3.4, 4.0, spec.size.Z),
					cf = cf * CFrame.new(side * (spec.size.X * 0.5 - 1.4), 2.0, 0),
					colour = C(46, 46, 48),
					material = Enum.Material.Metal,
					parent = model,
				})
			end
			BuildKit.part({
				name = "LoaderCab",
				size = Vector3.new(7, 7, 7),
				cf = cf * CFrame.new(0, spec.size.Y * 0.62, spec.size.Z * 0.28),
				colour = C(150, 124, 44),
				material = Enum.Material.Metal,
				parent = model,
			})
			BuildKit.window(cf * CFrame.new(-3.5, spec.size.Y * 0.62, spec.size.Z * 0.28) * CFrame.Angles(0, math.rad(90), 0), 5, 5, C(64, 58, 48), model)
			-- The boom and the grab, still holding a lift.
			BuildKit.detail({
				name = "Boom",
				size = Vector3.new(2.4, 2.4, 22),
				cf = cf * CFrame.new(0, spec.size.Y * 0.75, -6) * CFrame.Angles(math.rad(-22), 0, 0),
				colour = C(140, 114, 40),
				material = Enum.Material.Metal,
				parent = model,
			})
			BuildKit.detail({
				name = "Grab",
				size = Vector3.new(5, 4, 5),
				cf = cf * CFrame.new(0, spec.size.Y * 0.3, -16),
				colour = C(58, 58, 60),
				material = Enum.Material.Metal,
				parent = model,
			})
			for i = 0, 3 do
				local log = BuildKit.part({
					name = "HeldLog",
					size = Vector3.new(16, 2.4, 2.4),
					cf = cf * CFrame.new(-2 + i * 1.4, spec.size.Y * 0.18, -16) * CFrame.Angles(0, math.rad(90), 0),
					colour = BuildKit.weather(P.darkBark, 0.04, rng),
					material = Enum.Material.Wood,
					parent = model,
				})
				log.Shape = Enum.PartType.Cylinder
			end
		elseif kind == "signal_gantry" then
			for _, side in { -1, 1 } do
				BuildKit.part({
					name = "GantryLeg",
					size = Vector3.new(2.4, spec.size.Y, 2.4),
					cf = cf * CFrame.new(side * spec.size.X * 0.45, spec.size.Y * 0.5, 0),
					colour = C(78, 82, 86),
					material = Enum.Material.Metal,
					parent = model,
				})
			end
			BuildKit.part({
				name = "GantryBeam",
				size = Vector3.new(spec.size.X, 2.6, 3.0),
				cf = cf * CFrame.new(0, spec.size.Y, 0),
				colour = C(78, 82, 86),
				material = Enum.Material.Metal,
				parent = model,
			})
			BuildKit.part({
				name = "GantryWalkway",
				size = Vector3.new(spec.size.X, 0.3, 4.0),
				cf = cf * CFrame.new(0, spec.size.Y + 1.6, 1.6),
				colour = C(66, 66, 68),
				material = Enum.Material.DiamondPlate,
				parent = model,
			})
			BuildKit.handrail(cf * CFrame.new(0, spec.size.Y + 1.7, 3.4) * CFrame.Angles(0, math.rad(90), 0), spec.size.X, 3.4, C(70, 74, 78), model, true)
			-- Signal heads: three aspects, dark.
			for _, x in { -0.25, 0.25 } do
				for aspect = 0, 2 do
					local lampColour = if aspect == 0 then C(70, 30, 26) elseif aspect == 1 then C(70, 60, 26) else C(26, 60, 34)
					BuildKit.detail({
						name = "Aspect",
						size = Vector3.new(1.6, 1.6, 0.6),
						cf = cf * CFrame.new(x * spec.size.X, spec.size.Y - 2 - aspect * 2.0, -1.8),
						colour = lampColour,
						material = Enum.Material.SmoothPlastic,
						parent = model,
					})
				end
				BuildKit.detail({
					name = "SignalBack",
					size = Vector3.new(2.6, 7.5, 1.0),
					cf = cf * CFrame.new(x * spec.size.X, spec.size.Y - 4, -1.2),
					colour = C(40, 42, 44),
					material = Enum.Material.Metal,
					parent = model,
				})
			end
			BuildKit.ladder(cf * CFrame.new(-spec.size.X * 0.45 + 2, 0, 1.6), spec.size.Y, 2.2, C(74, 78, 82), model)
		elseif kind == "aerials" then
			for i = 0, 7 do
				local angle = math.rad(i * 45)
				BuildKit.detail({
					name = "AerialPole",
					size = Vector3.new(0.8, spec.size.Y, 0.8),
					cf = cf * CFrame.Angles(0, angle, 0) * CFrame.new(0, spec.size.Y * 0.5, spec.size.X * 0.35),
					colour = C(92, 88, 80),
					material = Enum.Material.Metal,
					parent = model,
				})
				for element = 0, 4 do
					BuildKit.detail({
						name = "AerialElement",
						size = Vector3.new(6 - element, 0.2, 0.2),
						cf = cf * CFrame.Angles(0, angle, 0) * CFrame.new(0, spec.size.Y * 0.6 + element * 1.6, spec.size.X * 0.35),
						colour = C(150, 146, 138),
						material = Enum.Material.Metal,
						parent = model,
					})
				end
			end
		elseif kind == "walkway" then
			BuildKit.part({
				name = "WalkwayDeck",
				size = spec.size,
				cf = cf * CFrame.new(0, spec.size.Y * 0.5, 0),
				colour = C(64, 66, 68),
				material = Enum.Material.DiamondPlate,
				parent = model,
			})
			for _, side in { -1, 1 } do
				BuildKit.handrail(cf * CFrame.new(side * spec.size.X * 0.5, spec.size.Y, 0), spec.size.Z, 3.2, C(74, 72, 68), model, true)
			end
		else
			-- Everything else is an enclosure, differing by material and roof.
			local wallColour, wallMaterial, roofKind
			if kind == "cabin" or kind == "hut" or kind == "shelter" then
				wallColour = BuildKit.weather(P.weatheredPlank, 0.04, rng)
				wallMaterial = Enum.Material.WoodPlanks
				roofKind = "pitched"
			elseif kind == "shed" or kind == "pump_house" then
				wallColour = C(102, 98, 90)
				wallMaterial = Enum.Material.CorrodedMetal
				roofKind = "corrugated"
			elseif kind == "depot" or kind == "facility" then
				wallColour = P.weatheredConcrete
				wallMaterial = Enum.Material.Concrete
				roofKind = "flat"
			else -- station_building
				wallColour = C(126, 86, 70)
				wallMaterial = Enum.Material.Brick
				roofKind = "pitched"
			end
			buildEnclosure(cf, spec.size, spec, wallColour, wallMaterial, roofKind, ctx)
		end
	end

	-- Platform nameboards. A station a crew arrives at in the dark has to
	-- announce itself, both so the place reads as finished and so the radio
	-- can refer to it by a name the player has actually seen written down.
	local nameboardSide = if def.platformSide == "right" then 1 else -1
	for _, along in { -70, 70 } do
		BuildKit.postSign(
			originCF * CFrame.new(nameboardSide * 26, 3, along) * CFrame.Angles(0, math.rad(nameboardSide * -90), 0),
			string.upper(def.name),
			model,
			{ width = 20, height = 4.6, subtitle = def.subtitle, plate = C(30, 42, 36) }
		)
	end

	-- Fixtures.
	local fixtures: { [string]: BasePart } = {}
	for _, spec in def.layout.fixtures do
		local cf = originCF * CFrame.new(spec.position) * CFrame.Angles(0, math.rad(spec.rotation), 0)
		fixtures[spec.id] = buildFixture(spec, cf, ctx)
	end

	-- Loot nodes.
	local lootNodes: { { part: BasePart, kind: string, tier: number, rolls: number, guaranteed: { string } } } = {}
	for _, node in def.layout.lootNodes do
		local cf = originCF * CFrame.new(node.position) * CFrame.Angles(0, math.rad(node.rotation), 0)
		local part = buildLootNode(node, cf, ctx)
		table.insert(lootNodes, {
			part = part,
			kind = node.kind,
			tier = node.tier,
			rolls = node.rolls,
			guaranteed = node.guaranteed or {},
		})
	end

	-- Discoveries: small, tagged markers at named positions.
	local discoveries: { { id: string, part: BasePart } } = {}
	for _, discovery in def.discoveries do
		local marker = BuildKit.part({
			name = "Discovery_" .. discovery.id,
			size = Vector3.new(4, 6, 4),
			cf = originCF * CFrame.new(discovery.position) * CFrame.new(0, 3, 0),
			transparency = 1,
			canCollide = false,
			canQuery = false,
			castShadow = false,
			parent = model,
		})
		marker:AddTag("Discovery")
		marker:SetAttribute("DiscoveryId", discovery.id)
		marker:SetAttribute("StationId", def.id)
		table.insert(discoveries, { id = discovery.id, part = marker :: BasePart })
	end

	local landmarks: { [string]: Vector3 } = {}
	for _, landmark in def.layout.landmarks do
		landmarks[landmark.id] = (originCF * CFrame.new(landmark.position)).Position
	end

	model:AddTag("Station")
	model:SetAttribute("StationId", def.id)
	model.Parent = parent

	return {
		model = model,
		stationId = def.id,
		origin = originCF,
		fixtures = fixtures,
		lootNodes = lootNodes,
		landmarks = landmarks,
		lights = ctx.lights,
		doors = ctx.doors,
		poweredLights = ctx.lights,
		discoveries = discoveries,
		partCount = BuildKit.countParts(model),
	}
end

return StationBuilder
