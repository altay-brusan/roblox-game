--!strict
--[[
	LobbyBuilder
	------------
	The railway maintenance yard the expedition leaves from.

	Deliberately a small, ordinary, working yard: a brick workshop, a covered
	waiting area with benches, a stores hut, a water column, a couple of sidings
	and the departure road. No concourse, no shopping arcade, no giant terminal.
	The whole thing is walkable in about twenty seconds, which is the point: a
	lobby is a place to gather, not a place to explore.

	Everything a player needs is reachable from the shelter without a map:
	  - the departure road and the train, directly ahead
	  - the crew board, under the shelter
	  - the workshop (loadout and cosmetics), on the left
	  - the stores hut (shop), on the right
	  - the notice board (quests, rewards, events), by the shelter

	Interactive fixtures are tagged here and given behaviour by LobbyService.
]]

local BuildKit = require(script.Parent.BuildKit)

local C = Color3.fromRGB
local P = BuildKit.Palette

local LobbyBuilder = {}

export type BuiltLobby = {
	model: Model,
	spawnCFrames: { CFrame },
	crewBoard: BasePart,
	workshopBench: BasePart,
	storesCounter: BasePart,
	noticeBoard: BasePart,
	trainPreviewCF: CFrame,
	departureCF: CFrame,
	lights: { Light },
	partCount: number,
}

--------------------------------------------------------------------------

