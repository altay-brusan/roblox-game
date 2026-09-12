--!strict
--[[
	CosmeticRegistry
	----------------
	Every appearance item: lamps, outfits, equipment finishes and crew patches.

	Nothing in this file changes a gameplay number. Lamp cosmetics may tint the
	beam, but beam range, angle and battery drain all come from Balance and are
	identical for every lamp, so no purchase makes the dark easier to see in.

	Sources:
	  default  owned by everyone
	  credits  bought with the free currency
	  robux    bought with Robux, keyed to Config.Monetization
	  quest    granted by a milestone or weekly quest
	  event    granted by a live event, and limited to its run
]]

local TableUtil = require(script.Parent.Parent.Core.TableUtil)

local C = Color3.fromRGB

export type CosmeticSlot = "lamp" | "outfit" | "finish" | "patch"
export type CosmeticSource = "default" | "credits" | "robux" | "quest" | "event"

export type CosmeticDef = {
	id: string,
	slot: CosmeticSlot,
	name: string,
	description: string,
	source: CosmeticSource,
	creditCost: number?,
	productKey: string?,
	questId: string?,
	eventId: string?,
	-- Slot-specific appearance data, read by the equipment and character
	-- builders. Colours only; no geometry is gated behind a purchase in a way
	-- that would change a silhouette enough to affect gameplay readability.
	body: Color3?,
	accent: Color3?,
	material: Enum.Material?,
	beamTint: Color3?,
	-- Patches are drawn on the crew jacket and shown beside your name on the
	-- crew panel, which is where most of their value actually sits.
	glyph: string?,
	rarity: number, -- 1 common .. 4 limited
}

local function cosmetic(def: CosmeticDef): CosmeticDef
	return def
end

