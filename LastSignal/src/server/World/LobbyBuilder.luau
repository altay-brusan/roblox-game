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
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local WeaponModels = require(ReplicatedStorage.LastSignal.Registry.WeaponModels)
local WeaponRegistry = require(ReplicatedStorage.LastSignal.Registry.WeaponRegistry)

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
	-- The yard service train runs along the departure road. At distance D its
	-- front coupler is at serviceOrigin * (0, 0, -D).
	serviceOrigin: CFrame,
	platformDistance: number,
	tunnelDistance: number,
	departurePost: BasePart,
	departureStatus: TextLabel,
	platformCFrame: CFrame,
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

	-- The Phantom Exchange terminal: an old platform ticket machine bolted
	-- beside the hatch. Nobody stands behind the counter; the machine answers.
	local terminalCF = cf * CFrame.new(size.X * 0.32, 0, -size.Z * 0.5 - 1.6)
	local terminal = BuildKit.part({
		name = "ExchangeTerminal",
		size = Vector3.new(2.6, 6.2, 1.6),
		cf = terminalCF * CFrame.new(0, 3.1, 0),
		colour = C(30, 32, 34),
		material = Enum.Material.Metal,
		parent = parent,
	})
	terminal:AddTag("StoresCounter")
	local screen = BuildKit.part({
		name = "ExchangeScreen",
		size = Vector3.new(1.9, 1.4, 0.1),
		cf = terminalCF * CFrame.new(0, 4.6, -0.82),
		colour = C(40, 120, 70),
		material = Enum.Material.Neon,
		parent = parent,
	})
	screen.Transparency = 0.2
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Front
	gui.PixelsPerStud = 60
	gui.LightInfluence = 0
	gui.Parent = screen
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundColor3 = C(6, 20, 12)
	label.TextColor3 = C(120, 255, 160)
	label.Font = Enum.Font.Code
	label.TextScaled = true
	label.Text = "PHANTOM EXCHANGE\nFARES TAKEN\nNO CHANGE GIVEN"
	label.Parent = gui
	BuildKit.detail({
		name = "IntercomGrille",
		size = Vector3.new(1.2, 0.8, 0.1),
		cf = terminalCF * CFrame.new(0, 3.2, -0.82),
		colour = C(70, 72, 70),
		material = Enum.Material.DiamondPlate,
		parent = parent,
	})
	BuildKit.detail({
		name = "FareSlot",
		size = Vector3.new(0.9, 0.12, 0.1),
		cf = terminalCF * CFrame.new(0, 2.2, -0.82),
		colour = C(176, 142, 74),
		material = Enum.Material.Metal,
		parent = parent,
	})
	local _, terminalLight = BuildKit.lamp(terminalCF * CFrame.new(0, 6.6, -0.6), "bulkhead", C(255, 70, 50), 0.8, 10, parent)
	table.insert(lights, terminalLight)
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

--------------------------------------------------------------------------
-- Armory rack
--------------------------------------------------------------------------

-- A wall-mounted rack beside the stores hatch with the three premium weapons
-- on it, built by the same code that builds them in your hands, so what is
-- on the wall is exactly what you would carry. The rack opens the armory.
local function buildArmory(cf: CFrame, parent: Instance, lights: { Light }): BasePart
	local board = BuildKit.part({
		name = "ArmoryBoard",
		size = Vector3.new(12, 8, 0.6),
		cf = cf * CFrame.new(0, 5.5, 0),
		colour = C(52, 46, 40),
		material = Enum.Material.WoodPlanks,
		parent = parent,
	})
	board:AddTag("ArmoryRack")
	for _, x in { -5.6, 5.6 } do
		BuildKit.part({
			name = "ArmoryPost",
			size = Vector3.new(0.6, 10, 0.6),
			cf = cf * CFrame.new(x, 5.0, 0.4),
			colour = C(40, 36, 32),
			material = Enum.Material.Wood,
			parent = parent,
		})
	end
	BuildKit.sign(cf * CFrame.new(0, 10.4, -0.35), 6, 1.2, "ARMORY", Enum.NormalId.Front, parent)
	local display = { "nightwatch_carbine", "arc_projector", "flare_launcher" }
	for i, id in display do
		local def = WeaponRegistry.get(id)
		if def then
			local built = WeaponModels.build(def, nil)
			built.model.Name = "Display_" .. id
			-- Shown flat on pegs, side on, a little larger than life so they
			-- read from across the yard.
			built.model:ScaleTo(1.3)
			built.root.Anchored = true
			built.model:PivotTo(cf * CFrame.new(-0.2, 9.9 - i * 2.2, -0.6) * CFrame.Angles(0, math.rad(90), 0))
			built.model.Parent = parent
			for _, x in { -1.6, 1.6 } do
				BuildKit.detail({
					name = "Peg",
					size = Vector3.new(0.15, 0.15, 0.5),
					cf = cf * CFrame.new(x, 9.5 - i * 2.2, -0.45),
					colour = C(150, 120, 64),
					material = Enum.Material.Metal,
					parent = parent,
				})
			end
		end
	end
	local _, light = BuildKit.lamp(cf * CFrame.new(0, 11.4, -1.0), "bulkhead", C(255, 226, 180), 1.1, 18, parent)
	table.insert(lights, light)
	return board
