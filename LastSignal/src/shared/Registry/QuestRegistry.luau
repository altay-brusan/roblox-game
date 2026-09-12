--!strict
--[[
	QuestRegistry
	-------------
	Daily and weekly quests, plus the chapter milestones.

	Design rule: every quest rewards doing something varied or cooperative, and
	none of them reward repetition of the cheapest possible action. There is no
	"complete 20 expeditions" quest, because that is a request to grind rather
	than a reason to play differently tonight.

	Quests are selected deterministically from a daily seed so every player on
	every server sees the same daily set. That matters for social play: crews
	can work on the same objectives together.
]]

local TableUtil = require(script.Parent.Parent.Core.TableUtil)

export type QuestPeriod = "daily" | "weekly" | "milestone"

export type QuestDef = {
	id: string,
	period: QuestPeriod,
	name: string,
	description: string,
	-- Counter the progression system increments. Must match a stat key that
	-- something actually reports; ProgressionService asserts this at boot.
	stat: string,
	target: number,
	credits: number,
	xp: number,
	-- Optional cosmetic or item reward.
	reward: { kind: string, id: string, quantity: number? }?,
	-- Difficulty weighting used when picking the daily set: the picker takes a
	-- spread rather than three hard ones or three trivial ones.
	weight: number,
	tier: number, -- 1 light, 2 moderate, 3 demanding
	-- Quests that require other people. Solo players still get a viable set
	-- because the picker guarantees at most one co-op quest per day.
	cooperative: boolean?,
}

local function quest(def: QuestDef): QuestDef
	return def
end

--------------------------------------------------------------------------
-- Daily pool
--------------------------------------------------------------------------

local DAILY: { QuestDef } = {
	quest({
		id = "d_stations",
		period = "daily",
		name = "Make the stops",
		description = "Clear three stations on any difficulty.",
		stat = "stations_cleared",
		target = 3,
		credits = 220,
		xp = 160,
		weight = 10,
		tier = 1,
	}),
	quest({
		id = "d_optional",
		period = "daily",
		name = "Take the long way",
		description = "Complete four optional objectives.",
		stat = "optional_objectives",
		target = 4,
		credits = 260,
		xp = 190,
		weight = 9,
		tier = 2,
	}),
	quest({
		id = "d_records",
		period = "daily",
		name = "Read the room",
		description = "Recover five dispatch logs or recordings.",
		stat = "records_found",
		target = 5,
		credits = 200,
		xp = 150,
		weight = 8,
		tier = 1,
	}),
	quest({
		id = "d_rescue",
		period = "daily",
		name = "Nobody stays down",
		description = "Revive three crew members.",
		stat = "revives_given",
		target = 3,
		credits = 300,
		xp = 230,
		weight = 8,
		tier = 2,
		cooperative = true,
	}),
	quest({
		id = "d_repair",
		period = "daily",
		name = "Keep her running",
		description = "Restore 120 points of locomotive condition.",
		stat = "condition_repaired",
		target = 120,
		credits = 240,
		xp = 180,
		weight = 8,
		tier = 2,
	}),
	quest({
		id = "d_fuel",
		period = "daily",
		name = "Full tanks",
		description = "Deliver six jerry cans to the locomotive.",
		stat = "fuel_delivered",
		target = 6,
		credits = 210,
		xp = 150,
		weight = 9,
		tier = 1,
	}),
	quest({
		id = "d_quiet",
		period = "daily",
		name = "Quiet approach",
		description = "Clear a station without firing a single shot.",
		stat = "silent_stations",
		target = 1,
		credits = 320,
		xp = 250,
		weight = 6,
		tier = 3,
	}),
	quest({
		id = "d_repel",
		period = "daily",
		name = "Stand your ground",
		description = "Drive off the Signal-Eater twice.",
		stat = "creature_repelled",
		target = 2,
		credits = 340,
		xp = 260,
		weight = 6,
		tier = 3,
	}),
	quest({
		id = "d_notfooled",
		period = "daily",
		name = "Not the dispatcher",
		description = "Ignore three false transmissions in one expedition.",
		stat = "false_instructions_ignored",
		target = 3,
		credits = 300,
		xp = 240,
		weight = 7,
		tier = 2,
	}),
	quest({
		id = "d_together",
		period = "daily",
		name = "Within earshot",
		description = "Finish an expedition without any crew member being downed.",
		stat = "flawless_expeditions",
		target = 1,
		credits = 380,
		xp = 300,
		weight = 5,
		tier = 3,
		cooperative = true,
	}),
	quest({
		id = "d_driver",
		period = "daily",
		name = "At the controls",
		description = "Drive the train for eight kilometres of track.",
		stat = "distance_driven",
		target = 8000,
		credits = 230,
		xp = 170,
		weight = 8,
		tier = 1,
	}),
	quest({
		id = "d_discoveries",
		period = "daily",
		name = "Off the marked path",
		description = "Find three optional discoveries.",
		stat = "discoveries_found",
		target = 3,
		credits = 250,
		xp = 190,
		weight = 7,
		tier = 2,
	}),
}

