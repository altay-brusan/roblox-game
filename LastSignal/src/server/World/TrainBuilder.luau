--!strict
--[[
	TrainBuilder
	------------
	Builds a complete locomotive and consist from a TrainRegistry definition.

	STRUCTURE
	---------
	The whole train is one welded rigid assembly hanging off a single anchored
	root part. That choice is load-bearing:

	  - Moving a thousand anchored parts by CFrame every frame is expensive.
	    Moving one anchored root that a thousand parts are welded to is cheap,
	    because Roblox treats the welded set as a single assembly.
	  - It guarantees the train can never deform, stretch or come apart, which
	    is the usual failure mode of constraint-driven rolling stock.

	Passengers do not ride by friction. An anchored assembly imparts no velocity
	to what stands on it, so a player on a moving train would be left behind.
	Instead the client applies the train's per-frame delta CFrame to its own
	character while that character is inside the train volume. The client owns
	its character's physics, so this is smooth at any framerate and produces no
	jitter, no sliding and no falling through floors. See TrainRideController.

	GEOMETRY
	--------
	Exterior and interior are built against the same dimensions, from the same
	numbers, so a window on the outside is a window on the inside and a door
	always opens into a real space. Every carriage is walkable end to end and
	the gangways between them are real openings, not teleports.
]]

local BuildKit = require(script.Parent.BuildKit)
local TrainRegistry = require(game:GetService("ReplicatedStorage").LastSignal.Registry.TrainRegistry)

local C = Color3.fromRGB
local P = BuildKit.Palette

local TrainBuilder = {}

export type CabControls = {
	throttleLever: BasePart,
	brakeLever: BasePart,
	emergencyHandle: BasePart,
	reverser: BasePart,
	hornButton: BasePart,
	headlightSwitch: BasePart,
	cabinLightSwitch: BasePart,
	wiperSwitch: BasePart,
	doorSwitch: BasePart,
	radioDial: BasePart,
	speedNeedle: BasePart,
	fuelNeedle: BasePart,
	conditionNeedle: BasePart,
	driverSeat: Seat,
	wiperArms: { BasePart },
}

export type BuiltTrain = {
	model: Model,
	root: BasePart,
	trainId: string,
	-- Ordered, front to back.
	carriages: { Model },
	-- Everything a service needs to drive, light or interact with the train.
	cab: CabControls,
	headlights: { SpotLight },
	tailLights: { PointLight },
	cabinLights: { Light },
	interiorLights: { Light },
	wheels: { BasePart },
	doors: { { model: Model, hinge: BasePart, side: string, carriage: number } },
	fuelPoint: BasePart,
	repairPoint: BasePart,
	supplyRack: BasePart,
	radioSet: BasePart,
	-- Local-space box that defines "inside the train", used by the client ride
	-- controller and by the server for shelter checks.
	volumeSize: Vector3,
	volumeOffset: CFrame,
	partCount: number,
}

--------------------------------------------------------------------------
-- Articulation
--------------------------------------------------------------------------

-- Parts that move relative to the train (door hinges, gauge needles, wiper
-- arms) cannot be welded with a WeldConstraint and then moved by CFrame:
-- writing the CFrame of any part in a welded assembly moves the whole
-- assembly, anchored root included. That is what used to swing the entire
-- train off its track every time a door opened.
--
-- Instead each moving part gets its own Weld to the root, and is animated by
-- rewriting that Weld's C0, which moves only the part. Parts that ride on a
-- moving part (a door leaf on its hinge, a blade on its wiper arm) are welded
-- to that part rather than to the root.

-- Filled while a train is being built; consumed by the weld pass in build().
local followers: { [BasePart]: BasePart } = {}

--- Marks a part as articulated about a pivot. The pivot is where the part
--- rotates from, which for a needle is the dial centre rather than the
--- needle's own middle.
local function articulate(part: BasePart, pivot: CFrame)
	part:SetAttribute("ArticulationPivot", pivot:ToObjectSpace(part.CFrame))
	part:AddTag("Articulated")
end

--- Poses an articulated part. `offset` is applied in the pivot's frame, so
--- CFrame.Angles(0, a, 0) swings a door about its hinge.
function TrainBuilder.pose(part: BasePart, offset: CFrame)
	local joint = part:FindFirstChild("Articulation")
	if joint and joint:IsA("Weld") then
		local base = joint:GetAttribute("BaseC0")
		if typeof(base) == "CFrame" then
			joint.C0 = base * offset
		end
	end
end

--------------------------------------------------------------------------
-- Walls with openings
--------------------------------------------------------------------------

export type Opening = { z0: number, z1: number, y0: number, y1: number }

