--!strict
--[[
	GameConfig
	----------
	Top-level switches for LAST SIGNAL. Anything an operator might reasonably
	want to change without reading code lives here.

	PLACE TOPOLOGY
	--------------
	The brief asks for a lobby that is separate from the expedition. There are
	two ways to do that on Roblox and they have very different prerequisites:

	  "single"  Lobby and expedition occupy one place, far apart in world space.
	            Crews are moved between them by the server. Works immediately in
	            Studio and on an unpublished place, needs no API access, and has
	            no teleport failure modes at all.

	  "two"     Lobby is one published place, the expedition is a second place in
	            the same universe, joined by TeleportService with reserved
	            servers. This is the shape most large Roblox games use because it
	            isolates expedition load from lobby load.

	The project ships in "single" mode so it is playable the moment you open it.
	Every teleport path for "two" mode is implemented and tested for its failure
	branches, but it cannot be exercised until both places are published; see
	docs/PUBLISHING.md. Switching modes is this one value plus two place IDs.
]]

export type PlaceMode = "single" | "two"

local GameConfig = {}

GameConfig.GameName = "LAST SIGNAL"
GameConfig.StudioName = "RIPGAMES"
GameConfig.ChapterName = "Chapter One: The Long Grade"

-- Bumped whenever the save schema changes. DataService migrates on load.
GameConfig.DataVersion = 3

-- Build stamp, surfaced in the settings panel and in analytics events so a
-- bug report can be tied to a specific build.
GameConfig.BuildId = "1.0.0"

--------------------------------------------------------------------------
-- Place topology
--------------------------------------------------------------------------

GameConfig.PlaceMode = "single" :: PlaceMode

-- Only used when PlaceMode is "two". Zero means "not configured", which makes
-- the lobby fall back to single-place behaviour rather than failing a teleport.
GameConfig.LobbyPlaceId = 0
GameConfig.ExpeditionPlaceId = 0

-- How long the client waits on a teleport before showing recovery options.
GameConfig.TeleportTimeoutSeconds = 20
GameConfig.TeleportRetryAttempts = 3

--------------------------------------------------------------------------
-- World layout (single-place mode)
--------------------------------------------------------------------------

-- The lobby sits at the origin. The expedition corridor runs north from a
-- distant offset so streaming never has both loaded for the same player.
GameConfig.LobbyOrigin = Vector3.new(0, 0, 0)
GameConfig.ExpeditionOrigin = Vector3.new(0, 0, -20000)

-- The railway is a straight line along -Z from the expedition origin. Stations
-- are placed along it by StationRegistry. Keeping the line straight is a
-- deliberate simplification: it makes carriage physics, streaming and creature
-- navigation dramatically more reliable than a curved spline would, and the
-- forest density hides the geometry.
GameConfig.TrackDirection = Vector3.new(0, 0, -1)
GameConfig.TrackLength = 14000

--------------------------------------------------------------------------
-- Crew and session
--------------------------------------------------------------------------

GameConfig.MinCrewSize = 1
GameConfig.MaxCrewSize = 6
GameConfig.MaxServerPlayers = 24

GameConfig.DepartureCountdownSeconds = 10
GameConfig.ReadyRequiredFraction = 1.0 -- every member must be ready to depart

-- A crew whose leader leaves is handed to the longest-present member rather
-- than being disbanded, so a disconnect does not end everyone else's evening.
GameConfig.LeaderTransferGraceSeconds = 5

-- How long a disconnected player's expedition slot is held for reconnection.
GameConfig.ReconnectGraceSeconds = 180

--------------------------------------------------------------------------
-- Expedition pacing
--------------------------------------------------------------------------

-- Target wall-clock for a successful normal run. Used by the pacing director
-- to decide whether to stretch or compress optional content.
GameConfig.TargetRunSeconds = 32 * 60
GameConfig.MinRunSeconds = 22 * 60
GameConfig.MaxRunSeconds = 48 * 60

GameConfig.CinematicSeconds = 38
GameConfig.CinematicSkippableAfter = 2

--------------------------------------------------------------------------
-- Difficulty
--------------------------------------------------------------------------

export type DifficultyId = "signal" | "blackout" | "derelict"

GameConfig.Difficulties = {
	{
		id = "signal",
		name = "Signal",
		blurb = "The intended experience. Threats are dangerous but readable.",
		threatRate = 1.0,
		damageTaken = 1.0,
		lootRate = 1.0,
		creditMultiplier = 1.0,
		xpMultiplier = 1.0,
		reviveSeconds = 12,
		unlockLevel = 0,
	},
	{
		id = "blackout",
		name = "Blackout",
		blurb = "Less light, less loot, and the forest pays closer attention.",
		threatRate = 1.35,
		damageTaken = 1.3,
		lootRate = 0.82,
		creditMultiplier = 1.45,
		xpMultiplier = 1.4,
		reviveSeconds = 16,
		unlockLevel = 6,
	},
	{
		id = "derelict",
		name = "Derelict",
		blurb = "The train fails more often and the radio lies more convincingly.",
		threatRate = 1.7,
		damageTaken = 1.6,
		lootRate = 0.7,
		creditMultiplier = 2.0,
		xpMultiplier = 1.9,
		reviveSeconds = 22,
		unlockLevel = 14,
	},
}

GameConfig.DefaultDifficulty = "signal" :: DifficultyId

function GameConfig.getDifficulty(id: string?)
	for _, entry in GameConfig.Difficulties do
		if entry.id == id then
			return entry
		end
	end
	return GameConfig.Difficulties[1]
end

--------------------------------------------------------------------------
-- Persistence
--------------------------------------------------------------------------

-- Changing this key starts everyone from zero. It is versioned so a broken
-- migration can be rolled forward into a fresh namespace rather than
-- corrupting live saves.
GameConfig.DataStoreName = "LastSignal_Profiles_v3"
GameConfig.LeaderboardStoreName = "LastSignal_Boards_v3"

GameConfig.AutosaveIntervalSeconds = 180
GameConfig.SessionLockStaleSeconds = 1200
GameConfig.DataRetryAttempts = 5

-- In Studio, DataStore access is often unavailable or slow. When true, the
-- server uses an in-memory store so the full progression loop is testable
-- without touching live player data. Never enabled on a real server.
GameConfig.UseMockDataInStudio = true

--------------------------------------------------------------------------
-- Performance
--------------------------------------------------------------------------

GameConfig.MaxActiveLights = 26
GameConfig.ForestStreamRadius = 620
GameConfig.CorpseCleanupSeconds = 45
GameConfig.DroppedItemLifetimeSeconds = 600

-- Server tick rates. Anything gameplay-authoritative runs at these rates
-- rather than every frame, which keeps CPU predictable with six players plus
-- creatures plus a moving train.
GameConfig.VitalsTickRate = 4
GameConfig.TrainTickRate = 20
GameConfig.CreatureTickRate = 10
GameConfig.DirectorTickRate = 1

return table.freeze(GameConfig)
