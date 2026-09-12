--!strict
--[[
	WorldService
	------------
	Owns every piece of built geometry and hands lanes out to expeditions.

	LANES
	-----
	In single-place mode the lobby and the expeditions share one server, so an
	expedition cannot simply be built at a fixed spot: two crews would occupy
	the same track. Instead the server holds a small number of lanes, each a
	complete 14,000 stud corridor of track, forest and stations, separated far
	enough along X that streaming never loads two at once.

	A lane is built once, the first time it is claimed, and then reused. Between
	expeditions its state is reset (loot restocked, doors closed, lights off,
	fixtures returned to their starting positions) rather than its geometry
	rebuilt, because rebuilding a forest takes seconds and resetting takes
	milliseconds.

	Building is incremental: the builders yield periodically so a lane coming
	online never stalls the server heartbeat, and the crew waiting for it sees
	real progress rather than a frozen loading screen.

	The honest limitation: the number of concurrent expeditions on one server is
	bounded by memory, and GameConfig.MaxConcurrentExpeditions is that bound.
	Two-place mode removes it entirely by giving each crew its own server.
]]

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.LastSignal

local GameConfig = require(Shared.Config.GameConfig)
local Logger = require(Shared.Core.Logger)
local Protect = require(Shared.Core.Protect)
local Signal = require(Shared.Core.Signal)
local StationRegistry = require(Shared.Registry.StationRegistry)
local ItemRegistry = require(Shared.Registry.ItemRegistry)
local BuildKit = require(script.Parent.Parent.World.BuildKit)
local ForestBuilder = require(script.Parent.Parent.World.ForestBuilder)
local LobbyBuilder = require(script.Parent.Parent.World.LobbyBuilder)
local StationBuilder = require(script.Parent.Parent.World.StationBuilder)
local TrainBuilder = require(script.Parent.Parent.World.TrainBuilder)
local TrainRegistry = require(Shared.Registry.TrainRegistry)

local log = Logger.new("WorldService")

local WorldService = {}

export type Lane = {
	index: number,
	origin: Vector3,
	root: Folder,
	built: boolean,
	building: boolean,
	claimedBy: string?, -- crew id
	stations: { StationBuilder.BuiltStation },
	track: Model?,
	forest: Model?,
	dropContainer: Folder,
	creatureContainer: Folder,
	trainContainer: Folder,
	partCount: number,
}

local lanes: { Lane } = {}
local lobby: LobbyBuilder.BuiltLobby? = nil
local previewTrain: TrainBuilder.BuiltTrain? = nil
local worldRoot: Folder? = nil

WorldService.LaneReady = Signal.new() :: Signal.Signal<Lane>
WorldService.BuildProgress = Signal.new() :: Signal.Signal<number, number, string>

--------------------------------------------------------------------------
-- Lobby
--------------------------------------------------------------------------

function WorldService.buildLobby(): LobbyBuilder.BuiltLobby
	if lobby then
		return lobby
	end
	local root = worldRoot :: Folder
	local started = os.clock()
	local built = LobbyBuilder.build(GameConfig.LobbyOrigin, root, 217)

	-- A ring of forest around the yard, so the lobby sits in the same world as
	-- the expedition rather than on a floating pad.
	ForestBuilder.populate({
		centre = GameConfig.LobbyOrigin,
		halfExtents = Vector2.new(320, 380),
		trackClearance = 150,
		clearings = { { position = GameConfig.LobbyOrigin, radius = 175 } },
		density = 4.0,
		seed = 991,
		parent = built.model,
	})

	-- The preview train on the near siding. The brief asks for a train preview
	-- in the lobby, and without one the first question every player asks is
	-- "where is the train", because the expedition train only exists inside a
	-- lane after departure.
	--
	-- It is the real TrainBuilder output, not a mock-up, so what you look at in
	-- the yard is exactly what you board.
	local previewOk, preview = pcall(function()
		return TrainBuilder.build(
			TrainRegistry.StarterTrainId,
			"livery_depot",
			"interior_standard",
			built.trainPreviewCF,
			built.model,
			991
		)
	end)

	if previewOk and preview then
		-- It must not carry the Train tag: the client ride controller resolves
		-- the train it is riding by that tag, and a stationary lobby train
		-- would be picked up instead of the real one.
		preview.model:RemoveTag("Train")
		preview.model:AddTag("PreviewTrain")
		preview.model.Name = "PreviewTrain"

		-- Lit, so it reads as a living object in a dark yard rather than a
		-- silhouette. Marker and tail lamps are already on from the builder.
		for _, spot in preview.headlights do
			spot.Enabled = true
		end
		for _, light in preview.cabinLights do
			light.Enabled = true
		end
		for _, light in preview.interiorLights do
			light.Enabled = true
		end
		-- Doors open, so a player can walk through it before they ever depart.
		for _, door in preview.doors do
			local closed = door.model:GetAttribute("ClosedCFrame")
			if typeof(closed) ~= "CFrame" then
				closed = door.hinge.CFrame
				door.model:SetAttribute("ClosedCFrame", closed)
			end
			door.model:PivotTo((closed :: CFrame) * CFrame.Angles(0, math.rad(105), 0))
		end

		previewTrain = preview
		log.info(string.format("lobby preview train built (%d parts)", preview.partCount))
	else
		log.error("lobby preview train failed to build:", tostring(preview))
	end

	lobby = built
	log.info(
		string.format(
			"lobby built in %.1fs (%d parts)",
			os.clock() - started,
			BuildKit.countParts(built.model)
		)
	)
	return built
