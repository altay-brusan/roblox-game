--!strict
--[[
	StationRegistry
	---------------
	Chapter One: The Long Grade. Five stops, in order, each with its own layout,
	objective shape, environmental story and threat profile.

	The rule that shaped this file: no two stops ask for the same verb. Fetching
	is the tutorial, and after that every stop asks for something structurally
	different, because "collect four things" repeated five times is the failure
	mode the brief calls out.

	  1  Marrow Halt          restore power     (sequence: find, fuel, start, throw)
	  2  Tolbridge Camp       cooperate         (two separated levers, held together)
	  3  Ninety-Three Tower   communicate       (one reads, others act, on radio)
	  4  Hallow Bridge        repair under time (fetch a part, fit it, hold the area)
	  5  Ward Hill Relay      converge          (three sub-tasks, then the ending)

	`layout` blocks are consumed by the station builders in server/World. Sizes
	are in studs and every interior listed here is actually built and enterable.
]]

local TableUtil = require(script.Parent.Parent.Core.TableUtil)

--- One step of a "sequence" objective. Fields are optional because each step
--- kind uses a different subset; ExpeditionService validates per kind.
export type StepDef = {
	id: string,
	text: string,
	kind: string,
	item: string?,
	quantity: number?,
	fixture: string?,
	seconds: number?,
	needsFuel: boolean?,
	allowAbandon: boolean?,
}

export type ObjectiveKind =
	"collect" -- gather N of an item
	| "deliver" -- bring an item to a specific station fixture
	| "operate" -- use a fixture, possibly with a prerequisite
	| "sequence" -- ordered sub-steps
	| "simultaneous" -- two or more fixtures held at once by different players
	| "relay" -- one player reads a value, another enters it
	| "defend" -- survive at a location for a duration
	| "escort" -- move an object along a path

export type ObjectiveDef = {
	id: string,
	kind: ObjectiveKind,
	title: string, -- shown in the corner objective panel, kept under 48 chars
	detail: string, -- one line of extra context on the objective panel
	optional: boolean,
	-- Interpreted per kind. Quantities scale by crew size via Balance.
	params: { [string]: any },
	-- Credits and XP on completion, before multipliers.
	credits: number,
	xp: number,
	-- Objectives that must be done first.
	requires: { string }?,
}

export type LootNode = {
	kind: string, -- "locker" | "crate" | "shelf" | "body" | "cabinet" | "toolboard"
	position: Vector3, -- relative to the station origin
	rotation: number, -- degrees about Y
	tier: number,
	rolls: number,
	-- Guaranteed contents, always spawned in addition to the random rolls.
	guaranteed: { string }?,
}

export type BuildingSpec = {
	id: string,
	kind: string, -- interpreted by the station builder
	position: Vector3,
	rotation: number,
	size: Vector3,
	-- Buildings flagged interior get a real enterable inside with its own
	-- lighting, props and at least two ways in.
	interior: boolean,
	entrances: number,
	storey: number?,
}

export type FixtureSpec = {
	id: string,
	kind: string, -- "generator" | "breaker" | "fusebox" | "lever" | "frame" | ...
	position: Vector3,
	rotation: number,
	-- Links this fixture to an objective step.
	objective: string?,
	step: string?,
}

export type StationDef = {
	id: string,
	index: number,
	name: string,
	subtitle: string,
	-- Distance along the track from the expedition origin, in studs.
	distance: number,
	-- Platform side the train doors open onto.
	platformSide: "left" | "right",
	-- Environmental story: what happened here, told through the build and the
	-- optional records rather than through a cutscene.
	story: string,
	-- One line the dispatcher says on approach.
	approachLine: string,
	-- Threat profile at this stop.
	threat: {
		baseline: number,
		escalation: number, -- added to the director's band pressure
		creatureActive: boolean,
		mimicryEnabled: boolean,
		-- A scripted beat that fires once, at a specific objective step.
		scriptedBeat: string?,
	},
	layout: {
		radius: number, -- clearing radius carved from the forest
		buildings: { BuildingSpec },
		fixtures: { FixtureSpec },
		lootNodes: { LootNode },
		-- Named landmarks the radio and the objective panel can refer to, so
		-- directions are always speakable: "the water tower", not "grid 4".
		landmarks: { { id: string, name: string, position: Vector3 } },
	},
	objectives: { ObjectiveDef },
	-- Optional discoveries. None are required; all give credits and story.
	discoveries: { { id: string, name: string, position: Vector3, hint: string } },
	-- Expected time on station for a crew of three, used by the pacing director.
	expectedSeconds: number,
}

local V = Vector3.new

local function station(def: StationDef): StationDef
	return def
end

--------------------------------------------------------------------------

