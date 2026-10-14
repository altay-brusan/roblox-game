--!strict
--[[
	JourneyRegistry
	---------------
	Night runs: the repeatable journey beside the story.

	The story is one fixed telling. A night run is the same line, the same
	stations and objectives, with a seeded set of emergencies on the way and a
	route decision at Tolbridge. It exists so the line is worth riding again,
	and it is described in the lobby as exactly that: not a new story, a
	different night on the same railway.

	This file is data. JourneyService plans and runs it; the lobby and the
	results screen read it, so what a player is told is what the server does.

	PLANNING RULES (enforced by JourneyService.plan, checked by validate)
	---------------------------------------------------------------------
	  - Seeded: the same seed, tier and crew size give the same plan.
	  - Weighted pick, per template weight.
	  - A template appears at most once per run, and never in two
	    consecutive segments if it is allowed twice.
	  - Each template has prerequisites: which segments it may use.
	  - Tension budget per tier: the sum of template tension may not exceed it.
	  - Incompatible pairs never share a segment (see `incompatible`), so no
	    combination removes every solution.
	  - At most `maxSimultaneous` events active at once, plus one for crews of
	    three or more, and never more than one that stops the train.
	  - The headline (highest tension) event of the player's last run is not
	    the headline again, when that history is available.
	  - Every segment start leaves a quiet stretch (`quietStuds`) before any
	    event, and events in a segment are spaced apart.
	  - If no valid plan is found in 25 attempts, FALLBACK_PLAN is used.
]]

local TableUtil = require(script.Parent.Parent.Core.TableUtil)

export type Category = "technical" | "route" | "horror" | "station"

export type Template = {
	id: string,
	name: string,
	category: Category,
	-- One line for the briefing and the report.
	summary: string,
	weight: number,
	tension: number,
	-- Segments it may be placed in. A segment is the line between two stops:
	-- segment 1 is the yard to Marrow Halt, segment 2 Marrow to Tolbridge,
	-- and so on. Station events use the station index instead.
	segments: { number },
	-- Stops the train until resolved (only one of these at a time).
	holdsTrain: boolean,
	-- Seconds the crew has before the event escalates, then fails.
	escalateAfter: number,
	failAfter: number,
}

local TEMPLATES: { [string]: Template } = {
	carriage_blackout = {
		id = "carriage_blackout",
		name = "Carriage blackout",
		category = "technical",
		summary = "The carriage breaker trips and the train goes dark. Reset it in the first carriage. A dark train is not a shelter.",
		weight = 10,
		tension = 2,
		segments = { 2, 3, 4, 5 },
		holdsTrain = false,
		escalateAfter = 45,
		failAfter = 120,
	},
	signal_fault = {
		id = "signal_fault",
		name = "Signal at danger",
		category = "route",
		summary = "A red signal holds the train. Ring Control from the signal post telephone, which runs off the train's power, or wait for the timetable to clear it.",
		weight = 9,
		tension = 1,
		segments = { 2, 3, 4, 5 },
		holdsTrain = true,
		escalateAfter = 60,
		failAfter = 150,
	},
	brake_drag = {
		id = "brake_drag",
		name = "Dragging brakes",
		category = "technical",
		summary = "A brake cylinder sticks on. The train is held to half speed and burns fuel fast until someone releases the valve on the locomotive, from outside.",
		weight = 8,
		tension = 1,
		segments = { 2, 3, 4, 5 },
		holdsTrain = false,
		escalateAfter = 60,
		failAfter = 9999,
	},
	fallen_tree = {
		id = "fallen_tree",
		name = "Tree across the line",
		category = "route",
		summary = "A fallen pine blocks the track. Two cuts clear it, and every cut is heard in the forest.",
		weight = 8,
		tension = 2,
		segments = { 2, 3, 4, 5 },
		holdsTrain = true,
		escalateAfter = 50,
		failAfter = 9999,
	},
	electrical_fire = {
		id = "electrical_fire",
		name = "Electrical fire",
		category = "technical",
		summary = "A heater shorts and a carriage starts to burn. Beat it out, or spend a coolant canister to smother it. Left alone it grows, eats the train's condition, and takes the lights with it.",
		weight = 7,
		tension = 2,
		segments = { 2, 3, 4, 5 },
		holdsTrain = false,
		escalateAfter = 25,
		failAfter = 75,
	},
	door_jam = {
		id = "door_jam",
		name = "A door that will not latch",
		category = "technical",
		summary = "A carriage door swings open and will not stay shut. Train protection holds you to a crawl until it is forced closed; a crowbar makes it quick.",
		weight = 8,
		tension = 1,
		segments = { 1, 2, 3, 4, 5 },
		holdsTrain = false,
		escalateAfter = 40,
		failAfter = 9999,
	},
	roof_visitor = {
		id = "roof_visitor",
		name = "Something on the roof",
		category = "horror",
		summary = "It drops onto the roof and walks the length of the train. Sound the horn to throw it off, or keep every door shut and the lights on until it gives up.",
		weight = 7,
		tension = 3,
		segments = { 3, 4, 5 },
		holdsTrain = false,
		escalateAfter = 20,
		failAfter = 40,
	},
	inspection = {
		id = "inspection",
		name = "Unscheduled inspection",
		category = "station",
		summary = "Control asks for the inspector's log at this station to be signed. It is somewhere on the platform or in the buildings. Signing it earns fuel and RIP Coin; skipping it costs nothing but the reward.",
		weight = 6,
		tension = 0,
		-- Station indices: never the first or the last stop.
		segments = { 2, 3, 4 },
		holdsTrain = false,
		escalateAfter = 9999,
		failAfter = 9999,
	},
}