local function buildWorkshop(cf: CFrame, parent: Instance, lights: { Light }, rng: Random): BasePart
	local size = Vector3.new(44, 26, 60)
	local half = size * 0.5

	-- Brick shell with a large roller-shutter opening facing the yard.
	for _, side in { -1, 1 } do
		BuildKit.part({
			name = "WorkshopWall",
			size = Vector3.new(1.0, size.Y, size.Z),
			cf = cf * CFrame.new(side * half.X, size.Y * 0.5, 0),
			colour = C(122, 84, 68),
			material = Enum.Material.Brick,
			parent = parent,
		})
		for i = 0, 2 do
			BuildKit.window(
				cf * CFrame.new(side * (half.X + 0.05), 17, -18 + i * 18),
				7,
				6,
				C(64, 60, 52),
				parent,
				rng:NextNumber() < 0.2
			)
		end
	end
	BuildKit.part({
		name = "WorkshopBack",
		size = Vector3.new(size.X, size.Y, 1.0),
		cf = cf * CFrame.new(0, size.Y * 0.5, half.Z),
		colour = C(122, 84, 68),
		material = Enum.Material.Brick,
		parent = parent,
	})
	-- Front wall either side of the shutter.
	for _, side in { -1, 1 } do
		BuildKit.part({
			name = "WorkshopFront",
			size = Vector3.new(size.X * 0.28, size.Y, 1.0),
			cf = cf * CFrame.new(side * (size.X * 0.36), size.Y * 0.5, -half.Z),
			colour = C(122, 84, 68),
			material = Enum.Material.Brick,
			parent = parent,
		})
	end
	BuildKit.part({
		name = "ShutterHeader",
		size = Vector3.new(size.X * 0.44, size.Y - 18, 1.0),
		cf = cf * CFrame.new(0, 18 + (size.Y - 18) * 0.5, -half.Z),
		colour = C(122, 84, 68),
		material = Enum.Material.Brick,
		parent = parent,
	})
	-- The shutter itself, rolled up.
	BuildKit.detail({
		name = "RollerShutter",
		size = Vector3.new(size.X * 0.44, 3.0, 1.4),
		cf = cf * CFrame.new(0, 19, -half.Z),
		colour = C(112, 108, 100),
		material = Enum.Material.CorrodedMetal,
		parent = parent,
	})

	BuildKit.part({
		name = "WorkshopFloor",
		size = Vector3.new(size.X - 1, 0.6, size.Z - 1),
		cf = cf * CFrame.new(0, 0.3, 0),
		colour = C(88, 86, 82),
		material = Enum.Material.Concrete,
		parent = parent,
	})
	-- Sawtooth roof, which is what a workshop of this era actually has.
	for i = 0, 2 do
		local z = -half.Z + 10 + i * 20
		BuildKit.wedge({
			name = "SawtoothRoof",
			size = Vector3.new(size.X + 1, 7, 20),
			cf = cf * CFrame.new(0, size.Y + 3.5, z) * CFrame.Angles(0, math.rad(180), 0),
			colour = C(70, 68, 64),
			material = Enum.Material.Metal,
			parent = parent,
		})
		-- North light glazing on the vertical face of each sawtooth.
		BuildKit.detail({
			name = "NorthLight",
			size = Vector3.new(size.X, 6.5, 0.4),
			cf = cf * CFrame.new(0, size.Y + 3.4, z + 10),
			colour = C(150, 170, 185),
			material = Enum.Material.Glass,
			transparency = 0.6,
			parent = parent,
		})
	end

	-- Interior: benches, a pit, tool boards, an overhead gantry crane.
	local bench = BuildKit.part({
		name = "WorkshopBench",
		size = Vector3.new(5.0, 4.0, 26.0),
		cf = cf * CFrame.new(half.X - 5, 2.6, 4),
		colour = C(96, 78, 56),
		material = Enum.Material.Wood,
		parent = parent,
	})
	bench:AddTag("WorkshopBench")
	BuildKit.detail({
		name = "BenchTop",
		size = Vector3.new(5.6, 0.5, 26.4),
		cf = bench.CFrame * CFrame.new(0, 2.2, 0),
		colour = C(112, 92, 66),
		material = Enum.Material.Wood,
		parent = parent,
	})
	for i = 0, 3 do
		BuildKit.detail({
			name = "Vice",
			size = Vector3.new(1.6, 1.6, 2.0),
			cf = bench.CFrame * CFrame.new(0, 3.2, -10 + i * 7),
			colour = C(110, 60, 50),
			material = Enum.Material.Metal,
			parent = parent,
		})
	end
	BuildKit.detail({
		name = "ToolBoard",
		size = Vector3.new(0.4, 8.0, 24.0),
		cf = cf * CFrame.new(half.X - 1.2, 10, 4),
		colour = C(92, 74, 54),
		material = Enum.Material.Wood,
		parent = parent,
	})

	-- Inspection pit with a handrail, the detail that says "railway workshop".
	BuildKit.part({
		name = "PitFloor",
		size = Vector3.new(10, 0.5, 34),
		cf = cf * CFrame.new(-6, -3.5, 0),
		colour = C(72, 70, 66),
		material = Enum.Material.Concrete,
		parent = parent,
	})
	for _, side in { -1, 1 } do
		BuildKit.part({
			name = "PitWall",
			size = Vector3.new(0.8, 4.4, 34),
			cf = cf * CFrame.new(-6 + side * 5, -1.5, 0),
			colour = C(80, 78, 74),
			material = Enum.Material.Concrete,
			parent = parent,
		})
		BuildKit.handrail(cf * CFrame.new(-6 + side * 5.6, 0.6, 0), 34, 3.2, C(178, 148, 52), parent, true)
	end

	-- Overhead travelling crane.
	for _, side in { -1, 1 } do
		BuildKit.detail({
			name = "CraneRail",
			size = Vector3.new(1.2, 1.2, size.Z - 4),
			cf = cf * CFrame.new(side * (half.X - 3), 20, 0),
			colour = C(76, 80, 84),
			material = Enum.Material.Metal,
			parent = parent,
		})
	end
	BuildKit.detail({
		name = "CraneBridge",
		size = Vector3.new(size.X - 6, 2.4, 3.0),
		cf = cf * CFrame.new(0, 20, -8),
		colour = C(150, 124, 44),
		material = Enum.Material.Metal,
		parent = parent,
	})
	BuildKit.detail({
		name = "CraneHook",
		size = Vector3.new(1.0, 6.0, 1.0),
		cf = cf * CFrame.new(0, 15, -8),
		colour = C(60, 58, 56),
		material = Enum.Material.Metal,
		parent = parent,
	})

	for i = 0, 2 do
		local _, light = BuildKit.lamp(
			cf * CFrame.new(0, size.Y - 4, -18 + i * 18),
			"strip",
			C(238, 244, 255),
			1.6,
			42,
			parent
		)
		table.insert(lights, light)
	end

	return bench
