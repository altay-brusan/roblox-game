--!strict
--[[
	RewardService
	-------------
	Daily login rewards, login streaks and playtime rewards.

	Two design decisions here are deliberate and worth stating plainly:

	  1. Missing a day steps the streak back by one, it does not reset it.
	     A seven-day streak broken on day four becomes a three-day streak.
	     Nothing is ever taken away, and there is no product sold anywhere in
	     this project that protects or restores a streak.

	  2. Playtime rewards are capped per day. A reward that keeps paying out
	     forever turns into an incentive to idle in the lobby, which is the
	     opposite of what a session-based co-op game wants.

	Every claim writes a claimed-marker in the same profile update that reads
	it, so a double click, a reconnect or two servers cannot double-grant.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.LastSignal

local Balance = require(Shared.Config.Balance)
local Guard = require(Shared.Core.Guard)
local Logger = require(Shared.Core.Logger)
local Net = require(Shared.Core.Net)
local QuestRegistry = require(Shared.Registry.QuestRegistry)
local DataService = require(script.Parent.DataService)
local ProgressionService = require(script.Parent.ProgressionService)

local log = Logger.new("RewardService")

local RewardService = {}

--------------------------------------------------------------------------
-- Login rewards
--------------------------------------------------------------------------

--- The reward for a given streak position, wrapping once the table runs out
--- so a long streak keeps paying the top value rather than falling to zero.
local function loginRewardFor(streak: number): number
	local table_ = Balance.Economy.dailyLoginCredits
	local index = math.clamp(streak, 1, #table_)
	return table_[index]
end

--- Where the player's streak stands today, without changing anything.
function RewardService.loginState(player: Player): { available: boolean, streak: number, nextStreak: number, credits: number, claimedToday: boolean, resetIn: number }
	local profile = DataService.getProfile(player)
	local today = QuestRegistry.currentDay()
	if not profile then
		return { available = false, streak = 0, nextStreak = 1, credits = 0, claimedToday = false, resetIn = 0 }
	end

	local claimedToday = profile.login.lastClaimDay == today
	local gap = today - profile.login.lastClaimDay
	local nextStreak: number
	if profile.login.lastClaimDay == 0 then
		nextStreak = 1
	elseif gap <= 1 then
		nextStreak = profile.login.streak + (if claimedToday then 0 else 1)
	else
		-- Step back one for each missed day beyond the grace, floored at 1.
		local penalty = math.max(0, gap - 1 - Balance.Economy.streakGraceDays)
		nextStreak = math.max(1, profile.login.streak - penalty + 1)
	end

	return {
		available = not claimedToday,
		streak = profile.login.streak,
		nextStreak = nextStreak,
		credits = loginRewardFor(nextStreak),
		claimedToday = claimedToday,
		resetIn = QuestRegistry.secondsUntilDailyReset(),
	}
end

function RewardService.claimLogin(player: Player): (boolean, string?, number?)
	local profile = DataService.getProfile(player)
	if not profile then
		return false, "NOT_LOADED", nil
	end
	if not DataService.isWritable(player) then
		return false, "READ_ONLY", nil
	end

	local today = QuestRegistry.currentDay()
	if profile.login.lastClaimDay == today then
		return false, "ALREADY_CLAIMED", nil
	end

	local state = RewardService.loginState(player)
	local granted = false
	local awardedStreak = state.nextStreak

	DataService.update(player, function(p)
		-- Re-check inside the update: this is the line that makes the claim
		-- safe against a double click or a racing second call.
		if p.login.lastClaimDay == today then
			return
		end
		p.login.lastClaimDay = today
		p.login.streak = awardedStreak
		p.login.bestStreak = math.max(p.login.bestStreak, awardedStreak)
		granted = true
	end)

	if not granted then
		return false, "ALREADY_CLAIMED", nil
	end

	local credits = loginRewardFor(awardedStreak)
	ProgressionService.award(player, {
		credits = credits,
		xp = 0,
		source = "daily_login",
		exact = true,
	})

	log.info(string.format("%s claimed daily login, streak %d", player.Name, awardedStreak))
	RewardService.pushToClient(player)
	return true, nil, credits
end

--------------------------------------------------------------------------
-- Playtime rewards
--------------------------------------------------------------------------

local sessionSeconds: { [number]: number } = {}

function RewardService.playtimeState(player: Player): { secondsToday: number, claimed: number, maximum: number, nextAt: number, available: boolean }
	local profile = DataService.getProfile(player)
	if not profile then
		return { secondsToday = 0, claimed = 0, maximum = 0, nextAt = 0, available = false }
	end
	local interval = Balance.Economy.playtimeRewardIntervalSeconds
	local maximum = Balance.Economy.maxPlaytimeRewardsPerDay
	local earned = math.floor(profile.playtime.secondsToday / interval)
	local claimed = profile.playtime.rewardsClaimedToday
	return {
		secondsToday = profile.playtime.secondsToday,
		claimed = claimed,
		maximum = maximum,
		nextAt = (claimed + 1) * interval,
		available = claimed < maximum and earned > claimed,
	}
end

function RewardService.claimPlaytime(player: Player): (boolean, string?, number?)
	local profile = DataService.getProfile(player)
	if not profile then
		return false, "NOT_LOADED", nil
	end
	if not DataService.isWritable(player) then
		return false, "READ_ONLY", nil
	end

	local state = RewardService.playtimeState(player)
	if not state.available then
		return false, if state.claimed >= state.maximum then "DAILY_CAP" else "NOT_READY", nil
	end

	local granted = false
	DataService.update(player, function(p)
		local interval = Balance.Economy.playtimeRewardIntervalSeconds
		local earned = math.floor(p.playtime.secondsToday / interval)
		if p.playtime.rewardsClaimedToday >= Balance.Economy.maxPlaytimeRewardsPerDay then
			return
		end
		if earned <= p.playtime.rewardsClaimedToday then
			return
		end
		p.playtime.rewardsClaimedToday += 1
		granted = true
	end)

	if not granted then
		return false, "NOT_READY", nil
	end

	local credits = Balance.Economy.playtimeRewardCredits
	ProgressionService.award(player, { credits = credits, xp = 0, source = "playtime", exact = true })
	RewardService.pushToClient(player)
	return true, nil, credits
end

--------------------------------------------------------------------------
-- Client sync
--------------------------------------------------------------------------

function RewardService.pushToClient(player: Player)
	Net.fireClient("Notify", player, {
		kind = "rewards_state",
		login = RewardService.loginState(player),
		playtime = RewardService.playtimeState(player),
		silent = true,
	})
end

--------------------------------------------------------------------------

function RewardService.start()
	DataService.ProfileLoaded:Connect(function(player)
		sessionSeconds[player.UserId] = 0
		local today = QuestRegistry.currentDay()
		DataService.update(player, function(p)
			if p.playtime.day ~= today then
				p.playtime.day = today
				p.playtime.secondsToday = 0
				p.playtime.rewardsClaimedToday = 0
			end
		end)
		-- A short delay so the login panel does not fight the loading screen
		-- for the player's attention.
		task.delay(3, function()
			if player.Parent then
				RewardService.pushToClient(player)
			end
		end)
	end)

	Players.PlayerRemoving:Connect(function(player)
		sessionSeconds[player.UserId] = nil
	end)

	-- Playtime accrual. Counted in whole minutes so the write rate stays low.
	task.spawn(function()
		while true do
			task.wait(60)
			local today = QuestRegistry.currentDay()
			for _, player in Players:GetPlayers() do
				local profile = DataService.getProfile(player)
				if profile then
					DataService.update(player, function(p)
						if p.playtime.day ~= today then
							p.playtime.day = today
							p.playtime.secondsToday = 0
							p.playtime.rewardsClaimedToday = 0
						end
						p.playtime.secondsToday += 60
						p.stats.playtime_seconds = (p.stats.playtime_seconds or 0) + 60
					end)
					sessionSeconds[player.UserId] = (sessionSeconds[player.UserId] or 0) + 60
					local state = RewardService.playtimeState(player)
					if state.available then
						Net.fireClient("Notify", player, {
							kind = "reward_ready",
							title = "Playtime reward ready",
							body = "Collect it from the notice board or the rewards panel.",
							duration = 6,
						})
					end
					RewardService.pushToClient(player)
				end
			end
		end
	end)

	-- Reward claims share the single RewardCommand remote with quests.
	-- QuestService owns that remote's handler and dispatches unknown commands
	-- here, so neither service can overwrite the other's binding. A remote can
	-- only have one OnServerInvoke, and silently replacing one is a bug that
	-- looks like a rate limit.

	log.info("started")
end

--- Command handlers surfaced to QuestService's dispatcher, so both services
--- can share the single RewardCommand remote without one clobbering the other.
function RewardService.handleCommand(player: Player, command: string): { [string]: any }?
	if command == "claim_login" then
		local ok, err, credits = RewardService.claimLogin(player)
		return { ok = ok, error = err, credits = credits }
	elseif command == "claim_playtime" then
		local ok, err, credits = RewardService.claimPlaytime(player)
		return { ok = ok, error = err, credits = credits }
	elseif command == "reward_state" then
		return {
			ok = true,
			login = RewardService.loginState(player),
			playtime = RewardService.playtimeState(player),
		}
	end
	return nil
end

RewardService.Commands = { "claim_login", "claim_playtime", "reward_state" }

--- Used by QuestService when validating an incoming command name.
function RewardService.ownsCommand(command: string): boolean
	return table.find(RewardService.Commands, command) ~= nil
end

--- Kept so the Guard enum in QuestService stays in one place.
RewardService.GuardHelper = Guard

return RewardService
