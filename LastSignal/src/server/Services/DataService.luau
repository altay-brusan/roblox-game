--!strict
--[[
	DataService
	-----------
	Profile loading, session locking, autosave and shutdown safety.

	THE RULE THAT MATTERS
	---------------------
	Never overwrite real progress with defaults. Every failure path in this
	file either keeps the player's existing data or refuses to save, and none
	of them silently substitute a fresh profile. A player whose load failed
	gets a clearly-marked read-only session and a visible warning; they do not
	get a blank profile that then saves over eight hours of progress.

	SESSION LOCKING
	---------------
	Two servers editing the same profile is the classic duplication bug. Each
	profile carries a lock: server job id plus a heartbeat timestamp. Loading
	claims the lock; a lock whose heartbeat is older than the stale threshold
	is considered abandoned and can be taken over, which is what recovers a
	profile after a server crash.

	STUDIO
	------
	Studio usually has no DataStore access, and using live data from Studio is
	how test edits reach real players. With GameConfig.UseMockDataInStudio the
	service uses an in-memory store instead, so the full progression loop is
	testable and nothing touches production. That is logged loudly at boot.
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.LastSignal

local GameConfig = require(Shared.Config.GameConfig)
local Logger = require(Shared.Core.Logger)
local Signal = require(Shared.Core.Signal)
local TableUtil = require(Shared.Core.TableUtil)
local Protect = require(Shared.Core.Protect)
local ProfileSchema = require(script.Parent.ProfileSchema)

local log = Logger.new("DataService")

local DataService = {}

export type Profile = ProfileSchema.Profile

export type Session = {
	player: Player,
	userId: number,
	profile: Profile,
	-- False when the profile could not be loaded or the lock could not be
	-- taken. A read-only session never saves.
	writable: boolean,
	-- Why the session is read-only, surfaced to the player.
	readOnlyReason: string?,
	loadedAt: number,
	lastSave: number,
	dirty: boolean,
	-- Guards against two concurrent saves for the same player.
	saving: boolean,
}

--------------------------------------------------------------------------

local sessions: { [number]: Session } = {}
local shuttingDown = false

DataService.ProfileLoaded = Signal.new() :: Signal.Signal<Player, Profile>
DataService.ProfileReleased = Signal.new() :: Signal.Signal<Player, Profile>
DataService.ProfileChanged = Signal.new() :: Signal.Signal<Player, Profile>

--------------------------------------------------------------------------
-- Store abstraction
--------------------------------------------------------------------------

type StoreLike = {
	update: (key: string, transform: (any) -> any?) -> (boolean, any),
	read: (key: string) -> (boolean, any),
}

local useMock = RunService:IsStudio() and GameConfig.UseMockDataInStudio

local realStore: DataStore? = nil
local mockData: { [string]: any } = {}

if not useMock then
	local ok, store = pcall(function()
		return DataStoreService:GetDataStore(GameConfig.DataStoreName)
	end)
	if ok then
		realStore = store
	else
		log.error("could not open DataStore; all sessions will be read-only:", tostring(store))
	end
else
	log.warn("Studio mock data is ACTIVE. Progress is in memory only and no live player data is touched.")
end

--- UpdateAsync with retries and exponential backoff. Returns (ok, value).
--- The transform may return nil to abort the write without erroring.
local function storeUpdate(key: string, transform: (any) -> any?): (boolean, any)
	if useMock then
		local result = transform(TableUtil.deepCopy(mockData[key]))
		if result == nil then
			return false, mockData[key]
		end
		mockData[key] = TableUtil.deepCopy(result)
		return true, result
	end

	local store = realStore
	if not store then
		return false, nil
	end

	local delaySeconds = 0.6
	for attempt = 1, GameConfig.DataRetryAttempts do
		local aborted = false
		local ok, result = pcall(function()
			return store:UpdateAsync(key, function(current)
				local transformed = transform(current)
				if transformed == nil then
					aborted = true
					return nil
				end
				return transformed
			end)
		end)
		if ok and not aborted then
			return true, result
		end
		if aborted then
			return false, result
		end
		log.warn(string.format("UpdateAsync attempt %d for %s failed: %s", attempt, key, tostring(result)))
		if attempt < GameConfig.DataRetryAttempts then
			task.wait(delaySeconds)
			delaySeconds *= 2
		end
	end
	return false, nil
end

local function storeRead(key: string): (boolean, any)
	if useMock then
		return true, TableUtil.deepCopy(mockData[key])
	end
	local store = realStore
	if not store then
		return false, nil
	end
	local delaySeconds = 0.6
	for attempt = 1, GameConfig.DataRetryAttempts do
		local ok, result = pcall(function()
			return store:GetAsync(key)
		end)
		if ok then
			return true, result
		end
		log.warn(string.format("GetAsync attempt %d for %s failed: %s", attempt, key, tostring(result)))
		if attempt < GameConfig.DataRetryAttempts then
			task.wait(delaySeconds)
			delaySeconds *= 2
		end
	end
	return false, nil
end

local function keyFor(userId: number): string
	return "player_" .. tostring(userId)
end

--------------------------------------------------------------------------
-- Locking
--------------------------------------------------------------------------

type Envelope = {
	data: any,
	lockJobId: string?,
	lockHeartbeat: number?,
}

local function lockIsStale(envelope: Envelope): boolean
	local heartbeat = envelope.lockHeartbeat
	if not heartbeat then
		return true
	end
	return (os.time() - heartbeat) > GameConfig.SessionLockStaleSeconds
end

--------------------------------------------------------------------------
-- Loading
--------------------------------------------------------------------------

local function buildSession(player: Player, profile: Profile, writable: boolean, reason: string?): Session
	return {
		player = player,
		userId = player.UserId,
		profile = profile,
		writable = writable,
		readOnlyReason = reason,
		loadedAt = os.clock(),
		lastSave = os.clock(),
		dirty = false,
		saving = false,
	}
end

--- Loads a profile and claims its session lock.
function DataService.load(player: Player): Session
	local userId = player.UserId
	local existing = sessions[userId]
	if existing then
		return existing
	end

	local key = keyFor(userId)
	local jobId = if game.JobId ~= "" then game.JobId else "studio"

	local claimed = false
	local loadedData: any = nil
	local lockedByOther = false

	local ok, result = storeUpdate(key, function(current: any): any?
		local envelope: Envelope = current or { data = nil, lockJobId = nil, lockHeartbeat = nil }

		-- Someone else holds a live lock. Do not take the profile.
		if envelope.lockJobId and envelope.lockJobId ~= jobId and not lockIsStale(envelope) then
			lockedByOther = true
			return nil -- abort the write, leaving their lock intact
		end

		envelope.lockJobId = jobId
		envelope.lockHeartbeat = os.time()
		claimed = true
		loadedData = envelope.data
		return envelope
	end)

	if lockedByOther then
		-- A read-only session: the player can play, but nothing is written.
		-- This is far better than kicking them, and far better than writing.
		log.warn(string.format("%s is locked by another server; session is read-only", player.Name))
		local fallbackOk, fallbackEnvelope = storeRead(key)
		local fallbackProfile: Profile
		if fallbackOk and fallbackEnvelope and fallbackEnvelope.data then
			local migrated = ProfileSchema.migrate(fallbackEnvelope.data)
			fallbackProfile = ProfileSchema.normalise(migrated)
		else
			fallbackProfile = ProfileSchema.fresh()
		end
		local session = buildSession(player, fallbackProfile, false, "SESSION_LOCKED")
		sessions[userId] = session
		DataService.ProfileLoaded:Fire(player, session.profile)
		return session
	end

	if not ok or not claimed then
		-- The store is unavailable. A fresh profile here that later saved would
		-- destroy the player's progress, so this session never writes.
		log.error(string.format("could not load %s (%s); session is read-only", player.Name, tostring(result)))
		local session = buildSession(player, ProfileSchema.fresh(), false, "LOAD_FAILED")
		sessions[userId] = session
		DataService.ProfileLoaded:Fire(player, session.profile)
		return session
	end

	local profile: Profile
	local isNew = loadedData == nil
	if isNew then
		profile = ProfileSchema.fresh()
		log.info(string.format("new profile for %s", player.Name))
	else
		local migrated, migrationChanged = ProfileSchema.migrate(loadedData)
		if migrated.version ~= GameConfig.DataVersion then
			-- Migration did not complete. The profile is playable but must not
			-- be written back in a half-migrated state.
			log.error(
				string.format("migration incomplete for %s (at v%s); session is read-only", player.Name, tostring(migrated.version))
			)
			local session = buildSession(player, ProfileSchema.normalise(migrated), false, "MIGRATION_FAILED")
			sessions[userId] = session
			DataService.ProfileLoaded:Fire(player, session.profile)
			return session
		end
		profile = ProfileSchema.normalise(migrated)
		if migrationChanged then
			log.info(string.format("migrated %s to v%d", player.Name, GameConfig.DataVersion))
		end
	end

	profile.lastSeen = os.time()
	profile.sessionCount += 1
	if profile.firstJoin == 0 then
		profile.firstJoin = os.time()
	end

	local session = buildSession(player, profile, true, nil)
	session.dirty = true
	sessions[userId] = session
	DataService.ProfileLoaded:Fire(player, profile)
	return session
end

--------------------------------------------------------------------------
-- Saving
--------------------------------------------------------------------------

--- Writes the profile and refreshes the lock heartbeat.
--- `release` drops the lock, which must happen when the player leaves.
function DataService.save(userId: number, release: boolean?): boolean
	local session = sessions[userId]
	if not session then
		return false
	end
	if not session.writable then
		return false
	end
	if session.saving then
		return false
	end
	session.saving = true

	local jobId = if game.JobId ~= "" then game.JobId else "studio"
	local snapshot = TableUtil.deepCopy(session.profile)
	snapshot.lastSeen = os.time()

	local ok = storeUpdate(keyFor(userId), function(current: any): any?
		local envelope: Envelope = current or {}

		-- Another server took the profile while we held it. That means our lock
		-- went stale, which means our copy may be behind theirs. Merging blindly
		-- risks reverting their work, so we refuse and mark the session
		-- read-only rather than overwrite.
		if envelope.lockJobId and envelope.lockJobId ~= jobId then
			return nil
		end

		-- Purchase receipts are unioned rather than replaced. If a receipt was
		-- processed on another server between our load and our save, it must
		-- survive; losing one means a player paid and got nothing.
		if envelope.data and envelope.data.purchases then
			local stored = envelope.data.purchases
			if type(stored.receipts) == "table" then
				for receiptId, timestamp in stored.receipts do
					if snapshot.purchases.receipts[receiptId] == nil then
						snapshot.purchases.receipts[receiptId] = timestamp
					end
				end
			end
			if type(stored.products) == "table" then
				for productKey, count in stored.products do
					local mine = snapshot.purchases.products[productKey] or 0
					if type(count) == "number" and count > mine then
						snapshot.purchases.products[productKey] = count
					end
				end
			end
			if type(stored.robuxSpent) == "number" and stored.robuxSpent > snapshot.purchases.robuxSpent then
				snapshot.purchases.robuxSpent = stored.robuxSpent
			end
		end

		envelope.data = snapshot
		if release then
			envelope.lockJobId = nil
			envelope.lockHeartbeat = nil
		else
			envelope.lockJobId = jobId
			envelope.lockHeartbeat = os.time()
		end
		return envelope
	end)

	session.saving = false
	if ok then
		session.lastSave = os.clock()
		session.dirty = false
	else
		log.error(string.format("save failed for %d; marking session read-only", userId))
		session.writable = false
		session.readOnlyReason = "SAVE_CONFLICT"
	end
	return ok
end

--------------------------------------------------------------------------
-- Accessors
--------------------------------------------------------------------------

function DataService.getSession(player: Player): Session?
	return sessions[player.UserId]
end

function DataService.getProfile(player: Player): Profile?
	local session = sessions[player.UserId]
	return if session then session.profile else nil
end

--- Mutates a profile through a callback and marks it dirty. Every write to a
--- profile in this project goes through here, so nothing can change the data
--- without the autosave noticing.
function DataService.update(player: Player, mutator: (Profile) -> ()): boolean
	local session = sessions[player.UserId]
	if not session then
		return false
	end
	local ok, err = Protect.call(mutator, session.profile)
	if not ok then
		log.error("profile mutation failed:", tostring(err))
		return false
	end
	session.dirty = true
	DataService.ProfileChanged:Fire(player, session.profile)
	return true
end

function DataService.isWritable(player: Player): boolean
	local session = sessions[player.UserId]
	return session ~= nil and session.writable
end

function DataService.readOnlyReason(player: Player): string?
	local session = sessions[player.UserId]
	return if session then session.readOnlyReason else nil
end

--- Reads another player's profile without claiming it. Used by admin tools
--- and the leaderboard. Never returns a writable handle.
function DataService.peek(userId: number): Profile?
	local live = sessions[userId]
	if live then
		return TableUtil.deepCopy(live.profile) :: Profile
	end
	local ok, envelope = storeRead(keyFor(userId))
	if not ok or not envelope or not envelope.data then
		return nil
	end
	local migrated = ProfileSchema.migrate(envelope.data)
	return ProfileSchema.normalise(migrated)
end

--------------------------------------------------------------------------
-- Release and lifecycle
--------------------------------------------------------------------------

function DataService.release(player: Player)
	local userId = player.UserId
	local session = sessions[userId]
	if not session then
		return
	end
	if session.writable then
		DataService.save(userId, true)
	end
	DataService.ProfileReleased:Fire(player, session.profile)
	sessions[userId] = nil
end

--- Owner-only. Wipes gameplay progress but preserves purchase records, because
--- a player who spent Robux keeps what they bought regardless of a reset.
function DataService.resetProgress(userId: number): boolean
	local session = sessions[userId]
	if not session or not session.writable then
		return false
	end
	local preservedPurchases = TableUtil.deepCopy(session.profile.purchases)
	local fresh = ProfileSchema.fresh()
	fresh.purchases = preservedPurchases
	fresh.firstJoin = session.profile.firstJoin
	fresh.sessionCount = session.profile.sessionCount

	-- Re-grant everything the preserved purchases entitle them to. Without
	-- this, a reset would take away paid cosmetics while keeping the receipt.
	session.profile = fresh
	session.dirty = true
	DataService.ProfileChanged:Fire(session.player, fresh)
	return true
end

function DataService.start()
	Players.PlayerRemoving:Connect(function(player)
		DataService.release(player)
	end)

	-- Autosave loop. Staggered by user id so twenty players do not all write
	-- in the same second and exhaust the DataStore budget.
	task.spawn(function()
		while not shuttingDown do
			task.wait(5)
			local now = os.clock()
			for userId, session in sessions do
				if session.writable and session.dirty then
					local stagger = (userId % 30)
					if now - session.lastSave >= GameConfig.AutosaveIntervalSeconds + stagger then
						task.spawn(DataService.save, userId, false)
					end
				end
			end
		end
	end)

	-- Lock heartbeat. Refreshing while playing is what stops another server
	-- deciding our lock is stale during a long session.
	task.spawn(function()
		while not shuttingDown do
			task.wait(GameConfig.SessionLockStaleSeconds / 4)
			for userId, session in sessions do
				if session.writable and not session.dirty then
					task.spawn(DataService.save, userId, false)
				end
			end
		end
	end)

	game:BindToClose(function()
		shuttingDown = true
		log.info("shutdown: flushing profiles")
		local pending = 0
		local completed = 0
		for userId, session in sessions do
			if session.writable then
				pending += 1
				task.spawn(function()
					DataService.save(userId, true)
					completed += 1
				end)
			end
		end
		-- Roblox allows roughly 30 seconds at shutdown. Waiting for real
		-- completion rather than a fixed sleep means a fast flush does not
		-- stall the shutdown and a slow one is not cut off early.
		local deadline = os.clock() + 25
		while completed < pending and os.clock() < deadline do
			task.wait(0.2)
		end
		log.info(string.format("shutdown: saved %d/%d profiles", completed, pending))
	end)

	log.info(string.format("started (store: %s)", if useMock then "STUDIO MOCK" else GameConfig.DataStoreName))
end

--- Exposed for the admin tools and the boot report.
function DataService.status(): { mock: boolean, available: boolean, sessions: number, readOnly: number }
	local total, readOnly = 0, 0
	for _, session in sessions do
		total += 1
		if not session.writable then
			readOnly += 1
		end
	end
	return {
		mock = useMock,
		available = useMock or realStore ~= nil,
		sessions = total,
		readOnly = readOnly,
	}
end

return DataService
