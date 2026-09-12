--!strict
--[[
	ProfileSchema
	-------------
	The shape of a saved player profile, plus the migration chain.

	Rules this file enforces:

	  1. `template` is the authority. New fields are added here and reach
	     existing players through TableUtil.reconcile at load, with no
	     migration step and no risk to existing data.
	  2. Migrations are only for changes reconcile cannot express: renamed
	     fields, changed units, restructured tables. Each migration is a pure
	     function from version N to N+1 and must never delete data it does not
	     understand.
	  3. Purchase records are append-only. No migration and no admin reset
	     removes them, because a player who paid Robux must keep what they paid
	     for even if every other part of the profile is wiped.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.LastSignal

local GameConfig = require(Shared.Config.GameConfig)
local CosmeticRegistry = require(Shared.Registry.CosmeticRegistry)
local TableUtil = require(Shared.Core.TableUtil)

local ProfileSchema = {}

export type Profile = {
	version: number,

	-- Economy and progression -------------------------------------------
	credits: number,
	xp: number,
	level: number,

	-- Ownership ----------------------------------------------------------
	trains: { [string]: boolean },
	liveries: { [string]: boolean },
	interiors: { [string]: boolean },
	cosmetics: { [string]: boolean },
	weapons: { [string]: boolean },

	-- Loadout and appearance ---------------------------------------------
	loadout: {
		train: string,
		livery: string,
		interior: string,
		primaryWeapon: string,
		sidearm: string,
		role: string,
		lamp: string,
		outfit: string,
		finish: string,
		patch: string,
	},

	-- Settings -------------------------------------------------------------
	settings: {
		masterVolume: number,
		musicVolume: number,
		ambienceVolume: number,
		sfxVolume: number,
		trainVolume: number,
		voiceVolume: number,
		uiVolume: number,
		creatureVolume: number,
		subtitles: boolean,
		directionalCues: boolean,
		reducedMotion: boolean,
		reducedFlashing: boolean,
		cameraShake: number,
		fieldOfView: number,
		hudScale: number,
		invertY: boolean,
		sensitivity: number,
		holdToSprint: boolean,
		holdToCrouch: boolean,
		touchLayout: string,
		highContrast: boolean,
		showDamageNumbers: boolean,
	},

	-- Statistics. Also the source of truth for quest progress counters.
	stats: { [string]: number },

	-- Quests ----------------------------------------------------------------
	quests: {
		dailyDay: number,
		daily: { [string]: number }, -- questId -> progress
		dailyClaimed: { [string]: boolean },
		weeklyWeek: number,
		weekly: { [string]: number },
		weeklyClaimed: { [string]: boolean },
		milestones: { [string]: boolean },
	},

	-- Daily rewards ----------------------------------------------------------
	login: {
		lastClaimDay: number,
		streak: number,
		bestStreak: number,
	},
	playtime: {
		day: number,
		secondsToday: number,
		rewardsClaimedToday: number,
	},

	-- Live events -------------------------------------------------------------
	events: {
		[string]: {
			tokens: number,
			claimed: { [string]: boolean }, -- threshold key -> claimed
			firstSeen: number,
		},
	},

	-- Achievements -------------------------------------------------------------
	achievements: { [string]: number }, -- id -> unlock timestamp

	-- Collections ----------------------------------------------------------------
	recordings: { [string]: boolean },
	discoveries: { [string]: boolean },

	-- Purchases. Append-only, never cleared. ------------------------------------
	purchases: {
		-- Roblox PurchaseId values already granted. This is what makes
		-- ProcessReceipt duplicate-safe across servers and reconnects.
		receipts: { [string]: number },
		-- Product key -> count of times purchased (consumables) or 1 (permanent).
		products: { [string]: number },
		-- Total Robux spent, for the operator's own reporting only.
		robuxSpent: number,
	},

	-- Session bookkeeping ---------------------------------------------------------
	firstJoin: number,
	lastSeen: number,
	sessionCount: number,
	-- Set while an expedition is in progress so a crash mid-run can restore
	-- the player to the right place rather than to a broken state.
	activeExpedition: {
		crewId: string?,
		stationIndex: number?,
		startedAt: number?,
	},
}

--------------------------------------------------------------------------
-- Template
--------------------------------------------------------------------------

local function defaultStats(): { [string]: number }
	-- Every stat a quest or achievement can reference must exist here, so a
	-- counter is never nil and progress arithmetic is always safe.
	return {
		expeditions_started = 0,
		expeditions_completed = 0,
		expeditions_failed = 0,
		expeditions_completed_blackout = 0,
		expeditions_completed_derelict = 0,
		full_line_runs = 0,
		clean_signal_runs = 0,
		large_crew_completions = 0,
		flawless_expeditions = 0,
		stations_cleared = 0,
		optional_objectives = 0,
		unique_objectives_completed = 0,
		silent_stations = 0,
		records_found = 0,
		unique_recordings = 0,
		discoveries_found = 0,
		revives_given = 0,
		revives_received = 0,
		times_downed = 0,
		deaths = 0,
		condition_repaired = 0,
		fuel_delivered = 0,
		distance_driven = 0,
		creature_repelled = 0,
		false_instructions_ignored = 0,
		false_instructions_followed = 0,
		shots_fired = 0,
		melee_hits = 0,
		items_collected = 0,
		credits_earned = 0,
		playtime_seconds = 0,
	}
end

local function defaultSettings()
	return {
		masterVolume = 0.85,
		musicVolume = 0.6,
		ambienceVolume = 0.8,
		sfxVolume = 0.9,
		trainVolume = 0.85,
		voiceVolume = 1.0,
		uiVolume = 0.7,
		creatureVolume = 1.0,
		subtitles = true,
		directionalCues = false,
		reducedMotion = false,
		reducedFlashing = false,
		cameraShake = 1.0,
		fieldOfView = 70,
		hudScale = 1.0,
		invertY = false,
		sensitivity = 1.0,
		holdToSprint = true,
		holdToCrouch = false,
		touchLayout = "default",
		highContrast = false,
		showDamageNumbers = false,
	}
end

function ProfileSchema.template(): Profile
	return {
		version = GameConfig.DataVersion,

		credits = 350, -- a small starting float so the shop is not empty on day one
		xp = 0,
		level = 1,

		trains = { warden = true },
		liveries = { livery_depot = true, livery_freight = true, livery_express = true, livery_engineering = true },
		interiors = { interior_standard = true },
		cosmetics = CosmeticRegistry.defaultOwned(),
		weapons = { wrench = true, crowbar = true, revolver = true },

		loadout = {
			train = "warden",
			livery = "livery_depot",
			interior = "interior_standard",
			primaryWeapon = "wrench",
			sidearm = "revolver",
			role = "crew",
			lamp = "lantern_standard",
			outfit = "outfit_crew",
			finish = "finish_standard",
			patch = "",
		},

		settings = defaultSettings(),
		stats = defaultStats(),

		quests = {
			dailyDay = 0,
			daily = {},
			dailyClaimed = {},
			weeklyWeek = 0,
			weekly = {},
			weeklyClaimed = {},
			milestones = {},
		},

		login = { lastClaimDay = 0, streak = 0, bestStreak = 0 },
		playtime = { day = 0, secondsToday = 0, rewardsClaimedToday = 0 },

		events = {},
		achievements = {},
		recordings = {},
		discoveries = {},

		purchases = { receipts = {}, products = {}, robuxSpent = 0 },

		firstJoin = 0,
		lastSeen = 0,
		sessionCount = 0,
		activeExpedition = {},
	}
end

--------------------------------------------------------------------------
-- Migrations
--------------------------------------------------------------------------

-- Each entry migrates FROM its key TO key + 1. Missing entries are treated as
-- no-ops, which is correct for versions whose only change was additive.
local MIGRATIONS: { [number]: (any) -> any } = {
	[1] = function(data: any): any
		-- v1 -> v2: cosmetics were stored as an array of ids; they are now a set.
		if type(data.cosmetics) == "table" and #data.cosmetics > 0 then
			local set: { [string]: boolean } = {}
			for _, id in data.cosmetics do
				if type(id) == "string" then
					set[id] = true
				end
			end
			data.cosmetics = set
		end
		return data
	end,

	[2] = function(data: any): any
		-- v2 -> v3: split the single `volume` setting into per-bus volumes, and
		-- moved purchase records under `purchases` so they can be protected as
		-- a unit. The old fields are read, then left in place rather than
		-- deleted, so a rollback to v2 still finds them.
		data.settings = data.settings or {}
		local legacyVolume = data.settings.volume
		if type(legacyVolume) == "number" then
			data.settings.masterVolume = legacyVolume
			data.settings.musicVolume = legacyVolume * 0.7
			data.settings.ambienceVolume = legacyVolume
			data.settings.sfxVolume = legacyVolume
			data.settings.trainVolume = legacyVolume
			data.settings.voiceVolume = math.min(1, legacyVolume * 1.15)
			data.settings.uiVolume = legacyVolume * 0.8
			data.settings.creatureVolume = legacyVolume
		end

		data.purchases = data.purchases or { receipts = {}, products = {}, robuxSpent = 0 }
		if type(data.receipts) == "table" then
			for key, value in data.receipts do
				if data.purchases.receipts[key] == nil then
					data.purchases.receipts[key] = value
				end
			end
		end
		if type(data.ownedProducts) == "table" then
			for key, value in data.ownedProducts do
				if data.purchases.products[key] == nil then
					data.purchases.products[key] = if type(value) == "number" then value else 1
				end
			end
		end
		return data
	end,
}

--- Runs every migration needed to bring `data` up to the current version.
--- Returns the migrated table and whether anything changed.
function ProfileSchema.migrate(data: any): (any, boolean)
	local from = tonumber(data.version) or 1
	local changed = false
	local current = data

	while from < GameConfig.DataVersion do
		local migration = MIGRATIONS[from]
		if migration then
			local ok, result = pcall(migration, current)
			if ok and type(result) == "table" then
				current = result
				changed = true
			else
				-- A failing migration must not destroy the profile. The data is
				-- left at its current version and the caller decides; DataService
				-- treats this as an uncertain load and refuses to overwrite.
				warn(string.format("[ProfileSchema] migration %d -> %d failed: %s", from, from + 1, tostring(result)))
				return current, changed
			end
		end
		from += 1
		current.version = from
		changed = true
	end

	return current, changed
end

--- Fills in anything missing and clamps values that must stay in range.
function ProfileSchema.normalise(data: any): Profile
	local profile = TableUtil.reconcile(data, ProfileSchema.template() :: any) :: any

	-- Numeric hygiene. A corrupted or tampered value must not propagate into
	-- gameplay maths, where NaN spreads silently.
	local function sane(value: any, fallback: number, min: number?, max: number?): number
		if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
			return fallback
		end
		if min and value < min then
			return min
		end
		if max and value > max then
			return max
		end
		return value
	end

	profile.credits = math.floor(sane(profile.credits, 0, 0))
	profile.xp = math.floor(sane(profile.xp, 0, 0))
	profile.level = math.floor(sane(profile.level, 1, 1, 60))

	for key, value in profile.stats do
		profile.stats[key] = math.floor(sane(value, 0, 0))
	end

	local settings = profile.settings
	for _, key in { "masterVolume", "musicVolume", "ambienceVolume", "sfxVolume", "trainVolume", "voiceVolume", "uiVolume", "creatureVolume" } do
		settings[key] = sane(settings[key], 0.8, 0, 1)
	end
	settings.fieldOfView = sane(settings.fieldOfView, 70, 55, 100)
	settings.hudScale = sane(settings.hudScale, 1, 0.75, 1.5)
	settings.sensitivity = sane(settings.sensitivity, 1, 0.2, 3)
	settings.cameraShake = sane(settings.cameraShake, 1, 0, 1)

	profile.purchases.robuxSpent = math.floor(sane(profile.purchases.robuxSpent, 0, 0))

	return profile :: Profile
end

--- A fresh profile for a player who has never played.
function ProfileSchema.fresh(): Profile
	local profile = ProfileSchema.template()
	profile.firstJoin = os.time()
	profile.lastSeen = os.time()
	return profile
end

--- The subset of a profile that is safe and useful to send to the client.
--- Receipts are deliberately excluded: the client has no use for them and they
--- are the one thing worth keeping entirely server-side.
function ProfileSchema.toClient(profile: Profile): { [string]: any }
	return {
		credits = profile.credits,
		xp = profile.xp,
		level = profile.level,
		trains = profile.trains,
		liveries = profile.liveries,
		interiors = profile.interiors,
		cosmetics = profile.cosmetics,
		weapons = profile.weapons,
		loadout = profile.loadout,
		settings = profile.settings,
		stats = profile.stats,
		quests = profile.quests,
		login = profile.login,
		playtime = profile.playtime,
		events = profile.events,
		achievements = profile.achievements,
		recordings = profile.recordings,
		discoveries = profile.discoveries,
		ownedProducts = profile.purchases.products,
		sessionCount = profile.sessionCount,
	}
end

return ProfileSchema
