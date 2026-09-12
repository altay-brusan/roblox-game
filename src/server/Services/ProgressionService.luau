--!strict
--[[
	ProgressionService
	------------------
	Credits, XP, levels, statistics and achievements.

	Everything that grants a reward in this game funnels through `award`, which
	means there is exactly one place that applies multipliers, one place that
	writes the profile, and one place that tells the client. That matters for
	the paid multipliers: the Signalman's Pass bonus cannot be applied twice or
	forgotten, because no other code path can grant credits.

	Statistics are the single source of truth for quest progress. A system
	reports "this happened" by bumping a stat; QuestService watches stats. No
	system ever reports progress to a quest directly, so a quest can never
	drift out of sync with the statistic it claims to track.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.LastSignal

local Balance = require(Shared.Config.Balance)
local Logger = require(Shared.Core.Logger)
local Net = require(Shared.Core.Net)
local Signal = require(Shared.Core.Signal)
local Monetization = require(Shared.Config.Monetization)
local CosmeticRegistry = require(Shared.Registry.CosmeticRegistry)
local TrainRegistry = require(Shared.Registry.TrainRegistry)
local WeaponRegistry = require(Shared.Registry.WeaponRegistry)
local DataService = require(script.Parent.DataService)
local ProfileSchema = require(script.Parent.ProfileSchema)

local log = Logger.new("ProgressionService")

local ProgressionService = {}

export type AwardSource = string

export type Award = {
	credits: number?,
	xp: number?,
	-- Stats to increment, as name -> amount.
	stats: { [string]: number }?,
	-- Cosmetics, liveries, interiors, trains or weapons to grant.
	unlocks: { { kind: string, id: string } }?,
	-- Where this came from, for analytics and for the reward feed.
	source: AwardSource,
	-- Skips multipliers. Used for admin grants and refunds, which must be exact.
	exact: boolean?,
}

export type AwardResult = {
	credits: number,
	xp: number,
	levelsGained: number,
	newLevel: number,
	unlocked: { { kind: string, id: string } },
}

ProgressionService.Awarded = Signal.new() :: Signal.Signal<Player, AwardResult, AwardSource>
ProgressionService.LevelUp = Signal.new() :: Signal.Signal<Player, number>
ProgressionService.StatChanged = Signal.new() :: Signal.Signal<Player, string, number>

--------------------------------------------------------------------------
-- Achievements
--------------------------------------------------------------------------

export type AchievementDef = {
	id: string,
	name: string,
	description: string,
	stat: string,
	target: number,
	credits: number,
	xp: number,
	cosmetic: string?,
	hidden: boolean?,
}

local ACHIEVEMENTS: { AchievementDef } = {
	{ id = "a_first_stop", name = "Request Stop", description = "Clear your first station.", stat = "stations_cleared", target = 1, credits = 120, xp = 100 },
	{ id = "a_ten_stops", name = "Regular Service", description = "Clear fifty stations.", stat = "stations_cleared", target = 50, credits = 800, xp = 650 },
	{ id = "a_hundred_stops", name = "Timetabled", description = "Clear two hundred stations.", stat = "stations_cleared", target = 200, credits = 2400, xp = 1900, cosmetic = "lantern_steel" },
	{ id = "a_driver", name = "Second Man", description = "Drive fifty kilometres of track.", stat = "distance_driven", target = 50000, credits = 600, xp = 500 },
	{ id = "a_long_driver", name = "Top Link", description = "Drive four hundred kilometres of track.", stat = "distance_driven", target = 400000, credits = 2800, xp = 2200, cosmetic = "outfit_yard" },
	{ id = "a_medic", name = "First Responder", description = "Revive twenty-five crew members.", stat = "revives_given", target = 25, credits = 700, xp = 600 },
	{ id = "a_medic_2", name = "Nobody Left", description = "Revive one hundred crew members.", stat = "revives_given", target = 100, credits = 2200, xp = 1800 },
	{ id = "a_mechanic", name = "Fitter", description = "Restore one thousand points of condition.", stat = "condition_repaired", target = 1000, credits = 700, xp = 600 },
	{ id = "a_archivist", name = "Paper Trail", description = "Recover one hundred records.", stat = "records_found", target = 100, credits = 900, xp = 750 },
	{ id = "a_explorer", name = "Off the Timetable", description = "Find thirty discoveries.", stat = "discoveries_found", target = 30, credits = 800, xp = 700 },
	{ id = "a_repel", name = "Not Tonight", description = "Drive off the Signal-Eater twenty times.", stat = "creature_repelled", target = 20, credits = 1100, xp = 950 },
	{ id = "a_sceptic", name = "Sceptic", description = "Ignore fifty false transmissions.", stat = "false_instructions_ignored", target = 50, credits = 1200, xp = 1000 },
	{ id = "a_complete", name = "The Long Grade", description = "Complete the chapter ten times.", stat = "expeditions_completed", target = 10, credits = 1500, xp = 1300 },
	{ id = "a_veteran", name = "Veteran Crew", description = "Complete the chapter fifty times.", stat = "expeditions_completed", target = 50, credits = 4000, xp = 3400, cosmetic = "lantern_operator" },
	{
		id = "a_never_down",
		name = "Untouched",
		description = "Complete five expeditions without being downed.",
		stat = "flawless_expeditions",
		target = 5,
		credits = 1800,
		xp = 1500,
		hidden = true,
	},
}

ProgressionService.Achievements = ACHIEVEMENTS

--------------------------------------------------------------------------
-- Multipliers
--------------------------------------------------------------------------

--- Everything that multiplies a reward, resolved in one place.
--- `crewSize` is passed by the expedition; elsewhere it is 1.
function ProgressionService.multipliers(player: Player, crewSize: number?): { credits: number, xp: number, reasons: { string } }
	local profile = DataService.getProfile(player)
	local creditMultiplier = 1.0
	local xpMultiplier = 1.0
	local reasons: { string } = {}

	if profile then
		-- Paid multipliers come from owned products, resolved through the
		-- monetization config so a product with no configured ID grants nothing.
		for productKey, count in profile.purchases.products do
			if count > 0 then
				local def = Monetization.get(productKey)
				if def and def.id > 0 then
					local grants = def.grants
					if type(grants.creditMultiplier) == "number" then
						creditMultiplier *= grants.creditMultiplier
						table.insert(reasons, def.name)
					end
					if type(grants.xpMultiplier) == "number" then
						xpMultiplier *= grants.xpMultiplier
					end
				end
			end
		end
	end

	-- Cooperation bonus. Scales with crew size, capped, and applies to
	-- everyone in the crew equally.
	if crewSize and crewSize > 1 then
		local bonus = math.min(Balance.Economy.maxCrewBonus, (crewSize - 1) * Balance.Economy.crewBonusPerMember)
		creditMultiplier *= (1 + bonus)
		xpMultiplier *= (1 + bonus)
		table.insert(reasons, string.format("Crew of %d", crewSize))
	end

	return { credits = creditMultiplier, xp = xpMultiplier, reasons = reasons }
end

--------------------------------------------------------------------------
-- Levelling
--------------------------------------------------------------------------

local function applyLevels(profile: ProfileSchema.Profile): number
	local gained = 0
	while profile.level < Balance.Progression.maxLevel do
		local needed = Balance.xpForLevel(profile.level)
		if profile.xp < needed then
			break
		end
		profile.xp -= needed
		profile.level += 1
		gained += 1
		-- A runaway grant should not loop forever.
		if gained > 100 then
			break
		end
	end
	if profile.level >= Balance.Progression.maxLevel then
		profile.xp = 0
	end
	return gained
end

--- XP still needed for the next level, for the HUD bar.
function ProgressionService.xpToNext(player: Player): (number, number)
	local profile = DataService.getProfile(player)
	if not profile then
		return 0, 1
	end
	if profile.level >= Balance.Progression.maxLevel then
		return 0, 1
	end
	return profile.xp, Balance.xpForLevel(profile.level)
end

--------------------------------------------------------------------------
-- Unlocks
--------------------------------------------------------------------------

--- Grants an unlock idempotently. Returns true only when it was newly granted,
--- so the reward feed does not announce something the player already had.
function ProgressionService.grantUnlock(player: Player, kind: string, id: string): boolean
	local profile = DataService.getProfile(player)
	if not profile then
		return false
	end

	local bucket: { [string]: boolean }?
	if kind == "cosmetic" then
		bucket = profile.cosmetics
		if not CosmeticRegistry.get(id) then
			log.warn("unknown cosmetic:", id)
			return false
		end
	elseif kind == "livery" then
		bucket = profile.liveries
		if not TrainRegistry.getLivery(id) or TrainRegistry.Liveries[id] == nil then
			log.warn("unknown livery:", id)
			return false
		end
	elseif kind == "interior" then
		bucket = profile.interiors
		if TrainRegistry.Interiors[id] == nil then
			log.warn("unknown interior:", id)
			return false
		end
	elseif kind == "train" then
		bucket = profile.trains
		if not TrainRegistry.get(id) then
			log.warn("unknown train:", id)
			return false
		end
	elseif kind == "weapon" then
		bucket = profile.weapons
		if not WeaponRegistry.exists(id) then
			log.warn("unknown weapon:", id)
			return false
		end
	else
		log.warn("unknown unlock kind:", kind)
		return false
	end

	local resolved = bucket :: { [string]: boolean }
	if resolved[id] then
		return false
	end
	DataService.update(player, function(p)
		local target: { [string]: boolean }
		if kind == "cosmetic" then
			target = p.cosmetics
		elseif kind == "livery" then
			target = p.liveries
		elseif kind == "interior" then
			target = p.interiors
		elseif kind == "train" then
			target = p.trains
		else
			target = p.weapons
		end
		target[id] = true
	end)
	return true
end

function ProgressionService.owns(player: Player, kind: string, id: string): boolean
	local profile = DataService.getProfile(player)
	if not profile then
		return false
	end
	if kind == "cosmetic" then
		return profile.cosmetics[id] == true
	elseif kind == "livery" then
		return profile.liveries[id] == true
	elseif kind == "interior" then
		return profile.interiors[id] == true
	elseif kind == "train" then
		return profile.trains[id] == true
	elseif kind == "weapon" then
		return profile.weapons[id] == true
	end
	return false
end

--------------------------------------------------------------------------
-- Statistics
--------------------------------------------------------------------------

function ProgressionService.addStat(player: Player, stat: string, amount: number): number
	local profile = DataService.getProfile(player)
	if not profile then
		return 0
	end
	if profile.stats[stat] == nil then
		-- An unknown stat is a bug, not a reason to lose the event. It is
		-- created so the data survives, and logged so it gets fixed.
		log.warn("stat not in schema, creating:", stat)
		profile.stats[stat] = 0
	end
	local newValue = 0
	DataService.update(player, function(p)
		p.stats[stat] = math.max(0, (p.stats[stat] or 0) + amount)
		newValue = p.stats[stat]
	end)
	ProgressionService.StatChanged:Fire(player, stat, newValue)
	ProgressionService.checkAchievements(player)
	return newValue
end

function ProgressionService.setStatMax(player: Player, stat: string, value: number): number
	local profile = DataService.getProfile(player)
	if not profile then
		return 0
	end
	local current = profile.stats[stat] or 0
	if value <= current then
		return current
	end
	return ProgressionService.addStat(player, stat, value - current)
end

function ProgressionService.getStat(player: Player, stat: string): number
	local profile = DataService.getProfile(player)
	if not profile then
		return 0
	end
	return profile.stats[stat] or 0
end

--------------------------------------------------------------------------
-- Awarding
--------------------------------------------------------------------------

--- The single entry point for granting anything. Returns exactly what was
--- granted after multipliers, which is what the reward feed displays.
function ProgressionService.award(player: Player, award: Award, crewSize: number?): AwardResult
	local result: AwardResult = { credits = 0, xp = 0, levelsGained = 0, newLevel = 1, unlocked = {} }
	local profile = DataService.getProfile(player)
	if not profile then
		return result
	end

	local multipliers = if award.exact then { credits = 1, xp = 1, reasons = {} } else ProgressionService.multipliers(player, crewSize)

	local credits = math.floor((award.credits or 0) * multipliers.credits + 0.5)
	local xp = math.floor((award.xp or 0) * multipliers.xp + 0.5)

	DataService.update(player, function(p)
		if credits ~= 0 then
			p.credits = math.max(0, p.credits + credits)
			if credits > 0 then
				p.stats.credits_earned = (p.stats.credits_earned or 0) + credits
			end
		end
		if xp > 0 then
			p.xp += xp
		end
		result.levelsGained = applyLevels(p)
		result.newLevel = p.level
	end)

	result.credits = credits
	result.xp = xp

	if award.stats then
		for stat, amount in award.stats do
			ProgressionService.addStat(player, stat, amount)
		end
	end

	if award.unlocks then
		for _, unlock in award.unlocks do
			if ProgressionService.grantUnlock(player, unlock.kind, unlock.id) then
				table.insert(result.unlocked, unlock)
			end
		end
	end

	if result.levelsGained > 0 then
		ProgressionService.LevelUp:Fire(player, result.newLevel)
	end

	ProgressionService.Awarded:Fire(player, result, award.source)
	ProgressionService.pushToClient(player)

	if result.credits ~= 0 or result.xp ~= 0 or #result.unlocked > 0 then
		Net.fireClient("RewardGranted", player, {
			credits = result.credits,
			xp = result.xp,
			levelsGained = result.levelsGained,
			level = result.newLevel,
			unlocked = result.unlocked,
			source = award.source,
			multiplierReasons = multipliers.reasons,
		})
	end

	return result
end

--- Spends credits. Returns false without spending when the balance is short,
--- which every caller must handle rather than assuming success.
function ProgressionService.spendCredits(player: Player, amount: number, reason: string): boolean
	if amount <= 0 then
		return false
	end
	local profile = DataService.getProfile(player)
	if not profile or profile.credits < amount then
		return false
	end
	if not DataService.isWritable(player) then
		-- A read-only session must not be allowed to spend, because the spend
		-- would not persist and the player would lose the purchase on rejoin.
		return false
	end
	DataService.update(player, function(p)
		p.credits -= amount
	end)
	log.debug(string.format("%s spent %d credits on %s", player.Name, amount, reason))
	ProgressionService.pushToClient(player)
	return true
end

--------------------------------------------------------------------------
-- Achievements
--------------------------------------------------------------------------

function ProgressionService.checkAchievements(player: Player)
	local profile = DataService.getProfile(player)
	if not profile then
		return
	end
	for _, def in ACHIEVEMENTS do
		if profile.achievements[def.id] == nil then
			local value = profile.stats[def.stat] or 0
			if value >= def.target then
				DataService.update(player, function(p)
					p.achievements[def.id] = os.time()
				end)
				local unlocks = {}
				if def.cosmetic then
					table.insert(unlocks, { kind = "cosmetic", id = def.cosmetic })
				end
				-- Achievement rewards are exact: they are a fixed prize, not
				-- something a multiplier should inflate.
				ProgressionService.award(player, {
					credits = def.credits,
					xp = def.xp,
					unlocks = unlocks,
					source = "achievement:" .. def.id,
					exact = true,
				})
				Net.fireClient("Notify", player, {
					kind = "achievement",
					title = def.name,
					body = def.description,
					duration = 6,
				})
				log.info(string.format("%s unlocked achievement %s", player.Name, def.id))
			end
		end
	end
end

function ProgressionService.achievementProgress(player: Player): { { id: string, name: string, description: string, progress: number, target: number, unlockedAt: number? } }
	local profile = DataService.getProfile(player)
	local out = {}
	if not profile then
		return out
	end
	for _, def in ACHIEVEMENTS do
		local unlockedAt = profile.achievements[def.id]
		if not def.hidden or unlockedAt then
			table.insert(out, {
				id = def.id,
				name = def.name,
				description = def.description,
				progress = math.min(def.target, profile.stats[def.stat] or 0),
				target = def.target,
				unlockedAt = unlockedAt,
			})
		end
	end
	return out
end

--------------------------------------------------------------------------
-- Client sync
--------------------------------------------------------------------------

function ProgressionService.pushToClient(player: Player)
	local profile = DataService.getProfile(player)
	if not profile then
		return
	end
	local payload = ProfileSchema.toClient(profile)
	payload.xpToNext = if profile.level < Balance.Progression.maxLevel then Balance.xpForLevel(profile.level) else 0
	payload.readOnly = not DataService.isWritable(player)
	payload.readOnlyReason = DataService.readOnlyReason(player)
	Net.fireClient("ProfileSnapshot", player, payload)
end

function ProgressionService.start()
	DataService.ProfileLoaded:Connect(function(player)
		ProgressionService.pushToClient(player)
		ProgressionService.checkAchievements(player)
		if not DataService.isWritable(player) then
			Net.fireClient("Notify", player, {
				kind = "warning",
				title = "Progress is not being saved",
				body = "Your data could not be loaded safely, so nothing will be written this session. Rejoining usually fixes it.",
				duration = 12,
				persistent = true,
			})
		end
	end)

	Net.onServerInvoke("RequestProfile", function(player)
		local profile = DataService.getProfile(player)
		if not profile then
			return { ok = false, error = "NOT_LOADED" }
		end
		ProgressionService.pushToClient(player)
		return { ok = true }
	end)

	log.info(string.format("started with %d achievements", #ACHIEVEMENTS))
end

return ProgressionService
