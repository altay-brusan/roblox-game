--!strict
--[[
	AnalyticsService
	----------------
	Measurement, defined precisely enough to act on.

	WHAT THIS DOES AND DOES NOT DO
	------------------------------
	It records counters and funnel steps in server memory and writes periodic
	aggregate snapshots to an ordered DataStore, keyed by day. It does not
	collect personal information, does not send anything to a third party, and
	does not store anything about an individual player beyond their user ID
	against their own aggregate counters, which the profile already holds.

	It also does not invent numbers. Every metric below is computed from an
	event this project actually fires. There are no modelled or estimated
	values anywhere in this file, and nothing here reports a figure that has
	not been measured on a real server.

	THE FUNNEL
	----------
	The questions the operator needs answered, and the events that answer them:

	  Do players start a run?      join -> lobby_ready -> crew_formed -> departed
	  Do they finish it?           departed -> station_1..5 -> completed
	  Where do they leave?         left_at, recorded with the phase and station
	  Does the shop get opened?    shop_opened
	  Does opening convert?        shop_opened -> prompt_shown -> purchased
	  What sells?                  purchased, by product key
	  Do they come back?           session_count from the profile, at join

	Reading these is documented in docs/ANALYTICS.md, including what each one
	does not tell you.
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.LastSignal

local GameConfig = require(Shared.Config.GameConfig)
local Guard = require(Shared.Core.Guard)
local Logger = require(Shared.Core.Logger)
local Net = require(Shared.Core.Net)
local Protect = require(Shared.Core.Protect)

local DataService = require(script.Parent.DataService)
local ExpeditionService = require(script.Parent.ExpeditionService)
local PurchaseService = require(script.Parent.PurchaseService)
local ShopService = require(script.Parent.ShopService)
local SurvivalService = require(script.Parent.SurvivalService)

local log = Logger.new("AnalyticsService")

local AnalyticsService = {}

--------------------------------------------------------------------------
-- Counters
--------------------------------------------------------------------------

local counters: { [string]: number } = {}
local sessionStart: { [number]: number } = {}
local playerPhase: { [number]: string } = {}

local function bump(key: string, amount: number?)
	counters[key] = (counters[key] or 0) + (amount or 1)
end

AnalyticsService.bump = bump

function AnalyticsService.snapshot(): { [string]: number }
	local copy: { [string]: number } = {}
	for key, value in counters do
		copy[key] = value
	end
	copy.uptime_seconds = math.floor(os.clock())
	copy.players_online = #Players:GetPlayers()
	return copy
end

--------------------------------------------------------------------------
-- Derived rates
--------------------------------------------------------------------------

--- The numbers an operator actually reads, each defined as a ratio of two
--- measured counters. A rate with a zero denominator is reported as nil
--- rather than as zero, because "no data" and "zero percent" are different
--- answers and confusing them leads to bad decisions.
function AnalyticsService.rates(): { [string]: number? }
	local function ratio(numerator: string, denominator: string): number?
		local bottom = counters[denominator] or 0
		if bottom <= 0 then
			return nil
		end
		return (counters[numerator] or 0) / bottom
	end

	return {
		-- Of the players who joined, how many got as far as departing.
		departure_rate = ratio("departed", "joined"),
		-- Of the expeditions that departed, how many finished successfully.
		completion_rate = ratio("expedition_completed", "departed"),
		-- Of the players who opened the shop, how many saw a purchase prompt.
		prompt_rate = ratio("prompt_shown", "shop_opened"),
		-- Of the prompts shown, how many completed. This is the conversion
		-- number, and it is the one worth acting on.
		conversion_rate = ratio("purchased", "prompt_shown"),
		-- Of the purchases made, how many were by a player who had bought
		-- before. Repeat purchase is the health signal for a live game.
		repeat_purchase_rate = ratio("purchased_repeat", "purchased"),
		-- Downs per expedition, a difficulty signal.
		downs_per_expedition = ratio("player_downed", "departed"),
	}
end

--------------------------------------------------------------------------
-- Persistence
--------------------------------------------------------------------------

local store: DataStore? = nil
if not RunService:IsStudio() then
	local ok, result = Protect.call(function()
		return DataStoreService:GetDataStore("LastSignal_Analytics_v1")
	end)
	if ok then
		store = result
	else
		log.warn("analytics store unavailable; counters stay in memory for this server only")
	end
end

local function dayKey(): string
	return os.date("!%Y-%m-%d")
end

--- Merges this server's counters into the day's aggregate. UpdateAsync makes
--- the merge safe when many servers write the same key.
local function flush()
	local target = store
	if not target then
		return
	end
	local snapshot = AnalyticsService.snapshot()
	local ok, err = Protect.call(function()
		target:UpdateAsync(dayKey(), function(current)
			local aggregate = current or {}
			for key, value in snapshot do
				if key ~= "uptime_seconds" and key ~= "players_online" then
					aggregate[key] = (aggregate[key] or 0) + value
				end
			end
			aggregate.servers_reporting = (aggregate.servers_reporting or 0) + 1
			return aggregate
		end)
	end)
	if ok then
		-- Counters are reset after a successful flush so the next flush does
		-- not double-count this server's events.
		table.clear(counters)
	else
		log.warn("analytics flush failed; counters retained:", tostring(err))
	end
end

function AnalyticsService.readDay(day: string?): { [string]: any }?
	local target = store
	if not target then
		return nil
	end
	local ok, result = Protect.call(function()
		return target:GetAsync(day or dayKey())
	end)
	return if ok then result else nil
end

--------------------------------------------------------------------------

function AnalyticsService.start()
	Players.PlayerAdded:Connect(function(player)
		sessionStart[player.UserId] = os.clock()
		playerPhase[player.UserId] = "joining"
		bump("joined")
	end)

	DataService.ProfileLoaded:Connect(function(player, profile)
		playerPhase[player.UserId] = "lobby"
		bump("lobby_ready")
		if profile.sessionCount > 1 then
			bump("returning_player")
		else
			bump("new_player")
		end
		if not DataService.isWritable(player) then
			bump("session_read_only")
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		local phase = playerPhase[player.UserId] or "unknown"
		bump("left_at_" .. phase)
		local started = sessionStart[player.UserId]
		if started then
			bump("session_seconds", math.floor(os.clock() - started))
			bump("sessions_ended")
		end
		sessionStart[player.UserId] = nil
		playerPhase[player.UserId] = nil
	end)

	ExpeditionService.StateChanged:Connect(function(expedition, state)
		for _, player in ExpeditionService.playersOf(expedition) do
			playerPhase[player.UserId] = state
		end
		if state == "cinematic" then
			bump("departed")
			bump("departed_crew_" .. tostring(expedition.crewSize))
			bump("departed_difficulty_" .. expedition.difficulty)
		end
	end)

	ExpeditionService.StationReached:Connect(function(_expedition, index)
		bump("station_reached_" .. tostring(index))
	end)

	ExpeditionService.Ended:Connect(function(expedition, success)
		if success then
			bump("expedition_completed")
		else
			bump("expedition_failed")
		end
		bump("expedition_seconds", math.floor((expedition.endedAt or os.clock()) - expedition.startedAt))
	end)

	SurvivalService.Downed:Connect(function()
		bump("player_downed")
	end)
	SurvivalService.Died:Connect(function()
		bump("player_died")
	end)
	SurvivalService.Revived:Connect(function(_player, by)
		bump(if by then "revive_by_teammate" else "revive_self")
	end)

	PurchaseService.Purchased:Connect(function(player, productKey, robux)
		bump("purchased")
		bump("purchased_" .. productKey)
		if robux > 0 then
			bump("robux_spent", robux)
		end
		local profile = DataService.getProfile(player)
		if profile then
			local distinct = 0
			for _, count in profile.purchases.products do
				if count > 0 then
					distinct += 1
				end
			end
			if distinct > 1 then
				bump("purchased_repeat")
			end
		end
	end)

	ShopService.PromptBlocked:Connect(function(_player, reason)
		bump("prompt_blocked_" .. reason)
	end)

	-- Client-reported funnel markers. These are the only client-originated
	-- analytics, they carry no free text, and the event name is validated
	-- against a fixed list so a client cannot write arbitrary counter keys.
	local CLIENT_EVENTS = {
		"shop_opened",
		"shop_category_viewed",
		"prompt_shown",
		"settings_opened",
		"quests_opened",
		"crew_panel_opened",
		"cinematic_skipped",
		"tutorial_prompt_seen",
		"mobile_session",
		"tablet_session",
		"desktop_session",
		"console_session",
	}
	Net.onServerEvent("Analytics", function(_player, rawEvent)
		local event = Guard.enum(rawEvent, CLIENT_EVENTS)
		if not event then
			return
		end
		bump(event)
	end)

	if store then
		task.spawn(function()
			while true do
				task.wait(300)
				local ok, err = Protect.call(flush)
				if not ok then
					log.warn("flush error:", tostring(err))
				end
			end
		end)
		game:BindToClose(function()
			Protect.call(flush)
		end)
	end

	log.info(string.format("started (persistence: %s, build %s)", if store then "on" else "memory only", GameConfig.BuildId))
end

return AnalyticsService