--- Builds a wall in the plane x = `x` (in originCF's frame) running from z0
--- to z1 and from y0 to y1, leaving every opening as a genuine gap. The wall
--- is cut into horizontal bands at each opening's top and bottom, and each
--- band into the spans no opening crosses, so a door is a hole a player can
--- walk through and a window is a hole they can see through.
local function openWall(
	originCF: CFrame,
	x: number,
	thickness: number,
	z0: number,
	z1: number,
	y0: number,
	y1: number,
	openings: { Opening },
	props: { name: string, colour: Color3, material: Enum.Material, detail: boolean? },
	parent: Instance
)
	local cuts = { y0, y1 }
	for _, opening in openings do
		table.insert(cuts, math.clamp(opening.y0, y0, y1))
		table.insert(cuts, math.clamp(opening.y1, y0, y1))
	end
	table.sort(cuts)
	for i = 1, #cuts - 1 do
		local bandBottom, bandTop = cuts[i], cuts[i + 1]
		if bandTop - bandBottom < 0.02 then
			continue
		end
		local middle = (bandBottom + bandTop) * 0.5
		local gaps: { { number } } = {}
		for _, opening in openings do
			if middle > opening.y0 and middle < opening.y1 then
				table.insert(gaps, { opening.z0, opening.z1 })
			end
		end
		table.sort(gaps, function(a, b)
			return a[1] < b[1]
		end)
		local cursor = z0
		local function piece(from: number, to: number)
			if to - from < 0.02 then
				return
			end
			local spec = {
				name = props.name,
				size = Vector3.new(thickness, bandTop - bandBottom, to - from),
				cf = originCF * CFrame.new(x, middle, (from + to) * 0.5),
				colour = props.colour,
				material = props.material,
				parent = parent,
			}
			if props.detail then
				BuildKit.detail(spec)
			else
				BuildKit.part(spec)
			end
		end
		for _, gap in gaps do
			piece(cursor, math.min(gap[1], z1))
			cursor = math.max(cursor, gap[2])
		end
		piece(cursor, z1)
	end
end

--------------------------------------------------------------------------
-- Bogies and running gear
--------------------------------------------------------------------------

local function buildWheel(cf: CFrame, radius: number, width: number, parent: Instance): BasePart
	-- Cylinder parts are oriented along X, so the wheel is rotated to stand up.
	local tyre = BuildKit.cylinder({
		name = "Wheel",
		size = Vector3.new(width, radius * 2, radius * 2),
		cf = cf * CFrame.Angles(0, 0, math.rad(90)) * CFrame.Angles(0, math.rad(90), 0),
		colour = C(58, 56, 54),
		material = Enum.Material.Metal,
		canCollide = false,
		castShadow = true,
		parent = parent,
	})
	-- Worn steel tread.
	BuildKit.cylinder({
		name = "Tread",
		size = Vector3.new(width * 0.55, radius * 2.02, radius * 2.02),
		cf = tyre.CFrame,
		colour = C(150, 148, 142),
		material = Enum.Material.Metal,
		reflectance = 0.18,
		canCollide = false,
		canQuery = false,
		castShadow = false,
		parent = parent,
	})
	-- Hub and spokes give the wheel a readable rotation.
	BuildKit.cylinder({
		name = "Hub",
		size = Vector3.new(width * 1.15, radius * 0.55, radius * 0.55),
		cf = tyre.CFrame,
		colour = C(72, 70, 66),
		material = Enum.Material.Metal,
		canCollide = false,
		canQuery = false,
		castShadow = false,
		parent = parent,
	})
	for i = 0, 5 do
		BuildKit.detail({
			name = "Spoke",
			size = Vector3.new(width * 0.4, radius * 1.5, 0.24),
			cf = tyre.CFrame * CFrame.Angles(math.rad(i * 30), 0, 0),
			colour = C(66, 64, 60),
			material = Enum.Material.Metal,
			parent = parent,
		})
	end
	tyre:AddTag("TrainWheel")
	return tyre
end

local function buildBogie(cf: CFrame, axles: number, wheelRadius: number, width: number, parent: Instance): { BasePart }
	local wheels: { BasePart } = {}
	local spacing = 6.2
	local frameLength = spacing * (axles - 1) + 7

	-- Bogie frame: two side frames and a transom.
	for _, side in { -1, 1 } do
		BuildKit.part({
			name = "BogieFrame",
			size = Vector3.new(0.8, 2.2, frameLength),
			cf = cf * CFrame.new(side * (width * 0.5 - 0.6), wheelRadius + 0.4, 0),
			colour = C(44, 44, 46),
			material = Enum.Material.Metal,
			canCollide = false,
			parent = parent,
		})
		-- Leaf spring stacks over each axle.
		for a = 0, axles - 1 do
			local z = -spacing * (axles - 1) * 0.5 + a * spacing
			for leaf = 0, 2 do
				BuildKit.detail({
					name = "Leaf",
					size = Vector3.new(0.5, 0.16, 2.6 - leaf * 0.5),
					cf = cf * CFrame.new(side * (width * 0.5 - 0.6), wheelRadius + 1.5 + leaf * 0.2, z),
					colour = C(52, 52, 54),
					material = Enum.Material.Metal,
					parent = parent,
				})
			end
			-- Axlebox.
			BuildKit.detail({
				name = "Axlebox",
				size = Vector3.new(1.1, 1.2, 1.4),
				cf = cf * CFrame.new(side * (width * 0.5 - 0.55), wheelRadius, z),
				colour = C(64, 60, 56),
				material = Enum.Material.Metal,
				parent = parent,
			})
			-- Brake shoe, sitting against the wheel face.
			BuildKit.detail({
				name = "BrakeShoe",
				size = Vector3.new(0.35, 1.6, 0.5),
				cf = cf * CFrame.new(side * (width * 0.5 - 1.5), wheelRadius, z + wheelRadius * 0.85),
				colour = C(88, 62, 48),
				material = Enum.Material.CorrodedMetal,
				parent = parent,
			})
		end
	end

	BuildKit.detail({
		name = "Transom",
		size = Vector3.new(width - 1.4, 1.0, 2.4),
		cf = cf * CFrame.new(0, wheelRadius + 0.8, 0),
		colour = C(46, 46, 48),
		material = Enum.Material.Metal,
		parent = parent,
	})

	-- Axles and wheels.
	for a = 0, axles - 1 do
		local z = -spacing * (axles - 1) * 0.5 + a * spacing
		BuildKit.detail({
			name = "Axle",
			size = Vector3.new(width - 1.2, 0.5, 0.5),
			cf = cf * CFrame.new(0, wheelRadius, z),
			colour = C(70, 68, 64),
			material = Enum.Material.Metal,
			parent = parent,
		})
		for _, side in { -1, 1 } do
			table.insert(wheels, buildWheel(cf * CFrame.new(side * (width * 0.5 + 0.15), wheelRadius, z), wheelRadius, 0.9, parent))
		end
	end

	return wheels
end

--------------------------------------------------------------------------
-- Couplers and buffer beams
--------------------------------------------------------------------------

local function buildCouplerEnd(cf: CFrame, width: number, colour: Color3, parent: Instance)
	-- Buffer beam.
	BuildKit.part({
		name = "BufferBeam",
		size = Vector3.new(width + 0.6, 2.0, 1.0),
		cf = cf,
		colour = C(112, 44, 40),
		material = Enum.Material.Metal,
		canCollide = false,
		parent = parent,
	})
	-- Buffers.
	for _, side in { -1, 1 } do
		BuildKit.cylinder({
			name = "BufferShank",
			size = Vector3.new(1.4, 1.0, 1.0),
			cf = cf * CFrame.new(side * width * 0.32, 0, -0.9) * CFrame.Angles(0, math.rad(90), 0),
			colour = C(60, 58, 56),
			material = Enum.Material.Metal,
			canCollide = false,
			canQuery = false,
			parent = parent,
		})
		BuildKit.cylinder({
			name = "BufferHead",
			size = Vector3.new(0.4, 1.9, 1.9),
			cf = cf * CFrame.new(side * width * 0.32, 0, -1.7) * CFrame.Angles(0, math.rad(90), 0),
			colour = C(46, 46, 48),
			material = Enum.Material.Metal,
			reflectance = 0.1,
			canCollide = false,
			canQuery = false,
			parent = parent,
		})
	end
	-- Drawhook and three-link chain.
	BuildKit.detail({
		name = "Drawhook",
		size = Vector3.new(0.5, 0.9, 1.2),
		cf = cf * CFrame.new(0, -0.2, -0.8),
		colour = C(54, 52, 50),
		material = Enum.Material.Metal,
		parent = parent,
	})
	for link = 1, 3 do
		BuildKit.detail({
			name = "Link",
			size = Vector3.new(0.12, 0.7, 0.45),
			cf = cf * CFrame.new(0, -0.7 - link * 0.35, -0.9) * CFrame.Angles(0, 0, math.rad(if link % 2 == 0 then 90 else 0)),
			colour = C(48, 46, 44),
			material = Enum.Material.Metal,
			parent = parent,
		})
	end
	-- Air and vacuum pipes with their cocks.
	for _, side in { -1, 1 } do
		BuildKit.pipeRun(
			cf,
			{ Vector3.new(side * width * 0.18, 0.6, 0.4), Vector3.new(side * width * 0.18, -0.4, -0.3), Vector3.new(side * width * 0.18, -0.9, -0.9) },
			0.28,
			C(58, 60, 58),
			parent
		)
		BuildKit.detail({
			name = "Cock",
			size = Vector3.new(0.45, 0.45, 0.3),
			cf = cf * CFrame.new(side * width * 0.18, 0.1, 0.0),
			colour = C(160, 62, 52),
			material = Enum.Material.Metal,
			parent = parent,
		})
	end
	-- Steps up to the footplate.
	for _, side in { -1, 1 } do
		for stepIndex = 0, 2 do
			BuildKit.part({
				name = "Step",
				size = Vector3.new(2.2, 0.22, 0.9),
				cf = cf * CFrame.new(side * (width * 0.5 - 1.0), -1.4 - stepIndex * 1.0, 0.6 + stepIndex * 0.35),
				colour = C(70, 70, 72),
				material = Enum.Material.DiamondPlate,
				parent = parent,
			})
		end
	end
end

--------------------------------------------------------------------------
-- Locomotive
--------------------------------------------------------------------------

-- Windscreen geometry, shared by the cab front and the glazing so the panes
-- always sit in the openings. Heights are above the body floor; the sill is
-- set below a seated driver's eye line so the line ahead is visible.
local WINDSCREEN_CENTRE = 6.5
local WINDSCREEN_WIDTH = 4.6
local WINDSCREEN_HEIGHT = 4.8

local function buildNose(
	cf: CFrame,
	style: string,
	width: number,
	height: number,
	livery: TrainRegistry.LiveryDef,
	parent: Instance
): (number, number)
	-- Returns the Z of the nose front face and the height for the headlamps,
	-- both relative to cf, so the lamps are mounted on the nose itself.
	--
	-- Every nose stays below the windscreen sill. The first versions of the
	-- blunt, raked and armoured noses were full-height blocks standing
	-- directly in front of the windscreen, so the driver saw a wall.
	local sill = WINDSCREEN_CENTRE - WINDSCREEN_HEIGHT * 0.5 - height * 0.5
	local lower = sill + height * 0.5 -- height of the nose from the body floor
	local function lowerCF(h: number, depth: number, z: number): CFrame
		return cf * CFrame.new(0, -height * 0.5 + h * 0.5, z - depth * 0.5)
	end

	if style == "raked" then
		-- Long sloping nose: a low block with a wedge rising to the sill.
		BuildKit.part({
			name = "NoseLower",
			size = Vector3.new(width, lower - 2.4, 7),
			cf = lowerCF(lower - 2.4, 7, 0),
			colour = livery.body,
			material = Enum.Material.Metal,
			parent = parent,
		})
		BuildKit.wedge({
			name = "Nose",
			size = Vector3.new(width, 2.4, 7),
			cf = cf * CFrame.new(0, sill - 1.2, -3.5) * CFrame.Angles(0, math.rad(180), 0),
			colour = livery.body,
			material = Enum.Material.Metal,
			parent = parent,
		})
		return -7.1, -height * 0.5 + (lower - 2.4) * 0.6
	elseif style == "bonnet" then
		-- A long low bonnet in front of a centre cab.
		BuildKit.part({
			name = "Bonnet",
			size = Vector3.new(width * 0.72, height * 0.62, 14),
			cf = cf * CFrame.new(0, -height * 0.16, -7),
			colour = livery.body,
			material = Enum.Material.Metal,
			parent = parent,
		})
		BuildKit.detail({
			name = "BonnetTop",
			size = Vector3.new(width * 0.74, 0.35, 14),
			cf = cf * CFrame.new(0, height * 0.16, -7),
			colour = livery.roof,
			material = Enum.Material.Metal,
			parent = parent,
		})
		for i = 0, 5 do
			BuildKit.vent(
				cf * CFrame.new(width * 0.36, -height * 0.16, -2.5 - i * 2.0) * CFrame.Angles(0, math.rad(90), 0),
				1.6,
				height * 0.4,
				livery.trim,
				parent
			)
		end
		return -14.1, -height * 0.25
	elseif style == "armoured" then
		BuildKit.part({
			name = "NoseArmour",
			size = Vector3.new(width + 0.4, lower, 5),
			cf = lowerCF(lower, 5, 0),
			colour = livery.body,
			material = Enum.Material.DiamondPlate,
			parent = parent,
		})
		-- Plough / obstacle deflector.
		BuildKit.wedge({
			name = "Plough",
			size = Vector3.new(width + 1.2, 3.2, 3.4),
			cf = cf * CFrame.new(0, -height * 0.5 + 0.4, -6.4) * CFrame.Angles(0, math.rad(180), 0),
			colour = C(58, 58, 60),
			material = Enum.Material.DiamondPlate,
			parent = parent,
		})
		for _, side in { -1, 1 } do
			BuildKit.detail({
				name = "ArmourRib",
				size = Vector3.new(0.4, height * 0.85, 5.6),
				cf = cf * CFrame.new(side * (width * 0.5 + 0.2), 0, -3),
				colour = livery.trim,
				material = Enum.Material.Metal,
				parent = parent,
			})
		end
		-- Armoured visor over the windscreen: slatted, so it can be seen past.
		for i = 0, 1 do
			BuildKit.detail({
				name = "VisorSlat",
				size = Vector3.new(width, 0.3, 1.6),
				cf = cf * CFrame.new(0, sill + WINDSCREEN_HEIGHT + 0.3 - i * 0.6, -0.9),
				colour = livery.trim,
				material = Enum.Material.Metal,
				parent = parent,
			})
		end
		return -5.1, -height * 0.5 + lower * 0.6
	else -- "blunt"
		-- A short lower nose projecting ahead of a flat cab front.
		BuildKit.part({
			name = "Nose",
			size = Vector3.new(width, lower - 1.2, 4),
			cf = lowerCF(lower - 1.2, 4, 0),
			colour = livery.body,
			material = Enum.Material.Metal,
			parent = parent,
		})
		-- Sloped top of the lower nose, rising to the windscreen sill.
		BuildKit.wedge({
			name = "NoseSlope",
			size = Vector3.new(width, 1.2, 4),
			cf = cf * CFrame.new(0, sill - 0.6, -2) * CFrame.Angles(0, math.rad(180), 0),
			colour = livery.body,
			material = Enum.Material.Metal,
			parent = parent,
		})
		return -4.1, -height * 0.5 + (lower - 1.2) * 0.55
	end
end

--- The flat cab front of a front-cab locomotive: a frame around the two
--- windscreen panes, so the glazing sits in a real opening.
local function buildCabFront(cf: CFrame, width: number, height: number, livery: TrainRegistry.LiveryDef, parent: Instance)
	local sill = WINDSCREEN_CENTRE - WINDSCREEN_HEIGHT * 0.5 - height * 0.5
	local head = WINDSCREEN_CENTRE + WINDSCREEN_HEIGHT * 0.5 - height * 0.5
	BuildKit.part({
		name = "CabFrontHeader",
		size = Vector3.new(width, height * 0.5 - head, 0.5),
		cf = cf * CFrame.new(0, (head + height * 0.5) * 0.5, 0.1),
		colour = livery.body,
		material = Enum.Material.Metal,
		parent = parent,
	})
	BuildKit.part({
		name = "CabFrontSill",
		size = Vector3.new(width, sill + height * 0.5, 0.5),
		cf = cf * CFrame.new(0, (sill - height * 0.5) * 0.5, 0.1),
		colour = livery.body,
		material = Enum.Material.Metal,
		parent = parent,
	})
	local paneOuter = width * 0.24 + WINDSCREEN_WIDTH * 0.5
	for _, side in { -1, 1 } do
		BuildKit.part({
			name = "CabFrontPost",
			size = Vector3.new(width * 0.5 - paneOuter, head - sill, 0.5),
			cf = cf * CFrame.new(side * (paneOuter + width * 0.5) * 0.5, (head + sill) * 0.5, 0.1),
			colour = livery.body,
			material = Enum.Material.Metal,
			parent = parent,
		})
	end
	BuildKit.detail({
		name = "NoseCrown",
		size = Vector3.new(width + 0.2, 0.5, 1.2),
		cf = cf * CFrame.new(0, height * 0.5 - 0.1, -0.3),
		colour = livery.roof,
		material = Enum.Material.Metal,
		parent = parent,
	})
end

local function buildCabInterior(
	cf: CFrame,
	width: number,
	height: number,
	livery: TrainRegistry.LiveryDef,
	interior: TrainRegistry.InteriorDef,
	parent: Instance
): CabControls
	local desk = C(58, 60, 62)

	-- Floor, ceiling and rear bulkhead.
	BuildKit.part({
		name = "CabFloor",
		size = Vector3.new(width - 0.8, 0.4, 11),
		cf = cf * CFrame.new(0, -height * 0.5 + 0.2, 0),
		colour = C(48, 48, 50),
		material = Enum.Material.DiamondPlate,
		parent = parent,
	})
	BuildKit.part({
		name = "CabCeiling",
		size = Vector3.new(width - 0.8, 0.35, 11),
		cf = cf * CFrame.new(0, height * 0.5 - 0.2, 0),
		colour = interior.wall,
		material = Enum.Material.Metal,
		parent = parent,
	})
	-- Rear bulkhead, with a doorway into the engine-room corridor so the crew
	-- can walk between the cab and the carriages.
	local corridorX0, corridorX1 = width * 0.5 - 0.6 - 3.4, width * 0.5 - 0.6
	local bulkheadHalf = width * 0.5 - 0.4
	local floorY = -height * 0.5 + 0.4
	local function bulkhead(x0: number, x1: number, y0: number, y1: number)
		BuildKit.part({
			name = "CabBulkhead",
			size = Vector3.new(x1 - x0, y1 - y0, 0.4),
			cf = cf * CFrame.new((x0 + x1) * 0.5, (y0 + y1) * 0.5, 5.3),
			colour = interior.wall,
			material = Enum.Material.Metal,
			parent = parent,
		})
	end
	bulkhead(-bulkheadHalf, corridorX0, -height * 0.5 + 0.4, height * 0.5 - 0.4)
	bulkhead(corridorX1, bulkheadHalf, -height * 0.5 + 0.4, height * 0.5 - 0.4)
	bulkhead(corridorX0, corridorX1, floorY + 7.4, height * 0.5 - 0.4)

	-- Driver's desk: a sloped console across the front of the cab.
	local deskTop = BuildKit.part({
		name = "DeskTop",
		size = Vector3.new(width - 2.2, 0.4, 2.6),
		cf = cf * CFrame.new(0, -height * 0.5 + 3.4, -3.6) * CFrame.Angles(math.rad(-18), 0, 0),
		colour = desk,
		material = Enum.Material.Metal,
		parent = parent,
	})
	BuildKit.part({
		name = "DeskFront",
		size = Vector3.new(width - 2.2, 3.0, 0.4),
		cf = cf * CFrame.new(0, -height * 0.5 + 1.9, -4.6),
		colour = desk,
		material = Enum.Material.Metal,
		parent = parent,
	})

	local function control(name: string, offset: CFrame, size: Vector3, colour: Color3, material: Enum.Material?): BasePart
		local p = BuildKit.part({
			name = name,
			size = size,
			cf = deskTop.CFrame * offset,
			colour = colour,
			material = material or Enum.Material.Metal,
			canCollide = false,
			parent = parent,
		})
		p:AddTag("CabControl")
		return p
	end

	-- Levers. Each has a visible pivot ball so its travel reads clearly.
	local throttle = control("ThrottleLever", CFrame.new(-2.6, 0.9, 0), Vector3.new(0.28, 1.8, 0.28), C(160, 130, 60))
	BuildKit.detail({
		name = "ThrottleKnob",
		size = Vector3.new(0.55, 0.55, 0.55),
		cf = throttle.CFrame * CFrame.new(0, 0.95, 0),
		colour = C(40, 40, 42),
		material = Enum.Material.SmoothPlastic,
		shape = Enum.PartType.Ball,
		parent = parent,
	})
	BuildKit.detail({
		name = "ThrottleQuadrant",
		size = Vector3.new(0.18, 1.4, 1.6),
		cf = throttle.CFrame * CFrame.new(-0.3, -0.4, 0),
		colour = C(72, 70, 68),
		material = Enum.Material.Metal,
		parent = parent,
	})

	local brake = control("BrakeLever", CFrame.new(-1.5, 0.8, 0), Vector3.new(0.26, 1.6, 0.26), C(140, 140, 145))
	BuildKit.detail({
		name = "BrakeKnob",
		size = Vector3.new(0.5, 0.5, 0.5),
		cf = brake.CFrame * CFrame.new(0, 0.85, 0),
		colour = C(40, 40, 42),
		material = Enum.Material.SmoothPlastic,
		shape = Enum.PartType.Ball,
		parent = parent,
	})

	local emergency = control("EmergencyHandle", CFrame.new(2.9, 0.7, 0), Vector3.new(0.3, 1.3, 0.3), C(178, 48, 42))
	BuildKit.detail({
		name = "EmergencyGuard",
		size = Vector3.new(1.1, 1.0, 1.1),
		cf = emergency.CFrame * CFrame.new(0, -0.5, 0),
		colour = C(196, 152, 58),
		material = Enum.Material.Metal,
		transparency = 0.45,
		parent = parent,
	})

	local reverser = control("Reverser", CFrame.new(-3.5, 0.55, 0.5), Vector3.new(0.9, 0.9, 0.35), C(90, 92, 96))
	local horn = control("HornButton", CFrame.new(0.4, 0.35, -0.6), Vector3.new(0.7, 0.35, 0.7), C(40, 40, 44), Enum.Material.SmoothPlastic)
	local headlightSwitch = control("HeadlightSwitch", CFrame.new(1.3, 0.3, -0.4), Vector3.new(0.35, 0.55, 0.35), C(196, 152, 58))
	local cabinLightSwitch = control("CabinLightSwitch", CFrame.new(1.8, 0.3, -0.4), Vector3.new(0.35, 0.55, 0.35), C(150, 152, 156))
	local wiperSwitch = control("WiperSwitch", CFrame.new(2.3, 0.3, -0.4), Vector3.new(0.35, 0.55, 0.35), C(110, 150, 170))
	local doorSwitch = control("DoorSwitch", CFrame.new(-0.6, 0.3, -0.6), Vector3.new(0.55, 0.35, 0.55), C(120, 170, 130), Enum.Material.SmoothPlastic)

	-- Gauges. Each is a dial face with a needle part the service rotates.
	local function gauge(offset: CFrame, label: string, faceColour: Color3): BasePart
		local face = BuildKit.detail({
			name = label .. "Face",
			size = Vector3.new(1.7, 0.2, 1.7),
			cf = deskTop.CFrame * offset,
			colour = faceColour,
			material = Enum.Material.SmoothPlastic,
			parent = parent,
		})
		BuildKit.detail({
			name = label .. "Bezel",
			size = Vector3.new(1.95, 0.28, 1.95),
			cf = face.CFrame * CFrame.new(0, -0.05, 0),
			colour = C(64, 62, 60),
			material = Enum.Material.Metal,
			parent = parent,
		})
		-- Tick marks around the dial.
		for i = 0, 10 do
			local angle = math.rad(-120 + i * 24)
			BuildKit.detail({
				name = "Tick",
				size = Vector3.new(0.08, 0.06, 0.3),
				cf = face.CFrame * CFrame.Angles(0, angle, 0) * CFrame.new(0, 0.12, -0.65),
				colour = C(30, 30, 32),
				material = Enum.Material.SmoothPlastic,
				parent = parent,
			})
		end
		local needle = BuildKit.detail({
			name = label .. "Needle",
			size = Vector3.new(0.09, 0.09, 0.72),
			cf = face.CFrame * CFrame.new(0, 0.16, -0.3),
			colour = C(190, 60, 50),
			material = Enum.Material.SmoothPlastic,
			parent = parent,
		})
		needle:AddTag("Gauge")
		-- Needles sweep about the dial centre.
		articulate(needle, face.CFrame)
		return needle
	end

	local speedNeedle = gauge(CFrame.new(-0.9, 0.22, -0.2), "Speed", C(214, 208, 190))
	local fuelNeedle = gauge(CFrame.new(1.0, 0.22, 0.6), "Fuel", C(206, 200, 182))
	local conditionNeedle = gauge(CFrame.new(2.4, 0.22, 0.6), "Condition", C(206, 200, 182))

	-- Radio set, mounted on the bulkhead behind the driver.
	local radio = BuildKit.part({
		name = "RadioSet",
		size = Vector3.new(2.4, 1.5, 1.0),
		cf = cf * CFrame.new(width * 0.28, -height * 0.5 + 4.2, 4.6),
		colour = C(58, 60, 56),
		material = Enum.Material.Metal,
		canCollide = false,
		parent = parent,
	})
	radio:AddTag("RadioSet")
	BuildKit.detail({
		name = "RadioDialFace",
		size = Vector3.new(1.2, 0.6, 0.2),
		cf = radio.CFrame * CFrame.new(0, 0.25, -0.55),
		colour = C(196, 186, 150),
		material = Enum.Material.Neon,
		parent = parent,
	})
	local radioDial = BuildKit.detail({
		name = "RadioDial",
		size = Vector3.new(0.45, 0.45, 0.3),
		cf = radio.CFrame * CFrame.new(-0.7, -0.35, -0.55),
		colour = C(40, 40, 42),
		material = Enum.Material.SmoothPlastic,
		parent = parent,
	})
	radioDial:AddTag("CabControl")
	BuildKit.grille(radio.CFrame * CFrame.new(0.5, -0.3, -0.52), 0.8, 0.7, 0.16, C(40, 40, 42), parent)

	-- Driver's seat. A real Seat so sitting is native and reliable.
	local seat = Instance.new("Seat")
	seat.Name = "DriverSeat"
	seat.Size = Vector3.new(2.2, 0.5, 2.2)
	seat.CFrame = cf * CFrame.new(-width * 0.22, -height * 0.5 + 2.4, -0.4)
	seat.Color = interior.seat
	seat.Material = interior.seatMaterial
	seat.Anchored = true
	seat.CanTouch = true
	seat.TopSurface = Enum.SurfaceType.Smooth
	seat.BottomSurface = Enum.SurfaceType.Smooth
	seat.Parent = parent
	seat:AddTag("DriverSeat")
	BuildKit.detail({
		name = "SeatBack",
		size = Vector3.new(2.2, 2.6, 0.4),
		cf = seat.CFrame * CFrame.new(0, 1.3, 1.1),
		colour = interior.seat,
		material = interior.seatMaterial,
		parent = parent,
	})
	BuildKit.detail({
		name = "SeatPedestal",
		size = Vector3.new(0.7, 2.2, 0.7),
		cf = seat.CFrame * CFrame.new(0, -1.2, 0),
		colour = C(52, 52, 54),
		material = Enum.Material.Metal,
		parent = parent,
	})

	-- Secondary seat for a second crew member.
	local mate = Instance.new("Seat")
	mate.Name = "SecondSeat"
	mate.Size = Vector3.new(2.0, 0.5, 2.0)
	mate.CFrame = cf * CFrame.new(width * 0.24, -height * 0.5 + 2.3, -0.4)
	mate.Color = interior.seat
	mate.Material = interior.seatMaterial
	mate.Anchored = true
	mate.Parent = parent

	-- Wiper arms on the inside of the windscreen.
	local wipers: { BasePart } = {}
	for _, side in { -1, 1 } do
		local pivot = cf * CFrame.new(side * width * 0.22, -height * 0.5 + 6.3, -5.2)
		BuildKit.detail({
			name = "WiperPivot",
			size = Vector3.new(0.35, 0.35, 0.3),
			cf = pivot,
			colour = C(40, 40, 42),
			material = Enum.Material.Metal,
			parent = parent,
		})
		local arm = BuildKit.detail({
			name = "WiperArm",
			size = Vector3.new(0.16, 3.4, 0.16),
			cf = pivot * CFrame.new(0, 1.7, -0.15),
			colour = C(36, 36, 38),
			material = Enum.Material.Metal,
			parent = parent,
		})
		local blade = BuildKit.detail({
			name = "WiperBlade",
			size = Vector3.new(0.12, 3.0, 0.1),
			cf = arm.CFrame * CFrame.new(0, 0.1, -0.14),
			colour = C(28, 28, 30),
			material = Enum.Material.SmoothPlastic,
			parent = parent,
		})
		arm:AddTag("WiperArm")
		-- The arm sweeps about its spindle; the blade rides on the arm.
		articulate(arm, pivot)
		followers[blade] = arm
		table.insert(wipers, arm)
	end

	return {
		throttleLever = throttle,
		brakeLever = brake,
		emergencyHandle = emergency,
		reverser = reverser,
		hornButton = horn,
		headlightSwitch = headlightSwitch,
		cabinLightSwitch = cabinLightSwitch,
		wiperSwitch = wiperSwitch,
		doorSwitch = doorSwitch,
		radioDial = radioDial,
		speedNeedle = speedNeedle,
		fuelNeedle = fuelNeedle,
		conditionNeedle = conditionNeedle,
		driverSeat = seat,
		wiperArms = wipers,
	}
end

local function buildLocomotive(
	originCF: CFrame,
	def: TrainRegistry.TrainDef,
	livery: TrainRegistry.LiveryDef,
	interior: TrainRegistry.InteriorDef,
	parent: Instance,
	rng: Random
): {
	wheels: { BasePart },
	cab: CabControls,
	headlights: { SpotLight },
	cabinLights: { Light },
	fuelPoint: BasePart,
	repairPoint: BasePart,
	radioSet: BasePart,
	doors: { { model: Model, hinge: BasePart, side: string, carriage: number } },
}
	local build = def.build
	local width = build.locoWidth
	local height = build.locoHeight
	local length = build.locoLength
	local model = BuildKit.model("Locomotive", parent)

	local wheels: { BasePart } = {}
	local doors: { { model: Model, hinge: BasePart, side: string, carriage: number } } = {}

	--------------------------------------------------------------
	-- Underframe and running gear
	--------------------------------------------------------------
	BuildKit.part({
		name = "Underframe",
		size = Vector3.new(width - 0.6, 1.6, length - 3),
		cf = originCF * CFrame.new(0, 2.2, 0),
		colour = livery.underframe,
		material = Enum.Material.Metal,
		canCollide = false,
		parent = model,
	})
	-- Solebar with rivets down each side.
	for _, side in { -1, 1 } do
		BuildKit.detail({
			name = "Solebar",
			size = Vector3.new(0.5, 1.9, length - 3),
			cf = originCF * CFrame.new(side * (width * 0.5 - 0.2), 2.2, 0),
			colour = livery.underframe,
			material = Enum.Material.Metal,
			parent = model,
		})
		BuildKit.rivetStrip(
			originCF * CFrame.new(side * (width * 0.5 + 0.05), 2.2, (length - 6) * 0.5),
			length - 6,
			2.2,
			0.1,
			C(58, 58, 58),
			model
		)
	end

	local bogieSpacing = length * 0.29
	for _, offset in { -bogieSpacing, bogieSpacing } do
		for _, w in buildBogie(originCF * CFrame.new(0, 0, offset), build.axlesPerBogie, build.wheelRadius, width - 2.2, model) do
			table.insert(wheels, w)
		end
	end

	-- Fuel and air tanks slung under the frame.
	BuildKit.cylinder({
		name = "FuelTank",
		size = Vector3.new(width - 4, 3.4, 3.4),
		cf = originCF * CFrame.new(0, 1.6, 0) * CFrame.Angles(0, math.rad(90), 0),
		colour = C(52, 54, 56),
		material = Enum.Material.Metal,
		canCollide = false,
		parent = model,
	})
	for _, side in { -1, 1 } do
		BuildKit.cylinder({
			name = "AirTank",
			size = Vector3.new(5, 1.5, 1.5),
			cf = originCF * CFrame.new(side * (width * 0.5 - 2.2), 1.4, length * 0.18) * CFrame.Angles(0, math.rad(90), 0),
			colour = C(62, 64, 66),
			material = Enum.Material.Metal,
			canCollide = false,
			canQuery = false,
			parent = model,
		})
	end

	--------------------------------------------------------------
	-- Body sides
	--------------------------------------------------------------
	local bodyBottom = 3.0
	local bodyTop = bodyBottom + height
	local bodyCentreY = (bodyBottom + bodyTop) * 0.5

	-- The cab occupies one end (or the centre); the engine bay the rest.
	local cabLength = 11
	local cabZ = if build.cabPosition == "front" then -(length * 0.5 - cabLength * 0.5 - 1) else 0

	-- The cab door opening and the cab side window, in body-local Z and in
	-- height above the body floor. Both sides use the same opening; the far
	-- side door is hinged at the other end of it so it still opens into the
	-- cab rather than into the engine room.
	local cabDoorZ0 = cabZ + 0.1
	local cabDoorZ1 = cabZ + 3.5
	local cabDoorTop = 7.4
	local sideWindowZ = cabZ - 2.6
	local sideWindowHeight = 3.2

	for _, side in { -1, 1 } do
		openWall(originCF, side * (width * 0.5 - 0.3), 0.6, -length * 0.5 + 2, length * 0.5 - 2, bodyBottom, bodyTop, {
			{ z0 = cabDoorZ0, z1 = cabDoorZ1, y0 = bodyBottom - 1, y1 = bodyBottom + cabDoorTop },
			{
				z0 = sideWindowZ - 2,
				z1 = sideWindowZ + 2,
				y0 = bodyBottom + WINDSCREEN_CENTRE - sideWindowHeight * 0.5,
				y1 = bodyBottom + WINDSCREEN_CENTRE + sideWindowHeight * 0.5,
			},
		}, { name = "BodySide", colour = livery.body, material = Enum.Material.Metal }, model)
		-- Waist stripe, if the livery has one.
		if livery.stripe then
			BuildKit.detail({
				name = "Stripe",
				size = Vector3.new(0.12, 0.9, length - 4),
				cf = originCF * CFrame.new(side * (width * 0.5 + 0.05), bodyCentreY + height * 0.12, 0),
				colour = livery.stripe,
				material = Enum.Material.Metal,
				parent = model,
			})
		end
		-- Hazard chevrons for liveries that use them.
		if livery.pattern == "chevron" then
			for i = 0, 5 do
				BuildKit.detail({
					name = "Chevron",
					size = Vector3.new(0.1, height * 0.3, 1.6),
					cf = originCF
						* CFrame.new(side * (width * 0.5 + 0.06), bodyBottom + height * 0.22, -length * 0.4 + i * 2.6)
						* CFrame.Angles(math.rad(28), 0, 0),
					colour = livery.trim,
					material = Enum.Material.Metal,
					parent = model,
				})
			end
		end

		-- Engine bay louvres and radiator grille.
		local bayStart = if build.cabPosition == "front" then -length * 0.5 + cabLength + 3 else -length * 0.5 + 4
		for i = 0, math.max(2, build.detailLevel) do
			local z = bayStart + i * 4.2
			if math.abs(z - cabZ) > cabLength * 0.6 and math.abs(z) < length * 0.5 - 4 then
				BuildKit.vent(
					originCF * CFrame.new(side * (width * 0.5 + 0.1), bodyCentreY + 1.0, z) * CFrame.Angles(0, math.rad(90), 0),
					3.0,
					height * 0.34,
					livery.trim,
					model
				)
			end
		end
		BuildKit.grille(
			originCF * CFrame.new(side * (width * 0.5 + 0.12), bodyCentreY - height * 0.2, length * 0.3) * CFrame.Angles(0, math.rad(90), 0),
			4.0,
			height * 0.3,
			0.5,
			C(46, 46, 48),
			model
		)

		-- Rust streaking, so painted steel does not read as plastic.
		BuildKit.rustStreaks(
			originCF * CFrame.new(side * (width * 0.5 + 0.07), bodyCentreY, 0),
			length - 6,
			height,
			build.detailLevel * 3,
			rng,
			model
		)

		-- Full-length handrail and grab irons.
		BuildKit.handrail(
			originCF * CFrame.new(side * (width * 0.5 + 0.45), bodyBottom - 0.2, 0),
			length - 8,
			1.1,
			livery.trim,
			model
		)

		-- Cab side door, in a real opening.
		local hingeZ = if side > 0 then cabDoorZ1 - 0.1 else cabDoorZ0 + 0.1
		local doorCF = originCF * CFrame.new(side * (width * 0.5 - 0.35), bodyBottom + 0.2, hingeZ)
		local door = BuildKit.door(doorCF * CFrame.Angles(0, math.rad(if side > 0 then 0 else 180), 0), 3.2, 7.0, 0.35, livery.body, Enum.Material.Metal, model)
		door.Name = "CabDoor"
		table.insert(doors, { model = door, hinge = door.PrimaryPart :: BasePart, side = if side > 0 then "right" else "left", carriage = 0 })
		-- Steps up to the cab door from the ballast.
		for stepIndex = 0, 1 do
			BuildKit.part({
				name = "CabStep",
				size = Vector3.new(1.8, 0.22, 3.0),
				cf = originCF * CFrame.new(side * (width * 0.5 + 0.55), bodyBottom - 1.1 - stepIndex * 1.1, (cabDoorZ0 + cabDoorZ1) * 0.5),
				colour = C(68, 68, 70),
				material = Enum.Material.DiamondPlate,
				parent = model,
			})
		end
		-- Cab side window ahead of the door, at the driver's eye line. The
		-- window builder glazes its local Y-Z plane, which is already the
		-- plane of the body side.
		BuildKit.window(
			originCF * CFrame.new(side * (width * 0.5 + 0.02), bodyBottom + WINDSCREEN_CENTRE, sideWindowZ),
			4.0,
			sideWindowHeight,
			livery.trim,
			model
		)
	end

	--------------------------------------------------------------
	-- Roof
	--------------------------------------------------------------
	BuildKit.part({
		name = "Roof",
		size = Vector3.new(width, 0.7, length - 4),
		cf = originCF * CFrame.new(0, bodyTop, 0),
		colour = livery.roof,
		material = Enum.Material.Metal,
		parent = model,
	})
	-- Slight roof camber, built from two shallow wedges.
	for _, side in { -1, 1 } do
		BuildKit.wedge({
			name = "RoofCamber",
			size = Vector3.new(width * 0.5, 0.6, length - 4),
			cf = originCF * CFrame.new(side * width * 0.25, bodyTop + 0.6, 0) * CFrame.Angles(0, math.rad(if side > 0 then 0 else 180), 0),
			colour = livery.roof,
			material = Enum.Material.Metal,
			canCollide = false,
			parent = model,
		})
	end

	-- Exhaust stacks with soot staining.
	for i = 1, build.exhaustStacks do
		local z = length * 0.1 + (i - 1) * 5
		BuildKit.cylinder({
			name = "ExhaustStack",
			size = Vector3.new(2.2, 2.6, 2.6),
			cf = originCF * CFrame.new(0, bodyTop + 1.6, z) * CFrame.Angles(0, 0, math.rad(90)),
			colour = C(44, 42, 40),
			material = Enum.Material.CorrodedMetal,
			canCollide = false,
			parent = model,
		})
		BuildKit.detail({
			name = "StackSoot",
			size = Vector3.new(3.0, 0.15, 3.0),
			cf = originCF * CFrame.new(0, bodyTop + 0.45, z),
			colour = C(28, 26, 24),
			material = Enum.Material.Slate,
			transparency = 0.3,
			parent = model,
		})
	end

	-- Radiator fan grilles on the roof.
	for i = 0, math.max(1, build.detailLevel - 2) do
		local z = -length * 0.06 - i * 5.5
		if math.abs(z - cabZ) > cabLength * 0.7 then
			BuildKit.cylinder({
				name = "FanRing",
				size = Vector3.new(0.5, 4.4, 4.4),
				cf = originCF * CFrame.new(0, bodyTop + 0.6, z),
				colour = C(52, 52, 54),
				material = Enum.Material.Metal,
				canCollide = false,
				canQuery = false,
				parent = model,
			})
			for blade = 0, 5 do
				BuildKit.detail({
					name = "FanBlade",
					size = Vector3.new(3.6, 0.14, 0.9),
					cf = originCF * CFrame.new(0, bodyTop + 0.62, z) * CFrame.Angles(0, math.rad(blade * 30), math.rad(18)),
					colour = C(64, 64, 66),
					material = Enum.Material.Metal,
					parent = model,
				})
			end
		end
	end

	-- Horn cluster on the cab roof.
	for i = 0, 1 do
		BuildKit.cylinder({
			name = "Horn",
			size = Vector3.new(2.2, 0.9, 0.9),
			cf = originCF * CFrame.new(-0.8 + i * 1.6, bodyTop + 1.0, cabZ - 3.0) * CFrame.Angles(0, math.rad(90), 0),
			colour = C(150, 120, 62),
			material = Enum.Material.Metal,
			canCollide = false,
			canQuery = false,
			parent = model,
		})
	end

	-- Roof walkway, so a player on the roof has somewhere to stand.
	BuildKit.part({
		name = "RoofWalkway",
		size = Vector3.new(3.2, 0.2, length - 10),
		cf = originCF * CFrame.new(0, bodyTop + 1.2, 0),
		colour = C(56, 56, 58),
		material = Enum.Material.DiamondPlate,
		parent = model,
	})

	--------------------------------------------------------------
	-- Nose, cab glazing and lights
	--------------------------------------------------------------
	local noseCF = originCF * CFrame.new(0, bodyCentreY, -length * 0.5 + 1)
	local noseFrontZ, lampY = buildNose(noseCF, build.nose, width, height, livery, model)
	if build.cabPosition == "front" then
		buildCabFront(noseCF, width, height, livery, model)
	end

	-- Windscreen: two panes with a centre pillar, in the plane of the cab
	-- front. BuildKit.window glazes its local Y-Z plane, so it is turned to
	-- face along the track; unturned, the panes stood edge-on to the driver.
	local screenZ = -length * 0.5 + 1.1
	for _, side in { -1, 1 } do
		BuildKit.window(
			originCF * CFrame.new(side * width * 0.24, bodyBottom + WINDSCREEN_CENTRE, screenZ) * CFrame.Angles(0, math.rad(90), 0),
			WINDSCREEN_WIDTH,
			WINDSCREEN_HEIGHT,
			livery.trim,
			model
		)
	end
	BuildKit.detail({
		name = "CentrePillar",
		size = Vector3.new(width * 0.48 - WINDSCREEN_WIDTH, WINDSCREEN_HEIGHT + 0.4, 0.5),
		cf = originCF * CFrame.new(0, bodyBottom + WINDSCREEN_CENTRE, screenZ),
		colour = livery.trim,
		material = Enum.Material.Metal,
		parent = model,
	})

	local headlights: { SpotLight } = {}
	for _, side in { -1, 1 } do
		local housing = BuildKit.detail({
			name = "HeadlampHousing",
			size = Vector3.new(2.0, 2.0, 1.2),
			cf = noseCF * CFrame.new(side * width * 0.3, lampY, noseFrontZ + 0.5),
			colour = C(50, 50, 52),
			material = Enum.Material.Metal,
			parent = model,
		})
		local lens = BuildKit.detail({
			name = "HeadlampLens",
			size = Vector3.new(1.6, 1.6, 0.3),
			cf = housing.CFrame * CFrame.new(0, 0, -0.7),
			colour = livery.lampColour,
			material = Enum.Material.Neon,
			parent = model,
		})
		lens.Name = "HeadlampLens"
		lens:AddTag("HeadlampLens")
		local spot = Instance.new("SpotLight")
		spot.Color = livery.lampColour
		spot.Brightness = 4.5
		spot.Range = 200 * def.handling.headlightRangeMultiplier
		spot.Angle = 56
		spot.Face = Enum.NormalId.Front
		spot.Shadows = true
		spot.Enabled = false
		spot.Parent = lens
		table.insert(headlights, spot)
	end
	-- Marker lights, always on, so the train is locatable from the forest.
	for _, side in { -1, 1 } do
		local marker = BuildKit.detail({
			name = "MarkerLamp",
			size = Vector3.new(0.8, 0.8, 0.5),
			cf = noseCF * CFrame.new(side * width * 0.42, lampY, noseFrontZ + 0.2),
			colour = C(255, 214, 150),
			material = Enum.Material.Neon,
			parent = model,
		})
		local point = Instance.new("PointLight")
		point.Color = C(255, 214, 150)
		point.Brightness = 1.4
		point.Range = 26
		point.Parent = marker
	end

	--------------------------------------------------------------
	-- Cab interior
	--------------------------------------------------------------
	local cab = buildCabInterior(
		originCF * CFrame.new(0, bodyBottom + height * 0.5, cabZ),
		width,
		height,
		livery,
		interior,
		model
	)

	local cabinLights: { Light } = {}
	do
		local _, light = BuildKit.lamp(
			originCF * CFrame.new(0, bodyTop - 1.2, cabZ + 1.0),
			"bulkhead",
			interior.lampColour,
			interior.lampBrightness,
			26,
			model
		)
		table.insert(cabinLights, light)
	end

	--------------------------------------------------------------
	-- Engine room: the prime mover, and a side corridor past it
	--------------------------------------------------------------
	-- The corridor runs along the right-hand side from the cab doorway to a
	-- vestibule at the rear, where a gangway opens onto the first carriage.
	-- This is how the crew walks between the carriages and the cab while the
	-- train is moving; without it, a driver who rode in a carriage could only
	-- reach the controls at a stop.
	do
		local roomZ0 = cabZ + 5.5
		local roomZ1 = length * 0.5 - 1.2
		local corridorX0 = width * 0.5 - 0.6 - 3.4
		local floorTop = bodyBottom + 0.4
		BuildKit.part({
			name = "EngineRoomFloor",
			size = Vector3.new(width - 1.2, 0.4, roomZ1 - roomZ0),
			cf = originCF * CFrame.new(0, floorTop - 0.2, (roomZ0 + roomZ1) * 0.5),
			colour = C(52, 52, 54),
			material = Enum.Material.DiamondPlate,
			parent = model,
		})
		BuildKit.part({
			name = "EngineRoomCeiling",
			size = Vector3.new(width - 1.2, 0.35, roomZ1 - roomZ0),
			cf = originCF * CFrame.new(0, bodyTop - 0.5, (roomZ0 + roomZ1) * 0.5),
			colour = C(70, 72, 70),
			material = Enum.Material.Metal,
			parent = model,
		})

		-- The prime mover fills the left of the room and stops short of the
		-- rear wall, leaving a vestibule across the full width.
		local blockX0 = -width * 0.5 + 0.8
		local blockX1 = corridorX0 - 0.4
		local blockZ0 = roomZ0 + 1.5
		local blockZ1 = roomZ1 - 6
		if blockZ1 - blockZ0 > 4 then
			local blockCF = originCF * CFrame.new((blockX0 + blockX1) * 0.5, floorTop, (blockZ0 + blockZ1) * 0.5)
			local blockSize = Vector3.new(blockX1 - blockX0, 5.4, blockZ1 - blockZ0)
			BuildKit.part({
				name = "PrimeMover",
				size = blockSize,
				cf = blockCF * CFrame.new(0, blockSize.Y * 0.5, 0),
				colour = C(64, 78, 70),
				material = Enum.Material.Metal,
				parent = model,
			})
			-- Cylinder head covers along the top, an exhaust manifold and a
			-- generator drum at the far end: the shape of a diesel, not a box.
			local heads = math.max(2, math.floor(blockSize.Z / 3.2))
			for i = 0, heads - 1 do
				BuildKit.detail({
					name = "CylinderHead",
					size = Vector3.new(blockSize.X * 0.7, 0.8, 2.2),
					cf = blockCF * CFrame.new(0, blockSize.Y + 0.4, -blockSize.Z * 0.5 + 1.6 + i * (blockSize.Z - 3.2) / math.max(1, heads - 1)),
					colour = C(82, 96, 86),
					material = Enum.Material.Metal,
					parent = model,
				})
			end
			BuildKit.cylinder({
				name = "ExhaustManifold",
				size = Vector3.new(blockSize.Z - 1, 0.7, 0.7),
				cf = blockCF * CFrame.new(blockSize.X * 0.5 - 0.3, blockSize.Y - 0.6, 0) * CFrame.Angles(0, math.rad(90), 0),
				colour = C(92, 74, 60),
				material = Enum.Material.CorrodedMetal,
				canCollide = false,
				parent = model,
			})
			BuildKit.cylinder({
				name = "Generator",
				size = Vector3.new(2.6, blockSize.X * 0.8, blockSize.X * 0.8),
				cf = blockCF * CFrame.new(0, blockSize.Y * 0.45, blockSize.Z * 0.5 + 1.3) * CFrame.Angles(0, math.rad(90), 0),
				colour = C(58, 66, 74),
				material = Enum.Material.Metal,
				parent = model,
			})
			-- Grab rail along the corridor side of the engine.
			BuildKit.detail({
				name = "CorridorRail",
				size = Vector3.new(0.16, 0.16, blockSize.Z),
				cf = blockCF * CFrame.new(blockSize.X * 0.5 + 0.25, 3.4, 0),
				colour = C(170, 140, 58),
				material = Enum.Material.Metal,
				parent = model,
			})
		end

		-- Corridor lamps, switched with the cab lights.
		for i = 0, 2 do
			local z = roomZ0 + 3 + i * ((roomZ1 - roomZ0 - 6) / 2)
			local _, light = BuildKit.lamp(
				originCF * CFrame.new(width * 0.5 - 2.4, bodyTop - 1.3, z),
				"bulkhead",
				interior.lampColour,
				interior.lampBrightness * 0.7,
				16,
				model
			)
			table.insert(cabinLights, light)
		end

		-- Rear end: a wall with a central gangway opening, a header, a
		-- concertina shroud and a walk plate over the coupling.
		local rearZ = length * 0.5 - 0.6
		local gangwayHalf = width * 0.21
		for _, side in { -1, 1 } do
			BuildKit.part({
				name = "RearEndWall",
				size = Vector3.new(width * 0.5 - gangwayHalf, height, 0.5),
				cf = originCF * CFrame.new(side * (gangwayHalf + (width * 0.5 - gangwayHalf) * 0.5), bodyCentreY, rearZ),
				colour = livery.body,
				material = Enum.Material.Metal,
				parent = model,
			})
		end
		BuildKit.part({
			name = "RearEndHeader",
			size = Vector3.new(gangwayHalf * 2, height - 7.4, 0.5),
			cf = originCF * CFrame.new(0, bodyBottom + 7.4 + (height - 7.4) * 0.5, rearZ),
			colour = livery.body,
			material = Enum.Material.Metal,
			parent = model,
		})
		for ring = 0, 2 do
			BuildKit.detail({
				name = "GangwayRing",
				size = Vector3.new(gangwayHalf * 2 + ring * 0.12, 7.6 + ring * 0.12, 0.3),
				cf = originCF * CFrame.new(0, bodyBottom + 3.8, rearZ + 0.6 + ring * 0.6),
				colour = C(42, 40, 40),
				material = Enum.Material.Fabric,
				parent = model,
			})
		end
		BuildKit.part({
			name = "GangwayPlate",
			size = Vector3.new(width * 0.36, 0.3, 3.2),
			cf = originCF * CFrame.new(0, bodyBottom + 0.3, rearZ + 1.6),
			colour = C(62, 62, 64),
			material = Enum.Material.DiamondPlate,
			parent = model,
		})
	end

	--------------------------------------------------------------
	-- Engine bay: fuel and repair points
	--------------------------------------------------------------
	local bayZ = if build.cabPosition == "front" then length * 0.2 else length * 0.32

	local fuelPoint = BuildKit.part({
		name = "FuelPoint",
		size = Vector3.new(2.2, 2.6, 2.2),
		cf = originCF * CFrame.new(width * 0.5 - 1.4, bodyBottom - 0.6, bayZ),
		colour = C(64, 66, 60),
		material = Enum.Material.Metal,
		canCollide = false,
		parent = model,
	})
	BuildKit.detail({
		name = "FillerCap",
		size = Vector3.new(1.2, 0.4, 1.2),
		cf = fuelPoint.CFrame * CFrame.new(0, 1.4, 0),
		colour = C(160, 130, 60),
		material = Enum.Material.Metal,
		parent = model,
	})
	fuelPoint:AddTag("TrainFuelPoint")

	local repairPoint = BuildKit.part({
		name = "RepairPoint",
		size = Vector3.new(2.4, 3.0, 2.4),
		cf = originCF * CFrame.new(-(width * 0.5 - 1.4), bodyBottom - 0.4, bayZ),
		colour = C(60, 62, 64),
		material = Enum.Material.DiamondPlate,
		canCollide = false,
		parent = model,
	})
	BuildKit.pipeRun(
		repairPoint.CFrame,
		{ Vector3.new(0, 1.6, -1), Vector3.new(0, 2.4, 0), Vector3.new(0, 2.4, 1.4) },
		0.4,
		C(120, 90, 60),
		model
	)
	repairPoint:AddTag("TrainRepairPoint")

	local radioSet = model:FindFirstChild("RadioSet", true) :: BasePart

	--------------------------------------------------------------
	-- Coupler ends
	--------------------------------------------------------------
	buildCouplerEnd(originCF * CFrame.new(0, 2.4, -length * 0.5), width, livery.body, model)
	buildCouplerEnd(originCF * CFrame.new(0, 2.4, length * 0.5) * CFrame.Angles(0, math.rad(180), 0), width, livery.body, model)

	return {
		wheels = wheels,
		cab = cab,
		headlights = headlights,
		cabinLights = cabinLights,
		fuelPoint = fuelPoint,
		repairPoint = repairPoint,
		radioSet = radioSet,
		doors = doors,
	}
end

--------------------------------------------------------------------------
-- Carriages
--------------------------------------------------------------------------

local function buildCarriage(
	originCF: CFrame,
	spec: TrainRegistry.CarriageSpec,
	index: number,
	def: TrainRegistry.TrainDef,
	livery: TrainRegistry.LiveryDef,
	interior: TrainRegistry.InteriorDef,
	parent: Instance,
	rng: Random
): {
	model: Model,
	wheels: { BasePart },
	lights: { Light },
	doors: { { model: Model, hinge: BasePart, side: string, carriage: number } },
	supplyRack: BasePart?,
}
	local model = BuildKit.model("Carriage" .. index, parent)
	local width = def.build.locoWidth - 0.5
	local height = def.build.locoHeight - 1.5
	local length = spec.length
	local wheels: { BasePart } = {}
	local lights: { Light } = {}
	local doors: { { model: Model, hinge: BasePart, side: string, carriage: number } } = {}
	local supplyRack: BasePart? = nil

	local bodyBottom = 3.0
	local bodyTop = bodyBottom + height
	local bodyCentreY = (bodyBottom + bodyTop) * 0.5
	local isFlat = spec.kind == "flat"

	--------------------------------------------------------------
	-- Underframe and bogies
	--------------------------------------------------------------
	BuildKit.part({
		name = "Underframe",
		size = Vector3.new(width - 0.4, 1.4, length - 2),
		cf = originCF * CFrame.new(0, 2.3, 0),
		colour = livery.underframe,
		material = Enum.Material.Metal,
		canCollide = false,
		parent = model,
	})
	for _, side in { -1, 1 } do
		BuildKit.detail({
			name = "Solebar",
			size = Vector3.new(0.45, 1.7, length - 2),
			cf = originCF * CFrame.new(side * (width * 0.5 - 0.15), 2.3, 0),
			colour = livery.underframe,
			material = Enum.Material.Metal,
			parent = model,
		})
		BuildKit.rivetStrip(
			originCF * CFrame.new(side * (width * 0.5 + 0.05), 2.3, (length - 5) * 0.5),
			length - 5,
			2.4,
			0.09,
			C(56, 56, 56),
			model
		)
	end
	for _, offset in { -length * 0.31, length * 0.31 } do
		for _, w in buildBogie(originCF * CFrame.new(0, 0, offset), 2, def.build.wheelRadius * 0.92, width - 2.4, model) do
			table.insert(wheels, w)
		end
	end

	--------------------------------------------------------------
	-- Floor. Collidable, because players walk on it.
	--------------------------------------------------------------
	BuildKit.part({
		name = "Floor",
		size = Vector3.new(width - 1.2, 0.5, length - 2.5),
		cf = originCF * CFrame.new(0, bodyBottom + 0.25, 0),
		colour = interior.floor,
		material = if isFlat then Enum.Material.WoodPlanks else Enum.Material.Fabric,
		parent = model,
	})

	if isFlat then
		--------------------------------------------------------------
		-- Flat wagon: deck, stanchions and a lashed load.
		--------------------------------------------------------------
		for _, side in { -1, 1 } do
			for i = 0, 5 do
				BuildKit.part({
					name = "Stanchion",
					size = Vector3.new(0.5, 5.0, 0.5),
					cf = originCF * CFrame.new(side * (width * 0.5 - 0.4), bodyBottom + 2.5, -length * 0.4 + i * (length * 0.16)),
					colour = livery.underframe,
					material = Enum.Material.Metal,
					parent = model,
				})
			end
			BuildKit.handrail(
				originCF * CFrame.new(side * (width * 0.5 - 0.4), bodyBottom + 0.3, 0),
				length - 6,
				1.0,
				livery.trim,
				model
			)
		end
		for i = 0, spec.crates - 1 do
			local cx = (i % 2 == 0) and -2.4 or 2.4
			local cz = -length * 0.33 + math.floor(i / 2) * 5.5
			BuildKit.part({
				name = "Cargo",
				size = Vector3.new(4.2, 3.4, 4.6),
				cf = originCF * CFrame.new(cx, bodyBottom + 2.2, cz) * CFrame.Angles(0, math.rad(rng:NextNumber(-4, 4)), 0),
				colour = BuildKit.weather(P.planking, 0.05, rng),
				material = Enum.Material.WoodPlanks,
				parent = model,
			})
		end
		-- Lashing straps over the load.
		for i = 0, 3 do
			BuildKit.detail({
				name = "Strap",
				size = Vector3.new(width - 1.5, 0.14, 0.4),
				cf = originCF * CFrame.new(0, bodyBottom + 4.0, -length * 0.3 + i * (length * 0.2)),
				colour = C(96, 84, 60),
				material = Enum.Material.Fabric,
				parent = model,
			})
		end
	else
		--------------------------------------------------------------
		-- Enclosed body
		--------------------------------------------------------------
		local isGuard = spec.kind == "guard"
		local windowCount = math.max(3, math.floor(length / 9))
		local windowSpacing = (length - 10) / (windowCount - 1)

		for _, side in { -1, 1 } do
			-- Side wall built as real segments around the door and window
			-- openings. The first version was a single solid slab with the
			-- doors and windows drawn on it, so nobody could board a carriage
			-- or see out of one.
			--
			-- The door hinges at doorZ and its leaf lies along the hinge's -Z;
			-- the far side is turned through 180 degrees, so the opening runs
			-- to opposite sides of doorZ on the two sides of the carriage.
			local doorZ = -length * 0.5 + length * 0.3
			local doorWidth = 3.4
			local doorFrom = if side > 0 then doorZ - doorWidth - 0.1 else doorZ - 0.1
			local doorTo = if side > 0 then doorZ + 0.1 else doorZ + doorWidth + 0.1
			local doorTop = 7.6

			local windowBottom = height * 0.62 - 1.9
			local windowTop = height * 0.62 + 1.9
			local windowZs: { number } = {}
			for i = 0, windowCount - 1 do
				local z = -length * 0.5 + 5 + i * windowSpacing
				-- A window never shares a bay with the door.
				if z + 2.3 < doorFrom - 0.6 or z - 2.3 > doorTo + 0.6 then
					table.insert(windowZs, z)
				end
			end

			local wallFrom = -length * 0.5 + 1.25
			local wallTo = length * 0.5 - 1.25
			-- Spans along the wall that are not covered by any gap.
			local function solidSpans(gaps: { { number } }): { { number } }
				table.sort(gaps, function(a, b)
					return a[1] < b[1]
				end)
				local spans: { { number } } = {}
				local cursor = wallFrom
				for _, gap in gaps do
					if gap[1] > cursor then
						table.insert(spans, { cursor, math.min(gap[1], wallTo) })
					end
					cursor = math.max(cursor, gap[2])
				end
				if cursor < wallTo then
					table.insert(spans, { cursor, wallTo })
				end
				return spans
			end

			local doorGap = { doorFrom, doorTo }
			local windowGaps: { { number } } = { { doorFrom, doorTo } }
			if not isGuard then
				for _, z in windowZs do
					table.insert(windowGaps, { z - 2.1, z + 2.1 })
				end
			end
			-- Three horizontal bands: below the windows, through them, above.
			local bands = {
				{ y0 = 0, y1 = windowBottom, gaps = { doorGap } },
				{ y0 = windowBottom, y1 = windowTop, gaps = windowGaps },
				{ y0 = windowTop, y1 = height, gaps = if doorTop > windowTop then { doorGap } else {} },
			}

			local function buildBands(name: string, x: number, thickness: number, colour: Color3, material: Enum.Material, detail: boolean, inset: number)
				for _, band in bands do
					local y0 = math.max(band.y0, inset)
					local y1 = math.min(band.y1, height - inset)
					if y1 - y0 < 0.05 then
						continue
					end
					for _, span in solidSpans(table.clone(band.gaps)) do
						local props = {
							name = name,
							size = Vector3.new(thickness, y1 - y0, span[2] - span[1]),
							cf = originCF * CFrame.new(x, bodyBottom + (y0 + y1) * 0.5, (span[1] + span[2]) * 0.5),
							colour = colour,
							material = material,
							parent = model,
						}
						if detail then
							BuildKit.detail(props)
						else
							BuildKit.part(props)
						end
					end
				end
				-- The lintel over the door, between its head and the band above.
				if doorTop < windowTop then
					local props = {
						name = name .. "Lintel",
						size = Vector3.new(thickness, windowTop - doorTop, doorTo - doorFrom),
						cf = originCF * CFrame.new(x, bodyBottom + (doorTop + windowTop) * 0.5, (doorFrom + doorTo) * 0.5),
						colour = colour,
						material = material,
						parent = model,
					}
					if detail then
						BuildKit.detail(props)
					else
						BuildKit.part(props)
					end
				end
			end

			buildBands("SideWall", side * (width * 0.5 - 0.28), 0.55, livery.body, Enum.Material.Metal, false, 0)
			-- Interior lining and dado follow the same openings.
			buildBands("Lining", side * (width * 0.5 - 0.62), 0.12, interior.wall, Enum.Material.Wood, true, 0.6)
			for _, span in solidSpans({ { doorFrom, doorTo } }) do
				BuildKit.detail({
					name = "Dado",
					size = Vector3.new(0.26, 1.0, span[2] - span[1]),
					cf = originCF * CFrame.new(side * (width * 0.5 - 0.72), bodyBottom + 1.6, (span[1] + span[2]) * 0.5),
					colour = interior.trim,
					material = Enum.Material.Wood,
					parent = model,
				})
			end
			-- Threshold plate across the doorway, so the floor reaches the step.
			BuildKit.part({
				name = "Threshold",
				size = Vector3.new(1.4, 0.5, doorTo - doorFrom),
				cf = originCF * CFrame.new(side * (width * 0.5 - 0.3), bodyBottom + 0.25, (doorFrom + doorTo) * 0.5),
				colour = C(70, 70, 72),
				material = Enum.Material.DiamondPlate,
				parent = model,
			})

			for _, z in windowZs do
				local broken = not isGuard and rng:NextNumber() < 0.12
				if isGuard then
					-- Guard van windows are shuttered with a narrow slit.
					BuildKit.detail({
						name = "Shutter",
						size = Vector3.new(0.2, 3.6, 4.0),
						cf = originCF * CFrame.new(side * (width * 0.5 + 0.05), bodyBottom + height * 0.62, z),
						colour = livery.trim,
						material = Enum.Material.DiamondPlate,
						parent = model,
					})
					BuildKit.detail({
						name = "Slit",
						size = Vector3.new(0.1, 0.5, 3.0),
						cf = originCF * CFrame.new(side * (width * 0.5 + 0.12), bodyBottom + height * 0.68, z),
						colour = C(20, 20, 22),
						material = Enum.Material.SmoothPlastic,
						parent = model,
					})
				else
					BuildKit.window(
						originCF * CFrame.new(side * (width * 0.5 + 0.02), bodyBottom + height * 0.62, z),
						4.2,
						3.8,
						livery.trim,
						model,
						broken
					)
				end
			end

			-- Passenger door, one per side, roughly a third along.
			local doorCF = originCF * CFrame.new(side * (width * 0.5 - 0.3), bodyBottom + 0.1, doorZ)
			local door = BuildKit.door(
				doorCF * CFrame.Angles(0, math.rad(if side > 0 then 0 else 180), 0),
				doorWidth,
				7.2,
				0.32,
				livery.body,
				Enum.Material.Metal,
				model
			)
			door.Name = "CarriageDoor"
			table.insert(doors, { model = door, hinge = door.PrimaryPart :: BasePart, side = if side > 0 then "right" else "left", carriage = index })
			-- Boarding steps below the doorway, for stations with low platforms.
			local doorMid = (doorFrom + doorTo) * 0.5
			for stepIndex = 0, 1 do
				BuildKit.part({
					name = "Step",
					size = Vector3.new(2.0, 0.22, doorWidth - 0.2),
					cf = originCF * CFrame.new(side * (width * 0.5 + 0.6), bodyBottom - 1.1 - stepIndex * 1.1, doorMid),
					colour = C(68, 68, 70),
					material = Enum.Material.DiamondPlate,
					parent = model,
				})
			end
			for _, edge in { doorFrom - 0.35, doorTo + 0.35 } do
				BuildKit.detail({
					name = "GrabRail",
					size = Vector3.new(0.18, 4.2, 0.18),
					cf = originCF * CFrame.new(side * (width * 0.5 + 0.18), bodyBottom + 2.6, edge),
					colour = livery.trim,
					material = Enum.Material.Metal,
					parent = model,
				})
			end

			BuildKit.rustStreaks(
				originCF * CFrame.new(side * (width * 0.5 + 0.06), bodyCentreY, 0),
				length - 6,
				height,
				def.build.detailLevel * 2,
				rng,
				model
			)
		end
		-- Roof with vents.
		BuildKit.part({
			name = "Roof",
			size = Vector3.new(width, 0.65, length - 2.5),
			cf = originCF * CFrame.new(0, bodyTop, 0),
			colour = livery.roof,
			material = Enum.Material.Metal,
			parent = model,
		})
		for _, side in { -1, 1 } do
			BuildKit.wedge({
				name = "RoofCamber",
				size = Vector3.new(width * 0.5, 0.55, length - 2.5),
				cf = originCF * CFrame.new(side * width * 0.25, bodyTop + 0.55, 0) * CFrame.Angles(0, math.rad(if side > 0 then 0 else 180), 0),
				colour = livery.roof,
				material = Enum.Material.Metal,
				canCollide = false,
				parent = model,
			})
		end
		for i = 0, math.floor(length / 14) do
			BuildKit.detail({
				name = "RoofVent",
				size = Vector3.new(1.8, 0.9, 1.8),
				cf = originCF * CFrame.new(0, bodyTop + 0.9, -length * 0.35 + i * 13),
				colour = C(92, 94, 96),
				material = Enum.Material.Metal,
				parent = model,
			})
		end

		-- End walls with gangway openings, so carriages genuinely connect.
		for _, endSign in { -1, 1 } do
			local endZ = endSign * (length * 0.5 - 0.6)
			-- Wall either side of the gangway.
			for _, side in { -1, 1 } do
				BuildKit.part({
					name = "EndWall",
					size = Vector3.new(width * 0.32, height, 0.5),
					cf = originCF * CFrame.new(side * (width * 0.34), bodyCentreY, endZ),
					colour = livery.body,
					material = Enum.Material.Metal,
					parent = model,
				})
			end
			-- Header above the gangway.
			BuildKit.part({
				name = "EndHeader",
				size = Vector3.new(width * 0.4, height - 7.4, 0.5),
				cf = originCF * CFrame.new(0, bodyBottom + 7.4 + (height - 7.4) * 0.5, endZ),
				colour = livery.body,
				material = Enum.Material.Metal,
				parent = model,
			})
			-- Concertina gangway shroud.
			for ring = 0, 2 do
				BuildKit.detail({
					name = "GangwayRing",
					size = Vector3.new(width * 0.42 + ring * 0.12, 7.6 + ring * 0.12, 0.3),
					cf = originCF * CFrame.new(0, bodyBottom + 3.8, endZ + endSign * (0.6 + ring * 0.6)),
					colour = C(42, 40, 40),
					material = Enum.Material.Fabric,
					parent = model,
				})
			end
			-- Gangway plate to walk across.
			BuildKit.part({
				name = "GangwayPlate",
				size = Vector3.new(width * 0.36, 0.3, 3.2),
				cf = originCF * CFrame.new(0, bodyBottom + 0.3, endZ + endSign * 1.6),
				colour = C(62, 62, 64),
				material = Enum.Material.DiamondPlate,
				parent = model,
			})
		end

		--------------------------------------------------------------
		-- Interior fittings
		--------------------------------------------------------------
		-- Seating: facing bays either side of a central aisle.
		local bays = math.floor(spec.seats / 4)
		for bay = 0, bays - 1 do
			local bz = -length * 0.5 + 9 + bay * 11
			for _, side in { -1, 1 } do
				for _, facing in { -1, 1 } do
					local seat = Instance.new("Seat")
					seat.Name = "PassengerSeat"
					seat.Size = Vector3.new(3.4, 0.45, 2.6)
					seat.CFrame = originCF * CFrame.new(side * (width * 0.26), bodyBottom + 2.0, bz + facing * 1.8)
					seat.Color = interior.seat
					seat.Material = interior.seatMaterial
					seat.Anchored = true
					seat.TopSurface = Enum.SurfaceType.Smooth
					seat.Parent = model
					BuildKit.detail({
						name = "SeatBack",
						size = Vector3.new(3.4, 3.2, 0.45),
						cf = seat.CFrame * CFrame.new(0, 1.6, facing * 1.3),
						colour = interior.seat,
						material = interior.seatMaterial,
						parent = model,
					})
					BuildKit.detail({
						name = "SeatFrame",
						size = Vector3.new(3.2, 1.5, 2.4),
						cf = seat.CFrame * CFrame.new(0, -0.9, 0),
						colour = interior.trim,
						material = Enum.Material.Wood,
						parent = model,
					})
				end
				-- Table between the facing pairs.
				BuildKit.detail({
					name = "Table",
					size = Vector3.new(3.0, 0.25, 2.2),
					cf = originCF * CFrame.new(side * (width * 0.26), bodyBottom + 2.9, bz),
					colour = interior.trim,
					material = Enum.Material.Wood,
					parent = model,
				})
			end
		end

		-- Luggage racks above the windows, on both sides.
		for _, side in { -1, 1 } do
			for rack = 0, spec.racks - 1 do
				local rz = -length * 0.5 + 8 + rack * ((length - 16) / math.max(1, spec.racks - 1))
				BuildKit.detail({
					name = "LuggageRack",
					size = Vector3.new(2.6, 0.18, 7.0),
					cf = originCF * CFrame.new(side * (width * 0.32), bodyBottom + height * 0.78, rz),
					colour = interior.trim,
					material = Enum.Material.Wood,
					parent = model,
				})
				for bracket = -1, 1, 2 do
					BuildKit.detail({
						name = "RackBracket",
						size = Vector3.new(2.4, 1.1, 0.16),
						cf = originCF * CFrame.new(side * (width * 0.32), bodyBottom + height * 0.83, rz + bracket * 3.2),
						colour = C(120, 110, 90),
						material = Enum.Material.Metal,
						parent = model,
					})
				end
			end
		end

		-- Storage crates and, in supply and workshop stock, the supply rack.
		if spec.kind == "supply" or spec.kind == "workshop" or spec.kind == "guard" then
			local rack = BuildKit.part({
				name = "SupplyRack",
				size = Vector3.new(3.0, 6.0, 8.0),
				cf = originCF * CFrame.new(-(width * 0.5 - 2.2), bodyBottom + 3.2, length * 0.28),
				colour = C(78, 74, 66),
				material = Enum.Material.Metal,
				parent = model,
			})
			rack:AddTag("SupplyRack")
			supplyRack = rack
			for shelf = 0, 3 do
				BuildKit.detail({
					name = "RackShelf",
					size = Vector3.new(3.2, 0.2, 8.2),
					cf = rack.CFrame * CFrame.new(0.1, -2.4 + shelf * 1.6, 0),
					colour = C(96, 92, 84),
					material = Enum.Material.Metal,
					parent = model,
				})
			end
			if spec.kind == "workshop" then
				BuildKit.part({
					name = "Workbench",
					size = Vector3.new(3.4, 0.4, 10.0),
					cf = originCF * CFrame.new(width * 0.5 - 2.4, bodyBottom + 3.0, -length * 0.15),
					colour = interior.trim,
					material = Enum.Material.Wood,
					parent = model,
				})
				BuildKit.detail({
					name = "Vice",
					size = Vector3.new(1.0, 1.0, 1.4),
					cf = originCF * CFrame.new(width * 0.5 - 2.4, bodyBottom + 3.7, -length * 0.15 - 4.0),
					colour = C(110, 60, 50),
					material = Enum.Material.Metal,
					parent = model,
				})
				BuildKit.detail({
					name = "ToolBoard",
					size = Vector3.new(0.25, 4.0, 8.0),
					cf = originCF * CFrame.new(width * 0.5 - 0.9, bodyBottom + 6.2, -length * 0.15),
					colour = C(92, 74, 54),
					material = Enum.Material.Wood,
					parent = model,
				})
			end
		end

		for crate = 0, math.min(spec.crates, 8) - 1 do
			BuildKit.part({
				name = "Crate",
				size = Vector3.new(2.6, 2.4, 2.6),
				cf = originCF
					* CFrame.new(
						(if crate % 2 == 0 then 1 else -1) * (width * 0.28),
						bodyBottom + 1.5,
						length * 0.5 - 6 - math.floor(crate / 2) * 3.2
					)
					* CFrame.Angles(0, math.rad(rng:NextNumber(-8, 8)), 0),
				colour = BuildKit.weather(P.planking, 0.06, rng),
				material = Enum.Material.WoodPlanks,
				parent = model,
			})
		end

		-- Interior lighting, spaced down the ceiling.
		local lampCount = math.max(2, math.floor(length / 16))
		for i = 0, lampCount - 1 do
			local lz = -length * 0.5 + 8 + i * ((length - 16) / math.max(1, lampCount - 1))
			local _, light = BuildKit.lamp(
				originCF * CFrame.new(0, bodyTop - 1.0, lz),
				"pendant",
				interior.lampColour,
				interior.lampBrightness,
				24,
				model
			)
			table.insert(lights, light)
		end
	end

	-- Coupler ends on every carriage.
	buildCouplerEnd(originCF * CFrame.new(0, 2.4, -length * 0.5), width, livery.body, model)
	buildCouplerEnd(originCF * CFrame.new(0, 2.4, length * 0.5) * CFrame.Angles(0, math.rad(180), 0), width, livery.body, model)

	return { model = model, wheels = wheels, lights = lights, doors = doors, supplyRack = supplyRack }
end

--------------------------------------------------------------------------
-- Public
--------------------------------------------------------------------------

--- Builds a complete train at the given CFrame, facing -Z.
--- Overall length of a consist, front coupler to rear buffer, matching the
--- layout build() produces.
function TrainBuilder.lengthOf(trainId: string): number
	local def = TrainRegistry.getOrStarter(trainId)
	local length = def.build.locoLength + 4
	for _, spec in def.build.carriages do
		length += spec.length + 4
	end
	return length
end

--- Builds a train with its front coupler at originCF. The consist trails
--- behind along originCF's +Z axis, so the train faces and drives along -Z.
function TrainBuilder.build(
	trainId: string,
	liveryId: string?,
	interiorId: string?,
	originCF: CFrame,
	parent: Instance,
	seed: number?
): BuiltTrain
	local def = TrainRegistry.getOrStarter(trainId)
	local livery = TrainRegistry.getLivery(liveryId or def.defaultLivery)
	local interior = TrainRegistry.getInterior(interiorId)
	local rng = Random.new(seed or 20217)
	followers = {}

	local model = BuildKit.model("Train_" .. def.id, nil)

	-- The root sits at the front coupler face. Everything is built relative to
	-- it, and it is the only part the movement code ever touches.
	local root = BuildKit.part({
		name = "TrainRoot",
		size = Vector3.new(2, 2, 2),
		cf = originCF,
		transparency = 1,
		canCollide = false,
		canQuery = false,
		castShadow = false,
		parent = model,
	})
	model.PrimaryPart = root

	local locoLength = def.build.locoLength
	local locoCF = originCF * CFrame.new(0, 0, locoLength * 0.5)
	local loco = buildLocomotive(locoCF, def, livery, interior, model, rng)

	local carriages: { Model } = {}
	local allWheels = loco.wheels
	local interiorLights: { Light } = {}
	local allDoors = loco.doors
	local supplyRack: BasePart? = nil

	local cursor = locoLength + 4
	for index, spec in def.build.carriages do
		local carriageCF = originCF * CFrame.new(0, 0, cursor + spec.length * 0.5)
		local built = buildCarriage(carriageCF, spec, index, def, livery, interior, model, rng)
		table.insert(carriages, built.model)
		for _, w in built.wheels do
			table.insert(allWheels, w)
		end
		for _, l in built.lights do
			table.insert(interiorLights, l)
		end
		for _, d in built.doors do
			table.insert(allDoors, d)
		end
		if built.supplyRack and not supplyRack then
			supplyRack = built.supplyRack
		end
		cursor += spec.length + 4
	end

	-- Tail lights on the rear of the last vehicle.
	local tailLights: { PointLight } = {}
	for _, side in { -1, 1 } do
		local lamp = BuildKit.detail({
			name = "TailLamp",
			size = Vector3.new(0.9, 0.9, 0.5),
			cf = originCF * CFrame.new(side * (def.build.locoWidth * 0.35), 5.4, cursor - 1),
			colour = C(200, 60, 50),
			material = Enum.Material.Neon,
			parent = model,
		})
		local point = Instance.new("PointLight")
		point.Color = C(200, 60, 50)
		point.Brightness = 1.6
		point.Range = 22
		point.Parent = lamp
		table.insert(tailLights, point)
	end

	-- Fallback supply rack: the locomotive always has somewhere to put things,
	-- even on a consist with no supply carriage.
	if not supplyRack then
		local rack = BuildKit.part({
			name = "SupplyRack",
			size = Vector3.new(2.6, 4.0, 5.0),
			cf = locoCF * CFrame.new(0, 4.6, locoLength * 0.28),
			colour = C(78, 74, 66),
			material = Enum.Material.Metal,
			canCollide = false,
			parent = model,
		})
		rack:AddTag("SupplyRack")
		supplyRack = rack
	end

	-- Doors swing about their hinge, and everything else in the door rides on it.
	for _, door in allDoors do
		articulate(door.hinge, door.hinge.CFrame)
		for _, part in door.model:GetDescendants() do
			if part:IsA("BasePart") and part ~= door.hinge then
				followers[part] = door.hinge
			end
		end
	end

	-- Weld the whole assembly to the root, then anchor only the root. This is
	-- what makes the train a single cheap rigid body. Articulated parts get a
	-- Weld whose C0 can be animated; see the Articulation section above.
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") and descendant ~= root then
			local leader = followers[descendant]
			if leader then
				local weld = Instance.new("WeldConstraint")
				weld.Part0 = leader
				weld.Part1 = descendant
				weld.Parent = descendant
			elseif descendant:HasTag("Articulated") then
				local relative = descendant:GetAttribute("ArticulationPivot")
				local rel: CFrame = if typeof(relative) == "CFrame" then relative else CFrame.identity
				local pivotWorld = descendant.CFrame * rel:Inverse()
				local joint = Instance.new("Weld")
				joint.Name = "Articulation"
				joint.Part0 = root
				joint.Part1 = descendant
				joint.C0 = root.CFrame:ToObjectSpace(pivotWorld)
				joint.C1 = rel:Inverse()
				joint:SetAttribute("BaseC0", joint.C0)
				joint.Parent = descendant
			else
				local weld = Instance.new("WeldConstraint")
				weld.Part0 = root
				weld.Part1 = descendant
				weld.Parent = root
			end
			descendant.Anchored = false
		end
	end
	root.Anchored = true
	followers = {}

	local totalLength = cursor
	local volumeSize = Vector3.new(def.build.locoWidth + 2, def.build.locoHeight + 6, totalLength)
	local volumeOffset = CFrame.new(0, def.build.locoHeight * 0.5 + 2, totalLength * 0.5)
	-- Read by TrainRideController to decide who is aboard.
	model:SetAttribute("VolumeSize", volumeSize)
	model:SetAttribute("VolumeOffset", volumeOffset)
	-- A passenger must never see half a train: it streams in and out whole.
	model.ModelStreamingMode = Enum.ModelStreamingMode.Atomic

	model:AddTag("Train")
	model.Parent = parent

	return {
		model = model,
		root = root,
		trainId = def.id,
		carriages = carriages,
		cab = loco.cab,
		headlights = loco.headlights,
		tailLights = tailLights,
		cabinLights = loco.cabinLights,
		interiorLights = interiorLights,
		wheels = allWheels,
		doors = allDoors,
		fuelPoint = loco.fuelPoint,
		repairPoint = loco.repairPoint,
		supplyRack = supplyRack :: BasePart,
		radioSet = loco.radioSet,
		volumeSize = volumeSize,
		volumeOffset = volumeOffset,
		partCount = BuildKit.countParts(model),
	}
end

return TrainBuilder
