--!strict
--[[
	ShopService
	-----------
	Assembles the shop catalogue and handles both currencies.

	What the client is sent is a fully-resolved list: live Robux price, owned
	state, eligibility, and whether the item is purchasable at all. The client
	renders that and nothing else, so the panel can never offer something the
	server would refuse, and an unconfigured product can never be presented as
	buyable.

	Prompt gating lives here. The shop refuses to open a Robux prompt while the
	player is in any of the states listed in Monetization.PromptBlockedStates:
	a cinematic, an encounter, a critical rescue, the expedition climax, or
	loading. Selling into a frightening moment is the kind of thing that makes
	players distrust a game, and it is cheap to prevent.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.LastSignal

local Guard = require(Shared.Core.Guard)
local Logger = require(Shared.Core.Logger)
local Net = require(Shared.Core.Net)
local Signal = require(Shared.Core.Signal)
local Monetization = require(Shared.Config.Monetization)
local CosmeticRegistry = require(Shared.Registry.CosmeticRegistry)
local TrainRegistry = require(Shared.Registry.TrainRegistry)
local WeaponRegistry = require(Shared.Registry.WeaponRegistry)
local DataService = require(script.Parent.DataService)
local ProgressionService = require(script.Parent.ProgressionService)
local PurchaseService = require(script.Parent.PurchaseService)

local log = Logger.new("ShopService")

local ShopService = {}

ShopService.PromptBlocked = Signal.new() :: Signal.Signal<Player, string>

-- Set by ExpeditionService and the cinematic controller. A player in a blocked
-- state cannot be shown a Robux prompt.
local blockedStates: { [number]: string } = {}

function ShopService.setBlockedState(player: Player, reason: string?)
	if reason and table.find(Monetization.PromptBlockedStates, reason) then
		blockedStates[player.UserId] = reason
	else
		blockedStates[player.UserId] = nil
	end
end

function ShopService.blockedReason(player: Player): string?
	return blockedStates[player.UserId]
end

--------------------------------------------------------------------------
-- Catalogue assembly
--------------------------------------------------------------------------

type Entry = {
	key: string,
	name: string,
	blurb: string,
	category: string,
	currency: string, -- "robux" | "credits"
	price: number?, -- live Robux price, or credit cost
	priceText: string?,
	owned: boolean,
	purchasable: boolean,
	unavailableReason: string?,
	permanent: boolean,
	order: number,
	preview: { [string]: any }?,
}

local function robuxEntries(player: Player): { Entry }
	local out: { Entry } = {}
	for _, def in Monetization.All do
		local owned = def.permanent and PurchaseService.ownsProduct(player, def.key)
		local price, liveName = PurchaseService.getPrice(def.key)

		local purchasable = true
		local reason: string? = nil
		if def.id <= 0 then
			purchasable = false
			reason = "This item is not available yet."
		elseif not price then
			purchasable = false
			reason = "Price unavailable. Try again in a moment."
		elseif owned then
			purchasable = false
			reason = "Owned"
		end

		table.insert(out, {
			key = def.key,
			-- The live Roblox name wins when available, so what the player sees
			-- in the shop matches what the purchase prompt will say.
			name = liveName or def.name,
			blurb = def.blurb,
			category = def.category,
			currency = "robux",
			price = price,
			owned = owned,
			purchasable = purchasable,
			unavailableReason = reason,
			permanent = def.permanent,
			order = def.order,
			preview = def.grants,
		})
	end
	return out
end

local function creditEntries(player: Player): { Entry }
	local out: { Entry } = {}
	local profile = DataService.getProfile(player)
	if not profile then
		return out
	end

	local function add(key: string, name: string, blurb: string, cost: number, owned: boolean, unlockLevel: number?, preview: { [string]: any }?)
		local purchasable = not owned
		local reason: string? = if owned then "Owned" else nil
		if not owned and unlockLevel and profile.level < unlockLevel then
			purchasable = false
			reason = string.format("Unlocks at level %d", unlockLevel)
		elseif not owned and profile.credits < cost then
			purchasable = false
			reason = "Not enough credits"
		end
		table.insert(out, {
			key = key,
			name = name,
			blurb = blurb,
			category = "exchange",
			currency = "credits",
			price = cost,
			owned = owned,
			purchasable = purchasable,
			unavailableReason = reason,
			permanent = true,
			order = cost,
			preview = preview,
		})
	end

	for _, def in CosmeticRegistry.creditPurchasable() do
		add("cosmetic:" .. def.id, def.name, def.description, def.creditCost or 0, profile.cosmetics[def.id] == true, nil, { slot = def.slot })
	end
	for _, def in TrainRegistry.allLiveries() do
		if def.source == "credits" and (def.creditCost or 0) > 0 then
			add("livery:" .. def.id, def.name, def.description, def.creditCost or 0, profile.liveries[def.id] == true, nil, { body = def.body, trim = def.trim })
		end
	end
	for _, def in TrainRegistry.allInteriors() do
		if def.source == "credits" and (def.creditCost or 0) > 0 then
			add("interior:" .. def.id, def.name, def.description, def.creditCost or 0, profile.interiors[def.id] == true)
		end
	end
	for _, def in TrainRegistry.allTrains() do
		if def.creditCost > 0 then
			add(
				"train:" .. def.id,
				def.name,
				def.tagline .. " " .. def.description,
				def.creditCost,
				profile.trains[def.id] == true,
				def.unlockLevel,
				{ class = def.class, handling = def.handling }
			)
		end
	end
	for _, def in WeaponRegistry.all() do
		if def.creditCost > 0 then
			add(
				"weapon:" .. def.id,
				def.name,
				def.description,
				def.creditCost,
				profile.weapons[def.id] == true,
				def.unlockLevel,
				{ kind = def.kind, damage = def.damage, range = def.range }
			)
		end
	end

	return out
end

function ShopService.catalogue(player: Player): { [string]: any }
	local entries: { Entry } = {}
	for _, entry in robuxEntries(player) do
		table.insert(entries, entry)
	end
	for _, entry in creditEntries(player) do
		table.insert(entries, entry)
	end
	table.sort(entries, function(a, b)
		if a.category ~= b.category then
			return a.category < b.category
		end
		return a.order < b.order
	end)

	local profile = DataService.getProfile(player)
	return {
		categories = Monetization.Categories,
		entries = entries,
		credits = if profile then profile.credits else 0,
		promptBlocked = ShopService.blockedReason(player),
		-- Told plainly rather than hidden, so an operator testing the shop can
		-- see immediately why nothing is buyable.
		anyRobuxConfigured = Monetization.audit().configured > 0,
	}
end

function ShopService.pushToClient(player: Player)
	Net.fireClient("ShopState", player, ShopService.catalogue(player))
end

--------------------------------------------------------------------------
-- Credit purchases
--------------------------------------------------------------------------

local function buyWithCredits(player: Player, entryKey: string): (boolean, string?)
	local kind, id = string.match(entryKey, "^(%a+):(.+)$")
	if not kind or not id then
		return false, "BAD_ENTRY"
	end

	local profile = DataService.getProfile(player)
	if not profile then
		return false, "NOT_LOADED"
	end
	if not DataService.isWritable(player) then
		return false, "READ_ONLY"
	end

	local cost: number? = nil
	local unlockLevel = 0

	if kind == "cosmetic" then
		local def = CosmeticRegistry.get(id)
		if not def or def.source ~= "credits" then
			return false, "NOT_FOR_SALE"
		end
		cost = def.creditCost
	elseif kind == "livery" then
		local def = TrainRegistry.Liveries[id]
		if not def or def.source ~= "credits" then
			return false, "NOT_FOR_SALE"
		end
		cost = def.creditCost
	elseif kind == "interior" then
		local def = TrainRegistry.Interiors[id]
		if not def or def.source ~= "credits" then
			return false, "NOT_FOR_SALE"
		end
		cost = def.creditCost
	elseif kind == "train" then
		local def = TrainRegistry.get(id)
		if not def or def.creditCost <= 0 then
			return false, "NOT_FOR_SALE"
		end
		cost = def.creditCost
		unlockLevel = def.unlockLevel
	elseif kind == "weapon" then
		local def = WeaponRegistry.get(id)
		if not def or def.creditCost <= 0 then
			return false, "NOT_FOR_SALE"
		end
		cost = def.creditCost
		unlockLevel = def.unlockLevel
	else
		return false, "BAD_ENTRY"
	end

	if not cost or cost <= 0 then
		return false, "NOT_FOR_SALE"
	end
	if ProgressionService.owns(player, kind, id) then
		return false, "ALREADY_OWNED"
	end
	if profile.level < unlockLevel then
		return false, "LEVEL_LOCKED"
	end

	-- Spend before granting. If the grant somehow fails, the refund below
	-- restores the credits rather than leaving the player short.
	if not ProgressionService.spendCredits(player, cost, entryKey) then
		return false, "INSUFFICIENT_CREDITS"
	end
	if not ProgressionService.grantUnlock(player, kind, id) then
		ProgressionService.award(player, { credits = cost, source = "refund:" .. entryKey, exact = true })
		return false, "GRANT_FAILED"
	end

	log.info(string.format("%s bought %s for %d credits", player.Name, entryKey, cost))
	ShopService.pushToClient(player)
	ProgressionService.pushToClient(player)
	return true, nil
end

--------------------------------------------------------------------------

function ShopService.start()
	Net.onServerInvoke("ShopCommand", function(player, rawCommand, rawArg)
		local command = Guard.enum(rawCommand, { "catalogue", "buy_credits", "prompt_robux" })
		if not command then
			return { ok = false, error = "BAD_COMMAND" }
		end

		if command == "catalogue" then
			return { ok = true, catalogue = ShopService.catalogue(player) }
		end

		if command == "buy_credits" then
			local entryKey = Guard.string(rawArg, 96)
			if not entryKey then
				return { ok = false, error = "BAD_ENTRY" }
			end
			local ok, err = buyWithCredits(player, entryKey)
			return { ok = ok, error = err, catalogue = ShopService.catalogue(player) }
		end

		-- prompt_robux
		local productKey = Guard.id(rawArg)
		if not productKey then
			return { ok = false, error = "BAD_PRODUCT" }
		end
		local blocked = ShopService.blockedReason(player)
		if blocked then
			ShopService.PromptBlocked:Fire(player, blocked)
			return { ok = false, error = "BLOCKED", blockedBy = blocked }
		end
		local ok, err = PurchaseService.prompt(player, productKey, nil)
		return { ok = ok, error = err }
	end)

	DataService.ProfileLoaded:Connect(function(player)
		task.delay(2, function()
			if player.Parent then
				ShopService.pushToClient(player)
			end
		end)
	end)

	PurchaseService.Purchased:Connect(function(player)
		ShopService.pushToClient(player)
	end)

	ProgressionService.Awarded:Connect(function(player)
		ShopService.pushToClient(player)
	end)

	game:GetService("Players").PlayerRemoving:Connect(function(player)
		blockedStates[player.UserId] = nil
	end)

	log.info("started")
end

return ShopService
