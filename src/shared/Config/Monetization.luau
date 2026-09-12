--!strict
--[[
	Monetization
	------------
	Every Robux-earning product in LAST SIGNAL is declared here, and only here.

	HOW TO TURN THIS ON
	-------------------
	Each entry has an `id` field set to 0. Zero means "not configured": the shop
	renders the product as Unavailable, the buy button is disabled, and no
	purchase can be attempted or simulated. Nothing anywhere in this project
	fakes a purchase.

	To go live, RIPjafar1 creates each Game Pass and Developer Product on the
	published experience, then pastes the numeric ID into the matching `id`
	field here. Full walkthrough with screenshots of where each number comes
	from is in docs/MONETIZATION.md.

	IMPORTANT OWNERSHIP NOTE
	------------------------
	Robux from Game Passes and Developer Products is paid to the owner of the
	experience the products belong to. Creating them under the RIPGAMES group or
	under the RIPjafar1 account is what directs revenue; the strings in this file
	do not. If the place is published under a different account, that account is
	paid. See docs/OWNERSHIP.md.

	PRICE FIELDS
	------------
	`suggestedPrice` is a design note for whoever configures the product. It is
	never shown to players. The shop always displays the live price fetched from
	MarketplaceService:GetProductInfo, so what a player sees is always what
	Roblox will actually charge.
]]

local Monetization = {}

export type ProductKind = "gamepass" | "developerproduct"

export type ProductDef = {
	key: string,
	kind: ProductKind,
	id: number,
	name: string,
	blurb: string,
	suggestedPrice: number,
	category: string,
	-- What owning or consuming this grants. Interpreted by PurchaseService.
	grants: { [string]: any },
	-- Permanent entitlements can only be bought once; the shop hides the button
	-- and shows Owned instead.
	permanent: boolean,
	-- Sort weight inside its shop category.
	order: number,
}

--------------------------------------------------------------------------
-- Game Passes (permanent entitlements)
--------------------------------------------------------------------------

local GAMEPASSES: { ProductDef } = {
	{
		key = "vip_crew",
		kind = "gamepass",
		id = 0,
		name = "Signalman's Pass",
		blurb = "Permanent: +25% credits and XP, a reserved cab seat cosmetic, the Signalman lantern skin, and a second daily quest slot.",
		suggestedPrice = 399,
		category = "passes",
		grants = {
			creditMultiplier = 1.25,
			xpMultiplier = 1.25,
			extraDailyQuest = 1,
			cosmetics = { "lantern_signalman", "patch_signalman" },
			chatTag = "SIGNALMAN",
		},
		permanent = true,
		order = 1,
	},
	{
		key = "cargo_rig",
		kind = "gamepass",
		id = 0,
		name = "Cargo Rigging",
		blurb = "Permanent: +6 inventory slots and +18 kg carry weight for every crew member you bring, including your friends.",
		suggestedPrice = 249,
		category = "passes",
		grants = {
			inventorySlots = 6,
			carryWeight = 18,
			sharedWithCrew = true,
		},
		permanent = true,
		order = 2,
	},
	{
		key = "workshop_access",
		kind = "gamepass",
		id = 0,
		name = "Workshop Access",
		blurb = "Permanent: unlocks the lobby workshop bench for livery mixing, plus three exclusive interior kits.",
		suggestedPrice = 199,
		category = "passes",
		grants = {
			workshopBench = true,
			cosmetics = { "interior_brass", "interior_surveyor", "interior_ashwood" },
		},
		permanent = true,
		order = 3,
	},
}

--------------------------------------------------------------------------
-- Developer Products (consumables and one-off unlocks)
--------------------------------------------------------------------------

