--!strict
--[[
	LAST SIGNAL - server boot
	=========================
	A RIPGAMES production.

	This is the only Script on the server. Everything else is a ModuleScript
	started from here, in a fixed order, so there is exactly one place to look
	when something does not come up.

	BOOT ORDER
	----------
	The order below is not arbitrary. Each stage depends on the ones above it:

	  1  Net            remotes must exist before any service binds a handler
	  2  Data           profiles must load before anything reads or writes one
	  3  Economy        progression, quests, rewards, purchases, shop
	  4  World          the lobby and the expedition lanes get built
	  5  Session        crews, expeditions, the train
	  6  Gameplay       interaction, survival, combat, creatures, threat
	  7  Live           events, administration, analytics, leaderboards
	  8  Players        only now are joining players accepted

	Player joins are deliberately last. A player who connects mid-boot would
	otherwise find a world with no ground and services that are not listening.

	If a service fails to start, the failure is logged with its name and boot
	continues. A broken leaderboard must not stop the game from running; a
	broken DataService will already have put every session into read-only mode
	rather than risking player data.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("LastSignal")

local GameConfig = require(Shared.Config.GameConfig)
local Logger = require(Shared.Core.Logger)
local Monetization = require(Shared.Config.Monetization)
local Audio = require(Shared.Config.Audio)
local Net = require(Shared.Core.Net)
local Protect = require(Shared.Core.Protect)

local Services = script.Services

local log = Logger.new("Boot")

--------------------------------------------------------------------------

local startedAt = os.clock()

log.info(string.rep("=", 58))
log.info(string.format("%s - %s", GameConfig.GameName, GameConfig.ChapterName))
log.info(string.format("%s  build %s  place mode %s", GameConfig.StudioName, GameConfig.BuildId, GameConfig.PlaceMode))
log.info(string.rep("=", 58))

-- Remotes first. Every service below binds handlers to these.
Net.initServer()

--------------------------------------------------------------------------
-- Service registry
--------------------------------------------------------------------------

type ServiceEntry = { name: string, module: ModuleScript, stage: string }

local BOOT_ORDER: { ServiceEntry } = {
	{ name = "DataService", module = Services.DataService, stage = "Data" },

	{ name = "ProgressionService", module = Services.ProgressionService, stage = "Economy" },
	{ name = "RewardService", module = Services.RewardService, stage = "Economy" },
	{ name = "QuestService", module = Services.QuestService, stage = "Economy" },
	{ name = "PurchaseService", module = Services.PurchaseService, stage = "Economy" },
	{ name = "ShopService", module = Services.ShopService, stage = "Economy" },
	{ name = "InventoryService", module = Services.InventoryService, stage = "Economy" },

	{ name = "WorldService", module = Services.WorldService, stage = "World" },

	{ name = "CrewService", module = Services.CrewService, stage = "Session" },
	{ name = "TrainService", module = Services.TrainService, stage = "Session" },
	{ name = "ExpeditionService", module = Services.ExpeditionService, stage = "Session" },

	{ name = "SurvivalService", module = Services.SurvivalService, stage = "Gameplay" },
	{ name = "InteractionService", module = Services.InteractionService, stage = "Gameplay" },
	{ name = "CreatureService", module = Services.CreatureService, stage = "Gameplay" },
	{ name = "CombatService", module = Services.CombatService, stage = "Gameplay" },
	{ name = "HorrorDirector", module = Services.HorrorDirector, stage = "Gameplay" },

	{ name = "EventService", module = Services.EventService, stage = "Live" },
	{ name = "AdminService", module = Services.AdminService, stage = "Live" },
	{ name = "AnalyticsService", module = Services.AnalyticsService, stage = "Live" },
	{ name = "LeaderboardService", module = Services.LeaderboardService, stage = "Live" },
}

local loaded: { [string]: any } = {}
local failures: { string } = {}
local currentStage = ""

for _, entry in BOOT_ORDER do
	if entry.stage ~= currentStage then
		currentStage = entry.stage
		log.info(string.format("-- %s --", currentStage))
	end

	local okRequire, service = Protect.call(require, entry.module)
	if not okRequire then
		table.insert(failures, entry.name)
		log.error(string.format("%s failed to load: %s", entry.name, tostring(service)))
		continue
	end

	loaded[entry.name] = service

	if type(service) == "table" and type(service.start) == "function" then
		local okStart, err = Protect.call(service.start)
		if not okStart then
			table.insert(failures, entry.name)
			log.error(string.format("%s failed to start: %s", entry.name, tostring(err)))
		end
	end
end

--------------------------------------------------------------------------
-- Configuration report
--------------------------------------------------------------------------

-- Printed at every boot so an operator can see, without reading any code,
-- exactly what is configured and what is switched off.
do
	log.info(string.rep("-", 58))
	log.info("Configuration")

	local money = Monetization.audit()
	if money.configured == 0 then
		log.warn(string.format("Monetization: 0 of %d products configured. The shop will show", money.total))
		log.warn("  every item as Unavailable and no purchase can be made.")
		log.warn("  Fill in the IDs in Config.Monetization. See docs/MONETIZATION.md.")
	else
		log.info(string.format("Monetization: %d of %d products configured.", money.configured, money.total))
		if #money.missing > 0 then
			log.warn("  Not yet configured: " .. table.concat(money.missing, ", "))
		end
	end

	local Admin = require(Shared.Config.Admin)
	local roles = Admin.audit()
	if roles.active == 0 then
		log.warn("Administration: no user IDs configured. Nobody has admin access.")
		log.warn("  Fill in the numeric user IDs in Config.Admin. See docs/ADMIN.md.")
	else
		log.info(string.format("Administration: %d role(s) active.", roles.active))
		if #roles.inactive > 0 then
			log.warn("  Roles with no user ID: " .. table.concat(roles.inactive, ", "))
		end
	end

	local audio = Audio.audit()
	if audio.configured == 0 then
		log.warn(string.format("Audio: 0 of %d cues configured. The game runs silently.", audio.total))
		log.warn("  The mixer, ducking, occlusion and subtitles all work; they have")
		log.warn("  nothing to play. See docs/AUDIO.md to fill in the asset IDs.")
	else
		log.info(string.format("Audio: %d of %d cues configured.", audio.configured, audio.total))
	end

	local dataStatus = (loaded.DataService and loaded.DataService.status and loaded.DataService.status()) or nil
	if dataStatus then
		if dataStatus.mock then
			log.warn("Data: Studio mock store. Progress is in memory only this session.")
		elseif not dataStatus.available then
			log.error("Data: DataStore unavailable. Every session will be read-only.")
		else
			log.info("Data: live DataStore.")
		end
	end

	if GameConfig.PlaceMode == "two" then
		if GameConfig.LobbyPlaceId <= 0 or GameConfig.ExpeditionPlaceId <= 0 then
			log.warn("Place mode is 'two' but the place IDs are not set; falling back to single-place behaviour.")
		end
	end

	log.info(string.rep("-", 58))
end

--------------------------------------------------------------------------
-- Player lifecycle
--------------------------------------------------------------------------

local DataService = loaded.DataService
local WorldService = loaded.WorldService

local function onPlayerAdded(player: Player)
	-- The profile is loaded before the character exists, so nothing spawns
	-- into the world with default values that would then be saved.
	local okLoad, err = Protect.call(DataService.load, player)
	if not okLoad then
		log.error(string.format("profile load raised for %s: %s", player.Name, tostring(err)))
	end

	local lobby = WorldService and WorldService.getLobby()
	local spawnCF = if lobby then lobby.spawnCFrames[math.random(1, #lobby.spawnCFrames)] else CFrame.new(0, 10, 0)

	player.CharacterAdded:Connect(function(character)
		-- Placing the character explicitly, rather than relying on a
		-- SpawnLocation, means a respawn always lands somewhere real even if
		-- the player died in a lane that has since been torn down.
		task.defer(function()
			if character.Parent then
				local currentLobby = WorldService and WorldService.getLobby()
				local target = if currentLobby then currentLobby.spawnCFrames[math.random(1, #currentLobby.spawnCFrames)] else spawnCF
				-- Only reposition when the player is not on an expedition;
				-- ExpeditionService places its own crew.
				local ExpeditionService = loaded.ExpeditionService
				if not (ExpeditionService and ExpeditionService.forPlayer(player)) then
					character:PivotTo(target)
				end
			end
		end)
	end)

	player:LoadCharacter()
end

for _, player in Players:GetPlayers() do
	task.spawn(onPlayerAdded, player)
end
Players.PlayerAdded:Connect(function(player)
	task.spawn(onPlayerAdded, player)
end)

--------------------------------------------------------------------------

local elapsed = os.clock() - startedAt
if #failures == 0 then
	log.info(string.format("Ready in %.2fs. %d services started.", elapsed, #BOOT_ORDER))
else
	log.error(string.format("Ready in %.2fs with %d failure(s): %s", elapsed, #failures, table.concat(failures, ", ")))
end

if RunService:IsStudio() then
	log.info("Studio session. Press Play to test; use the F9 console to read this log.")
end