--------------------------------------------------------------------------
-- Weekly pool
--------------------------------------------------------------------------

local WEEKLY: { QuestDef } = {
	quest({
		id = "w_complete",
		period = "weekly",
		name = "The long grade",
		description = "Complete the chapter three times.",
		stat = "expeditions_completed",
		target = 3,
		credits = 1400,
		xp = 1100,
		weight = 10,
		tier = 2,
	}),
	quest({
		id = "w_blackout",
		period = "weekly",
		name = "Lights out",
		description = "Complete the chapter once on Blackout or harder.",
		stat = "expeditions_completed_blackout",
		target = 1,
		credits = 1800,
		xp = 1400,
		weight = 8,
		tier = 3,
	}),
	quest({
		id = "w_crew",
		period = "weekly",
		name = "Full crew",
		description = "Complete an expedition with four or more crew members.",
		stat = "large_crew_completions",
		target = 1,
		credits = 1500,
		xp = 1200,
		weight = 8,
		tier = 2,
		cooperative = true,
	}),
	quest({
		id = "w_archive",
		period = "weekly",
		name = "The archive",
		description = "Recover twenty records across the week.",
		stat = "records_found",
		target = 20,
		credits = 1300,
		xp = 1000,
		weight = 9,
		tier = 2,
		reward = { kind = "cosmetic", id = "patch_archivist" },
	}),
	quest({
		id = "w_medic",
		period = "weekly",
		name = "Field medicine",
		description = "Revive twelve crew members across the week.",
		stat = "revives_given",
		target = 12,
		credits = 1600,
		xp = 1300,
		weight = 8,
		tier = 3,
		cooperative = true,
	}),
	quest({
		id = "w_variety",
		period = "weekly",
		name = "Every stop",
		description = "Complete every required objective at all five stations, across any number of runs.",
		stat = "unique_objectives_completed",
		target = 11,
		credits = 1700,
		xp = 1350,
		weight = 7,
		tier = 3,
	}),
}

--------------------------------------------------------------------------
-- Chapter milestones (one-off, permanent)
--------------------------------------------------------------------------

local MILESTONES: { QuestDef } = {
	quest({
		id = "m_first_run",
		period = "milestone",
		name = "Zero Two Seventeen",
		description = "Complete your first expedition.",
		stat = "expeditions_completed",
		target = 1,
		credits = 500,
		xp = 400,
		weight = 0,
		tier = 1,
		reward = { kind = "cosmetic", id = "patch_departure" },
	}),
	quest({
		id = "m_all_stations",
		period = "milestone",
		name = "The whole line",
		description = "Clear all five stations in a single expedition.",
		stat = "full_line_runs",
		target = 1,
		credits = 900,
		xp = 700,
		weight = 0,
		tier = 2,
		reward = { kind = "livery", id = "livery_ashline" },
	}),
	quest({
		id = "m_derelict",
		period = "milestone",
		name = "Derelict",
		description = "Complete the chapter on Derelict.",
		stat = "expeditions_completed_derelict",
		target = 1,
		credits = 2500,
		xp = 2000,
		weight = 0,
		tier = 3,
		reward = { kind = "livery", id = "livery_pinewatch" },
	}),
	quest({
		id = "m_archive_full",
		period = "milestone",
		name = "Eleven days",
		description = "Recover all eight recordings.",
		stat = "unique_recordings",
		target = 8,
		credits = 1200,
		xp = 950,
		weight = 0,
		tier = 3,
		reward = { kind = "cosmetic", id = "lantern_operator" },
	}),
	quest({
		id = "m_never_fooled",
		period = "milestone",
		name = "It is not the dispatcher",
		description = "Complete the chapter without ever following a false transmission.",
		stat = "clean_signal_runs",
		target = 1,
		credits = 1600,
		xp = 1300,
		weight = 0,
		tier = 3,
		reward = { kind = "cosmetic", id = "patch_signalman_earned" },
	}),
}