local DEVELOPER_PRODUCTS: { ProductDef } = {
	{
		key = "field_revive",
		kind = "developerproduct",
		id = 0,
		name = "Emergency Stimulant",
		blurb = "Revive yourself once, where you fell, with 40% health. Only offered while you are down and only when a teammate is not already reviving you.",
		suggestedPrice = 20,
		category = "field",
		grants = { selfRevive = 1 },
		permanent = false,
		order = 1,
	},
	{
		key = "credits_small",
		kind = "developerproduct",
		id = 0,
		name = "Supply Voucher",
		blurb = "1,000 credits, spendable on liveries, interiors and cosmetics.",
		suggestedPrice = 99,
		category = "credits",
		grants = { credits = 1000 },
		permanent = false,
		order = 1,
	},
	{
		key = "credits_medium",
		kind = "developerproduct",
		id = 0,
		name = "Depot Requisition",
		blurb = "5,500 credits. Better value than the Supply Voucher.",
		suggestedPrice = 449,
		category = "credits",
		grants = { credits = 5500 },
		permanent = false,
		order = 2,
	},
	{
		key = "credits_large",
		kind = "developerproduct",
		id = 0,
		name = "Regional Stockpile",
		blurb = "14,000 credits. Best value.",
		suggestedPrice = 999,
		category = "credits",
		grants = { credits = 14000 },
		permanent = false,
		order = 3,
	},
	{
		key = "livery_ember",
		kind = "developerproduct",
		id = 0,
		name = "Livery: Ember Line",
		blurb = "Permanent livery. Oxblood panels, brass trim, warm running lights that read clearly at distance in fog.",
		suggestedPrice = 149,
		category = "liveries",
		grants = { cosmetics = { "livery_ember" } },
		permanent = true,
		order = 1,
	},
	{
		key = "livery_permafrost",
		kind = "developerproduct",
		id = 0,
		name = "Livery: Permafrost",
		blurb = "Permanent livery. Frost-bitten white over grey steel with ice-blue signal lamps.",
		suggestedPrice = 149,
		category = "liveries",
		grants = { cosmetics = { "livery_permafrost" } },
		permanent = true,
		order = 2,
	},
	{
		key = "livery_nightpost",
		kind = "developerproduct",
		id = 0,
		name = "Livery: Night Post",
		blurb = "Permanent livery. Matte black with reflective hazard chevrons that catch your own headlights.",
		suggestedPrice = 199,
		category = "liveries",
		grants = { cosmetics = { "livery_nightpost" } },
		permanent = true,
		order = 3,
	},
	{
		key = "lantern_kit",
		kind = "developerproduct",
		id = 0,
		name = "Lamp Collection",
		blurb = "Permanent: four cosmetic flashlight bodies, including the brass Dispatcher lamp with a warmer beam tint.",
		suggestedPrice = 129,
		category = "cosmetics",
		grants = { cosmetics = { "lantern_brass", "lantern_dispatcher", "lantern_field", "lantern_hooded" } },
		permanent = true,
		order = 1,
	},
	{
		key = "crew_outfits",
		kind = "developerproduct",
		id = 0,
		name = "Crew Wardrobe",
		blurb = "Permanent: six crew outfits including the conductor's coat and the long-haul engineer's kit.",
		suggestedPrice = 179,
		category = "cosmetics",
		grants = {
			cosmetics = {
				"outfit_conductor",
				"outfit_engineer",
				"outfit_surveyor",
				"outfit_medic",
				"outfit_lineman",
				"outfit_forester",
			},
		},
		permanent = true,
		order = 2,
	},
	{
		key = "tool_finishes",
		kind = "developerproduct",
		id = 0,
		name = "Equipment Finishes",
		blurb = "Permanent: worn brass, gunmetal and enamel finishes for your tools and weapons. Appearance only, no stat change.",
		suggestedPrice = 99,
		category = "cosmetics",
		grants = { cosmetics = { "finish_brass", "finish_gunmetal", "finish_enamel" } },
		permanent = true,
		order = 3,
	},
}

--------------------------------------------------------------------------
-- Lookup tables
--------------------------------------------------------------------------

Monetization.GamePasses = GAMEPASSES
Monetization.DeveloperProducts = DEVELOPER_PRODUCTS

local byKey: { [string]: ProductDef } = {}
local allProducts: { ProductDef } = {}

for _, def in GAMEPASSES do
	byKey[def.key] = def
	table.insert(allProducts, def)
end
for _, def in DEVELOPER_PRODUCTS do
	if byKey[def.key] then
		error("Monetization: duplicate product key " .. def.key)
	end
	byKey[def.key] = def
	table.insert(allProducts, def)
end

Monetization.All = allProducts

function Monetization.get(key: string): ProductDef?
	return byKey[key]
end

--- Reverse lookup used by ProcessReceipt and gamepass checks, where Roblox
--- gives us only a numeric ID.
function Monetization.byId(kind: ProductKind, id: number): ProductDef?
	if id <= 0 then
		return nil
	end
	for _, def in allProducts do
		if def.kind == kind and def.id == id then
			return def
		end
	end
	return nil
end

--- A product is purchasable only when it has a real ID. Everything that can
--- show a buy button must call this first.
function Monetization.isConfigured(key: string): boolean
	local def = byKey[key]
	return def ~= nil and def.id > 0
end

--- Reports configuration state at boot so the operator sees exactly what is
--- live and what is still switched off.
function Monetization.audit(): { configured: number, total: number, missing: { string } }
	local configured = 0
	local missing: { string } = {}
	for _, def in allProducts do
		if def.id > 0 then
			configured += 1
		else
			table.insert(missing, def.key)
		end
	end
	table.sort(missing)
	return { configured = configured, total = #allProducts, missing = missing }
end

--------------------------------------------------------------------------
-- Shop categories
--------------------------------------------------------------------------

Monetization.Categories = {
	{ id = "featured", name = "Featured", robux = true },
	{ id = "passes", name = "Passes", robux = true },
	{ id = "liveries", name = "Liveries", robux = true },
	{ id = "cosmetics", name = "Cosmetics", robux = true },
	{ id = "credits", name = "Credits", robux = true },
	{ id = "field", name = "Field Supplies", robux = true },
	{ id = "exchange", name = "Credit Exchange", robux = false },
}

--------------------------------------------------------------------------
-- Design guardrails, enforced by tests in docs/TESTING.md
--------------------------------------------------------------------------

-- No product in this file grants combat power, damage, health, ammunition
-- capacity or threat suppression. Cargo Rigging grants carry capacity, which
-- affects how much loot a crew can haul, not how hard they hit. This is a
-- deliberate constraint: it keeps the free experience whole and keeps the
-- paid content about identity and convenience.
Monetization.NoCombatAdvantage = true

-- Purchase prompts are suppressed while any of these are true. Checked by
-- ShopService before it will open a prompt.
Monetization.PromptBlockedStates = {
	"cinematic",
	"encounter",
	"downed_teammate_critical",
	"expedition_climax",
	"loading",
}

return Monetization