-- Pairs that never share a segment. Each line says why.
local INCOMPATIBLE: { { string } } = {
	-- Both stop the train: two holds at once is one long wait.
	{ "signal_fault", "fallen_tree" },
	-- The visitor's quiet answer is a lit train; a blackout removes it.
	{ "roof_visitor", "carriage_blackout" },
	-- An open door is the visitor's way in; the pair is unwinnable quietly.
	{ "roof_visitor", "door_jam" },
	-- A fire already threatens the lights; with a blackout nothing is visible
	-- to fight it by.
	{ "electrical_fire", "carriage_blackout" },
}

export type Route = {
	id: string,
	name: string,
	stations: { number },
	summary: string,
}

local ROUTES: { [string]: Route } = {
	main = {
		id = "main",
		name = "Main line",
		stations = { 1, 2, 3, 4, 5 },
		summary = "All five stations. Ninety-Three has fuel and supplies, and a station's worth of work.",
	},
	cutoff = {
		id = "cutoff",
		name = "Ninety-Three cut-off",
		stations = { 1, 2, 4, 5 },
		summary = "Runs straight past Ninety-Three: one station shorter, but no refuelling stop between Tolbridge and Hallow Bridge, and a longer dark run.",
	},
}

export type Tier = {
	id: string,
	name: string,
	summary: string,
	events: number,
	tensionBudget: number,
	maxSimultaneous: number,
	-- Fuel at departure, as a fraction of a full tank.
	startFuel: number,
	-- Whether the briefing lists the night's events before departure.
	briefed: boolean,
	-- Night runs completed (on any tier) before this tier opens.
	unlockAfter: number,
}

local TIERS: { Tier } = {
	{
		id = "night",
		name = "Night Run",
		summary = "Three emergencies on the way, announced in the briefing. A full tank.",
		events = 3,
		tensionBudget = 5,
		maxSimultaneous = 1,
		startFuel = 1.0,
		briefed = true,
		unlockAfter = 0,
	},
	{
		id = "hard",
		name = "Hard Night",
		summary = "Five emergencies, two can overlap, and the briefing only tells you how many. Three-quarters of a tank.",
		events = 5,
		tensionBudget = 9,
		maxSimultaneous = 2,
		startFuel = 0.75,
		briefed = false,
		unlockAfter = 1,
	},
	{
		id = "last",
		name = "Last Train",
		summary = "Seven emergencies, overlapping, unannounced, on a half tank. For crews who know the line.",
		events = 7,
		tensionBudget = 13,
		maxSimultaneous = 2,
		startFuel = 0.5,
		briefed = false,
		unlockAfter = 3,
	},
}

-- Used when no valid plan can be generated. Small, safe and known to work.
local FALLBACK_PLAN: { { template: string, segment: number } } = {
	{ template = "door_jam", segment = 2 },
	{ template = "signal_fault", segment = 3 },
	{ template = "inspection", segment = 4 },
}

export type Unlock = {
	id: string,
	name: string,
	description: string,
	kind: "cosmetic" | "utility",
	-- Night runs completed to earn it.
	after: number,
	cosmetic: string?,
}

-- Earned only by playing. None of these can be bought.
local UNLOCKS: { Unlock } = {
	{
		id = "patch_night_run",
		name = "Night Run patch",
		description = "A crew patch for completing a night run.",
		kind = "cosmetic",
		after = 1,
		cosmetic = "patch_night_run",
	},
	{
		id = "linemans_toolkit",
		name = "Lineman's toolkit",
		description = "Night-run repair jobs take 20% less time. Earned after three completed night runs.",
		kind = "utility",
		after = 3,
	},
	{
		id = "finish_soot",
		name = "Soot finish",
		description = "A smoke-blackened weapon finish for five completed night runs.",
		kind = "cosmetic",
		after = 5,
		cosmetic = "finish_soot",
	},
}

local JourneyRegistry = {}

JourneyRegistry.Templates = TableUtil.deepFreeze(TEMPLATES) :: { [string]: Template }
JourneyRegistry.Incompatible = TableUtil.deepFreeze(INCOMPATIBLE) :: { { string } }
JourneyRegistry.Routes = TableUtil.deepFreeze(ROUTES) :: { [string]: Route }
JourneyRegistry.Tiers = TableUtil.deepFreeze(TIERS) :: { Tier }
JourneyRegistry.FallbackPlan = TableUtil.deepFreeze(FALLBACK_PLAN) :: { { template: string, segment: number } }
JourneyRegistry.Unlocks = TableUtil.deepFreeze(UNLOCKS) :: { Unlock }

-- Quiet line after each stop before any event may start, in studs.
JourneyRegistry.quietStuds = 450
-- Minimum line between two event starts in the same segment, in studs.
JourneyRegistry.spacingStuds = 700

function JourneyRegistry.tier(id: string?): Tier
	for _, tier in TIERS do
		if tier.id == id then
			return tier
		end
	end
	return TIERS[1]
end

function JourneyRegistry.incompatible(a: string, b: string): boolean
	for _, pair in INCOMPATIBLE do
		if (pair[1] == a and pair[2] == b) or (pair[1] == b and pair[2] == a) then
			return true
		end
	end
	return false
end

return JourneyRegistry
