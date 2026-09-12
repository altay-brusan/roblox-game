--!strict
--[[
	LAST SIGNAL - client boot
	=========================

	The only LocalScript in the project. Every controller is a ModuleScript
	started from here, in order.

	BOOT ORDER
	----------
	  State      the replicated store, first, so nothing reads an empty table
	  Input      bindings and the touch layout
	  Camera     before anything that changes camera mode
	  Presentation  audio, HUD, prompts, menus
	  Sequences  cinematic, weapons, train ride

	A controller that fails to start is logged and skipped. The game remains
	playable with a broken menu; it is not playable with a broken camera, so
	the camera controller has its own watchdog regardless of what happens here.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")

local Shared = ReplicatedStorage:WaitForChild("LastSignal")

local GameConfig = require(Shared.Config.GameConfig)
local Logger = require(Shared.Core.Logger)
local Protect = require(Shared.Core.Protect)

local Controllers = script.Controllers

local log = Logger.new("ClientBoot")

local startedAt = os.clock()

log.info(string.format("%s client starting (build %s)", GameConfig.GameName, GameConfig.BuildId))

--------------------------------------------------------------------------

local BOOT_ORDER = {
	{ name = "StateController", module = Controllers.StateController },
	{ name = "InputController", module = Controllers.InputController },
	{ name = "CameraController", module = Controllers.CameraController },
	{ name = "AudioController", module = Controllers.AudioController },
	{ name = "HUDController", module = Controllers.HUDController },
	{ name = "InteractionController", module = Controllers.InteractionController },
	{ name = "MenuController", module = Controllers.MenuController },
	{ name = "CinematicController", module = Controllers.CinematicController },
	{ name = "WeaponController", module = Controllers.WeaponController },
	{ name = "CabController", module = Controllers.CabController },
	{ name = "TrainRideController", module = Controllers.TrainRideController },
}

local failures: { string } = {}

for _, entry in BOOT_ORDER do
	local okRequire, controller = Protect.call(require, entry.module)
	if not okRequire then
		table.insert(failures, entry.name)
		log.error(string.format("%s failed to load: %s", entry.name, tostring(controller)))
		continue
	end
	if type(controller) == "table" and type(controller.start) == "function" then
		local okStart, err = Protect.call(controller.start)
		if not okStart then
			table.insert(failures, entry.name)
			log.error(string.format("%s failed to start: %s", entry.name, tostring(err)))
		end
	end
end

--------------------------------------------------------------------------
-- Core GUI
--------------------------------------------------------------------------

-- The default backpack and health bar are replaced by this project's own HUD.
-- The player list and chat stay: they are how crews coordinate, and the brief
-- asks for readable coordination tools with voice chat optional.
local function setCoreGui()
	local attempts = 0
	while attempts < 10 do
		attempts += 1
		local ok = pcall(function()
			StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false)
			StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Health, false)
			StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.PlayerList, true)
			StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Chat, true)
		end)
		if ok then
			return
		end
		task.wait(0.5)
	end
	log.warn("could not configure the core interface")
end
setCoreGui()

--------------------------------------------------------------------------
-- First-run guidance
--------------------------------------------------------------------------

-- Brief contextual guidance rather than a permanent tutorial panel. Each hint
-- is shown once, when the situation it describes first occurs.
local StateController = require(Controllers.StateController)
local HUDController = require(Controllers.HUDController)

local shownHints: { [string]: boolean } = {}

local function hint(id: string, title: string, body: string)
	if shownHints[id] then
		return
	end
	shownHints[id] = true
	HUDController.notify({ kind = "info", title = title, body = body, duration = 9 })
end

task.spawn(function()
	-- Wait for the profile, then decide whether this is a first session.
	local deadline = os.clock() + 20
	while not StateController.profile() and os.clock() < deadline do
		task.wait(0.25)
	end
	local profile = StateController.profile()
	local isNew = profile ~= nil and (profile.sessionCount or 1) <= 1

	if isNew then
		task.wait(2)
		hint(
			"welcome",
			"Tolbridge Yard",
			"The crew board is under the shelter. Form a crew, or depart alone: everything in the chapter can be done by one person."
		)
	end

	StateController.Changed:Connect(function(key, value)
		if key ~= "expedition" or type(value) ~= "table" then
			return
		end
		if value.state == "travelling" and value.stationIndex == 0 then
			hint(
				"travelling",
				"Take the controls",
				"Sit in the driver's seat. Release the brake, then open the throttle. Fuel and condition are top right."
			)
		elseif value.state == "onstation" then
			hint(
				"first_station",
				"Marrow Halt",
				"Your objective is in the top left corner. Search lockers and crates for supplies, and take everything you can carry."
			)
		end
	end)
end)

--------------------------------------------------------------------------

local elapsed = os.clock() - startedAt
if #failures == 0 then
	log.info(string.format("client ready in %.2fs", elapsed))
else
	log.error(string.format("client ready in %.2fs with %d failure(s): %s", elapsed, #failures, table.concat(failures, ", ")))
end