local STATIONS: { StationDef } = {

	----------------------------------------------------------------------
	-- 1. MARROW HALT
	----------------------------------------------------------------------
	station({
		id = "marrow_halt",
		index = 1,
		name = "Marrow Halt",
		subtitle = "Rural stopping place, two platforms, no staff",
		distance = 1750,
		platformSide = "right",
		story = "A request stop that served three farms and a quarry. The evacuation came through here first and took the rolling stock with it. Somebody stacked the waiting room furniture against the door from the inside, then left through the window.",
		approachLine = "Marrow Halt ahead. Board is dark, so you will be doing it by hand. Fuel point is at the far end of the down platform.",
		threat = {
			baseline = 6,
			escalation = 0,
			creatureActive = false,
			mimicryEnabled = false,
			scriptedBeat = "first_call", -- a single distant call as you finish
		},
		layout = {
			radius = 300,
			buildings = {
				{ id = "station_house", kind = "station_building", position = V(34, 0, 0), rotation = 0, size = V(30, 16, 54), interior = true, entrances = 3 },
				{ id = "waiting_room", kind = "shelter", position = V(34, 0, -76), rotation = 0, size = V(16, 11, 22), interior = true, entrances = 2 },
				{ id = "goods_shed", kind = "shed", position = V(66, 0, 92), rotation = 12, size = V(34, 18, 44), interior = true, entrances = 2 },
				{ id = "signal_hut", kind = "hut", position = V(-40, 0, 118), rotation = -8, size = V(14, 13, 16), interior = true, entrances = 1 },
				{ id = "water_tower", kind = "water_tower", position = V(-58, 0, -104), rotation = 0, size = V(20, 42, 20), interior = false, entrances = 0 },
				{ id = "platform_up", kind = "platform", position = V(-22, 0, 0), rotation = 0, size = V(14, 3, 210), interior = false, entrances = 0 },
				{ id = "platform_down", kind = "platform", position = V(22, 0, 0), rotation = 0, size = V(14, 3, 210), interior = false, entrances = 0 },
			},
			fixtures = {
				{ id = "generator", kind = "generator", position = V(60, 0, 96), rotation = 90, objective = "restore_power", step = "start_generator" },
				{ id = "fusebox", kind = "fusebox", position = V(38, 0, 14), rotation = 180, objective = "restore_power", step = "fit_fuse" },
				{ id = "breaker", kind = "breaker", position = V(38, 0, 22), rotation = 180, objective = "restore_power", step = "throw_breaker" },
				{ id = "fuel_point", kind = "fuel_point", position = V(20, 0, -96), rotation = 270, objective = "refuel", step = "refuel" },
			},
			lootNodes = {
				{ kind = "locker", position = V(30, 0, 8), rotation = 0, tier = 1, rolls = 2, guaranteed = { "battery" } },
				{ kind = "cabinet", position = V(40, 0, -6), rotation = 180, tier = 1, rolls = 2 },
				{ kind = "shelf", position = V(64, 0, 84), rotation = 0, tier = 1, rolls = 3, guaranteed = { "fusebox_fuse" } },
				{ kind = "crate", position = V(70, 0, 100), rotation = 30, tier = 1, rolls = 2, guaranteed = { "fuel_can" } },
				{ kind = "crate", position = V(62, 0, 108), rotation = -20, tier = 1, rolls = 2 },
				{ kind = "toolboard", position = V(-38, 0, 116), rotation = 90, tier = 2, rolls = 1, guaranteed = { "wrench" } },
				{ kind = "locker", position = V(36, 0, -74), rotation = 0, tier = 1, rolls = 2, guaranteed = { "bandage" } },
				{ kind = "body", position = V(-52, 0, -98), rotation = 0, tier = 2, rolls = 2, guaranteed = { "dispatch_log" } },
			},
			landmarks = {
				{ id = "water_tower", name = "the water tower", position = V(-58, 0, -104) },
				{ id = "goods_shed", name = "the goods shed", position = V(66, 0, 92) },
				{ id = "station_house", name = "the station house", position = V(34, 0, 0) },
				{ id = "fuel_point", name = "the fuel point", position = V(20, 0, -96) },
			},
		},
		objectives = {
			{
				id = "restore_power",
				kind = "sequence",
				title = "Restore power to the halt",
				detail = "The generator is in the goods shed. The board is in the station house.",
				optional = false,
				params = {
					steps = {
						{ id = "find_fuse", text = "Find a ceramic fuse", kind = "collect", item = "fusebox_fuse", quantity = 1 },
						{ id = "fit_fuse", text = "Fit the fuse to the board", kind = "operate", fixture = "fusebox", seconds = 3 },
						{ id = "start_generator", text = "Start the generator", kind = "operate", fixture = "generator", seconds = 5, needsFuel = true },
						{ id = "throw_breaker", text = "Throw the main breaker", kind = "operate", fixture = "breaker", seconds = 2 },
					} :: { StepDef },
				},
				credits = 120,
				xp = 90,
			},
			{
				id = "refuel",
				kind = "deliver",
				title = "Refuel the locomotive",
				detail = "The fuel point only works once the halt has power.",
				optional = false,
				params = { fixture = "fuel_point", targetFuel = 85, requiresPower = true },
				credits = 90,
				xp = 70,
				requires = { "restore_power" },
			},
			{
				id = "supplies_marrow",
				kind = "collect",
				title = "Gather what you can carry",
				detail = "Anything you leave behind stays behind.",
				optional = true,
				params = { anyItems = true, quantity = 6 },
				credits = 65,
				xp = 45,
			},
		},
		discoveries = {
			{ id = "barricade", name = "The barricade", position = V(34, 0, -76), hint = "Somebody built this from the inside." },
			{ id = "quarry_ledger", name = "Quarry ledger", position = V(66, 0, 92), hint = "Last entry is four days before the collapse." },
		},
		expectedSeconds = 300,
	}),

	----------------------------------------------------------------------
	-- 2. TOLBRIDGE LOGGING CAMP
	----------------------------------------------------------------------
	station({
		id = "tolbridge_camp",
		index = 2,
		name = "Tolbridge Camp",
		subtitle = "Forestry loading point, private siding",
		distance = 4200,
		platformSide = "left",
		story = "A working camp until the line closed. The loader is still parked across the running line with a full grab of timber, because whoever was driving it left in the middle of a lift. Clearing it needs two people at opposite ends of the yard.",
		approachLine = "Tolbridge. There is a loader fouling the line. You will need the yard interlock released at both ends before it will move, and that means splitting up.",
		threat = {
			baseline = 18,
			escalation = 1,
			creatureActive = true,
			mimicryEnabled = false,
			scriptedBeat = "first_sighting", -- silhouette across the log stacks
		},
		layout = {
			radius = 380,
			buildings = {
				{ id = "camp_office", kind = "cabin", position = V(-70, 0, -40), rotation = 22, size = V(26, 14, 32), interior = true, entrances = 2 },
				{ id = "bunkhouse", kind = "cabin", position = V(-96, 0, 26), rotation = -14, size = V(22, 13, 46), interior = true, entrances = 2 },
				{ id = "sawshed", kind = "shed", position = V(-52, 0, 96), rotation = 0, size = V(44, 20, 60), interior = true, entrances = 3 },
				{ id = "loader", kind = "loader", position = V(0, 0, 30), rotation = 74, size = V(18, 22, 34), interior = false, entrances = 0 },
				{ id = "log_stacks_a", kind = "log_stack", position = V(-34, 0, -110), rotation = 6, size = V(30, 14, 70), interior = false, entrances = 0 },
				{ id = "log_stacks_b", kind = "log_stack", position = V(40, 0, 128), rotation = -10, size = V(26, 12, 62), interior = false, entrances = 0 },
				{ id = "fuel_store", kind = "hut", position = V(52, 0, -72), rotation = 180, size = V(16, 12, 18), interior = true, entrances = 1 },
			},
			fixtures = {
				{ id = "interlock_north", kind = "lever", position = V(-16, 0, -128), rotation = 0, objective = "clear_line", step = "hold_north" },
				{ id = "interlock_south", kind = "lever", position = V(18, 0, 150), rotation = 180, objective = "clear_line", step = "hold_south" },
				{ id = "loader_controls", kind = "controls", position = V(6, 0, 30), rotation = 74, objective = "clear_line", step = "move_loader" },
			},
			lootNodes = {
				{ kind = "toolboard", position = V(-50, 0, 92), rotation = 0, tier = 2, rolls = 2, guaranteed = { "axe" } },
				{ kind = "crate", position = V(-48, 0, 104), rotation = 15, tier = 1, rolls = 3 },
				{ kind = "crate", position = V(50, 0, -68), rotation = 180, tier = 1, rolls = 2, guaranteed = { "fuel_can" } },
				{ kind = "crate", position = V(56, 0, -76), rotation = 180, tier = 1, rolls = 2, guaranteed = { "fuel_can" } },
				{ kind = "locker", position = V(-94, 0, 20), rotation = -14, tier = 1, rolls = 3, guaranteed = { "medkit" } },
				{ kind = "cabinet", position = V(-68, 0, -44), rotation = 22, tier = 2, rolls = 2, guaranteed = { "repair_kit" } },
				{ kind = "shelf", position = V(-72, 0, -34), rotation = 22, tier = 1, rolls = 2, guaranteed = { "dispatch_log" } },
				{ kind = "body", position = V(-30, 0, -104), rotation = 0, tier = 2, rolls = 2, guaranteed = { "ammo_shell" } },
				{ kind = "crate", position = V(38, 0, 122), rotation = -10, tier = 2, rolls = 2 },
			},
			landmarks = {
				{ id = "loader", name = "the loader", position = V(0, 0, 30) },
				{ id = "sawshed", name = "the saw shed", position = V(-52, 0, 96) },
				{ id = "north_interlock", name = "the north interlock", position = V(-16, 0, -128) },
				{ id = "south_interlock", name = "the south interlock", position = V(18, 0, 150) },
				{ id = "bunkhouse", name = "the bunkhouse", position = V(-96, 0, 26) },
			},
		},
		objectives = {
			{
				id = "clear_line",
				kind = "simultaneous",
				title = "Clear the loader off the line",
				detail = "Both interlocks must be held at once, then the loader can be driven clear.",
				optional = false,
				params = {
					holdFixtures = { "interlock_north", "interlock_south" },
					holdSeconds = 6,
					-- Solo players get a timed lever: pull one, sprint to the other.
					soloTimerSeconds = 34,
					thenFixture = "loader_controls",
					thenSeconds = 8,
				},
				credits = 150,
				xp = 110,
			},
			{
				id = "camp_fuel",
				kind = "collect",
				title = "Take on fuel from the camp store",
				detail = "Two cans are in the fuel store by the south gate.",
				optional = false,
				params = { item = "fuel_can", quantity = 2, deliverTo = "train_fuel_point" },
				credits = 100,
				xp = 75,
			},
			{
				id = "bunkhouse_search",
				kind = "collect",
				title = "Search the bunkhouse",
				detail = "The crews left in a hurry. Their kit is still here.",
				optional = true,
				params = { anyItems = true, quantity = 4, area = "bunkhouse" },
				credits = 65,
				xp = 45,
			},
		},
		discoveries = {
			{ id = "unfinished_lift", name = "The unfinished lift", position = V(0, 0, 30), hint = "The grab is still full." },
			{ id = "camp_radio", name = "Camp radio set", position = V(-70, 0, -40), hint = "Tuned to a frequency that is not the dispatcher's." },
			{ id = "marked_trees", name = "Marked trees", position = V(40, 0, 128), hint = "Someone painted these from the wrong side." },
		},
		expectedSeconds = 420,
	}),

	----------------------------------------------------------------------
	-- 3. NINETY-THREE SIGNAL TOWER
	----------------------------------------------------------------------
	station({
		id = "tower_93",
		index = 3,
		name = "Ninety-Three",
		subtitle = "Interlocking tower and lineside cabin",
		distance = 7100,
		platformSide = "right",
		story = "A mechanical interlocking tower, still working, still requiring a person in it. The frame will not release the section ahead until the ground levers match the code chalked on the tower's diagram board, and the diagram board cannot be read from the ground.",
		approachLine = "Ninety-Three. The section ahead is locked out. Someone gets up in the tower and reads the frame, everyone else works the ground levers. Say the numbers out loud.",
		threat = {
			baseline = 32,
			escalation = 2,
			creatureActive = true,
			mimicryEnabled = true, -- the radio starts lying here
			scriptedBeat = "false_dispatcher",
		},
		layout = {
			radius = 340,
			buildings = {
				{ id = "tower", kind = "signal_tower", position = V(-38, 0, 0), rotation = 0, size = V(22, 46, 26), interior = true, entrances = 2, storey = 3 },
				{ id = "cabin", kind = "hut", position = V(36, 0, -58), rotation = 180, size = V(18, 13, 22), interior = true, entrances = 2 },
				{ id = "relay_room", kind = "shed", position = V(44, 0, 44), rotation = 0, size = V(22, 14, 28), interior = true, entrances = 2 },
				{ id = "platform", kind = "platform", position = V(20, 0, 0), rotation = 0, size = V(12, 3, 160), interior = false, entrances = 0 },
				{ id = "gantry", kind = "signal_gantry", position = V(0, 0, 140), rotation = 0, size = V(60, 36, 8), interior = false, entrances = 0 },
			},
			fixtures = {
				{ id = "frame", kind = "interlocking_frame", position = V(-38, 30, 0), rotation = 0, objective = "release_section", step = "read_frame" },
				{ id = "ground_lever_1", kind = "lever", position = V(4, 0, -90), rotation = 0, objective = "release_section", step = "set_levers" },
				{ id = "ground_lever_2", kind = "lever", position = V(4, 0, -40), rotation = 0, objective = "release_section", step = "set_levers" },
				{ id = "ground_lever_3", kind = "lever", position = V(4, 0, 40), rotation = 0, objective = "release_section", step = "set_levers" },
				{ id = "ground_lever_4", kind = "lever", position = V(4, 0, 90), rotation = 0, objective = "release_section", step = "set_levers" },
				{ id = "relay_bay", kind = "relay_bay", position = V(44, 0, 40), rotation = 0, objective = "replace_relay", step = "fit_relay" },
			},
			lootNodes = {
				{ kind = "cabinet", position = V(-36, 0, 6), rotation = 0, tier = 2, rolls = 2, guaranteed = { "signal_key" } },
				{ kind = "shelf", position = V(-40, 15, -4), rotation = 0, tier = 2, rolls = 2, guaranteed = { "dispatch_log" } },
				{ kind = "locker", position = V(34, 0, -54), rotation = 180, tier = 2, rolls = 3, guaranteed = { "battery", "battery" } },
				{ kind = "crate", position = V(46, 0, 48), rotation = 0, tier = 3, rolls = 2, guaranteed = { "relay" } },
				{ kind = "toolboard", position = V(42, 0, 38), rotation = 90, tier = 2, rolls = 2 },
				{ kind = "body", position = V(-30, 0, 120), rotation = 0, tier = 3, rolls = 2, guaranteed = { "recorder", "ammo_pistol" } },
			},
			landmarks = {
				{ id = "tower", name = "the tower", position = V(-38, 0, 0) },
				{ id = "gantry", name = "the signal gantry", position = V(0, 0, 140) },
				{ id = "relay_room", name = "the relay room", position = V(44, 0, 44) },
				{ id = "cabin", name = "the lineside cabin", position = V(36, 0, -58) },
			},
		},
		objectives = {
			{
				id = "replace_relay",
				kind = "deliver",
				title = "Replace the failed relay",
				detail = "The relay room is across the running line. Look both ways; the line is not as dead as it looks.",
				optional = false,
				params = { item = "relay", fixture = "relay_bay", seconds = 6 },
				credits = 120,
				xp = 95,
			},
			{
				id = "release_section",
				kind = "relay",
				title = "Release the section ahead",
				detail = "Read the frame in the tower, set the four ground levers to match.",
				optional = false,
				params = {
					readerFixture = "frame",
					-- Four levers, each with three positions. The code is generated
					-- per expedition so it cannot be memorised between runs.
					leverFixtures = { "ground_lever_1", "ground_lever_2", "ground_lever_3", "ground_lever_4" },
					positions = 3,
					-- Solo: the frame prints a paper slip you can carry down.
					soloPrintsSlip = true,
					-- Wrong combinations are recoverable, but they make noise.
					wrongAttemptNoise = 12,
				},
				credits = 180,
				xp = 140,
				requires = { "replace_relay" },
			},
			{
				id = "tower_records",
				kind = "collect",
				title = "Recover the tower records",
				detail = "Three logbooks, one on each floor.",
				optional = true,
				params = { item = "dispatch_log", quantity = 3, area = "tower" },
				credits = 70,
				xp = 55,
			},
		},
		discoveries = {
			{ id = "chalk_board", name = "The diagram board", position = V(-38, 30, 0), hint = "Someone has been keeping it up to date. Recently." },
			{ id = "second_voice", name = "Tape in the cabin", position = V(36, 0, -58), hint = "Two voices. One of them is yours." },
			{ id = "gantry_climb", name = "The gantry ladder", position = V(0, 0, 140), hint = "You can get up there, if you want to." },
		},
		expectedSeconds = 480,
	}),

	----------------------------------------------------------------------
	-- 4. HALLOW BRIDGE
	----------------------------------------------------------------------
	station({
		id = "hallow_bridge",
		index = 4,
		name = "Hallow Bridge",
		subtitle = "Lifting span over the Hallow, permanent way depot",
		distance = 10400,
		platformSide = "left",
		story = "A lifting span, raised for river traffic that stopped running years ago, and never lowered. The hydraulics failed with the span up. The depot on the near bank has exactly one spare valve, and fitting it means standing in the open on the bank for four minutes while the pumps prime.",
		approachLine = "Hallow Bridge. Span is up and the hydraulics are dead. There is a spare valve in the depot stores. Once the pumps start, do not let anything stop them.",
		threat = {
			baseline = 48,
			escalation = 3,
			creatureActive = true,
			mimicryEnabled = true,
			scriptedBeat = "bridge_siege",
		},
		layout = {
			radius = 420,
			buildings = {
				{ id = "depot", kind = "depot", position = V(-64, 0, -70), rotation = 0, size = V(52, 24, 76), interior = true, entrances = 3 },
				{ id = "stores", kind = "shed", position = V(-58, 0, 16), rotation = 0, size = V(24, 15, 30), interior = true, entrances = 2 },
				{ id = "pump_house", kind = "pump_house", position = V(46, 0, 96), rotation = 0, size = V(26, 18, 30), interior = true, entrances = 2 },
				{ id = "bridge", kind = "lift_bridge", position = V(0, 0, 230), rotation = 0, size = V(46, 70, 220), interior = false, entrances = 0 },
				{ id = "bank_walkway", kind = "walkway", position = V(26, 0, 150), rotation = 0, size = V(8, 4, 120), interior = false, entrances = 0 },
				{ id = "crew_hut", kind = "hut", position = V(-30, 0, 110), rotation = 20, size = V(15, 12, 18), interior = true, entrances = 1 },
			},
			fixtures = {
				{ id = "valve_store", kind = "stores_cage", position = V(-58, 0, 16), rotation = 0, objective = "repair_span", step = "get_valve" },
				{ id = "hydraulic_head", kind = "hydraulics", position = V(46, 0, 92), rotation = 0, objective = "repair_span", step = "fit_valve" },
				{ id = "pump_start", kind = "controls", position = V(50, 0, 100), rotation = 90, objective = "repair_span", step = "run_pumps" },
				{ id = "span_control", kind = "controls", position = V(30, 0, 160), rotation = 0, objective = "repair_span", step = "lower_span" },
			},
			lootNodes = {
				{ kind = "crate", position = V(-56, 0, 12), rotation = 0, tier = 3, rolls = 1, guaranteed = { "hydraulic_valve" } },
				{ kind = "shelf", position = V(-60, 0, 22), rotation = 0, tier = 2, rolls = 3, guaranteed = { "repair_kit" } },
				{ kind = "toolboard", position = V(-62, 0, -66), rotation = 90, tier = 2, rolls = 3 },
				{ kind = "locker", position = V(-68, 0, -80), rotation = 0, tier = 2, rolls = 3, guaranteed = { "medkit", "flare" } },
				{ kind = "crate", position = V(-58, 0, -92), rotation = 0, tier = 2, rolls = 2, guaranteed = { "fuel_can" } },
				{ kind = "cabinet", position = V(44, 0, 90), rotation = 0, tier = 2, rolls = 2, guaranteed = { "coolant" } },
				{ kind = "locker", position = V(-28, 0, 106), rotation = 20, tier = 2, rolls = 2, guaranteed = { "ammo_shell", "flare" } },
				{ kind = "body", position = V(26, 0, 186), rotation = 0, tier = 3, rolls = 2, guaranteed = { "dispatch_log", "ammo_rifle" } },
			},
			landmarks = {
				{ id = "depot", name = "the depot", position = V(-64, 0, -70) },
				{ id = "stores", name = "the stores", position = V(-58, 0, 16) },
				{ id = "pump_house", name = "the pump house", position = V(46, 0, 96) },
				{ id = "span", name = "the span", position = V(0, 0, 230) },
			},
		},
		objectives = {
			{
				id = "repair_span",
				kind = "sequence",
				title = "Lower the span",
				detail = "Valve from the stores, fit it at the pump house, then hold the area while the pumps prime.",
				optional = false,
				params = {
					steps = {
						{ id = "get_valve", text = "Recover the hydraulic valve", kind = "collect", item = "hydraulic_valve", quantity = 1 },
						{ id = "fit_valve", text = "Fit the valve at the pump house", kind = "operate", fixture = "hydraulic_head", seconds = 9 },
						{ id = "run_pumps", text = "Prime the pumps", kind = "defend", fixture = "pump_start", seconds = 210, allowAbandon = true },
						{ id = "lower_span", text = "Lower the span", kind = "operate", fixture = "span_control", seconds = 6 },
					} :: { StepDef },
				},
				credits = 240,
				xp = 190,
			},
			{
				id = "depot_supplies",
				kind = "collect",
				title = "Strip the depot stores",
				detail = "This is the last real depot before the relay.",
				optional = true,
				params = { anyItems = true, quantity = 8, area = "depot" },
				credits = 80,
				xp = 60,
			},
			{
				id = "river_crossing",
				kind = "operate",
				title = "Cross on the maintenance walkway",
				detail = "There is a way across without lowering the span. It is not a good way.",
				optional = true,
				params = { fixture = "bank_walkway", seconds = 0, risk = "fall" },
				credits = 90,
				xp = 70,
			},
		},
		discoveries = {
			{ id = "river_marks", name = "Marks on the pier", position = V(0, 0, 230), hint = "Something climbs this regularly." },
			{ id = "depot_roster", name = "Depot roster", position = V(-64, 0, -70), hint = "Everyone signed out. Nobody signed back in." },
		},
		expectedSeconds = 540,
	}),

	----------------------------------------------------------------------
	-- 5. WARD HILL RELAY
	----------------------------------------------------------------------
	station({
		id = "ward_hill",
		index = 5,
		name = "Ward Hill Relay",
		subtitle = "Regional communications facility",
		distance = 13500,
		platformSide = "right",
		story = "The reason the line exists. A hilltop relay that carried every signal in the region, including the one that told everybody to leave. It is still transmitting. Nobody has been here to transmit anything for eleven days.",
		approachLine = "Ward Hill. This is the last one. Get the transmitter running and we can put out a real signal. And listen to me carefully: whatever answers you up there, it is not me.",
		threat = {
			baseline = 62,
			escalation = 4,
			creatureActive = true,
			mimicryEnabled = true,
			scriptedBeat = "finale",
		},
		layout = {
			radius = 460,
			buildings = {
				{ id = "relay_hall", kind = "facility", position = V(-50, 0, 60), rotation = 0, size = V(64, 26, 96), interior = true, entrances = 4, storey = 2 },
				{ id = "mast_base", kind = "mast", position = V(0, 0, 190), rotation = 0, size = V(30, 140, 30), interior = false, entrances = 0 },
				{ id = "plant_room", kind = "shed", position = V(48, 0, 36), rotation = 0, size = V(28, 18, 36), interior = true, entrances = 2 },
				{ id = "accommodation", kind = "cabin", position = V(-88, 0, -50), rotation = 16, size = V(28, 14, 40), interior = true, entrances = 2 },
				{ id = "platform", kind = "platform", position = V(22, 0, -40), rotation = 0, size = V(14, 3, 180), interior = false, entrances = 0 },
				{ id = "aerial_farm", kind = "aerials", position = V(70, 0, 150), rotation = 0, size = V(90, 24, 90), interior = false, entrances = 0 },
			},
			fixtures = {
				{ id = "plant_generator", kind = "generator", position = V(46, 0, 32), rotation = 0, objective = "power_relay", step = "start_plant" },
				{ id = "main_board", kind = "breaker", position = V(-48, 0, 44), rotation = 0, objective = "power_relay", step = "close_board" },
				{ id = "transmitter", kind = "transmitter", position = V(-52, 0, 84), rotation = 0, objective = "send_signal", step = "fit_valve" },
				{ id = "tuning_desk", kind = "controls", position = V(-44, 0, 88), rotation = 0, objective = "send_signal", step = "tune" },
				{ id = "mast_switch", kind = "controls", position = V(0, 0, 176), rotation = 0, objective = "send_signal", step = "raise_power" },
			},
			lootNodes = {
				{ kind = "crate", position = V(46, 0, 40), rotation = 0, tier = 2, rolls = 3, guaranteed = { "fuel_can" } },
				{ kind = "cabinet", position = V(-46, 0, 52), rotation = 0, tier = 3, rolls = 2, guaranteed = { "radio_part" } },
				{ kind = "shelf", position = V(-54, 0, 70), rotation = 0, tier = 2, rolls = 3 },
				{ kind = "locker", position = V(-86, 0, -46), rotation = 16, tier = 2, rolls = 3, guaranteed = { "medkit", "battery" } },
				{ kind = "toolboard", position = V(50, 0, 42), rotation = 90, tier = 2, rolls = 2, guaranteed = { "repair_kit" } },
				{ kind = "body", position = V(-50, 12, 90), rotation = 0, tier = 3, rolls = 3, guaranteed = { "recorder", "ammo_rifle", "flare" } },
				{ kind = "crate", position = V(66, 0, 146), rotation = 0, tier = 3, rolls = 2 },
			},
			landmarks = {
				{ id = "relay_hall", name = "the relay hall", position = V(-50, 0, 60) },
				{ id = "mast", name = "the mast", position = V(0, 0, 190) },
				{ id = "plant_room", name = "the plant room", position = V(48, 0, 36) },
				{ id = "accommodation", name = "the accommodation block", position = V(-88, 0, -50) },
			},
		},
		objectives = {
			{
				id = "power_relay",
				kind = "sequence",
				title = "Bring the facility up",
				detail = "Plant room generator, then the main board in the relay hall.",
				optional = false,
				params = {
					steps = {
						{ id = "start_plant", text = "Start the plant generator", kind = "operate", fixture = "plant_generator", seconds = 7, needsFuel = true },
						{ id = "close_board", text = "Close the main board", kind = "operate", fixture = "main_board", seconds = 4 },
					} :: { StepDef },
				},
				credits = 160,
				xp = 130,
			},
			{
				id = "send_signal",
				kind = "sequence",
				title = "Send the signal",
				detail = "Fit the transmitter valve, tune the desk, then raise mast power.",
				optional = false,
				params = {
					steps = {
						{ id = "fit_valve", text = "Fit the transmitter valve", kind = "operate", fixture = "transmitter", item = "radio_part", seconds = 8 },
						{ id = "tune", text = "Tune the desk to the regional frequency", kind = "relay", fixture = "tuning_desk", seconds = 12 },
						{ id = "raise_power", text = "Raise mast power", kind = "defend", fixture = "mast_switch", seconds = 150 },
					} :: { StepDef },
				},
				credits = 400,
				xp = 320,
				requires = { "power_relay" },
			},
			{
				id = "the_eleven_days",
				kind = "collect",
				title = "Find out what happened here",
				detail = "Four recordings, spread across the facility.",
				optional = true,
				params = { item = "recorder", quantity = 4 },
				credits = 140,
				xp = 110,
			},
		},
		discoveries = {
			{ id = "still_transmitting", name = "The carrier", position = V(-52, 0, 84), hint = "It has been transmitting the whole time. On its own." },
			{ id = "operator_room", name = "Operator's room", position = V(-88, 0, -50), hint = "Eleven days of meals, all uneaten." },
			{ id = "mast_top", name = "The mast ladder", position = V(0, 0, 190), hint = "You can see the whole valley from up there. Including how much of it is moving." },
		},
		expectedSeconds = 600,
	}),
}