local COSMETICS: { [string]: CosmeticDef } = {

	--------------------------------------------------------------------
	-- Lamps
	--------------------------------------------------------------------
	lantern_standard = cosmetic({
		id = "lantern_standard",
		slot = "lamp",
		name = "Issue Lamp",
		description = "Standard crew lamp. Scuffed plastic, taped switch.",
		source = "default",
		body = C(64, 66, 70),
		accent = C(180, 182, 186),
		material = Enum.Material.SmoothPlastic,
		beamTint = C(255, 243, 214),
		rarity = 1,
	}),
	lantern_steel = cosmetic({
		id = "lantern_steel",
		slot = "lamp",
		name = "Steel Lamp",
		description = "Heavier, older, and it has survived more than you have.",
		source = "credits",
		creditCost = 1200,
		body = C(96, 100, 106),
		accent = C(140, 144, 150),
		material = Enum.Material.Metal,
		beamTint = C(250, 246, 232),
		rarity = 1,
	}),
	lantern_operator = cosmetic({
		id = "lantern_operator",
		slot = "lamp",
		name = "Operator's Lamp",
		description = "Found at Ward Hill. Somebody kept it working for eleven days.",
		source = "quest",
		questId = "m_archive_full",
		body = C(58, 62, 58),
		accent = C(178, 150, 84),
		material = Enum.Material.Metal,
		beamTint = C(255, 236, 198),
		rarity = 3,
	}),
	lantern_brass = cosmetic({
		id = "lantern_brass",
		slot = "lamp",
		name = "Brass Lamp",
		description = "Polished brass with a fluted lens.",
		source = "robux",
		productKey = "lantern_kit",
		body = C(172, 138, 70),
		accent = C(206, 178, 112),
		material = Enum.Material.Metal,
		beamTint = C(255, 232, 186),
		rarity = 2,
	}),
	lantern_dispatcher = cosmetic({
		id = "lantern_dispatcher",
		slot = "lamp",
		name = "Dispatcher's Lamp",
		description = "Control room issue, with a warm amber lens.",
		source = "robux",
		productKey = "lantern_kit",
		body = C(52, 56, 62),
		accent = C(196, 152, 58),
		material = Enum.Material.Metal,
		beamTint = C(255, 222, 168),
		rarity = 2,
	}),
	lantern_field = cosmetic({
		id = "lantern_field",
		slot = "lamp",
		name = "Field Lamp",
		description = "Canvas-wrapped, rubber bumpered, built to be dropped.",
		source = "robux",
		productKey = "lantern_kit",
		body = C(84, 88, 72),
		accent = C(58, 60, 54),
		material = Enum.Material.Fabric,
		beamTint = C(252, 244, 220),
		rarity = 2,
	}),
	lantern_hooded = cosmetic({
		id = "lantern_hooded",
		slot = "lamp",
		name = "Hooded Lamp",
		description = "A deep hood that throws a tighter, colder pool of light.",
		source = "robux",
		productKey = "lantern_kit",
		body = C(40, 42, 46),
		accent = C(120, 126, 134),
		material = Enum.Material.Metal,
		beamTint = C(230, 240, 255),
		rarity = 2,
	}),
	lantern_signalman = cosmetic({
		id = "lantern_signalman",
		slot = "lamp",
		name = "Signalman's Lamp",
		description = "Three-aspect hand lamp with a red and green shutter.",
		source = "robux",
		productKey = "vip_crew",
		body = C(46, 50, 48),
		accent = C(180, 60, 52),
		material = Enum.Material.Metal,
		beamTint = C(255, 238, 206),
		rarity = 3,
	}),
	lantern_sleeper = cosmetic({
		id = "lantern_sleeper",
		slot = "lamp",
		name = "Sleeper Lamp",
		description = "Maroon enamel, from a service that stopped running long ago.",
		source = "event",
		eventId = "lost_conductor",
		body = C(92, 40, 46),
		accent = C(186, 162, 116),
		material = Enum.Material.Metal,
		beamTint = C(255, 226, 186),
		rarity = 4,
	}),

	--------------------------------------------------------------------
	-- Outfits
	--------------------------------------------------------------------
	outfit_crew = cosmetic({
		id = "outfit_crew",
		slot = "outfit",
		name = "Crew Coveralls",
		description = "What everyone starts in. Oil-stained and warm.",
		source = "default",
		body = C(66, 70, 64),
		accent = C(196, 152, 58),
		material = Enum.Material.Fabric,
		rarity = 1,
	}),
	outfit_yard = cosmetic({
		id = "outfit_yard",
		slot = "outfit",
		name = "Yard Jacket",
		description = "Heavy donkey jacket with reflective shoulders.",
		source = "credits",
		creditCost = 1800,
		body = C(44, 46, 50),
		accent = C(210, 206, 190),
		material = Enum.Material.Fabric,
		rarity = 1,
	}),
	outfit_conductor = cosmetic({
		id = "outfit_conductor",
		slot = "outfit",
		name = "Conductor's Coat",
		description = "Double-breasted, brass-buttoned, entirely impractical out here.",
		source = "robux",
		productKey = "crew_outfits",
		body = C(38, 42, 54),
		accent = C(186, 152, 78),
		material = Enum.Material.Fabric,
		rarity = 2,
	}),
	outfit_engineer = cosmetic({
		id = "outfit_engineer",
		slot = "outfit",
		name = "Long-Haul Engineer",
		description = "Quilted liner, tool loops, and a lamp clip on the chest.",
		source = "robux",
		productKey = "crew_outfits",
		body = C(72, 62, 52),
		accent = C(140, 132, 118),
		material = Enum.Material.Fabric,
		rarity = 2,
	}),
	outfit_surveyor = cosmetic({
		id = "outfit_surveyor",
		slot = "outfit",
		name = "Surveyor",
		description = "Waxed cotton and a map case that still has maps in it.",
		source = "robux",
		productKey = "crew_outfits",
		body = C(86, 80, 58),
		accent = C(120, 104, 74),
		material = Enum.Material.Fabric,
		rarity = 2,
	}),
	outfit_medic = cosmetic({
		id = "outfit_medic",
		slot = "outfit",
		name = "Line Medic",
		description = "White armband, deep pockets, and rather a lot of blood that is not yours.",
		source = "robux",
		productKey = "crew_outfits",
		body = C(58, 62, 66),
		accent = C(218, 214, 206),
		material = Enum.Material.Fabric,
		rarity = 2,
	}),
	outfit_lineman = cosmetic({
		id = "outfit_lineman",
		slot = "outfit",
		name = "Lineman",
		description = "Climbing harness, rubber gauntlets, insulated boots.",
		source = "robux",
		productKey = "crew_outfits",
		body = C(52, 58, 48),
		accent = C(178, 148, 52),
		material = Enum.Material.Fabric,
		rarity = 2,
	}),
	outfit_forester = cosmetic({
		id = "outfit_forester",
		slot = "outfit",
		name = "Forester",
		description = "Oiled wool and a collar you can pull right up.",
		source = "robux",
		productKey = "crew_outfits",
		body = C(48, 58, 46),
		accent = C(96, 74, 52),
		material = Enum.Material.Fabric,
		rarity = 2,
	}),

	--------------------------------------------------------------------
	-- Equipment finishes
	--------------------------------------------------------------------
	finish_standard = cosmetic({
		id = "finish_standard",
		slot = "finish",
		name = "Works Finish",
		description = "Factory paint, mostly worn off.",
		source = "default",
		body = C(96, 100, 106),
		material = Enum.Material.Metal,
		rarity = 1,
	}),
	finish_brass = cosmetic({
		id = "finish_brass",
		slot = "finish",
		name = "Worn Brass",
		description = "Brass fittings, handled until they shine.",
		source = "robux",
		productKey = "tool_finishes",
		body = C(176, 142, 74),
		material = Enum.Material.Metal,
		rarity = 2,
	}),
	finish_gunmetal = cosmetic({
		id = "finish_gunmetal",
		slot = "finish",
		name = "Gunmetal",
		description = "Deep blued steel that eats the light.",
		source = "robux",
		productKey = "tool_finishes",
		body = C(52, 54, 60),
		material = Enum.Material.Metal,
		rarity = 2,
	}),
	finish_enamel = cosmetic({
		id = "finish_enamel",
		slot = "finish",
		name = "Depot Enamel",
		description = "Thick green enamel, chipped down to the primer.",
		source = "robux",
		productKey = "tool_finishes",
		body = C(56, 76, 62),
		material = Enum.Material.SmoothPlastic,
		rarity = 2,
	}),

	--------------------------------------------------------------------
	-- Patches
	--------------------------------------------------------------------
	patch_departure = cosmetic({
		id = "patch_departure",
		slot = "patch",
		name = "0217",
		description = "For completing your first expedition.",
		source = "quest",
		questId = "m_first_run",
		accent = C(196, 152, 58),
		glyph = "numerals",
		rarity = 1,
	}),
	patch_archivist = cosmetic({
		id = "patch_archivist",
		slot = "patch",
		name = "Archivist",
		description = "For recovering twenty records in a week.",
		source = "quest",
		questId = "w_archive",
		accent = C(150, 160, 180),
		glyph = "page",
		rarity = 2,
	}),
	patch_signalman_earned = cosmetic({
		id = "patch_signalman_earned",
		slot = "patch",
		name = "Never Fooled",
		description = "For completing the chapter without following a single false transmission.",
		source = "quest",
		questId = "m_never_fooled",
		accent = C(180, 60, 52),
		glyph = "aspect",
		rarity = 3,
	}),
	patch_signalman = cosmetic({
		id = "patch_signalman",
		slot = "patch",
		name = "Signalman",
		description = "Comes with the Signalman's Pass.",
		source = "robux",
		productKey = "vip_crew",
		accent = C(196, 152, 58),
		glyph = "aspect",
		rarity = 2,
	}),
	patch_conductor = cosmetic({
		id = "patch_conductor",
		slot = "patch",
		name = "Lost Conductor",
		description = "Awarded during the Lost Conductor. Not available afterwards.",
		source = "event",
		eventId = "lost_conductor",
		accent = C(186, 162, 116),
		glyph = "ticket",
		rarity = 4,
	}),
}

