--!strict
--[[
	JourneyService
	--------------
	Night runs: planning a seeded set of emergencies, running them, the route
	decision at Tolbridge, the report, and what a crew earns.

	Story runs are untouched: with mode "story" nothing here does anything.

	PLANNING is a pure function of (seed, tier, crew size, last headline), so
	a seed reproduces its night exactly. See JourneyRegistry for the rules it
	follows. If it cannot find a valid plan it uses the fallback plan, and
	says so in the report.

	RUNNING. Travel events start when the train passes their distance in the
	right segment, if the simultaneous cap and the one-hold rule allow; if not
	they slide forward, and if the segment runs out they are recorded as "no
	room tonight". Station events start on arrival. An event that cannot start
	(no carriage, no door, station not on the route) is recorded as skipped
	with the reason, and the run carries on: the runtime fallback.

	RESET. A retry cleans up every active event and re-arms everything after
	the checkpoint. The end of a run cleans up everything. Leaving or dying
	never strands a task: every task is a part on the train or the line that
	anyone in the crew can finish, and nothing needs two players at once.

	Nothing here is essential to the core journey. If the profile cannot be
	read, the run still plays and the report says progress was not saved.
]]

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.LastSignal

local Balance = require(Shared.Config.Balance)
local Guard = require(Shared.Core.Guard)
local JourneyRegistry = require(Shared.Registry.JourneyRegistry)
local Logger = require(Shared.Core.Logger)
local Net = require(Shared.Core.Net)
local Protect = require(Shared.Core.Protect)
local StationRegistry = require(Shared.Registry.StationRegistry)

local DataService = require(script.Parent.DataService)
local ExpeditionService = require(script.Parent.ExpeditionService)
local HorrorDirector = require(script.Parent.HorrorDirector)
local CreatureService = require(script.Parent.CreatureService)
local InteractionService = require(script.Parent.InteractionService)
local ProgressionService = require(script.Parent.ProgressionService)
local TrainService = require(script.Parent.TrainService)
local JourneyEvents = require(script.Parent.Parent.Journey.JourneyEvents)

local log = Logger.new("JourneyService")

local JourneyService = {}

export type Entry = {
	template: string,
	segment: number,
	at: number,
	status: string, -- pending | active | resolved | failed | skipped
	outcome: string?,
	startedAt: number?,
	escalated: boolean,
	chainedFrom: string?,
	ctx: any?,
}

export type Plan = {
	entries: { Entry },
	fallback: boolean,
	attempts: number,
	headline: string,
}

type Journey = {
	guid: string,
	seed: number,
	tier: string,
	crewSize: number,
	plan: Plan,
	route: string,
	routeChosenBy: string,
	choiceOpen: boolean,
	choiceDeadline: number,
	quietUntil: number,
	inspectionCredits: number,
	rng: Random,
	-- Rewards already paid this run, so a retry cannot pay them twice.
	paid: { [string]: boolean },
}

local journeys: { [string]: Journey } = {}

-- Per-player choices for their next run, set from the crew panel.
type Prefs = { mode: string, tier: string, seed: number? }
local prefs: { [number]: Prefs } = {}

local function prefsFor(userId: number): Prefs
	local p = prefs[userId]
	if not p then
		p = { mode = "story", tier = "night", seed = nil }
		prefs[userId] = p
	end
	return p
end

--------------------------------------------------------------------------
-- Geometry
--------------------------------------------------------------------------

local function segmentBounds(segment: number): (number, number)
	local finish = StationRegistry.byIndex(segment)
	local start = if segment > 1 then StationRegistry.byIndex(segment - 1) else nil
	return (if start then start.distance else 0), (if finish then finish.distance else 0)
end

local function segmentOf(distance: number): number
	for index, station in StationRegistry.Stations do
		if distance <= station.distance + 1 then
			return index
		end
	end
	return StationRegistry.count() + 1
end

--------------------------------------------------------------------------
-- Planning
--------------------------------------------------------------------------

