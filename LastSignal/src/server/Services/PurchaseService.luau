--!strict
--[[
	PurchaseService
	---------------
	Every Robux transaction in LAST SIGNAL passes through this file.

	THE FOUR THINGS THAT GO WRONG WITH ROBLOX PURCHASES, AND WHAT IS DONE HERE
	-------------------------------------------------------------------------
	1. Double-granting. ProcessReceipt can be called more than once for the
	   same PurchaseId, across servers and across rejoins. Every receipt id is
	   recorded in the profile before the grant is acknowledged, and a receipt
	   already present is acknowledged without granting again.

	2. Losing a purchase. If the profile cannot be written, returning
	   PurchaseGranted tells Roblox the player got their goods when they did
	   not. This service returns NotProcessedYet in that case, so Roblox retries
	   later, including on the player's next join. Nothing is ever acknowledged
	   before it is safely recorded.

	3. Granting to a player who has left. ProcessReceipt fires with a UserId,
	   not a Player. If that player is gone, this returns NotProcessedYet and
	   Roblox re-delivers when they next join. The purchase is never dropped.

	4. Unconfigured products. Every product ships with id = 0. A zero id means
	   the product does not exist yet, so it cannot be prompted, cannot be
	   matched by a receipt, and is shown as Unavailable. Nothing simulates a
	   purchase and no code path grants anything for free.

	GAME PASSES
	-----------
	Passes are entitlements rather than transactions: ownership is queried from
	Roblox, then mirrored into the profile so the rest of the game can read it
	without a web call. The mirror is refreshed on join and after a prompt, and
	the profile copy is only ever additive, so a temporary Roblox API failure
	cannot revoke a pass a player owns.
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.LastSignal

local Logger = require(Shared.Core.Logger)
local Net = require(Shared.Core.Net)
local Signal = require(Shared.Core.Signal)
local Protect = require(Shared.Core.Protect)
local Monetization = require(Shared.Config.Monetization)
local CosmeticRegistry = require(Shared.Registry.CosmeticRegistry)
local DataService = require(script.Parent.DataService)
local ProgressionService = require(script.Parent.ProgressionService)

local log = Logger.new("PurchaseService")

local PurchaseService = {}

PurchaseService.Purchased = Signal.new() :: Signal.Signal<Player, string, number>

--------------------------------------------------------------------------
-- Price cache
--------------------------------------------------------------------------

-- GetProductInfo is a web call and is rate limited. Prices are cached, and the
-- cache is what the shop displays, so the panel never blocks on the network.
type PriceEntry = { price: number, name: string, fetchedAt: number, ok: boolean }
local priceCache: { [string]: PriceEntry } = {}
local PRICE_TTL = 600

local function cacheKey(kind: string, id: number): string
	return kind .. ":" .. tostring(id)
end

--- Fetches the live price. Returns nil when the product is unconfigured or
--- the lookup failed; callers must render that as Unavailable, never as free.
function PurchaseService.getPrice(productKey: string): (number?, string?)
	local def = Monetization.get(productKey)
	if not def or def.id <= 0 then
		return nil, nil
	end

	local key = cacheKey(def.kind, def.id)
	local cached = priceCache[key]
	if cached and cached.ok and (os.clock() - cached.fetchedAt) < PRICE_TTL then
		return cached.price, cached.name
	end

	local infoType = if def.kind == "gamepass" then Enum.InfoType.GamePass else Enum.InfoType.Product
	local ok, info = Protect.call(function()
		return MarketplaceService:GetProductInfo(def.id, infoType)
	end)

	if ok and type(info) == "table" and type(info.PriceInRobux) == "number" then
		priceCache[key] = {
			price = info.PriceInRobux,
			name = info.Name or def.name,
			fetchedAt = os.clock(),
			ok = true,
		}
		return info.PriceInRobux, info.Name or def.name
	end

	log.warn(string.format("price lookup failed for %s (%s %d): %s", productKey, def.kind, def.id, tostring(info)))
	priceCache[key] = { price = 0, name = def.name, fetchedAt = os.clock(), ok = false }
	return nil, nil
end

--------------------------------------------------------------------------
-- Granting
--------------------------------------------------------------------------

--- Applies a product's `grants` block to a profile. Returns a description of
--- what changed, for the purchase confirmation panel.
local function applyGrants(player: Player, def: Monetization.ProductDef): { [string]: any }
	local summary: { [string]: any } = { credits = 0, cosmetics = {} }
	local grants = def.grants

	if type(grants.credits) == "number" and grants.credits > 0 then
		-- Purchased credits are exact: a multiplier on bought currency would
		-- make the pass a currency amplifier, which is not what it says it is.
		ProgressionService.award(player, {
			credits = grants.credits,
			source = "purchase:" .. def.key,
			exact = true,
		})
		summary.credits = grants.credits
	end

	-- Cosmetics listed on the product, plus anything in the cosmetic registry
	-- that names this product. The registry is the authority, so adding a
	-- cosmetic to a bundle never needs this file to change.
	local cosmeticIds: { [string]: boolean } = {}
	if type(grants.cosmetics) == "table" then
		for _, id in grants.cosmetics do
			cosmeticIds[id] = true
		end
	end
	for _, id in CosmeticRegistry.grantedByProduct(def.key) do
		cosmeticIds[id] = true
	end
	for id in cosmeticIds do
		if ProgressionService.grantUnlock(player, "cosmetic", id) then
			table.insert(summary.cosmetics, id)
		end
	end

	-- Liveries and interiors named by the product key.
	local TrainRegistry = require(Shared.Registry.TrainRegistry)
	for id, livery in TrainRegistry.Liveries do
		if livery.productKey == def.key then
			if ProgressionService.grantUnlock(player, "livery", id) then
				table.insert(summary.cosmetics, id)
			end
		end
	end
	for id, interior in TrainRegistry.Interiors do
		if interior.productKey == def.key then
			if ProgressionService.grantUnlock(player, "interior", id) then
				table.insert(summary.cosmetics, id)
			end
		end
	end

	-- Consumable field effects are handled by the system that offers them
	-- (DownedService for the self revive). This service only records that the
	-- consumable was bought and fires the signal.
	return summary
end

--- Records the purchase on the profile. Returns false when the write could not
--- be made, which is the signal to tell Roblox to retry later.
local function recordPurchase(player: Player, def: Monetization.ProductDef, receiptId: string?, robux: number): boolean
	if not DataService.isWritable(player) then
		return false
	end
	local recorded = false
	DataService.update(player, function(p)
		if receiptId then
			if p.purchases.receipts[receiptId] then
				-- Already recorded on this profile. Not an error: this is the
				-- duplicate path, and it must still report success.
				recorded = true
				return
			end
			p.purchases.receipts[receiptId] = os.time()
		end
		p.purchases.products[def.key] = (p.purchases.products[def.key] or 0) + 1
		p.purchases.robuxSpent += math.max(0, robux)
		recorded = true
	end)
	if not recorded then
		return false
	end
	-- Force an immediate save. Waiting for the autosave window would leave a
	-- gap where a server crash loses a paid purchase.
	return DataService.save(player.UserId, false)
end

--------------------------------------------------------------------------
-- Developer products: ProcessReceipt
--------------------------------------------------------------------------

local function processReceipt(receiptInfo: any): Enum.ProductPurchaseDecision
	local userId = receiptInfo.PlayerId
	local productId = receiptInfo.ProductId
	local receiptId = tostring(receiptInfo.PurchaseId)
	local robux = receiptInfo.CurrencySpent or 0

	local player = Players:GetPlayerByUserId(userId)
	if not player then
		-- The player left before we could grant. Roblox will call again when
		-- they next join. Acknowledging here would lose the purchase.
		log.info(string.format("receipt %s for absent user %d, deferring", receiptId, userId))
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local profile = DataService.getProfile(player)
	if not profile then
		log.warn(string.format("receipt %s: profile not loaded for %s, deferring", receiptId, player.Name))
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	-- Already granted. Acknowledge so Roblox stops re-delivering.
	if profile.purchases.receipts[receiptId] then
		log.info(string.format("receipt %s already granted to %s", receiptId, player.Name))
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	local def = Monetization.byId("developerproduct", productId)
	if not def then
		-- An unrecognised product id. This happens when a product exists on the
		-- Roblox side but is not in Monetization, which is a configuration
		-- error. Granting nothing and acknowledging would take the player's
		-- Robux for nothing, so this defers and logs loudly for the operator.
		log.error(
			string.format(
				"receipt %s is for product id %d, which is not in Config.Monetization. Add it, then the purchase will be delivered automatically.",
				receiptId,
				productId
			)
		)
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	if not DataService.isWritable(player) then
		log.warn(string.format("receipt %s: %s has a read-only session, deferring", receiptId, player.Name))
		Net.fireClient("PurchaseResult", player, {
			ok = false,
			error = "SESSION_READ_ONLY",
			productKey = def.key,
			message = "Your purchase is safe and will be delivered when your data loads correctly. Try rejoining.",
		})
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	-- Record first, then grant. If recording fails, nothing has been given and
	-- Roblox retries. If recording succeeds but a grant errors, the grant is
	-- replayed by the reconciliation pass on the next join.
	if not recordPurchase(player, def, receiptId, robux) then
		log.error(string.format("receipt %s: could not persist for %s, deferring", receiptId, player.Name))
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local summary = applyGrants(player, def)

	log.info(string.format("granted %s to %s (receipt %s, %d Robux)", def.key, player.Name, receiptId, robux))
	PurchaseService.Purchased:Fire(player, def.key, robux)

	Net.fireClient("PurchaseResult", player, {
		ok = true,
		productKey = def.key,
		productName = def.name,
		summary = summary,
	})

	return Enum.ProductPurchaseDecision.PurchaseGranted
end

--------------------------------------------------------------------------
-- Game passes
--------------------------------------------------------------------------

--- Queries Roblox for pass ownership and mirrors it into the profile.
--- Only ever adds. A failed query must never revoke a pass.
function PurchaseService.refreshPasses(player: Player)
	local profile = DataService.getProfile(player)
	if not profile then
		return
	end
	for _, def in Monetization.GamePasses do
		if def.id > 0 then
			local ok, owns = Protect.call(function()
				return MarketplaceService:UserOwnsGamePassAsync(player.UserId, def.id)
			end)
			if ok and owns == true then
				if (profile.purchases.products[def.key] or 0) <= 0 then
					if recordPurchase(player, def, nil, 0) then
						applyGrants(player, def)
						log.info(string.format("%s owns pass %s; mirrored to profile", player.Name, def.key))
						PurchaseService.Purchased:Fire(player, def.key, 0)
					end
				else
					-- Already mirrored, but re-apply grants so a pass bundle
					-- that gained a new cosmetic in an update reaches players
					-- who bought it before that update shipped.
					applyGrants(player, def)
				end
			elseif not ok then
				log.warn(string.format("pass check failed for %s / %s: %s", player.Name, def.key, tostring(owns)))
			end
		end
	end
end

function PurchaseService.ownsProduct(player: Player, productKey: string): boolean
	local profile = DataService.getProfile(player)
	if not profile then
		return false
	end
	return (profile.purchases.products[productKey] or 0) > 0
end

--------------------------------------------------------------------------
-- Prompting
--------------------------------------------------------------------------

--- Opens the Roblox purchase prompt. Returns false with a reason when the
--- product is unconfigured, already owned, or prompts are currently blocked.
function PurchaseService.prompt(player: Player, productKey: string, blockedReason: string?): (boolean, string?)
	local def = Monetization.get(productKey)
	if not def then
		return false, "UNKNOWN_PRODUCT"
	end
	if def.id <= 0 then
		return false, "NOT_CONFIGURED"
	end
	if blockedReason then
		-- Prompts are suppressed during cinematics, encounters and other
		-- moments listed in Monetization.PromptBlockedStates.
		return false, "BLOCKED:" .. blockedReason
	end
	if def.permanent and PurchaseService.ownsProduct(player, productKey) then
		return false, "ALREADY_OWNED"
	end

	local ok, err = Protect.call(function()
		if def.kind == "gamepass" then
			MarketplaceService:PromptGamePassPurchase(player, def.id)
		else
			MarketplaceService:PromptProductPurchase(player, def.id)
		end
	end)
	if not ok then
		log.warn(string.format("prompt failed for %s: %s", productKey, tostring(err)))
		return false, "PROMPT_FAILED"
	end
	return true, nil
end

--------------------------------------------------------------------------

function PurchaseService.start()
	-- There can be only one ProcessReceipt callback in a place. Assigning it
	-- here, once, is deliberate: a second assignment anywhere would silently
	-- disable this one and start losing purchases.
	MarketplaceService.ProcessReceipt = function(receiptInfo)
		local ok, decision = Protect.call(processReceipt, receiptInfo)
		if not ok then
			-- An error in the handler must not acknowledge the purchase.
			log.error("ProcessReceipt raised:", tostring(decision))
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end
		return decision
	end

	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, gamePassId, wasPurchased)
		if wasPurchased then
			-- Re-query rather than trusting the event, so the profile mirror
			-- always reflects what Roblox actually believes.
			task.spawn(PurchaseService.refreshPasses, player)
			local def = Monetization.byId("gamepass", gamePassId)
			if def then
				Net.fireClient("PurchaseResult", player, { ok = true, productKey = def.key, productName = def.name })
			end
		end
	end)

	DataService.ProfileLoaded:Connect(function(player)
		task.spawn(function()
			PurchaseService.refreshPasses(player)
			ProgressionService.pushToClient(player)
		end)
	end)

	local audit = Monetization.audit()
	if audit.configured == 0 then
		log.warn(
			string.format(
				"no products are configured (0 of %d have an ID). The shop will show every item as Unavailable and no purchase can be made. See docs/MONETIZATION.md.",
				audit.total
			)
		)
	else
		log.info(string.format("%d of %d products configured", audit.configured, audit.total))
		if #audit.missing > 0 then
			log.warn("unconfigured products: " .. table.concat(audit.missing, ", "))
		end
	end
end

return PurchaseService