end

function WorldService.getPreviewTrain(): TrainBuilder.BuiltTrain?
	return previewTrain
end

function WorldService.getLobby(): LobbyBuilder.BuiltLobby?
	return lobby
end

--------------------------------------------------------------------------
-- Lane construction
--------------------------------------------------------------------------

local function laneOrigin(index: number): Vector3
	return GameConfig.ExpeditionOrigin + Vector3.new((index - 1) * GameConfig.ExpeditionLaneSpacing, 0, 0)
end

--- Builds a lane incrementally. Yields between phases so the server keeps
--- ticking; the caller is expected to be a coroutine that can wait.
local function buildLane(lane: Lane, onProgress: (number, string) -> ())
	lane.building = true
	local started = os.clock()
	local origin = lane.origin

	onProgress(0.05, "Laying track")
	-- Track is laid in segments so a 14,000 stud line does not build in one
	-- uninterrupted burst.
	local trackModel = BuildKit.model("Track", lane.root)
	local segmentLength = 1000
	local segments = math.ceil(GameConfig.TrackLength / segmentLength)
	local rng = Random.new(4000 + lane.index)
	for i = 0, segments - 1 do
		local segment = BuildKit.trackSection(
			CFrame.new(origin + Vector3.new(0, 0, -i * segmentLength)),
			math.min(segmentLength, GameConfig.TrackLength - i * segmentLength),
			trackModel,
			rng
		)
		segment.Name = "TrackSegment" .. i
		if i % 2 == 1 then
			task.wait()
		end
		onProgress(0.05 + 0.2 * ((i + 1) / segments), "Laying track")
	end
	lane.track = trackModel

	onProgress(0.28, "Building stations")
	local clearings: { { position: Vector3, radius: number } } = {}
	for index, def in StationRegistry.Stations do
		local stationOrigin = StationRegistry.originFor(def, origin)
		local built = StationBuilder.build(def, CFrame.new(stationOrigin), lane.root, 7000 + lane.index * 100 + index)
		table.insert(lane.stations, built)
		table.insert(clearings, { position = stationOrigin, radius = def.layout.radius })
		task.wait()
		onProgress(0.28 + 0.27 * (index / #StationRegistry.Stations), "Building " .. def.name)
	end

	onProgress(0.56, "Growing the forest")
	-- The forest is the expensive phase. It is built in slices along the line
	-- so progress is honest and the server never blocks for more than a frame.
	local forestRoot = BuildKit.model("Forest", lane.root)
	local sliceLength = 2000
	local slices = math.ceil(GameConfig.TrackLength / sliceLength)
	for i = 0, slices - 1 do
		local sliceCentreZ = origin.Z - (i * sliceLength + sliceLength * 0.5)
		local sliceExtent = math.min(sliceLength, GameConfig.TrackLength - i * sliceLength) * 0.5
		ForestBuilder.populate({
			centre = Vector3.new(origin.X, origin.Y, sliceCentreZ),
			halfExtents = Vector2.new(GameConfig.ForestCorridorHalfWidth, sliceExtent),
			trackClearance = 30,
			clearings = clearings,
			density = GameConfig.ForestDensity,
			seed = 12000 + lane.index * 1000 + i,
			parent = forestRoot,
		})
		task.wait()
		onProgress(0.56 + 0.4 * ((i + 1) / slices), "Growing the forest")
	end
	lane.forest = forestRoot

	onProgress(0.98, "Final checks")
	lane.partCount = BuildKit.countParts(lane.root)
	lane.built = true
	lane.building = false

	log.info(
		string.format(
			"lane %d built in %.1fs (%d parts, %d stations)",
			lane.index,
			os.clock() - started,
			lane.partCount,
			#lane.stations
		)
	)
	onProgress(1, "Ready")
	WorldService.LaneReady:Fire(lane)
end

--------------------------------------------------------------------------
-- Lane state reset
--------------------------------------------------------------------------

--- Returns a lane to its starting condition without rebuilding geometry.
function WorldService.resetLane(lane: Lane)
	-- Clear anything spawned during the last run.
	lane.dropContainer:ClearAllChildren()
	lane.creatureContainer:ClearAllChildren()
	lane.trainContainer:ClearAllChildren()

	for _, station in lane.stations do
		-- Loot nodes become searchable again and their contents are re-rolled
		-- by ExpeditionService, so two runs never find the same layout.
		for _, node in station.lootNodes do
			node.part:SetAttribute("Searched", false)
		end
		-- Lights off: every station starts dark.
		for _, light in station.lights do
			light.Enabled = false
		end
		-- Doors closed and fixtures reset.
		for _, door in station.doors do
			local hinge = door.PrimaryPart
			if hinge then
				local baseCF = door:GetAttribute("ClosedCFrame")
				if typeof(baseCF) == "CFrame" then
					door:PivotTo(baseCF)
				end
			end
		end
		for _, fixture in station.fixtures do
			fixture:SetAttribute("State", "idle")
			fixture:SetAttribute("Progress", 0)
			fixture:SetAttribute("Powered", false)
		end
	end
end

--------------------------------------------------------------------------
-- Claiming
--------------------------------------------------------------------------

--- Claims a lane for a crew, building it if needed. Yields until ready.
--- Returns nil when every lane is occupied, which the lobby reports plainly.
function WorldService.claimLane(crewId: string, onProgress: ((number, string) -> ())?): Lane?
	local progress: (number, string) -> () = onProgress or function() end

	-- Prefer an already-built free lane, so a crew that can start immediately
	-- does not wait for a fresh build.
	local candidate: Lane? = nil
	for _, lane in lanes do
		if not lane.claimedBy and lane.built and not lane.building then
			candidate = lane
			break
		end
	end
	if not candidate then
		for _, lane in lanes do
			if not lane.claimedBy and not lane.building then
				candidate = lane
				break
			end
		end
	end
	if not candidate then
		return nil
	end

	local lane = candidate :: Lane
	lane.claimedBy = crewId

	if not lane.built then
		local ok, err = Protect.call(buildLane, lane, function(fraction: number, label: string)
			progress(fraction, label)
			WorldService.BuildProgress:Fire(lane.index, fraction, label)
		end)
		if not ok then
			log.error(string.format("lane %d build failed: %s", lane.index, tostring(err)))
			lane.building = false
			lane.claimedBy = nil
			return nil
		end
	else
		progress(0.5, "Preparing the line")
		WorldService.resetLane(lane)
		task.wait()
		progress(1, "Ready")
	end

	return lane
end

function WorldService.releaseLane(lane: Lane)
	lane.claimedBy = nil
	WorldService.resetLane(lane)
	log.info(string.format("lane %d released", lane.index))
end

function WorldService.laneFor(crewId: string): Lane?
	for _, lane in lanes do
		if lane.claimedBy == crewId then
			return lane
		end
	end
	return nil
end

function WorldService.availableLanes(): number
	local free = 0
	for _, lane in lanes do
		if not lane.claimedBy then
			free += 1
		end
	end
	return free
end

--------------------------------------------------------------------------
-- Dropped items
--------------------------------------------------------------------------

--- Builds a physical dropped item from its registry model spec. Dropped
--- objects use real geometry, not a generic box with a label.
function WorldService.buildDroppedItem(itemId: string, quantity: number, cf: CFrame, parent: Instance): Instance?
	local def = ItemRegistry.get(itemId)
	if not def then
		return nil
	end

	local model = BuildKit.model("Dropped_" .. itemId, nil)
	local spec = def.model
	local root: BasePart

	local shape = spec.shape
	if shape == "cylinder" or shape == "vial" or shape == "bottle" or shape == "roll" then
		root = BuildKit.cylinder({
			name = "Body",
			size = Vector3.new(spec.size.Y, spec.size.X, spec.size.Z),
			cf = cf * CFrame.Angles(0, 0, math.rad(90)),
			colour = spec.colour,
			material = spec.material,
			parent = model,
		})
	elseif shape == "jerrycan" then
		root = BuildKit.part({
			name = "Body",
			size = spec.size,
			cf = cf,
			colour = spec.colour,
			material = spec.material,
			parent = model,
		})
		-- Spout and handle, so a jerry can reads as one at a glance.
		BuildKit.detail({
			name = "Spout",
			size = Vector3.new(0.18, 0.3, 0.18),
			cf = cf * CFrame.new(spec.size.X * 0.3, spec.size.Y * 0.55, 0),
			colour = spec.accent or spec.colour,
			material = Enum.Material.Metal,
			parent = model,
		})
		BuildKit.detail({
			name = "Handle",
			size = Vector3.new(spec.size.X * 0.7, 0.12, 0.12),
			cf = cf * CFrame.new(0, spec.size.Y * 0.58, 0),
			colour = spec.accent or spec.colour,
			material = Enum.Material.Metal,
			parent = model,
		})
	elseif shape == "case" then
		root = BuildKit.part({
			name = "Body",
			size = spec.size,
			cf = cf,
			colour = spec.colour,
			material = spec.material,
			parent = model,
		})
		BuildKit.detail({
			name = "Latch",
			size = Vector3.new(0.12, 0.18, spec.size.Z * 0.35),
			cf = cf * CFrame.new(spec.size.X * 0.5, 0, 0),
			colour = spec.accent or Color3.fromRGB(180, 180, 180),
			material = Enum.Material.Metal,
			parent = model,
		})
		BuildKit.detail({
			name = "Marking",
			size = Vector3.new(spec.size.X * 0.5, 0.05, spec.size.Z * 0.5),
			cf = cf * CFrame.new(0, spec.size.Y * 0.5, 0),
			colour = spec.accent or Color3.fromRGB(240, 240, 240),
			material = Enum.Material.SmoothPlastic,
			parent = model,
		})
	elseif shape == "page" then
		root = BuildKit.part({
			name = "Body",
			size = spec.size,
			cf = cf * CFrame.Angles(0, math.rad(math.random(0, 180)), 0),
			colour = spec.colour,
			material = spec.material,
			parent = model,
		})
	else
		root = BuildKit.part({
			name = "Body",
			size = spec.size,
			cf = cf,
			colour = spec.colour,
			material = spec.material,
			parent = model,
		})
		if spec.accent then
			BuildKit.detail({
				name = "Accent",
				size = Vector3.new(spec.size.X * 1.02, spec.size.Y * 0.25, spec.size.Z * 1.02),
				cf = cf * CFrame.new(0, spec.size.Y * 0.3, 0),
				colour = spec.accent,
				material = spec.material,
				parent = model,
			})
		end
	end

	if spec.emissive and spec.emissive > 0 then
		local glow = Instance.new("PointLight")
		glow.Color = spec.accent or spec.colour
		glow.Brightness = spec.emissive * 3
		glow.Range = 12
		glow.Parent = root
	end

	model.PrimaryPart = root
	BuildKit.weldAssembly(model, root)
	root.Name = "Body"
	model:SetAttribute("ItemId", itemId)
	model:SetAttribute("Quantity", quantity)
	model:AddTag("DroppedItem")
	model.Parent = parent
	return model
end

--------------------------------------------------------------------------

function WorldService.start()
	local root = Instance.new("Folder")
	root.Name = "LastSignalWorld"
	root.Parent = Workspace
	worldRoot = root

	-- Remove the default baseplate and spawn if the place still has them, so
	-- the built world is what the player actually stands on.
	for _, name in { "Baseplate", "SpawnLocation" } do
		local existing = Workspace:FindFirstChild(name)
		if existing then
			existing:Destroy()
		end
	end

	WorldService.buildLobby()

	for index = 1, GameConfig.MaxConcurrentExpeditions do
		local laneRoot = Instance.new("Folder")
		laneRoot.Name = "Lane" .. index
		laneRoot.Parent = root

		local drops = Instance.new("Folder")
		drops.Name = "Drops"
		drops.Parent = laneRoot

		local creatures = Instance.new("Folder")
		creatures.Name = "Creatures"
		creatures.Parent = laneRoot

		local trains = Instance.new("Folder")
		trains.Name = "Trains"
		trains.Parent = laneRoot

		table.insert(lanes, {
			index = index,
			origin = laneOrigin(index),
			root = laneRoot,
			built = false,
			building = false,
			claimedBy = nil,
			stations = {},
			dropContainer = drops,
			creatureContainer = creatures,
			trainContainer = trains,
			partCount = 0,
		})
	end

	-- Pre-build the first lane in the background so the first crew of the
	-- server departs without a long wait. Later lanes build on demand.
	task.spawn(function()
		task.wait(2)
		local first = lanes[1]
		if first and not first.built and not first.building and not first.claimedBy then
			log.info("pre-building lane 1")
			local ok, err = Protect.call(buildLane, first, function() end)
			if not ok then
				log.error("pre-build failed:", tostring(err))
				first.building = false
			end
		end
	end)

	log.info(string.format("started with %d lane(s)", #lanes))
end

function WorldService.status(): { lanes: { { index: number, built: boolean, claimed: boolean, parts: number } }, lobbyParts: number }
	local out = {}
	for _, lane in lanes do
		table.insert(out, {
			index = lane.index,
			built = lane.built,
			claimed = lane.claimedBy ~= nil,
			parts = lane.partCount,
		})
	end
	return {
		lanes = out,
		lobbyParts = if lobby then lobby.partCount else 0,
	}
end

return WorldService