local function templateIds(): { string }
	local ids = {}
	for id in JourneyRegistry.Templates do
		table.insert(ids, id)
	end
	-- Dictionary order is not stable; the seed must be.
	table.sort(ids)
	return ids
end

local function headlineOf(entries: { Entry }): string
	local best, bestTension = "", -1
	for _, e in entries do
		local t = JourneyRegistry.Templates[e.template]
		if t and (t.tension > bestTension or (t.tension == bestTension and e.template < best)) then
			best, bestTension = e.template, t.tension
		end
	end
	return best
end

local function capFor(tierId: string, crewSize: number): number
	return JourneyRegistry.tier(tierId).maxSimultaneous + (if crewSize >= 3 then 1 else 0)
end

--- Checks a plan against every rule. Returns false and the first broken one.
function JourneyService.validate(entries: { Entry }, tierId: string, crewSize: number, lastHeadline: string?): (boolean, string?)
	local tier = JourneyRegistry.tier(tierId)
	local cap = capFor(tierId, crewSize)
	local seen: { [string]: boolean } = {}
	local tension = 0
	local perSegment: { [number]: { Entry } } = {}
	for _, e in entries do
		local t = JourneyRegistry.Templates[e.template]
		if not t then
			return false, "unknown template " .. e.template
		end
		if seen[e.template] then
			return false, "duplicate " .. e.template
		end
		seen[e.template] = true
		if not table.find(t.segments, e.segment) then
			return false, e.template .. " not allowed in segment " .. e.segment
		end
		tension += t.tension
		perSegment[e.segment] = perSegment[e.segment] or {}
		table.insert(perSegment[e.segment], e)
	end
	if tension > tier.tensionBudget then
		return false, "over tension budget"
	end
	for segment, list in perSegment do
		local holds, travel = 0, 0
		for i, a in list do
			local ta = JourneyRegistry.Templates[a.template]
			if ta.holdsTrain then
				holds += 1
			end
			if ta.category ~= "station" then
				travel += 1
				local s0, s1 = segmentBounds(segment)
				if a.at < s0 + JourneyRegistry.quietStuds or a.at > s1 - 500 then
					return false, a.template .. " outside its window"
				end
			end
			for j = i + 1, #list do
				local b = list[j]
				if JourneyRegistry.incompatible(a.template, b.template) then
					return false, a.template .. " incompatible with " .. b.template
				end
				local tb = JourneyRegistry.Templates[b.template]
				if ta.category ~= "station" and tb.category ~= "station" and math.abs(a.at - b.at) < JourneyRegistry.spacingStuds then
					return false, "too close together"
				end
			end
		end
		if holds > 1 then
			return false, "two holds in segment " .. segment
		end
		if travel > cap then
			return false, "too many in segment " .. segment
		end
	end
	if lastHeadline and lastHeadline ~= "" and #entries > 1 and headlineOf(entries) == lastHeadline then
		return false, "same headline as last run"
	end
	return true, nil
end