--------------------------------------------------------------------------
-- Travel events between stations
--------------------------------------------------------------------------

-- These are not stops. They happen while the train is moving, at a distance
-- along the track, and they exist so the travel legs are not dead time.
export type TravelEventDef = {
	id: string,
	distance: number,
	name: string,
	description: string,
	kind: string,
	params: { [string]: any },
}

local TRAVEL_EVENTS: { TravelEventDef } = {
	{
		id = "deer_crossing",
		distance = 2900,
		name = "Something on the line",
		description = "Shapes crossing the track ahead. Braking is optional; hitting them costs condition.",
		kind = "obstacle",
		params = { conditionCost = 6, brakingWindow = 7, harmless = true },
	},
	{
		id = "service_tunnel",
		distance = 5600,
		name = "Ashcombe Tunnel",
		description = "Nine hundred studs of unlit tunnel. Interior lighting only, radio cuts out, and the carriage doors must be closed.",
		kind = "tunnel",
		params = { length = 900, radioBlackout = true, requiresDoorsClosed = true, conditionCostIfOpen = 8 },
	},
	{
		id = "overheat",
		distance = 8600,
		name = "The long grade",
		description = "A sustained climb. The engine runs hot unless coolant is applied or the throttle is eased.",
		kind = "mechanical",
		params = { gradeLength = 1400, overheatRate = 0.9, mitigations = { "coolant", "throttle_below" }, throttleBelowNotch = 5 },
	},
	{
		id = "passenger",
		distance = 11800,
		name = "Something in the last carriage",
		description = "A door that was closed is open, and the carriage is heavier than it was.",
		kind = "intruder",
		params = { carriage = -1, revealSeconds = 45 },
	},
}