end

local function buildShelter(cf: CFrame, parent: Instance, lights: { Light }): (BasePart, BasePart)
	local width, length = 26, 40

	BuildKit.part({
		name = "ShelterFloor",
		size = Vector3.new(width, 0.8, length),
		cf = cf * CFrame.new(0, 0.4, 0),
		colour = P.weatheredConcrete,
		material = Enum.Material.Concrete,
		parent = parent,
	})
	-- Back and side walls; the yard side is open, which is what a waiting
	-- shelter is.
	BuildKit.part({
		name = "ShelterBack",
		size = Vector3.new(0.8, 14, length),
		cf = cf * CFrame.new(width * 0.5, 7, 0),
		colour = C(126, 88, 72),
		material = Enum.Material.Brick,
		parent = parent,
	})
	for _, side in { -1, 1 } do
		BuildKit.part({
			name = "ShelterSide",
			size = Vector3.new(width, 14, 0.8),
			cf = cf * CFrame.new(0, 7, side * length * 0.5),
			colour = C(126, 88, 72),
			material = Enum.Material.Brick,
			parent = parent,
		})
	end
	-- Posts and a lean-to canopy.
	for i = 0, 3 do
		BuildKit.detail({
			name = "ShelterPost",
			size = Vector3.new(1.0, 14, 1.0),
			cf = cf * CFrame.new(-width * 0.5 + 1, 7, -length * 0.5 + 4 + i * 10.6),
			colour = C(62, 66, 64),
			material = Enum.Material.Metal,
			parent = parent,
		})
	end
	BuildKit.wedge({
		name = "Canopy",
		size = Vector3.new(width + 3, 3.5, length + 2),
		cf = cf * CFrame.new(0, 15.8, 0) * CFrame.Angles(0, math.rad(180), 0),
		colour = C(66, 64, 60),
		material = Enum.Material.Metal,
		parent = parent,
	})

	-- Benches, the ordinary slatted kind.
	local benchSeat: BasePart? = nil
	for i = 0, 2 do
		local benchCF = cf * CFrame.new(width * 0.5 - 4, 2.2, -length * 0.5 + 8 + i * 12)
		for slat = 0, 3 do
			local part = BuildKit.part({
				name = "BenchSlat",
				size = Vector3.new(0.8, 0.35, 9.0),
				cf = benchCF * CFrame.new(-1.2 + slat * 0.95, 0, 0),
				colour = C(102, 76, 50),
				material = Enum.Material.WoodPlanks,
				parent = parent,
			})
			if not benchSeat then
				benchSeat = part
			end
		end
		for slat = 0, 3 do
			BuildKit.detail({
				name = "BenchBack",
				size = Vector3.new(0.35, 0.8, 9.0),
				cf = benchCF * CFrame.new(1.8, 1.4 + slat * 0.95, 0),
				colour = C(102, 76, 50),
				material = Enum.Material.WoodPlanks,
				parent = parent,
			})
		end
		for _, end_ in { -1, 1 } do
			BuildKit.detail({
				name = "BenchFrame",
				size = Vector3.new(4.4, 2.4, 0.5),
				cf = benchCF * CFrame.new(0, -1.0, end_ * 4.2),
				colour = C(56, 58, 56),
				material = Enum.Material.Metal,
				parent = parent,
			})
		end
	end

	-- Crew board: the physical object the crew interface hangs off.
	local crewBoard = BuildKit.part({
		name = "CrewBoard",
		size = Vector3.new(0.6, 9.0, 14.0),
		cf = cf * CFrame.new(width * 0.5 - 0.9, 8.5, -length * 0.5 + 10),
		colour = C(48, 54, 50),
		material = Enum.Material.SmoothPlastic,
		parent = parent,
	})
	crewBoard:AddTag("CrewBoard")
	BuildKit.detail({
		name = "CrewBoardFrame",
		size = Vector3.new(0.8, 9.6, 14.6),
		cf = crewBoard.CFrame * CFrame.new(0.15, 0, 0),
		colour = C(142, 118, 62),
		material = Enum.Material.Metal,
		parent = parent,
	})
	BuildKit.detail({
		name = "CrewBoardGlass",
		size = Vector3.new(0.15, 8.4, 13.4),
		cf = crewBoard.CFrame * CFrame.new(-0.35, 0, 0),
		colour = C(150, 170, 185),
		material = Enum.Material.Glass,
		transparency = 0.7,
		parent = parent,
	})

	-- Notice board for quests, rewards and events.
	local noticeBoard = BuildKit.part({
		name = "NoticeBoard",
		size = Vector3.new(0.6, 8.0, 12.0),
		cf = cf * CFrame.new(width * 0.5 - 0.9, 8.0, length * 0.5 - 10),
		colour = C(96, 76, 54),
		material = Enum.Material.Wood,
		parent = parent,
	})
	noticeBoard:AddTag("NoticeBoard")
	-- Pinned papers, so it reads as a notice board before you interact.
	local rng = Random.new(7)
	for _noticeIndex = 1, 7 do
		BuildKit.detail({
			name = "Notice",
			size = Vector3.new(0.1, rng:NextNumber(1.2, 2.2), rng:NextNumber(0.9, 1.6)),
			cf = noticeBoard.CFrame
				* CFrame.new(-0.36, rng:NextNumber(-2.8, 2.8), rng:NextNumber(-4.5, 4.5))
				* CFrame.Angles(rng:NextNumber(-0.08, 0.08), 0, 0),
			colour = C(208, 200, 178),
			material = Enum.Material.SmoothPlastic,
			parent = parent,
		})
	end

	for i = 0, 2 do
		local _, light = BuildKit.lamp(
			cf * CFrame.new(0, 14.2, -length * 0.5 + 8 + i * 12),
			"bulkhead",
			C(255, 228, 178),
			1.1,
			30,
			parent
		)
		table.insert(lights, light)
	end

	return crewBoard, noticeBoard