--- The night's emergencies for a seed. Pure: same inputs, same plan.
function JourneyService.plan(seed: number, tierId: string, crewSize: number, lastHeadline: string?): Plan
	local tier = JourneyRegistry.tier(tierId)
	local rng = Random.new(seed)
	local ids = templateIds()
	for attempt = 1, 25 do
		local entries: { Entry } = {}
		local used: { [string]: boolean } = {}
		local tension = 0
		for _ = 1, tier.events do
			-- Weighted pick among templates that still fit the budget.
			local total = 0
			local candidates = {}
			for _, id in ids do
				local t = JourneyRegistry.Templates[id]
				if not used[id] and tension + t.tension <= tier.tensionBudget then
					table.insert(candidates, t)
					total += t.weight
				end
			end
			if total <= 0 then
				break
			end
			local roll = rng:NextNumber() * total
			local pick = candidates[#candidates]
			for _, t in candidates do
				roll -= t.weight
				if roll <= 0 then
					pick = t
					break
				end
			end
			used[pick.id] = true
			tension += pick.tension
			local segment = pick.segments[rng:NextInteger(1, #pick.segments)]
			local s0, s1 = segmentBounds(segment)
			local window = (s1 - 500) - (s0 + JourneyRegistry.quietStuds)
			local at = s0 + JourneyRegistry.quietStuds + rng:NextNumber() * window
			table.insert(entries, {
				template = pick.id,
				segment = segment,
				at = math.floor(at),
				status = "pending",
				escalated = false,
			})
		end
		table.sort(entries, function(a, b)
			if a.segment ~= b.segment then
				return a.segment < b.segment
			end
			return a.at < b.at
		end)
		local ok = JourneyService.validate(entries, tierId, crewSize, lastHeadline)
		if ok then
			return { entries = entries, fallback = false, attempts = attempt, headline = headlineOf(entries) }
		end
	end
	-- The fallback: small, safe, known to work.
	local entries: { Entry } = {}
	for _, f in JourneyRegistry.FallbackPlan do
		local s0, s1 = segmentBounds(f.segment)
		table.insert(entries, { template = f.template, segment = f.segment, at = math.floor((s0 + s1) / 2), status = "pending", escalated = false })
	end
	return { entries = entries, fallback = true, attempts = 25, headline = headlineOf(entries) }
end

--------------------------------------------------------------------------
-- Running
--------------------------------------------------------------------------

local startEntry: (any, Journey, Entry) -> ()

local function endEntry(expedition: any, journey: Journey, entry: Entry, status: string, outcome: string)
	if entry.status ~= "active" then
		return
	end
	local impl = JourneyEvents[entry.template]
	if status == "failed" and impl.fail then
		Protect.call(impl.fail, entry.ctx)
	end
	entry.status = status
	entry.outcome = outcome
	Protect.call(impl.cleanup, entry.ctx)
	-- A recovery interval after a travel emergency; a station event ending as
	-- the train leaves needs none.
	if JourneyRegistry.Templates[entry.template].category ~= "station" then
		journey.quietUntil = os.clock() + 25
	end
	log.info(string.format("%s: %s %s (%s)", expedition.id, entry.template, status, outcome))
	ExpeditionService.push(expedition)
end

local function activeCount(journey: Journey): (number, boolean)
	local n, hold = 0, false
	for _, e in journey.plan.entries do
		if e.status == "active" then
			local t = JourneyRegistry.Templates[e.template]
			if t.category ~= "station" then
				n += 1
			end
			if t.holdsTrain then
				hold = true
			end
		end
	end
	return n, hold
end

local function isActive(journey: Journey, templateId: string): boolean
	for _, e in journey.plan.entries do
		if e.template == templateId and e.status == "active" then
			return true
		end
	end
	return false
end

local function makeCtx(expedition: any, journey: Journey, entry: Entry): any
	local train = expedition.train
	local players = function()
		return ExpeditionService.playersOf(expedition)
	end
	local ctx = {
		expedition = expedition,
		train = train,
		state = {},
		elapsed = 0,
		rng = Random.new(journey.seed + entry.at),
	}
	ctx.notify = function(kind: string, title: string, body: string)
		Net.fireClients("Notify", players(), { kind = kind, title = title, body = body, duration = 7 })
	end
	ctx.radio = function(source: string, attribution: string, text: string, duration: number)
		Net.fireClients("RadioMessage", players(), { id = "journey", source = source, text = text, duration = duration, attribution = attribution, isFalse = false })
	end
	ctx.cue = function(name: string, position: Vector3?)
		Net.fireClients("HorrorCue", players(), { cue = name, position = position or train.built.root.Position })
	end
	ctx.threat = function(amount: number)
		HorrorDirector.addThreat(expedition.id, amount)
	end
	ctx.noise = function(position: Vector3, loudness: number)
		CreatureService.hearNoise(expedition.id, position, loudness)
	end
	ctx.holdTrain = function(studsAhead: number): number
		local holdAt = train.distance + studsAhead
		local nextIndex = ExpeditionService.nextStationIndex(expedition)
		local nextStation = if nextIndex then StationRegistry.byIndex(nextIndex) else nil
		if nextStation then
			holdAt = math.min(holdAt, nextStation.distance - 120)
		end
		TrainService.setStopDistance(train, holdAt)
		return holdAt
	end
	ctx.releaseTrain = function()
		local nextIndex = ExpeditionService.nextStationIndex(expedition)
		local nextStation = if nextIndex then StationRegistry.byIndex(nextIndex) else nil
		if expedition.state == "travelling" and nextStation then
			TrainService.setStopDistance(train, nextStation.distance)
			-- Train protection shut the throttle when it held the train, so
			-- the driver has to be told to open it again.
			ctx.notify("info", "Line clear", "Open the throttle and drive on.")
		end
	end
	ctx.applyLights = function()
		TrainService.applyLights(train)
	end
	ctx.setDoor = function(door: any, angle: number)
		TrainService.setDoorAngle(door, angle)
	end
	ctx.chain = function(templateId: string)
		if isActive(journey, templateId) then
			return
		end
		local chained: Entry = {
			template = templateId,
			segment = segmentOf(train.distance),
			at = math.floor(train.distance),
			status = "pending",
			escalated = false,
			chainedFrom = entry.template,
		}
		table.insert(journey.plan.entries, chained)
		startEntry(expedition, journey, chained)
	end
	ctx.isActive = function(templateId: string): boolean
		return isActive(journey, templateId)
	end
	ctx.award = function(credits: number, fuel: number): boolean
		-- Once per station per run: a retry must not turn a reward into a farm.
		local key = "award:" .. entry.template .. ":" .. entry.segment
		if journey.paid[key] then
			return false
		end
		journey.paid[key] = true
		TrainService.addFuel(train, fuel)
		journey.inspectionCredits += credits
		for _, player in players() do
			ProgressionService.award(player, { credits = credits, source = "journey:inspection" }, expedition.crewSize)
		end
		return true
	end
	ctx.stationFixtures = function(): { BasePart }
		local out = {}
		local built = expedition.lane.stations[entry.segment]
		if built then
			for _, part in built.fixtures do
				table.insert(out, part)
			end
		end
		table.sort(out, function(a, b)
			return a.Name < b.Name
		end)
		return out
	end
	ctx.resolve = function(outcome: string)
		endEntry(expedition, journey, entry, "resolved", outcome)
	end
	ctx.fail = function(outcome: string)
		endEntry(expedition, journey, entry, "failed", outcome)
	end
	return ctx
end

function startEntry(expedition: any, journey: Journey, entry: Entry)
	local impl = JourneyEvents[entry.template]
	if not impl then
		entry.status = "skipped"
		entry.outcome = "Not available in this build"
		return
	end
	entry.ctx = makeCtx(expedition, journey, entry)
	entry.status = "active"
	entry.startedAt = os.clock()
	entry.escalated = false
	local ok, started = Protect.call(impl.start, entry.ctx)
	if not ok or not started then
		-- The runtime fallback: record it, put anything back, carry on.
		entry.status = "skipped"
		entry.outcome = if ok then "Could not start here" else "Could not start (error)"
		Protect.call(impl.cleanup, entry.ctx)
		log.warn(string.format("%s: %s could not start: %s", expedition.id, entry.template, tostring(started)))
		return
	end
	log.info(string.format("%s: %s started at %.0f", expedition.id, entry.template, expedition.train.distance))
	ExpeditionService.push(expedition)
end

local function step(expedition: any, journey: Journey, dt: number)
	local now = os.clock()
	local train = expedition.train
	-- Active events: timers.
	for _, entry in journey.plan.entries do
		if entry.status ~= "active" then
			continue
		end
		local impl = JourneyEvents[entry.template]
		local t = JourneyRegistry.Templates[entry.template]
		local elapsed = now - (entry.startedAt or now)
		local ctx: any = entry.ctx
		ctx.elapsed = elapsed
		if impl.tick then
			Protect.call(impl.tick, entry.ctx, dt)
		end
		if entry.status ~= "active" then
			continue
		end
		if not entry.escalated and elapsed >= t.escalateAfter then
			entry.escalated = true
			if impl.escalate then
				Protect.call(impl.escalate, entry.ctx)
			end
		end
		if elapsed >= t.failAfter then
			endEntry(expedition, journey, entry, "failed", "Ignored too long")
		end
	end

	-- Pending travel events.
	if expedition.state ~= "travelling" then
		return
	end
	local here = segmentOf(train.distance)
	local cap = capFor(journey.tier, journey.crewSize)
	for _, entry in journey.plan.entries do
		if entry.status ~= "pending" then
			continue
		end
		local t = JourneyRegistry.Templates[entry.template]
		if t.category == "station" then
			continue
		end
		if here > entry.segment then
			entry.status = "skipped"
			entry.outcome = "The train was past it"
			log.info(string.format("%s: %s skipped (passed)", expedition.id, entry.template))
			continue
		end
		if here < entry.segment or train.distance < entry.at then
			continue
		end
		local count, hold = activeCount(journey)
		if count >= cap or (t.holdsTrain and hold) or now < journey.quietUntil then
			-- No room yet: move it a little ahead of the train, within its
			-- segment. Relative to the train, so a long wait does not push it
			-- off the end of the segment while the train is standing still.
			local _, s1 = segmentBounds(entry.segment)
			entry.at = math.max(entry.at, train.distance) + 150
			if entry.at > s1 - 300 then
				entry.status = "skipped"
				entry.outcome = "No room tonight"
				log.info(string.format("%s: %s skipped (no room)", expedition.id, entry.template))
			end
			continue
		end
		startEntry(expedition, journey, entry)
	end
end

--------------------------------------------------------------------------
-- Report and progression
--------------------------------------------------------------------------

local TIER_BONUS: { [string]: number } = { night = 300, hard = 600, last = 1000 }

local function report(expedition: any, player: Player, success: boolean): any
	local journey = journeys[expedition.id]
	if not journey then
		return nil
	end
	local tier = JourneyRegistry.tier(journey.tier)
	local route = JourneyRegistry.Routes[journey.route]
	local events = {}
	for _, e in journey.plan.entries do
		local t = JourneyRegistry.Templates[e.template]
		table.insert(events, {
			name = t.name,
			status = if e.status == "active" then "unresolved" else e.status,
			outcome = e.outcome or (if e.status == "pending" then "Never reached" else ""),
			chainedFrom = if e.chainedFrom then JourneyRegistry.Templates[e.chainedFrom].name else nil,
		})
	end
	local out: { [string]: any } = {
		mode = "nightrun",
		seed = journey.seed,
		tier = tier.name,
		route = route.name,
		routeChosenBy = journey.routeChosenBy,
		events = events,
		fallback = journey.plan.fallback,
		inspectionCredits = journey.inspectionCredits,
		bonus = 0,
		unlocked = {},
		saved = false,
		alreadyCredited = false,
	}

	local profile = DataService.getProfile(player)
	if not profile then
		-- Progress is optional; the run still counts as played.
		return out
	end
	local j = profile.journeys
	if table.find(j.rewarded, journey.guid) then
		out.alreadyCredited = true
		out.saved = DataService.isWritable(player)
		return out
	end
	local completedBefore = j.completed
	local ok = DataService.update(player, function(p)
		local pj = p.journeys
		if success then
			pj.completed += 1
		else
			pj.failed += 1
		end
		for _, e in journey.plan.entries do
			if e.status == "resolved" or e.status == "failed" then
				pj.eventsSeen[e.template] = (pj.eventsSeen[e.template] or 0) + 1
			end
		end
		pj.lastHeadline = journey.plan.headline
		table.insert(pj.rewarded, journey.guid)
		while #pj.rewarded > 20 do
			table.remove(pj.rewarded, 1)
		end
		table.insert(pj.history, { seed = journey.seed, tier = journey.tier, route = journey.route, success = success, at = os.time() })
		while #pj.history > 10 do
			table.remove(pj.history, 1)
		end
	end)
	if ok and success then
		local bonus = TIER_BONUS[journey.tier] or 0
		ProgressionService.award(player, { credits = bonus, xp = bonus, source = "journey:" .. journey.tier }, expedition.crewSize)
		out.bonus = bonus
		for _, unlock in JourneyRegistry.Unlocks do
			if completedBefore < unlock.after and j.completed >= unlock.after then
				if unlock.cosmetic then
					ProgressionService.grantUnlock(player, "cosmetic", unlock.cosmetic)
				else
					DataService.update(player, function(p)
						p.journeys.utility[unlock.id] = true
					end)
				end
				table.insert(out.unlocked, unlock.name)
			end
		end
	end
	out.saved = ok and DataService.isWritable(player)
	ProgressionService.pushToClient(player)
	return out
end

--------------------------------------------------------------------------
-- Setup at departure
--------------------------------------------------------------------------

local function begin(expedition: any)
	if journeys[expedition.id] then
		return
	end
	local leaderId = expedition.members[1]
	local p = if leaderId then prefsFor(leaderId) else nil
	if not p or p.mode ~= "nightrun" then
		return
	end
	local leader = game:GetService("Players"):GetPlayerByUserId(leaderId)
	local profile = if leader then DataService.getProfile(leader) else nil
	local completed = if profile then profile.journeys.completed else 0
	-- A tier the leader has not unlocked falls back to the first.
	local tier = JourneyRegistry.tier(p.tier)
	if completed < tier.unlockAfter then
		tier = JourneyRegistry.Tiers[1]
	end
	local seed = p.seed or Random.new():NextInteger(1, 99999)
	local lastHeadline = if profile then profile.journeys.lastHeadline else nil
	local plan = JourneyService.plan(seed, tier.id, expedition.crewSize, lastHeadline)
	-- Studio test hook: a server-set "JourneyForce" attribute on the leader,
	-- "template@segment,template@segment", forces a plan so each template can
	-- be exercised on its own. Does nothing outside Studio.
	local forced = if leader and game:GetService("RunService"):IsStudio() then leader:GetAttribute("JourneyForce") else nil
	if type(forced) == "string" and forced ~= "" then
		local entries: { Entry } = {}
		for _, item in string.split(forced, ",") do
			local parts = string.split(item, "@")
			local segment = tonumber(parts[2]) or 2
			local s0 = segmentBounds(segment)
			local inSegment = 0
			for _, e in entries do
				if e.segment == segment then
					inSegment += 1
				end
			end
			table.insert(entries, { template = parts[1], segment = segment, at = s0 + JourneyRegistry.quietStuds + 50 + inSegment * 900, status = "pending", escalated = false })
		end
		plan = { entries = entries, fallback = false, attempts = 0, headline = headlineOf(entries) }
		log.warn("FORCED night-run plan (Studio test): " .. forced)
	end

	local journey: Journey = {
		guid = HttpService:GenerateGUID(false),
		seed = seed,
		tier = tier.id,
		crewSize = expedition.crewSize,
		plan = plan,
		route = "main",
		routeChosenBy = "default",
		choiceOpen = false,
		choiceDeadline = 0,
		quietUntil = 0,
		inspectionCredits = 0,
		rng = Random.new(seed),
		paid = {},
	}
	journeys[expedition.id] = journey
	expedition.mode = "nightrun"
	expedition.train.fuel = Balance.Train.maxFuel * tier.startFuel

	local names = {}
	for _, e in plan.entries do
		table.insert(names, JourneyRegistry.Templates[e.template].name)
	end
	local briefing = if tier.briefed
		then "Tonight: " .. table.concat(names, ", ") .. "."
		else string.format("%d emergencies expected. Control will not say which.", #plan.entries)
	Net.fireClients("Notify", ExpeditionService.playersOf(expedition), {
		kind = "info",
		title = string.format("%s, seed %d", tier.name, seed),
		body = briefing,
		duration = 12,
	})
	log.info(string.format("%s: night run seed %d tier %s, %d events%s: %s", expedition.id, seed, tier.id, #plan.entries, if plan.fallback then " (FALLBACK)" else "", table.concat(names, ", ")))
end

--------------------------------------------------------------------------

function JourneyService.forExpedition(id: string): Journey?
	return journeys[id]
end

function JourneyService.start()
	ExpeditionService.resultsExtra = report
	InteractionService.holdScale = function(player: Player): number
		local profile = DataService.getProfile(player)
		if profile and profile.journeys.utility.linemans_toolkit and ExpeditionService.forPlayer(player) then
			local expedition = ExpeditionService.forPlayer(player)
			if expedition and expedition.mode == "nightrun" then
				return 0.8
			end
		end
		return 1
	end

	ExpeditionService.StateChanged:Connect(function(expedition, state)
		if state == "cinematic" then
			Protect.call(begin, expedition)
		end
		local journey = journeys[expedition.id]
		if journey and state == "travelling" and journey.choiceOpen then
			-- Left Tolbridge without choosing: the main line.
			journey.choiceOpen = false
			Net.fireClients("JourneyChoice", ExpeditionService.playersOf(expedition), { id = "route", closed = true })
		end
		if journey and state == "travelling" then
			-- An inspection not signed before leaving is simply missed.
			for _, entry in journey.plan.entries do
				if entry.template == "inspection" and entry.status == "active" then
					endEntry(expedition, journey, entry, "skipped", "Left without signing")
				end
			end
		end
	end)

	ExpeditionService.StationReached:Connect(function(expedition, index)
		local journey = journeys[expedition.id]
		if not journey then
			return
		end
		for _, entry in journey.plan.entries do
			if entry.status == "pending" and entry.template == "inspection" and entry.segment == index then
				startEntry(expedition, journey, entry)
			elseif entry.status == "pending" and entry.template == "inspection" and entry.segment < index then
				entry.status = "skipped"
				entry.outcome = "Not on this route"
			end
		end
		if index == 2 then
			journey.choiceOpen = true
			journey.choiceDeadline = os.clock() + 240
			local options = {}
			for _, id in { "main", "cutoff" } do
				local r = JourneyRegistry.Routes[id]
				table.insert(options, { id = id, name = r.name, summary = r.summary })
			end
			Net.fireClients("JourneyChoice", ExpeditionService.playersOf(expedition), {
				id = "route",
				title = "The junction after Tolbridge",
				body = "Control can set the points either way. Choose before you leave the station; if nobody chooses, it is the main line.",
				options = options,
			})
		end
	end)

	ExpeditionService.Retried:Connect(function(expedition)
		local journey = journeys[expedition.id]
		if not journey then
			return
		end
		local back = expedition.stationIndex
		for i = #journey.plan.entries, 1, -1 do
			local entry = journey.plan.entries[i]
			if entry.status == "active" then
				Protect.call(JourneyEvents[entry.template].cleanup, entry.ctx)
			end
			if entry.chainedFrom and entry.segment > back then
				table.remove(journey.plan.entries, i)
			elseif entry.segment > back or (entry.template == "inspection" and entry.segment == back) then
				-- After the checkpoint: it happens again.
				entry.status = "pending"
				entry.outcome = nil
				entry.ctx = nil
			elseif entry.status == "active" then
				entry.status = "skipped"
				entry.outcome = "Interrupted by the retry"
			end
		end
		expedition.train.speedCap = nil
		expedition.train.fuelMultiplier = nil
		journey.quietUntil = os.clock() + 20
		for _, entry in journey.plan.entries do
			if entry.status == "pending" and entry.template == "inspection" and entry.segment == back then
				startEntry(expedition, journey, entry)
			end
		end
	end)

	ExpeditionService.Ended:Connect(function(expedition)
		local journey = journeys[expedition.id]
		if not journey then
			return
		end
		for _, entry in journey.plan.entries do
			if entry.status == "active" then
				Protect.call(JourneyEvents[entry.template].cleanup, entry.ctx)
			end
		end
		expedition.train.speedCap = nil
		expedition.train.fuelMultiplier = nil
		journeys[expedition.id] = nil
	end)

	InteractionService.RunTaskDone:Connect(function(player, part, usedFast)
		local expedition = ExpeditionService.forPlayer(player)
		local journey = if expedition then journeys[expedition.id] else nil
		if not journey then
			return
		end
		for _, entry in journey.plan.entries do
			local impl = JourneyEvents[entry.template]
			if entry.status == "active" and impl.onTask then
				Protect.call(impl.onTask, entry.ctx, part, usedFast)
			end
		end
	end)

	TrainService.HornSounded:Connect(function(train)
		for id, journey in journeys do
			local expedition = ExpeditionService.byId(id)
			if expedition and expedition.train == train then
				for _, entry in journey.plan.entries do
					local impl = JourneyEvents[entry.template]
					if entry.status == "active" and impl.onHorn then
						Protect.call(impl.onHorn, entry.ctx)
					end
				end
			end
		end
	end)

	Net.onServerInvoke("JourneyCommand", function(player, rawCommand, rawA, rawB)
		local command = Guard.enum(rawCommand, { "get", "set", "choose" })
		if command == "get" then
			local profile = DataService.getProfile(player)
			local completed = if profile then profile.journeys.completed else 0
			local tiers = {}
			for _, tier in JourneyRegistry.Tiers do
				table.insert(tiers, { id = tier.id, name = tier.name, summary = tier.summary, unlocked = completed >= tier.unlockAfter, unlockAfter = tier.unlockAfter })
			end
			local history = if profile then profile.journeys.history else {}
			return {
				ok = true,
				prefs = prefsFor(player.UserId),
				completed = completed,
				failed = if profile then profile.journeys.failed else 0,
				tiers = tiers,
				lastSeed = if #history > 0 then history[#history].seed else nil,
				utility = if profile then profile.journeys.utility else {},
				saved = DataService.isWritable(player),
			}
		elseif command == "set" then
			local p = prefsFor(player.UserId)
			local field = Guard.enum(rawA, { "mode", "tier", "seed" })
			if field == "mode" then
				p.mode = Guard.enum(rawB, { "story", "nightrun" }) or p.mode
			elseif field == "tier" then
				local id = Guard.enum(rawB, { "night", "hard", "last" })
				local profile = DataService.getProfile(player)
				local completed = if profile then profile.journeys.completed else 0
				if id and completed >= JourneyRegistry.tier(id).unlockAfter then
					p.tier = id
				else
					return { ok = false, error = "LOCKED" }
				end
			elseif field == "seed" then
				local n = tonumber(rawB)
				p.seed = if n and n >= 1 and n <= 99999 then math.floor(n) else nil
			end
			return { ok = true, prefs = p }
		elseif command == "choose" then
			local expedition = ExpeditionService.forPlayer(player)
			local journey = if expedition then journeys[expedition.id] else nil
			local option = Guard.enum(rawB, { "main", "cutoff" })
			if not expedition or not journey or not journey.choiceOpen or rawA ~= "route" or not option then
				return { ok = false, error = "NO_CHOICE" }
			end
			journey.choiceOpen = false
			journey.route = option
			journey.routeChosenBy = player.DisplayName
			expedition.route = table.clone(JourneyRegistry.Routes[option].stations)
			Net.fireClients("JourneyChoice", ExpeditionService.playersOf(expedition), { id = "route", closed = true })
			Net.fireClients("Notify", ExpeditionService.playersOf(expedition), {
				kind = "info",
				title = JourneyRegistry.Routes[option].name,
				body = player.DisplayName .. " set the points. " .. JourneyRegistry.Routes[option].summary,
				duration = 8,
			})
			ExpeditionService.push(expedition)
			return { ok = true }
		end
		return { ok = false, error = "BAD_COMMAND" }
	end)

	task.spawn(function()
		local last = os.clock()
		while true do
			task.wait(0.5)
			local now = os.clock()
			local dt = now - last
			last = now
			for id, journey in journeys do
				local expedition = ExpeditionService.byId(id)
				if expedition then
					local ok, err = Protect.call(step, expedition, journey, dt)
					if not ok then
						log.error("journey step failed: " .. tostring(err))
					end
				end
			end
		end
	end)

	log.info(string.format("started with %d event templates", #templateIds()))
end

return JourneyService