end

--------------------------------------------------------------------------
-- Platform 1
--------------------------------------------------------------------------

-- Where the 02:17 stands. The platform runs along the east side of the
-- departure road, directly in front of the spawn, so the first thing a new
-- player sees is a lit train with its doors open and a way up to it.
-- The platform edge sits just clear of the widest fixed part of the train
-- (locomotive handrails at 6.45), less than a stud from the carriage sides.
local PLATFORM_X = 12.7
local PLATFORM_WIDTH = 12
local PLATFORM_LENGTH = 190
local PLATFORM_TOP = 3.2

local function buildPlatform(originCF: CFrame, parent: Instance, lights: { Light }, rng: Random): (BasePart, TextLabel)
	local deckCF = originCF * CFrame.new(PLATFORM_X, 0, 0)
	BuildKit.part({
		name = "PlatformDeck",
		size = Vector3.new(PLATFORM_WIDTH, PLATFORM_TOP - 0.6, PLATFORM_LENGTH),
		cf = deckCF * CFrame.new(0, 0.6 + (PLATFORM_TOP - 0.6) * 0.5, 0),
		colour = C(118, 114, 106),
		material = Enum.Material.Concrete,
		parent = parent,
	})
	-- Coping stones and the painted safety line along the track edge.
	BuildKit.part({
		name = "PlatformCoping",
		size = Vector3.new(1.4, 0.3, PLATFORM_LENGTH),
		cf = deckCF * CFrame.new(-PLATFORM_WIDTH * 0.5 + 0.7, PLATFORM_TOP + 0.15, 0),
		colour = C(150, 146, 136),
		material = Enum.Material.Concrete,
		parent = parent,
	})
	BuildKit.detail({
		name = "SafetyLine",
		size = Vector3.new(0.5, 0.05, PLATFORM_LENGTH),
		cf = deckCF * CFrame.new(-PLATFORM_WIDTH * 0.5 + 2.2, PLATFORM_TOP + 0.02, 0),
		colour = C(214, 178, 62),
		material = Enum.Material.SmoothPlastic,
		parent = parent,
	})
	-- Wet patches on the deck catch the lamplight.
	for _ = 1, 8 do
		local size = rng:NextNumber(3, 7)
		BuildKit.detail({
			name = "Puddle",
			size = Vector3.new(size * 0.7, 0.04, size),
			cf = deckCF * CFrame.new(rng:NextNumber(-3, 4), PLATFORM_TOP + 0.03, rng:NextNumber(-85, 85)),
			colour = C(40, 44, 48),
			material = Enum.Material.Glass,
			transparency = 0.3,
			reflectance = 0.4,
			parent = parent,
		})
	end

	-- Ramps up from the yard, one directly in front of the spawn.
	for _, z in { -12, 52 } do
		local rampLength = 10
		BuildKit.wedge({
			name = "PlatformRamp",
			size = Vector3.new(8, PLATFORM_TOP - 0.6, rampLength),
			cf = deckCF
				* CFrame.new(PLATFORM_WIDTH * 0.5 + rampLength * 0.5, 0.6 + (PLATFORM_TOP - 0.6) * 0.5, z)
				* CFrame.Angles(0, math.rad(-90), 0),
			colour = C(110, 106, 98),
			material = Enum.Material.Concrete,
			parent = parent,
		})
		for _, side in { -1, 1 } do
			-- Posts at each end of the rail, so it stands rather than floats.
			for _, along in { 0.45, -0.45 } do
				BuildKit.detail({
					name = "RampRailPost",
					size = Vector3.new(0.2, 2.8, 0.2),
					cf = deckCF
						* CFrame.new(PLATFORM_WIDTH * 0.5 + rampLength * 0.5 + along * rampLength, 0.6 + (PLATFORM_TOP - 0.6) * (0.5 - along) + 1.4, z + side * 4.1),
					colour = C(150, 124, 52),
					material = Enum.Material.Metal,
					parent = parent,
				})
			end
			BuildKit.detail({
				name = "RampRail",
				size = Vector3.new(rampLength, 0.2, 0.2),
				cf = deckCF
					* CFrame.new(PLATFORM_WIDTH * 0.5 + rampLength * 0.5, 0.6 + (PLATFORM_TOP - 0.6) * 0.5 + 2.6, z + side * 4.1)
					* CFrame.Angles(0, 0, math.rad(-math.deg(math.atan2(PLATFORM_TOP - 0.6, rampLength)))),
				colour = C(170, 140, 58),
				material = Enum.Material.Metal,
				parent = parent,
			})
		end
	end

	-- Canopy over the middle of the platform: columns, a ribbed roof and
	-- pendant lamps.
	local canopyLength = 96
	local canopyHeight = PLATFORM_TOP + 10
	for i = 0, 8 do
		local z = -canopyLength * 0.5 + i * (canopyLength / 8)
		BuildKit.part({
			name = "CanopyColumn",
			size = Vector3.new(0.8, canopyHeight - PLATFORM_TOP, 0.8),
			cf = deckCF * CFrame.new(2.5, PLATFORM_TOP + (canopyHeight - PLATFORM_TOP) * 0.5, z),
			colour = C(52, 70, 62),
			material = Enum.Material.Metal,
			parent = parent,
		})
		BuildKit.detail({
			name = "CanopyBracket",
			size = Vector3.new(PLATFORM_WIDTH - 1, 0.5, 0.4),
			cf = deckCF * CFrame.new(-0.5, canopyHeight - 0.6, z),
			colour = C(52, 70, 62),
			material = Enum.Material.Metal,
			parent = parent,
		})
		if i % 2 == 0 then
			local _, light = BuildKit.lamp(deckCF * CFrame.new(-1, canopyHeight - 1.6, z), "pendant", C(255, 214, 160), 2.2, 34, parent)
			table.insert(lights, light)
		end
	end
	BuildKit.part({
		name = "CanopyRoof",
		size = Vector3.new(PLATFORM_WIDTH + 1, 0.5, canopyLength + 4),
		cf = deckCF * CFrame.new(-0.5, canopyHeight, 0) * CFrame.Angles(0, 0, math.rad(4)),
		colour = C(46, 52, 52),
		material = Enum.Material.Metal,
		parent = parent,
	})
	BuildKit.detail({
		name = "CanopyValance",
		size = Vector3.new(0.3, 1.4, canopyLength + 4),
		cf = deckCF * CFrame.new(-PLATFORM_WIDTH * 0.5 - 0.3, canopyHeight - 0.8, 0),
		colour = C(118, 92, 58),
		material = Enum.Material.WoodPlanks,
		parent = parent,
	})

	-- Lamp posts beyond the canopy, so the whole length of the train is lit.
	for _, z in { -80, -62, 62, 80 } do
		BuildKit.part({
			name = "PlatformLampPost",
			size = Vector3.new(0.5, 11, 0.5),
			cf = deckCF * CFrame.new(3.5, PLATFORM_TOP + 5.5, z),
			colour = C(52, 70, 62),
			material = Enum.Material.Metal,
			parent = parent,
		})
		local _, light = BuildKit.lamp(deckCF * CFrame.new(2.4, PLATFORM_TOP + 10.6, z), "pendant", C(255, 206, 150), 2.2, 38, parent)
		table.insert(lights, light)
	end

	-- Benches and a luggage barrow: the platform is a place people wait.
	for _, z in { -30, 18 } do
		BuildKit.part({
			name = "PlatformBenchSeat",
			size = Vector3.new(1.6, 0.3, 6),
			cf = deckCF * CFrame.new(4.2, PLATFORM_TOP + 1.5, z),
			colour = BuildKit.weather(P.planking, 0.04, rng),
			material = Enum.Material.WoodPlanks,
			parent = parent,
		})
		BuildKit.detail({
			name = "PlatformBenchBack",
			size = Vector3.new(0.3, 1.6, 6),
			cf = deckCF * CFrame.new(5, PLATFORM_TOP + 2.4, z),
			colour = BuildKit.weather(P.planking, 0.04, rng),
			material = Enum.Material.WoodPlanks,
			parent = parent,
		})
		for _, offset in { -2.6, 2.6 } do
			BuildKit.detail({
				name = "PlatformBenchLeg",
				size = Vector3.new(1.6, 1.4, 0.3),
				cf = deckCF * CFrame.new(4.2, PLATFORM_TOP + 0.7, z + offset),
				colour = C(40, 44, 42),
				material = Enum.Material.Metal,
				parent = parent,
			})
		end
	end
	BuildKit.part({
		name = "LuggageBarrow",
		size = Vector3.new(2.6, 0.4, 5),
		cf = deckCF * CFrame.new(3.6, PLATFORM_TOP + 1.2, 36),
		colour = C(92, 70, 50),
		material = Enum.Material.WoodPlanks,
		parent = parent,
	})
	for i = 0, 2 do
		BuildKit.part({
			name = "Suitcase",
			size = Vector3.new(1.8, 1.0, 2.4),
			cf = deckCF
				* CFrame.new(3.6, PLATFORM_TOP + 1.9 + i * 1.0, 35 + i * 0.6)
				* CFrame.Angles(0, math.rad(rng:NextNumber(-12, 12)), 0),
			colour = BuildKit.weather(C(86, 58, 44), 0.05, rng),
			material = Enum.Material.Leather,
			parent = parent,
		})
	end

	-- The departure board, hung from the canopy facing the yard. Its text is
	-- driven live by DepartureService.
	local board = BuildKit.part({
		name = "DepartureBoard",
		size = Vector3.new(0.4, 3.6, 12),
		cf = deckCF * CFrame.new(PLATFORM_WIDTH * 0.5 - 0.2, canopyHeight - 3, -6),
		colour = C(22, 24, 26),
		material = Enum.Material.Metal,
		parent = parent,
	})
	local gui = Instance.new("SurfaceGui")
	gui.Name = "BoardFace"
	gui.Face = Enum.NormalId.Right
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 40
	gui.LightInfluence = 0
	gui.Brightness = 2
	gui.Parent = board
	local heading = Instance.new("TextLabel")
	heading.Name = "Heading"
	heading.BackgroundTransparency = 1
	heading.Size = UDim2.fromScale(1, 0.42)
	heading.Text = "02:17  UP MAIN  -  WARD HILL"
	heading.FontFace = Font.fromEnum(Enum.Font.Code)
	heading.TextScaled = true
	heading.TextColor3 = C(255, 176, 64)
	heading.Parent = gui
	local status = Instance.new("TextLabel")
	status.Name = "Status"
	status.BackgroundTransparency = 1
	status.Position = UDim2.fromScale(0, 0.48)
	status.Size = UDim2.fromScale(1, 0.4)
	status.Text = "NOW BOARDING"
	status.FontFace = Font.fromEnum(Enum.Font.Code)
	status.TextScaled = true
	status.TextColor3 = C(255, 206, 120)
	status.Parent = gui

	-- The departure post: the same crew panel as the board in the shelter,
	-- right beside the train, at a height where its prompt is actually seen.
	-- A board on a pole, at eye height, so its label is whole and its
	-- prompt is in view of a player standing in front of it.
	BuildKit.part({
		name = "DeparturePole",
		size = Vector3.new(0.4, 6.2, 0.4),
		cf = deckCF * CFrame.new(2.2, PLATFORM_TOP + 3.1, -14),
		colour = C(52, 70, 62),
		material = Enum.Material.Metal,
		parent = parent,
	})
	local post = BuildKit.part({
		name = "DeparturePost",
		size = Vector3.new(0.35, 2.6, 4.2),
		cf = deckCF * CFrame.new(2.45, PLATFORM_TOP + 4.6, -14),
		colour = C(32, 44, 38),
		material = Enum.Material.Metal,
		parent = parent,
	})
	post:AddTag("CrewBoard")
	BuildKit.label(post, Enum.NormalId.Right, "DEPART", "Alone or with a crew")
	local _, postLight = BuildKit.lamp(deckCF * CFrame.new(3.2, PLATFORM_TOP + 5.2, -14), "bulkhead", C(255, 196, 120), 0.9, 12, parent)
	table.insert(lights, postLight)

	-- Platform nameboards at both ends, readable from the yard.
	for _, z in { -88, 88 } do
		BuildKit.postSign(deckCF * CFrame.new(4.5, PLATFORM_TOP, z) * CFrame.Angles(0, math.rad(90), 0), "PLATFORM 1", parent, {
			width = 12,
			height = 8,
			subtitle = "02:17 Up Main",
			plate = C(32, 44, 38),
		})
	end

	return post, status