end

local function buildStoresHut(cf: CFrame, parent: Instance, lights: { Light }): BasePart
	local size = Vector3.new(22, 16, 26)
	BuildKit.corrugated(cf * CFrame.new(size.X * 0.5, size.Y * 0.5, 0), size.Z, size.Y, C(98, 102, 94), parent)
	BuildKit.corrugated(cf * CFrame.new(-size.X * 0.5, size.Y * 0.5, 0), size.Z, size.Y, C(98, 102, 94), parent)
	BuildKit.corrugated(
		cf * CFrame.new(0, size.Y * 0.5, size.Z * 0.5) * CFrame.Angles(0, math.rad(90), 0),
		size.X,
		size.Y,
		C(98, 102, 94),
		parent
	)
	-- Front wall with a serving hatch, which is the shop counter.
	for _, side in { -1, 1 } do
		BuildKit.part({
			name = "StoresFront",
			size = Vector3.new(size.X * 0.3, size.Y, 0.6),
			cf = cf * CFrame.new(side * size.X * 0.35, size.Y * 0.5, -size.Z * 0.5),
			colour = C(98, 102, 94),
			material = Enum.Material.CorrodedMetal,
			parent = parent,
		})
	end
	BuildKit.part({
		name = "StoresHeader",
		size = Vector3.new(size.X * 0.4, size.Y - 9, 0.6),
		cf = cf * CFrame.new(0, 9 + (size.Y - 9) * 0.5, -size.Z * 0.5),
		colour = C(98, 102, 94),
		material = Enum.Material.CorrodedMetal,
		parent = parent,
	})

	local counter = BuildKit.part({
		name = "StoresCounter",
		size = Vector3.new(size.X * 0.4, 1.0, 2.4),
		cf = cf * CFrame.new(0, 4.5, -size.Z * 0.5),
		colour = C(104, 84, 58),
		material = Enum.Material.Wood,
		parent = parent,
	})
	counter:AddTag("StoresCounter")
	BuildKit.part({
		name = "CounterFront",
		size = Vector3.new(size.X * 0.4, 4.0, 0.5),
		cf = cf * CFrame.new(0, 2.0, -size.Z * 0.5 - 0.9),
		colour = C(92, 74, 52),
		material = Enum.Material.Wood,
		parent = parent,
	})

	BuildKit.part({
		name = "StoresFloor",
		size = Vector3.new(size.X - 1, 0.5, size.Z - 1),
		cf = cf * CFrame.new(0, 0.25, 0),
		colour = C(82, 80, 76),
		material = Enum.Material.Concrete,
		parent = parent,
	})
	BuildKit.corrugated(cf * CFrame.new(0, size.Y + 0.4, 0) * CFrame.Angles(0, 0, math.rad(90)), size.Z, size.X, C(88, 92, 86), parent)

	-- Stock on shelves behind the counter, visible through the hatch.
	for shelf = 0, 2 do
		BuildKit.detail({
			name = "StockShelf",
			size = Vector3.new(size.X - 4, 0.3, 3.0),
			cf = cf * CFrame.new(0, 4 + shelf * 3.5, size.Z * 0.4),
			colour = C(88, 84, 76),
			material = Enum.Material.Metal,
			parent = parent,
		})
		for i = 0, 5 do
			BuildKit.detail({
				name = "StockBox",
				size = Vector3.new(2.0, 2.2, 2.2),
				cf = cf * CFrame.new(-size.X * 0.4 + 2 + i * 3.2, 5.4 + shelf * 3.5, size.Z * 0.4),
				colour = C(118, 96, 66),
				material = Enum.Material.Cardboard,
				parent = parent,
			})
		end
	end

	local _, light = BuildKit.lamp(cf * CFrame.new(0, size.Y - 2, 0), "pendant", C(255, 232, 186), 1.1, 28, parent)
	table.insert(lights, light)
	local _, hatchLight = BuildKit.lamp(cf * CFrame.new(0, 9.5, -size.Z * 0.5 - 1.2), "bulkhead", C(255, 220, 170), 1.0, 20, parent)
	table.insert(lights, hatchLight)

	return counter
