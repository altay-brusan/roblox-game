--!strict
--[[
	LeaderboardService
	------------------
	Global boards, on OrderedDataStores.

	WHAT IS RANKED, AND WHY
	-----------------------
	Only things that reward playing well or playing together. Deliberately not
	ranked: credits held, Robux spent, or anything else that would put a paying
	player at the top of a public list. A board that a purchase can climb turns
	the shop into a status ladder, which is the fastest way to make a paid item
	feel compulsory.

	  Expeditions completed   the headline board
	  Rescues                 cooperation
	  Records recovered       exploration
	  Fastest completion      skill, stored as a duration and ranked ascending

	OrderedDataStore only ranks integers ascending, so the fastest-time board
	stores (a large constant minus the duration) and is converted back when
	read. That is the standard approach and it is documented here because it is
	otherwise baffling to whoever maintains this next.
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

local log = Logger.new("LeaderboardService")

local LeaderboardService = {}

-- Fastest-time inversion constant. Any run longer than this is not ranked,
-- which is fine: it is well beyond the maximum sensible run length.
local TIME_CEILING = 7200

export type BoardDef = {
	id: string,
	name: string,
	description: string,
	stat: string?, -- profile stat that feeds it, when applicable
	inverted: boolean?, -- true for lower-is-better boards
	format: string, -- "number" | "duration"
}

local BOARDS: { BoardDef } = {
	{
		id = "completions",
		name = "Expeditions Completed",
		description = "Runs finished, all difficulties.",
		stat = "expeditions_completed",
		format = "number",
	},
	{
		id = "rescues",
		name = "Crew Recovered",
		description = "Teammates revived.",
		stat = "revives_given",
		format = "number",
	},
	{
		id = "records",
		name = "Records Recovered",
		description = "Dispatch logs and recordings found.",
		stat = "records_found",
		format = "number",
	},
	{
		id = "fastest",
		name = "Fastest Line",
		description = "Quickest complete run of the chapter.",
		inverted = true,
		format = "duration",
	},
}

LeaderboardService.Boards = BOARDS

--------------------------------------------------------------------------

local stores: { [string]: OrderedDataStore } = {}
local cache: { [string]: { fetchedAt: number, entries: { any } } } = {}
local CACHE_TTL = 120

local available = not RunService:IsStudio()

local function storeFor(boardId: string): OrderedDataStore?
	if not available then
		return nil
	end
	local existing = stores[boardId]
	if existing then
		return existing
	end
	local ok, result = Protect.call(function()
		return DataStoreService:GetOrderedDataStore(GameConfig.LeaderboardStoreName .. "_" .. boardId)
	end)
	if not ok then
		log.warn(string.format("board %s unavailable: %s", boardId, tostring(result)))
		return nil
	end
	stores[boardId] = result
	return result
end

--------------------------------------------------------------------------
-- Submission
--------------------------------------------------------------------------

local function submit(boardId: string, userId: number, value: number)
	local store = storeFor(boardId)
	if not store then
		return
	end
	local rounded = math.floor(value)
	if rounded <= 0 then
		return
	end
	local ok, err = Protect.call(function()
		-- The transform returns nil to abort the write when the new value is
		-- not an improvement. Luau types the callback as always returning a
		-- number, so the cast keeps the abort form the API actually supports.
		local transform = (function(current: any): any
			local existing = tonumber(current) or 0
			-- Boards only ever move up, which also means a partial or failed
			-- read can never lower somebody's standing.
			if rounded <= existing then
				return nil
			end
			return rounded
		end :: any) :: (any) -> number
		store:UpdateAsync(tostring(userId), transform)
	end)
	if not ok then
		log.warn(string.format("submit to %s failed: %s", boardId, tostring(err)))
	end
end

--- Pushes a player's current standing to every stat-backed board.
function LeaderboardService.submitAll(player: Player)
	local profile = DataService.getProfile(player)
	if not profile then
		return
	end
	for _, board in BOARDS do
		if board.stat then
			submit(board.id, player.UserId, profile.stats[board.stat] or 0)
		end
	end
end

--------------------------------------------------------------------------
-- Reading
--------------------------------------------------------------------------

function LeaderboardService.read(boardId: string, limit: number?): { any }
	local cached = cache[boardId]
	if cached and (os.clock() - cached.fetchedAt) < CACHE_TTL then
		return cached.entries
	end

	local store = storeFor(boardId)
	if not store then
		return {}
	end

	local board: BoardDef? = nil
	for _, candidate in BOARDS do
		if candidate.id == boardId then
			board = candidate
			break
		end
	end
	if not board then
		return {}
	end

	local count = math.clamp(limit or 25, 1, 100)
	local ok, pages = Protect.call(function()
		return store:GetSortedAsync(false, count)
	end)
	if not ok then
		log.warn(string.format("read of %s failed: %s", boardId, tostring(pages)))
		return cached and cached.entries or {}
	end

	local entries: { any } = {}
	local okPage, page = Protect.call(function()
		return (pages :: any):GetCurrentPage()
	end)
	if okPage and type(page) == "table" then
		for rank, entry in page do
			local userId = tonumber(entry.key) or 0
			local value = entry.value
			if (board :: BoardDef).inverted then
				value = TIME_CEILING - value
			end
			-- Names are resolved lazily and failures fall back to the user ID,
			-- so a rate-limited name lookup never blanks the board.
			local name = "Player " .. tostring(userId)
			local okName, resolvedName = Protect.call(function()
				return Players:GetNameFromUserIdAsync(userId)
			end)
			if okName and type(resolvedName) == "string" then
				name = resolvedName
			end
			table.insert(entries, { rank = rank, userId = userId, name = name, value = value })
		end
	end

	cache[boardId] = { fetchedAt = os.clock(), entries = entries }
	return entries
end

--------------------------------------------------------------------------

function LeaderboardService.start()
	if not available then
		log.warn("leaderboards are disabled in Studio; OrderedDataStore access is not reliable there")
	end

	Net.onServerInvoke("LeaderboardData", function(player, rawBoard)
		local boardId = Guard.id(rawBoard)
		local descriptors = {}
		for _, board in BOARDS do
			table.insert(descriptors, {
				id = board.id,
				name = board.name,
				description = board.description,
				format = board.format,
			})
		end
		if not boardId then
			return { ok = true, boards = descriptors, entries = {} }
		end
		local profile = DataService.getProfile(player)
		local personal: number? = nil
		for _, board in BOARDS do
			if board.id == boardId and board.stat and profile then
				personal = profile.stats[board.stat]
			end
		end
		return {
			ok = true,
			boards = descriptors,
			board = boardId,
			entries = LeaderboardService.read(boardId, 25),
			personal = personal,
			available = available,
		}
	end)

	-- Standings are submitted when a run ends rather than continuously, which
	-- keeps well inside the DataStore write budget.
	ExpeditionService.Ended:Connect(function(expedition, success)
		for _, player in ExpeditionService.playersOf(expedition) do
			task.spawn(LeaderboardService.submitAll, player)
		end
		if not success then
			return
		end
		-- Fastest board: only a full clear of every station counts.
		local elapsed = math.floor((expedition.endedAt or os.clock()) - expedition.startedAt)
		if elapsed > 0 and elapsed < TIME_CEILING and expedition.stationsCleared >= 5 then
			for _, player in ExpeditionService.playersOf(expedition) do
				task.spawn(submit, "fastest", player.UserId, TIME_CEILING - elapsed)
			end
		end
	end)

	-- Also submit on leave, so progress made without finishing a run counts.
	Players.PlayerRemoving:Connect(function(player)
		task.spawn(LeaderboardService.submitAll, player)
	end)

	log.info(string.format("started with %d boards", #BOARDS))
end

return LeaderboardService
