--!strict
--[[
	QuestService
	------------
	Daily quests, weekly quests and chapter milestones.

	Progress is derived from statistics rather than pushed by gameplay systems.
	When a stat changes, every quest watching that stat re-evaluates. This makes
	it impossible for a quest to miss an event, and it means quest progress
	survives a server crash: the stat is in the profile, so the progress is too.

	Daily and weekly sets are chosen from a shared seed, so everyone in a server
	is working on the same objectives and a crew can co-operate on them.

	Claims are explicit. Completing a quest does not auto-grant; the player
	claims it from the notice board or the quest panel. That is both a better
	reward moment and the thing that makes double-granting impossible, because
	the claimed flag is checked and set in one profile update.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.LastSignal

local Guard = require(Shared.Core.Guard)
local Logger = require(Shared.Core.Logger)
local Net = require(Shared.Core.Net)
local QuestRegistry = require(Shared.Registry.QuestRegistry)
local Monetization = require(Shared.Config.Monetization)
local DataService = require(script.Parent.DataService)
local ProgressionService = require(script.Parent.ProgressionService)

local log = Logger.new("QuestService")

local QuestService = {}

--------------------------------------------------------------------------
-- Slot resolution
--------------------------------------------------------------------------

--- Extra daily slots granted by owned products, resolved through the
--- monetization config so an unconfigured product grants nothing.
local function extraDailySlots(player: Player): number
	local profile = DataService.getProfile(player)
	if not profile then
		return 0
	end
	local extra = 0
	for productKey, count in profile.purchases.products do
		if count > 0 then
			local def = Monetization.get(productKey)
			if def and def.id > 0 and type(def.grants.extraDailyQuest) == "number" then
				extra += def.grants.extraDailyQuest
			end
		end
	end
	return extra
end

--- Rolls the daily and weekly sets forward if the period has changed.
--- Progress on the previous period is dropped, but nothing already claimed is
--- ever taken back.
function QuestService.refresh(player: Player)
	local profile = DataService.getProfile(player)
	if not profile then
		return
	end

	local day = QuestRegistry.currentDay()
	local week = QuestRegistry.currentWeek()

	DataService.update(player, function(p)
		if p.quests.dailyDay ~= day then
			p.quests.dailyDay = day
			p.quests.daily = {}
			p.quests.dailyClaimed = {}
			for _, def in QuestRegistry.selectDaily(day, extraDailySlots(player)) do
				p.quests.daily[def.id] = 0
			end
		end
		if p.quests.weeklyWeek ~= week then
			p.quests.weeklyWeek = week
			p.quests.weekly = {}
			p.quests.weeklyClaimed = {}
			for _, def in QuestRegistry.selectWeekly(week) do
				p.quests.weekly[def.id] = 0
			end
		end
	end)

	QuestService.evaluate(player)
end

--------------------------------------------------------------------------
-- Progress
--------------------------------------------------------------------------

--- Recomputes progress for every active quest from the player's statistics.
--- Daily and weekly quests measure progress from a baseline captured when the
--- period rolled over, so a weekly "recover twenty records" counts records
--- recovered this week, not since the account was created.
function QuestService.evaluate(player: Player)
	local profile = DataService.getProfile(player)
	if not profile then
		return
	end

	DataService.update(player, function(p)
		for questId in p.quests.daily do
			local def = QuestRegistry.get(questId)
			if def then
				local baselineKey = "__baseline_daily_" .. def.stat
				local baseline = p.quests.daily[baselineKey]
				if baseline == nil then
					baseline = p.stats[def.stat] or 0
					p.quests.daily[baselineKey] = baseline
				end
				p.quests.daily[questId] = math.max(0, (p.stats[def.stat] or 0) - baseline)
			end
		end
		for questId in p.quests.weekly do
			local def = QuestRegistry.get(questId)
			if def then
				local baselineKey = "__baseline_weekly_" .. def.stat
				local baseline = p.quests.weekly[baselineKey]
				if baseline == nil then
					baseline = p.stats[def.stat] or 0
					p.quests.weekly[baselineKey] = baseline
				end
				p.quests.weekly[questId] = math.max(0, (p.stats[def.stat] or 0) - baseline)
			end
		end
	end)

	QuestService.pushToClient(player)
end

--------------------------------------------------------------------------
-- Claiming
--------------------------------------------------------------------------

local function questState(profile: any, questId: string): (string?, number, boolean)
	if profile.quests.daily[questId] ~= nil then
		return "daily", profile.quests.daily[questId], profile.quests.dailyClaimed[questId] == true
	end
	if profile.quests.weekly[questId] ~= nil then
		return "weekly", profile.quests.weekly[questId], profile.quests.weeklyClaimed[questId] == true
	end
	local def = QuestRegistry.get(questId)
	if def and def.period == "milestone" then
		return "milestone", profile.stats[def.stat] or 0, profile.quests.milestones[questId] == true
	end
	return nil, 0, false
end

function QuestService.claim(player: Player, questId: string): (boolean, string?)
	local profile = DataService.getProfile(player)
	if not profile then
		return false, "NOT_LOADED"
	end
	if not DataService.isWritable(player) then
		return false, "READ_ONLY"
	end

	local def = QuestRegistry.get(questId)
	if not def then
		return false, "UNKNOWN_QUEST"
	end

	local period, progress, alreadyClaimed = questState(profile, questId)
	if not period then
		return false, "NOT_ACTIVE"
	end
	if alreadyClaimed then
		return false, "ALREADY_CLAIMED"
	end
	if progress < def.target then
		return false, "INCOMPLETE"
	end

	-- Mark claimed inside the same update that reads the flag. Two rapid
	-- claims cannot both pass, because the second sees the flag already set.
	local granted = false
	DataService.update(player, function(p)
		local _, _, claimedNow = questState(p, questId)
		if claimedNow then
			return
		end
		if period == "daily" then
			p.quests.dailyClaimed[questId] = true
		elseif period == "weekly" then
			p.quests.weeklyClaimed[questId] = true
		else
			p.quests.milestones[questId] = true
		end
		granted = true
	end)

	if not granted then
		return false, "ALREADY_CLAIMED"
	end

	local unlocks = {}
	if def.reward then
		table.insert(unlocks, { kind = def.reward.kind, id = def.reward.id })
	end

	-- Quest rewards are exact. A multiplier on a fixed daily reward would make
	-- the paid pass feel mandatory for dailies, which is not the intent.
	ProgressionService.award(player, {
		credits = def.credits,
		xp = def.xp,
		unlocks = unlocks,
		source = "quest:" .. questId,
		exact = true,
	})

	log.info(string.format("%s claimed quest %s", player.Name, questId))
	QuestService.pushToClient(player)
	return true, nil
end

--------------------------------------------------------------------------
-- Client sync
--------------------------------------------------------------------------

local function describe(player: Player): { [string]: any }
	local profile = DataService.getProfile(player)
	if not profile then
		return { daily = {}, weekly = {}, milestones = {} }
	end

	local function pack(period: string, progressTable: { [string]: number }, claimedTable: { [string]: boolean })
		local out = {}
		for questId, progress in progressTable do
			-- Baseline bookkeeping keys are internal and never shown.
			if string.sub(questId, 1, 2) ~= "__" then
				local def = QuestRegistry.get(questId)
				if def then
					table.insert(out, {
						id = def.id,
						name = def.name,
						description = def.description,
						progress = math.min(progress, def.target),
						target = def.target,
						credits = def.credits,
						xp = def.xp,
						reward = def.reward,
						claimed = claimedTable[questId] == true,
						cooperative = def.cooperative == true,
						tier = def.tier,
						period = period,
					})
				end
			end
		end
		table.sort(out, function(a, b)
			return a.id < b.id
		end)
		return out
	end

	local milestones = {}
	for _, def in QuestRegistry.Milestones do
		local progress = profile.stats[def.stat] or 0
		table.insert(milestones, {
			id = def.id,
			name = def.name,
			description = def.description,
			progress = math.min(progress, def.target),
			target = def.target,
			credits = def.credits,
			xp = def.xp,
			reward = def.reward,
			claimed = profile.quests.milestones[def.id] == true,
			period = "milestone",
			tier = def.tier,
		})
	end

	return {
		daily = pack("daily", profile.quests.daily, profile.quests.dailyClaimed),
		weekly = pack("weekly", profile.quests.weekly, profile.quests.weeklyClaimed),
		milestones = milestones,
		dailyResetIn = QuestRegistry.secondsUntilDailyReset(),
		weeklyResetIn = QuestRegistry.secondsUntilWeeklyReset(),
	}
end

function QuestService.pushToClient(player: Player)
	Net.fireClient("QuestState", player, describe(player))
end

--------------------------------------------------------------------------

function QuestService.start()
	-- Cross-check that every quest watches a statistic that actually exists.
	-- A quest pointing at a stat nothing writes can never be completed, and
	-- shipping one of those is a silent trap for players.
	do
		local template = require(script.Parent.ProfileSchema).template()
		local missing: { string } = {}
		for _, stat in QuestRegistry.requiredStats() do
			if template.stats[stat] == nil then
				table.insert(missing, stat)
			end
		end
		if #missing > 0 then
			log.error("quests reference stats that are not in the profile schema: " .. table.concat(missing, ", "))
		end
	end

	DataService.ProfileLoaded:Connect(function(player)
		QuestService.refresh(player)
	end)

	ProgressionService.StatChanged:Connect(function(player)
		QuestService.evaluate(player)
	end)

	-- This service owns the RewardCommand remote. RewardService's commands are
	-- dispatched from here rather than by binding the remote twice, because a
	-- second OnServerInvoke binding silently replaces the first.
	local RewardService = require(script.Parent.RewardService)

	Net.onServerInvoke("RewardCommand", function(player, rawCommand, rawArg)
		local allowed = { "claim_quest", "refresh_quests" }
		for _, name in RewardService.Commands do
			table.insert(allowed, name)
		end

		local command = Guard.enum(rawCommand, allowed)
		if not command then
			return { ok = false, error = "BAD_COMMAND" }
		end

		if command == "refresh_quests" then
			QuestService.refresh(player)
			return { ok = true }
		end

		if command == "claim_quest" then
			local questId = Guard.id(rawArg)
			if not questId then
				return { ok = false, error = "BAD_QUEST" }
			end
			local ok, err = QuestService.claim(player, questId)
			return { ok = ok, error = err }
		end

		local handled = RewardService.handleCommand(player, command)
		if handled then
			return handled
		end
		return { ok = false, error = "BAD_COMMAND" }
	end)

	-- Roll periods over for players who stay online across a reset.
	task.spawn(function()
		while true do
			task.wait(60)
			for _, player in game:GetService("Players"):GetPlayers() do
				local profile = DataService.getProfile(player)
				if profile then
					if profile.quests.dailyDay ~= QuestRegistry.currentDay() or profile.quests.weeklyWeek ~= QuestRegistry.currentWeek() then
						QuestService.refresh(player)
					end
				end
			end
		end
	end)

	log.info("started")
end

return QuestService
