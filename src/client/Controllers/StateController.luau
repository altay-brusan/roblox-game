--!strict
--[[
	StateController
	---------------
	The client's single copy of everything the server has told it.

	Every other controller reads from here and subscribes to changes. Nothing
	else on the client binds a network handler for state, which means there is
	one place where replicated state lives, one place it is validated, and no
	possibility of two panels disagreeing about the player's credit balance.

	State is read-only to consumers. A controller that wants to change something
	sends a command to the server and waits for the state to come back, which is
	what keeps the client from ever showing an outcome the server did not agree
	to.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("LastSignal")

local Net = require(Shared.Core.Net)
local Signal = require(Shared.Core.Signal)

local StateController = {}

export type Store = {
	profile: { [string]: any }?,
	crew: { [string]: any }?,
	crewList: { any },
	expedition: { [string]: any }?,
	vitals: { [string]: any }?,
	downed: { [string]: any }?,
	train: { [string]: any }?,
	inventory: { [string]: any }?,
	weapon: { [string]: any }?,
	shop: { [string]: any }?,
	quests: { [string]: any }?,
	event: { [string]: any }?,
	admin: { [string]: any }?,
	rewards: { [string]: any }?,
	-- Local, not replicated: which panel is open, current platform, and so on.
	ui: { [string]: any },
}

local store: Store = {
	profile = nil,
	crew = nil,
	crewList = {},
	expedition = nil,
	vitals = nil,
	downed = nil,
	train = nil,
	inventory = nil,
	weapon = nil,
	shop = nil,
	quests = nil,
	event = nil,
	admin = nil,
	rewards = nil,
	ui = { openPanel = nil, hudVisible = true, cinematic = false },
}

StateController.Changed = Signal.new() :: Signal.Signal<string, any>

--- Reads a slice. Returns the live table; callers must not mutate it.
function StateController.get(key: string): any
	return (store :: any)[key]
end

function StateController.profile(): { [string]: any }?
	return store.profile
end

local function set(key: string, value: any)
	(store :: any)[key] = value
	StateController.Changed:Fire(key, value)
end

StateController.set = set

--- Convenience for the UI layer's own state, which is not replicated.
function StateController.setUi(key: string, value: any)
	store.ui[key] = value
	StateController.Changed:Fire("ui", store.ui)
end

function StateController.ui(key: string): any
	return store.ui[key]
end

--------------------------------------------------------------------------
-- Derived helpers, so panels do not each re-derive the same thing
--------------------------------------------------------------------------

function StateController.credits(): number
	local profile = store.profile
	return if profile then profile.credits or 0 else 0
end

function StateController.level(): number
	local profile = store.profile
	return if profile then profile.level or 1 else 1
end

function StateController.owns(kind: string, id: string): boolean
	local profile = store.profile
	if not profile then
		return false
	end
	local bucket = profile[kind .. "s"]
	if type(bucket) ~= "table" then
		return false
	end
	return bucket[id] == true
end

function StateController.setting(name: string, fallback: any): any
	local profile = store.profile
	if not profile or type(profile.settings) ~= "table" then
		return fallback
	end
	local value = profile.settings[name]
	if value == nil then
		return fallback
	end
	return value
end

function StateController.isOnExpedition(): boolean
	local expedition = store.expedition
	if not expedition then
		return false
	end
	local state = expedition.state
	return state ~= nil and state ~= "lobby" and state ~= "results" and state ~= "cancelled"
end

function StateController.isDowned(): boolean
	local vitals = store.vitals
	return vitals ~= nil and vitals.state == "downed"
end

function StateController.isDead(): boolean
	local vitals = store.vitals
	return vitals ~= nil and vitals.state == "dead"
end

--------------------------------------------------------------------------

function StateController.start()
	Net.onClientEvent("ProfileSnapshot", function(payload)
		if type(payload) == "table" then
			set("profile", payload)
		end
	end)

	Net.onClientEvent("ProfileDelta", function(payload)
		if type(payload) ~= "table" or not store.profile then
			return
		end
		-- A delta merges into the existing profile rather than replacing it,
		-- so a partial update cannot blank a field the server did not send.
		local profile = store.profile :: { [string]: any }
		for key, value in payload do
			profile[key] = value
		end
		set("profile", profile)
	end)

	Net.onClientEvent("CrewState", function(payload)
		set("crew", payload)
	end)

	Net.onClientEvent("ExpeditionState", function(payload)
		if type(payload) ~= "table" then
			return
		end
		set("expedition", payload)
		-- Leaving an expedition clears everything scoped to it, so a stale
		-- inventory or objective list can never linger in the lobby.
		if payload.state == "lobby" or payload.state == "cancelled" then
			set("inventory", nil)
			set("vitals", nil)
			set("downed", nil)
			set("train", nil)
			set("weapon", nil)
		end
	end)

	Net.onClientEvent("VitalsState", function(payload)
		set("vitals", payload)
	end)

	Net.onClientEvent("DownedState", function(payload)
		set("downed", payload)
	end)

	Net.onClientEvent("TrainState", function(payload)
		set("train", payload)
	end)

	Net.onClientEvent("Inventory", function(payload)
		set("inventory", payload)
	end)

	Net.onClientEvent("ShopState", function(payload)
		set("shop", payload)
	end)

	Net.onClientEvent("QuestState", function(payload)
		set("quests", payload)
	end)

	Net.onClientEvent("EventState", function(payload)
		set("event", payload)
	end)

	Net.onClientEvent("AdminState", function(payload)
		set("admin", payload)
	end)

	Net.onClientEvent("WeaponEffect", function(payload)
		-- Only the state messages update the store; the rest are effects and
		-- belong to WeaponController.
		if type(payload) == "table" and payload.kind == "state" then
			set("weapon", payload)
		end
	end)

	Net.onClientEvent("Notify", function(payload)
		if type(payload) == "table" and payload.kind == "rewards_state" then
			set("rewards", payload)
		end
	end)

	-- Ask for a snapshot in case this client connected after the server had
	-- already pushed one.
	task.spawn(function()
		for _ = 1, 3 do
			if store.profile then
				return
			end
			Net.invokeServer("RequestProfile")
			task.wait(2)
		end
	end)
end

return StateController
