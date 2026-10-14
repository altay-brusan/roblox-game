--!strict
--[[
	LoadoutService
	--------------
	What a player takes on their next run: train, livery, interior, primary
	weapon and appearance. The loadout panel has always sent these choices as
	"loadout_*" settings, and SurvivalService has always passed them on to "the
	profile setting handler", but that handler did not exist, so every choice on
	the loadout panel was silently dropped. This is that handler.

	OWNERSHIP IS CHECKED HERE
	-------------------------
	A choice is accepted only if the profile owns it. Premium weapons are owned
	only through their Game Pass, which PurchaseService mirrors from Roblox, so
	a client that asks for a weapon it has not bought gets nothing. Equipping
	at the start of a run checks again (CombatService.equip).

	ONE PRIMARY WEAPON
	------------------
	The primary slot is the shared loadout limit: one weapon per run, whatever
	a player owns. Owning every pass never means carrying every advantage.

	Changes are refused during a run; the loadout is for the next one.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.LastSignal

local CosmeticRegistry = require(Shared.Registry.CosmeticRegistry)
local Guard = require(Shared.Core.Guard)
local Logger = require(Shared.Core.Logger)
local Net = require(Shared.Core.Net)
local Signal = require(Shared.Core.Signal)
local TrainRegistry = require(Shared.Registry.TrainRegistry)
local WeaponRegistry = require(Shared.Registry.WeaponRegistry)

local DataService = require(script.Parent.DataService)
local ExpeditionService = require(script.Parent.ExpeditionService)
local ProgressionService = require(script.Parent.ProgressionService)

local log = Logger.new("LoadoutService")

local LoadoutService = {}

LoadoutService.Changed = Signal.new() :: Signal.Signal<Player, string, string>

local SLOTS = { "train", "livery", "interior", "primary", "lamp", "outfit", "finish", "patch" }

--- Whether this profile may select this item for this slot.
local function allowed(profile: any, slot: string, id: string): (boolean, string?)
	if slot == "primary" then
		local def = WeaponRegistry.get(id)
		if not def then
			return false, "UNKNOWN"
		end
		if not (def.startingLoadout or profile.weapons[id]) then
			return false, "NOT_OWNED"
		end
		if profile.level < def.unlockLevel then
			return false, "LEVEL_LOCKED"
		end
		return true, nil
	elseif slot == "train" then
		return TrainRegistry.get(id) ~= nil and profile.trains[id] == true, "NOT_OWNED"
	elseif slot == "livery" then
		return TrainRegistry.Liveries[id] ~= nil and profile.liveries[id] == true, "NOT_OWNED"
	elseif slot == "interior" then
		return TrainRegistry.Interiors[id] ~= nil and profile.interiors[id] == true, "NOT_OWNED"
	else
		local def = CosmeticRegistry.get(id)
		if not def or def.slot ~= slot then
			return false, "UNKNOWN"
		end
		return profile.cosmetics[id] == true, "NOT_OWNED"
	end
end

--- Sets one loadout slot. Returns false and a reason when refused.
function LoadoutService.set(player: Player, slot: string, id: string): (boolean, string?)
	if ExpeditionService.forPlayer(player) then
		return false, "ON_EXPEDITION"
	end
	local profile = DataService.getProfile(player)
	if not profile then
		return false, "NOT_LOADED"
	end
	-- An empty patch is a valid choice: no patch.
	-- Studio test hook: a server-set "TestAllTrains" attribute lets every train
	-- be selected, to prove each can be ridden. Inert outside Studio.
	local testTrains = slot == "train" and game:GetService("RunService"):IsStudio() and player:GetAttribute("TestAllTrains") == true and TrainRegistry.get(id) ~= nil
	if not testTrains and not (slot == "patch" and id == "") then
		local ok, reason = allowed(profile, slot, id)
		if not ok then
			return false, reason
		end
	end
	local field = if slot == "primary" then "primaryWeapon" else slot
	DataService.update(player, function(p)
		(p.loadout :: any)[field] = id
	end)
	ProgressionService.pushToClient(player)
	LoadoutService.Changed:Fire(player, slot, id)
	log.debug(player.Name, slot, id)
	return true, nil
end

function LoadoutService.start()
	Net.onServerEvent("SetSetting", function(player, rawKey, rawValue)
		if type(rawKey) ~= "string" or string.sub(rawKey, 1, 8) ~= "loadout_" then
			return
		end
		local slot = Guard.enum(string.sub(rawKey, 9), SLOTS)
		local id = Guard.string(rawValue, 64)
		if not slot or not id then
			return
		end
		local ok, reason = LoadoutService.set(player, slot, id)
		if not ok then
			Net.fireClient("InteractResult", player, { ok = false, error = "LOADOUT_" .. tostring(reason) })
		end
	end)
	log.info("started")
end

return LoadoutService