--------------------------------------------------------------------------

local QuestRegistry = {}

QuestRegistry.Daily = TableUtil.deepFreeze(DAILY) :: { QuestDef }
QuestRegistry.Weekly = TableUtil.deepFreeze(WEEKLY) :: { QuestDef }
QuestRegistry.Milestones = TableUtil.deepFreeze(MILESTONES) :: { QuestDef }

QuestRegistry.DailySlots = 3
QuestRegistry.WeeklySlots = 2

local byId: { [string]: QuestDef } = {}
for _, list in { DAILY, WEEKLY, MILESTONES } do
	for _, def in list do
		byId[def.id] = def
	end
end

function QuestRegistry.get(id: string): QuestDef?
	return byId[id]
end

--- Every stat key any quest depends on. ProgressionService cross-checks this
--- against the stats it actually records, so a typo cannot ship a quest that
--- can never be completed.
function QuestRegistry.requiredStats(): { string }
	local seen: { [string]: boolean } = {}
	local out: { string } = {}
	for _, def in byId do
		if not seen[def.stat] then
			seen[def.stat] = true
			table.insert(out, def.stat)
		end
	end
	table.sort(out)
	return out
end

--- Deterministic daily selection. Every player on every server gets the same
--- set for a given day, so crews can co-operate on them.
--- `extraSlots` comes from the Signalman's Pass, which adds one slot.
function QuestRegistry.selectDaily(dayNumber: number, extraSlots: number?): { QuestDef }
	local slots = QuestRegistry.DailySlots + (extraSlots or 0)
	local rng = Random.new(dayNumber * 7919)
	local pool = TableUtil.shuffle(DAILY :: { any }, rng) :: { QuestDef }

	local picked: { QuestDef } = {}
	local coopUsed = false
	local tierCounts: { [number]: number } = { [1] = 0, [2] = 0, [3] = 0 }

	for _, def in pool do
		if #picked >= slots then
			break
		end
		-- At most one co-op quest per day, so a solo player always has a
		-- completable set.
		if def.cooperative and coopUsed then
			continue
		end
		-- At most one demanding quest per day.
		if def.tier == 3 and tierCounts[3] >= 1 then
			continue
		end
		table.insert(picked, def)
		tierCounts[def.tier] += 1
		if def.cooperative then
			coopUsed = true
		end
	end

	-- If the constraints starved the selection, top up from the shuffled pool.
	if #picked < slots then
		for _, def in pool do
			if #picked >= slots then
				break
			end
			local already = false
			for _, chosen in picked do
				if chosen.id == def.id then
					already = true
					break
				end
			end
			if not already then
				table.insert(picked, def)
			end
		end
	end

	return picked
end

function QuestRegistry.selectWeekly(weekNumber: number): { QuestDef }
	local rng = Random.new(weekNumber * 104729)
	local pool = TableUtil.shuffle(WEEKLY :: { any }, rng) :: { QuestDef }
	local picked: { QuestDef } = {}
	local coopUsed = false
	for _, def in pool do
		if #picked >= QuestRegistry.WeeklySlots then
			break
		end
		if def.cooperative and coopUsed then
			continue
		end
		table.insert(picked, def)
		if def.cooperative then
			coopUsed = true
		end
	end
	return picked
end

--- UTC day number, the shared clock for daily resets. Using UTC rather than
--- server-local time means a player's day does not shift when they connect to
--- a server in another region.
function QuestRegistry.currentDay(): number
	return math.floor(os.time() / 86400)
end

function QuestRegistry.currentWeek(): number
	return math.floor(os.time() / 604800)
end

function QuestRegistry.secondsUntilDailyReset(): number
	local now = os.time()
	return 86400 - (now % 86400)
end

function QuestRegistry.secondsUntilWeeklyReset(): number
	local now = os.time()
	return 604800 - (now % 604800)
end

return QuestRegistry