--------------------------------------------------------------------------

local CosmeticRegistry = {}

CosmeticRegistry.Cosmetics = TableUtil.deepFreeze(COSMETICS) :: { [string]: CosmeticDef }

CosmeticRegistry.DefaultsBySlot = {
	lamp = "lantern_standard",
	outfit = "outfit_crew",
	finish = "finish_standard",
	patch = "",
}

function CosmeticRegistry.get(id: string): CosmeticDef?
	return COSMETICS[id]
end

function CosmeticRegistry.bySlot(slot: CosmeticSlot): { CosmeticDef }
	local out: { CosmeticDef } = {}
	for _, def in COSMETICS do
		if def.slot == slot then
			table.insert(out, def)
		end
	end
	table.sort(out, function(a, b)
		if a.rarity ~= b.rarity then
			return a.rarity < b.rarity
		end
		return a.id < b.id
	end)
	return out
end

--- Everything purchasable with credits, for the free side of the shop.
function CosmeticRegistry.creditPurchasable(): { CosmeticDef }
	local out: { CosmeticDef } = {}
	for _, def in COSMETICS do
		if def.source == "credits" and (def.creditCost or 0) > 0 then
			table.insert(out, def)
		end
	end
	table.sort(out, function(a, b)
		return (a.creditCost or 0) < (b.creditCost or 0)
	end)
	return out
end

--- All cosmetics granted by a given Robux product, used when a receipt is
--- processed so one purchase reliably grants its whole bundle.
function CosmeticRegistry.grantedByProduct(productKey: string): { string }
	local out: { string } = {}
	for id, def in COSMETICS do
		if def.productKey == productKey then
			table.insert(out, id)
		end
	end
	table.sort(out)
	return out
end

--- Default ownership handed to a brand new profile.
function CosmeticRegistry.defaultOwned(): { [string]: boolean }
	local owned: { [string]: boolean } = {}
	for id, def in COSMETICS do
		if def.source == "default" then
			owned[id] = true
		end
	end
	return owned
end

return CosmeticRegistry
