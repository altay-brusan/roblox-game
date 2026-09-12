--!strict
--[[
	EventRegistry
	-------------
	Live events. One complete event ships with the game: The Lost Conductor.

	The point of this file is that a future event is data, not code. An event
	declares its window, its spawns, its collectible, its rewards and its
	encounter; EventService reads that and runs it. Adding the next event means
	adding a table here, not rewriting the expedition.

	Safety properties EventService guarantees for every event defined here:
	  - Claims are idempotent. Reconnecting, or clicking twice, cannot double
	    grant a reward.
	  - Progress earned during an event is never removed when it ends. Only the
	    ability to earn more stops.
	  - An event stopped early by an administrator settles outstanding claims
	    before it closes.
	  - An expired event still lets a player claim rewards they already earned,
	    for a grace period, so ending mid-expedition is not a punishment.
]]

local TableUtil = require(script.Parent.Parent.Core.TableUtil)

export type EventReward = {
	threshold: number, -- tokens required
	credits: number?,
	xp: number?,
	cosmetic: string?,
	livery: string?,
	title: string,
	description: string,
}

export type EventDef = {
	id: string,
	name: string,
	tagline: string,
	description: string,

	-- Window. Unix seconds. `startsAt = 0` means "not scheduled": the event is
	-- fully built but dormant, and an administrator turns it on.
	startsAt: number,
	endsAt: number,
	-- After endsAt, players may still claim already-earned rewards for this
	-- long. Nothing earned is lost by an expedition running past the deadline.
	claimGraceSeconds: number,

	-- Token collected during the event.
	tokenItem: string,
	tokenName: string,
	-- How many spawn per station, before crew scaling.
	tokensPerStation: number,
	-- Chance a station also hosts the encounter.
	encounterChance: number,

	-- The encounter this event adds.
	encounter: {
		id: string,
		name: string,
		description: string,
		-- Behaviour key handled by EventService; original to this event.
		behaviour: string,
		params: { [string]: any },
	}?,

	rewards: { EventReward },

	-- Eligibility. Kept deliberately loose: gating a limited cosmetic behind a
	-- level requirement punishes new players for arriving during the event.
	minLevel: number,
}

--------------------------------------------------------------------------

local EVENTS: { [string]: EventDef } = {
	lost_conductor = {
		id = "lost_conductor",
		name = "The Lost Conductor",
		tagline = "A service that never ran is still collecting tickets.",
		description = "Punched tickets have started appearing along the line, for a sleeper service that was cancelled before it ever left the yard. Somebody is still walking the train checking them. Collect the tickets, work out where the service was going, and decide whether to let him finish his round.",

		startsAt = 0, -- dormant until scheduled; see docs/EVENTS.md
		endsAt = 0,
		claimGraceSeconds = 7 * 86400,

		tokenItem = "conductor_ticket",
		tokenName = "Punched Ticket",
		tokensPerStation = 3,
		encounterChance = 0.45,

		encounter = {
			id = "the_conductor",
			name = "The Conductor",
			description = "He walks the length of the train, from the last carriage to the cab, checking tickets. He is not hostile and he cannot be stopped. If he reaches a player who is holding no ticket, that player's lamp goes out and stays out until the next station.",
			behaviour = "patrol_inspector",
			params = {
				-- Walks the consist end to end at a fixed, unhurried pace.
				speed = 6,
				-- Appears at a random point during travel, never during a
				-- station stop and never during the cinematic.
				spawnDuringTravelOnly = true,
				-- Holding a ticket makes the interaction safe and consumes it.
				appeasedByToken = true,
				-- The penalty is inconvenience, not damage. An event encounter
				-- that can kill you turns a limited cosmetic into a tax.
				penalty = "lamp_out_until_station",
				dealsDamage = false,
				-- He can be avoided entirely by being in a different carriage.
				avoidable = true,
				-- One appearance per travel leg, maximum.
				maxPerLeg = 1,
			},
		},

		rewards = {
			{
				threshold = 5,
				credits = 400,
				xp = 300,
				title = "First Punch",
				description = "Five tickets collected.",
			},
			{
				threshold = 15,
				credits = 900,
				xp = 700,
				cosmetic = "patch_conductor",
				title = "Full Round",
				description = "Fifteen tickets. The conductor's patch.",
			},
			{
				threshold = 30,
				credits = 1600,
				xp = 1200,
				cosmetic = "lantern_sleeper",
				title = "Sleeper Service",
				description = "Thirty tickets. The maroon sleeper lamp.",
			},
			{
				threshold = 50,
				credits = 2600,
				xp = 2000,
				livery = "livery_lostconductor",
				title = "The Whole Service",
				description = "Fifty tickets. The Sleeper Maroon livery for any train you own.",
			},
		},

		minLevel = 0,
	},
}

--------------------------------------------------------------------------

local EventRegistry = {}

EventRegistry.Events = TableUtil.deepFreeze(EVENTS) :: { [string]: EventDef }

function EventRegistry.get(id: string): EventDef?
	return EVENTS[id]
end

function EventRegistry.all(): { EventDef }
	local out: { EventDef } = {}
	for _, def in EVENTS do
		table.insert(out, def)
	end
	table.sort(out, function(a, b)
		return a.id < b.id
	end)
	return out
end

--- Is the event accepting new progress right now?
function EventRegistry.isActive(def: EventDef, now: number?): boolean
	local t = now or os.time()
	if def.startsAt <= 0 or def.endsAt <= 0 then
		return false
	end
	return t >= def.startsAt and t < def.endsAt
end

--- Can a player still claim rewards they already earned?
function EventRegistry.isClaimable(def: EventDef, now: number?): boolean
	local t = now or os.time()
	if def.startsAt <= 0 then
		return false
	end
	return t >= def.startsAt and t < def.endsAt + def.claimGraceSeconds
end

--- Rewards a token count has unlocked, in threshold order.
function EventRegistry.unlockedRewards(def: EventDef, tokens: number): { EventReward }
	local out: { EventReward } = {}
	for _, reward in def.rewards do
		if tokens >= reward.threshold then
			table.insert(out, reward)
		end
	end
	table.sort(out, function(a, b)
		return a.threshold < b.threshold
	end)
	return out
end

--- The next reward a player is working towards, for the progress bar.
function EventRegistry.nextReward(def: EventDef, tokens: number): EventReward?
	local best: EventReward? = nil
	for _, reward in def.rewards do
		if tokens < reward.threshold then
			if not best or reward.threshold < (best :: EventReward).threshold then
				best = reward
			end
		end
	end
	return best
end

--- Any event currently live. There is deliberately no support for two events
--- running at once: overlapping token economies confuse players and make the
--- reward panel unreadable.
function EventRegistry.activeEvent(now: number?): EventDef?
	for _, def in EVENTS do
		if EventRegistry.isActive(def, now) then
			return def
		end
	end
	return nil
end

return EventRegistry