end

--------------------------------------------------------------------------

function LobbyBuilder.build(origin: Vector3, parent: Instance, seed: number?): BuiltLobby
	local rng = Random.new(seed or 217)
	local model = BuildKit.model("Lobby", nil)
	local lights: { Light } = {}
	local originCF = CFrame.new(origin)

	--------------------------------------------------------------
	-- Ground and yard surface
	--------------------------------------------------------------
	BuildKit.part({
		name = "YardGround",
		size = Vector3.new(420, 2, 520),
		cf = originCF * CFrame.new(0, -1, 0),
		colour = P.soil,
		material = Enum.Material.Ground,
		parent = model,
	})
	BuildKit.part({
		name = "YardHardstanding",
		size = Vector3.new(220, 0.6, 300),
		cf = originCF * CFrame.new(0, 0.3, 0),
		colour = C(96, 92, 86),
		material = Enum.Material.Asphalt,
		parent = model,
	})
	-- Puddles. The yard is wet, and wet ground under lamps is most of what
	-- sells a night scene.
	for _ = 1, 24 do
		local size = rng:NextNumber(6, 22)
		BuildKit.detail({
			name = "Puddle",
			size = Vector3.new(size, 0.08, size * rng:NextNumber(0.5, 1.2)),
			cf = originCF * CFrame.new(rng:NextNumber(-105, 105), 0.64, rng:NextNumber(-140, 140)),
			colour = C(38, 42, 46),
			material = Enum.Material.Glass,
			transparency = 0.25,
			reflectance = 0.45,
			parent = model,
		})
	end

	--------------------------------------------------------------
	-- Tracks: departure road plus two sidings
	--------------------------------------------------------------
	local departureX = 0
	BuildKit.trackSection(originCF * CFrame.new(departureX, 0, 240), 480, model, rng)
	BuildKit.trackSection(originCF * CFrame.new(departureX - 34, 0, 180), 300, model, rng)
	BuildKit.trackSection(originCF * CFrame.new(departureX + 34, 0, 180), 300, model, rng)

	-- Buffer stops at the ends of the sidings.
	for _, x in { departureX - 34, departureX + 34 } do
		local stopCF = originCF * CFrame.new(x, 0, -110)
		BuildKit.part({
			name = "BufferStop",
			size = Vector3.new(14, 5, 3),
			cf = stopCF * CFrame.new(0, 2.5, 0),
			colour = C(84, 58, 46),
			material = Enum.Material.Wood,
			parent = model,
		})
		for _, side in { -1, 1 } do
			BuildKit.detail({
				name = "BufferFace",
				size = Vector3.new(2.2, 2.2, 1.0),
				cf = stopCF * CFrame.new(side * 4.7, 3.2, -1.8),
				colour = C(48, 48, 50),
				material = Enum.Material.Metal,
				parent = model,
			})
		end
		BuildKit.detail({
			name = "BufferStripe",
			size = Vector3.new(14.2, 1.4, 0.3),
			cf = stopCF * CFrame.new(0, 4.2, -1.6),
			colour = C(196, 160, 56),
			material = Enum.Material.SmoothPlastic,
			parent = model,
		})
	end

	--------------------------------------------------------------
	-- Buildings
	--------------------------------------------------------------
	local workshopBench = buildWorkshop(originCF * CFrame.new(-86, 0, -20) * CFrame.Angles(0, math.rad(90), 0), model, lights, rng)
	local crewBoard, noticeBoard = buildShelter(originCF * CFrame.new(52, 0, -30), model, lights)
	local storesCounter = buildStoresHut(originCF * CFrame.new(74, 0, 60) * CFrame.Angles(0, math.rad(-90), 0), model, lights)

	-- Water column by the departure road, the classic yard silhouette.
	do
		local columnCF = originCF * CFrame.new(departureX + 16, 0, 40)
		BuildKit.part({
			name = "WaterColumn",
			size = Vector3.new(2.0, 18, 2.0),
			cf = columnCF * CFrame.new(0, 9, 0),
			colour = C(58, 62, 60),
			material = Enum.Material.Metal,
			parent = model,
		})
		BuildKit.detail({
			name = "ColumnArm",
			size = Vector3.new(1.4, 1.4, 12),
			cf = columnCF * CFrame.new(0, 17, -6),
			colour = C(58, 62, 60),
			material = Enum.Material.Metal,
			parent = model,
		})
		BuildKit.detail({
			name = "ColumnBag",
			size = Vector3.new(2.2, 4.0, 2.2),
			cf = columnCF * CFrame.new(0, 14.5, -11),
			colour = C(52, 46, 40),
			material = Enum.Material.Fabric,
			parent = model,
		})
		BuildKit.detail({
			name = "ColumnBrazier",
			size = Vector3.new(2.6, 2.6, 2.6),
			cf = columnCF * CFrame.new(2.6, 1.3, 0),
			colour = C(88, 62, 48),
			material = Enum.Material.CorrodedMetal,
			parent = model,
		})
	end

	-- Yard lighting: tall masts with warm sodium heads.
	for _, spec in
		{
			Vector3.new(-40, 0, 90),
			Vector3.new(40, 0, 90),
			Vector3.new(-40, 0, -60),
			Vector3.new(40, 0, -60),
			Vector3.new(0, 0, 150),
		}
	do
		local mastCF = originCF * CFrame.new(spec)
		BuildKit.part({
			name = "YardLightMast",
			size = Vector3.new(1.6, 42, 1.6),
			cf = mastCF * CFrame.new(0, 21, 0),
			colour = C(56, 60, 58),
			material = Enum.Material.Metal,
			parent = model,
		})
		BuildKit.detail({
			name = "MastBase",
			size = Vector3.new(4, 1.5, 4),
			cf = mastCF * CFrame.new(0, 0.75, 0),
			colour = C(80, 78, 74),
			material = Enum.Material.Concrete,
			parent = model,
		})
		for _, head in { -1, 1 } do
			local _, light = BuildKit.lamp(
				mastCF * CFrame.new(head * 3, 41, 0) * CFrame.Angles(0, 0, math.rad(if head > 0 then 20 else -20)),
				"flood",
				C(255, 206, 140),
				3.2,
				88,
				model
			)
			table.insert(lights, light)
		end
	end

	-- Scattered yard clutter: pallets, drums, a permanent way trolley, sleepers.
	for _ = 1, 16 do
		local pos = originCF * CFrame.new(rng:NextNumber(-95, 95), 0, rng:NextNumber(-130, 130))
		local pick = rng:NextInteger(1, 4)
		if pick == 1 then
			BuildKit.part({
				name = "Pallet",
				size = Vector3.new(6, 0.8, 6),
				cf = pos * CFrame.new(0, 0.9, 0) * CFrame.Angles(0, math.rad(rng:NextNumber(0, 360)), 0),
				colour = BuildKit.weather(P.planking, 0.05, rng),
				material = Enum.Material.WoodPlanks,
				parent = model,
			})
		elseif pick == 2 then
			local drum = BuildKit.part({
				name = "Drum",
				size = Vector3.new(4.4, 3.2, 3.2),
				cf = pos * CFrame.new(0, 2.2, 0) * CFrame.Angles(0, 0, math.rad(90)),
				colour = BuildKit.weather(C(96, 72, 54), 0.07, rng),
				material = Enum.Material.CorrodedMetal,
				parent = model,
			})
			drum.Shape = Enum.PartType.Cylinder
		elseif pick == 3 then
			for i = 0, 4 do
				BuildKit.part({
					name = "StackedSleeper",
					size = Vector3.new(12, 0.9, 2.2),
					cf = pos * CFrame.new(0, 0.9 + i * 0.95, 0) * CFrame.Angles(0, math.rad(rng:NextNumber(-3, 3)), 0),
					colour = BuildKit.weather(P.sleeper, 0.04, rng),
					material = Enum.Material.WoodPlanks,
					parent = model,
				})
			end
		else
			BuildKit.part({
				name = "RailStack",
				size = Vector3.new(1.0, 1.0, 26),
				cf = pos * CFrame.new(0, 0.6, 0) * CFrame.Angles(0, math.rad(rng:NextNumber(0, 20)), 0),
				colour = C(96, 88, 80),
				material = Enum.Material.Metal,
				parent = model,
			})
		end
	end

	-- Perimeter fence, so the yard has an edge without a wall of nothing.
	for _, side in { -1, 1 } do
		for i = 0, 24 do
			BuildKit.detail({
				name = "FencePost",
				size = Vector3.new(0.5, 9, 0.5),
				cf = originCF * CFrame.new(side * 130, 4.5, -160 + i * 13),
				colour = C(64, 58, 50),
				material = Enum.Material.Wood,
				parent = model,
			})
		end
		for wire = 0, 3 do
			BuildKit.detail({
				name = "FenceWire",
				size = Vector3.new(0.12, 0.12, 312),
				cf = originCF * CFrame.new(side * 130, 2.5 + wire * 2.0, -4),
				colour = C(70, 70, 68),
				material = Enum.Material.Metal,
				parent = model,
			})
		end
	end

	--------------------------------------------------------------
	-- Spawns
	--------------------------------------------------------------
	local spawnCFrames: { CFrame } = {}
	for i = 0, 11 do
		local angle = math.rad(i * 30)
		spawnCFrames[i + 1] = originCF
			* CFrame.new(38 + math.cos(angle) * 9, 3, -14 + math.sin(angle) * 9)
			* CFrame.Angles(0, math.rad(-90), 0)
	end

	--------------------------------------------------------------
	-- Signage and navigation
	--------------------------------------------------------------
	-- A yard with no lettering reads as a blockout however detailed the
	-- geometry is, and a player who cannot see where to go does not depart.
	-- These are also the whole tutorial: the crew board says what it does.

	BuildKit.label(crewBoard, Enum.NormalId.Left, "CREW BOARD", "Form a crew and depart")
	BuildKit.label(noticeBoard, Enum.NormalId.Left, "NOTICES", "Orders, rewards and events")

	-- The yard nameboard, on the approach to the shelter.
	BuildKit.postSign(originCF * CFrame.new(20, 0, -80) * CFrame.Angles(0, math.rad(180), 0), "TOLBRIDGE YARD", model, {
		width = 22,
		height = 11,
		subtitle = "Regional Permanent Way Depot",
		plate = C(32, 44, 38),
	})

	-- Direction signs, so the three buildings are findable at night.
	BuildKit.postSign(originCF * CFrame.new(-46, 0, -18) * CFrame.Angles(0, math.rad(90), 0), "WORKSHOP", model, {
		width = 13,
		height = 7,
		subtitle = "Loadout",
	})
	BuildKit.postSign(originCF * CFrame.new(44, 0, 40) * CFrame.Angles(0, math.rad(-90), 0), "STORES", model, {
		width = 12,
		height = 7,
		subtitle = "Liveries and supplies",
	})
	BuildKit.postSign(originCF * CFrame.new(30, 0, -34) * CFrame.Angles(0, math.rad(-90), 0), "CREW SHELTER", model, {
		width = 15,
		height = 7,
		subtitle = "Departures",
	})

	-- The departure road is marked, because the preview train sits on the
	-- siding beside it and the two need telling apart.
	BuildKit.postSign(originCF * CFrame.new(departureX + 14, 0, 110) * CFrame.Angles(0, math.rad(180), 0), "DEPARTURE ROAD", model, {
		width = 17,
		height = 6,
		subtitle = "Up main to the north",
		plate = C(44, 34, 30),
	})
	BuildKit.postSign(originCF * CFrame.new(departureX - 20, 0, 90) * CFrame.Angles(0, math.rad(180), 0), "NO. 2 SIDING", model, {
		width = 15,
		height = 6,
		subtitle = "Stabled stock",
		plate = C(44, 34, 30),
	})

	model:AddTag("Lobby")
	model.Parent = parent

	return {
		model = model,
		spawnCFrames = spawnCFrames,
		crewBoard = crewBoard,
		workshopBench = workshopBench,
		storesCounter = storesCounter,
		noticeBoard = noticeBoard,
		-- The preview road, where the selected train is displayed.
		trainPreviewCF = originCF * CFrame.new(departureX - 34, 0, 40) * CFrame.Angles(0, math.rad(180), 0),
		-- Where the expedition train sits before departure.
		departureCF = originCF * CFrame.new(departureX, 0, 60) * CFrame.Angles(0, math.rad(180), 0),
		lights = lights,
		partCount = BuildKit.countParts(model),
	}
end

return LobbyBuilder