--------------------------------------------------------------------------

local StationRegistry = {}

StationRegistry.Stations = TableUtil.deepFreeze(STATIONS) :: { StationDef }
StationRegistry.TravelEvents = TableUtil.deepFreeze(TRAVEL_EVENTS) :: { TravelEventDef }

function StationRegistry.count(): number
	return #STATIONS
end

function StationRegistry.byIndex(index: number): StationDef?
	return STATIONS[index]
end

function StationRegistry.byId(id: string): StationDef?
	for _, def in STATIONS do
		if def.id == id then
			return def
		end
	end
	return nil
end

--- World position of a station's origin along the track.
function StationRegistry.originFor(def: StationDef, expeditionOrigin: Vector3): Vector3
	return expeditionOrigin + Vector3.new(0, 0, -def.distance)
end

--- Travel events that fall between two track distances, in order.
function StationRegistry.travelEventsBetween(fromDistance: number, toDistance: number): { TravelEventDef }
	local out: { TravelEventDef } = {}
	for _, event in TRAVEL_EVENTS do
		if event.distance > fromDistance and event.distance <= toDistance then
			table.insert(out, event)
		end
	end
	table.sort(out, function(a, b)
		return a.distance < b.distance
	end)
	return out
end

--- Total required objectives across the chapter, used by the results screen.
function StationRegistry.totalRequiredObjectives(): number
	local total = 0
	for _, def in STATIONS do
		for _, objective in def.objectives do
			if not objective.optional then
				total += 1
			end
		end
	end
	return total
end

return StationRegistry