end

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
		-- Long enough to carry the departure road from the south approach,
		-- where the next service appears, to the tunnel in the north.
		size = Vector3.new(520, 2, 1700),
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
	-- The departure road runs the full length of the yard: in from the south,
	-- past Platform 1, and north into the tunnel towards the line.
	BuildKit.trackSection(originCF * CFrame.new(departureX, 0, 820), 1560, model, rng)
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
	-- Facing the same way as the stores hatch, just past the hut's corner.
	buildArmory(originCF * CFrame.new(88, 0, 79) * CFrame.Angles(0, math.rad(-90), 0), model, lights)

	-- Water column by the departure road, the classic yard silhouette.
	do
		local columnCF = originCF * CFrame.new(departureX - 16, 0, 40)
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
			Vector3.new(-16, 0, 150),
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
		local clutterX = rng:NextNumber(-95, 95)
		-- Nothing is dumped on the departure road, the platform or its ramps.
		if clutterX > -12 and clutterX < 34 then
			clutterX += if clutterX < 11 then -26 else 26
		end
		local pos = originCF * CFrame.new(clutterX, 0, rng:NextNumber(-130, 130))
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
		-- Facing west, across the ramp to Platform 1 and the waiting train.
		spawnCFrames[i + 1] = originCF
			* CFrame.new(36 + math.cos(angle) * 5, 3, 8 + math.sin(angle) * 5)
			* CFrame.Angles(0, math.rad(90), 0)
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
	BuildKit.postSign(originCF * CFrame.new(46, 0, -72) * CFrame.Angles(0, math.rad(180), 0), "TOLBRIDGE YARD", model, {
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
	BuildKit.postSign(originCF * CFrame.new(44, 0, 40) * CFrame.Angles(0, math.rad(-90), 0), "PHANTOM EXCHANGE", model, {
		width = 16,
		height = 7,
		subtitle = "RIP Coin and Robux",
	})
	BuildKit.postSign(originCF * CFrame.new(30, 0, -34) * CFrame.Angles(0, math.rad(-90), 0), "CREW SHELTER", model, {
		width = 15,
		height = 7,
		subtitle = "Departures",
	})

	-- The departure road is marked, because the preview train sits on the
	-- siding beside it and the two need telling apart.
	BuildKit.postSign(originCF * CFrame.new(departureX + 22, 0, 110) * CFrame.Angles(0, math.rad(180), 0), "DEPARTURE ROAD", model, {
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

	-- Platform 1, and the tunnel the line leaves the yard through.
	local departurePost, departureStatus = buildPlatform(originCF, model, lights, rng)
	BuildKit.tunnel(originCF * CFrame.new(departureX, 0, -330) * CFrame.Angles(0, math.rad(180), 0), 300, model, rng)

	model:AddTag("Lobby")
	model.Parent = parent

	return {
		model = model,
		spawnCFrames = spawnCFrames,
		crewBoard = crewBoard,
		workshopBench = workshopBench,
		storesCounter = storesCounter,
		noticeBoard = noticeBoard,
		-- The next service appears out of sight to the south (distance 0), draws
		-- up with its consist along Platform 1, and swaps to the line once it is
		-- well inside the tunnel.
		serviceOrigin = originCF * CFrame.new(departureX, 0, 640),
		platformDistance = 716,
		tunnelDistance = 1090,
		departurePost = departurePost,
		departureStatus = departureStatus,
		platformCFrame = originCF * CFrame.new(PLATFORM_X + 2, PLATFORM_TOP + 3, 0) * CFrame.Angles(0, math.rad(-90), 0),
		lights = lights,
		partCount = BuildKit.countParts(model),
	}
end

return LobbyBuilder
