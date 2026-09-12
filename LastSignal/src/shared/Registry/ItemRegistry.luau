--!strict
--[[
	ItemRegistry
	------------
	Every carryable object in LAST SIGNAL.

	Design rule followed here: a small number of items that each change a
	decision, rather than a long catalogue of near-duplicates. Each entry below
	answers "what would a player give up to carry this?".

	Weight is the real constraint. Slots exist so the grid reads clearly, but
	weight is what forces the interesting choice between a jerry can and a
	medical kit on the walk back.

	`model` describes the procedural build used by the world builders and the
	dropped-item spawner. Items are recognisable by silhouette and material; no
	item in this project relies on a floating name board to be identified.
]]

local TableUtil = require(script.Parent.Parent.Core.TableUtil)

export type ItemCategory = "medical" | "power" | "fuel" | "tool" | "component" | "ammo" | "consumable" | "story" | "weapon"

export type ModelSpec = {
	shape: string, -- interpreted by BuildKit.buildItemModel
	size: Vector3,
	colour: Color3,
	material: Enum.Material,
	accent: Color3?,
	emissive: number?,
}

export type ItemDef = {
	id: string,
	name: string,
	category: ItemCategory,
	description: string,
	-- Short line shown on the proximity prompt, never a floating label.
	promptVerb: string,
	weight: number,
	stackSize: number,
	-- Items marked essential cannot be destroyed and are returned to the train
	-- supply rack instead of the floor when dropped inside a carriage.
	essential: boolean,
	-- Can be placed in one of the five quick slots.
	quickUsable: boolean,
	useSeconds: number?,
	model: ModelSpec,
	-- Free-form payload consumed by InventoryService and the interaction system.
	effect: { [string]: any }?,
	-- Relative frequency when a loot table asks for a random item of a tier.
	lootWeight: number,
	lootTier: number, -- 1 common, 2 uncommon, 3 rare
	icon: string?, -- vector glyph key drawn by the UI kit, not an image asset
}

local function item(def: ItemDef): ItemDef
	return def
end

local C = Color3.fromRGB

local ITEMS: { [string]: ItemDef } = {

	--------------------------------------------------------------------
	-- Medical
	--------------------------------------------------------------------
	bandage = item({
		id = "bandage",
		name = "Field Dressing",
		category = "medical",
		description = "Stops bleeding and restores a little health. Quick to apply, which matters more than the amount it heals.",
		promptVerb = "Take dressing",
		weight = 0.3,
		stackSize = 6,
		essential = false,
		quickUsable = true,
		useSeconds = 2.2,
		model = { shape = "roll", size = Vector3.new(0.45, 0.3, 0.45), colour = C(226, 220, 205), material = Enum.Material.Fabric },
		effect = { heal = 22, stopBleed = true },
		lootWeight = 34,
		lootTier = 1,
		icon = "cross",
	}),
	medkit = item({
		id = "medkit",
		name = "Trauma Kit",
		category = "medical",
		description = "Full field kit. Heals substantially but takes long enough that you need somebody watching the door.",
		promptVerb = "Take trauma kit",
		weight = 2.4,
		stackSize = 2,
		essential = false,
		quickUsable = true,
		useSeconds = 6.5,
		model = { shape = "case", size = Vector3.new(1.1, 0.7, 0.55), colour = C(188, 62, 56), material = Enum.Material.SmoothPlastic, accent = C(235, 235, 230) },
		effect = { heal = 68, stopBleed = true, curesInjury = true },
		lootWeight = 10,
		lootTier = 2,
		icon = "case-cross",
	}),
	stimulant = item({
		id = "stimulant",
		name = "Field Stimulant",
		category = "medical",
		description = "Restores stamina instantly and blunts pain for a short while. The crash afterwards is real.",
		promptVerb = "Take stimulant",
		weight = 0.2,
		stackSize = 4,
		essential = false,
		quickUsable = true,
		useSeconds = 1.4,
		model = { shape = "vial", size = Vector3.new(0.22, 0.6, 0.22), colour = C(150, 198, 172), material = Enum.Material.Glass, emissive = 0.15 },
		effect = { stamina = 100, staminaBoostSeconds = 25, crashSeconds = 12 },
		lootWeight = 14,
		lootTier = 2,
		icon = "vial",
	}),

	--------------------------------------------------------------------
	-- Power and light
	--------------------------------------------------------------------
	battery = item({
		id = "battery",
		name = "Lamp Cell",
		category = "power",
		description = "Recharges your flashlight. The single most argued-over object on any expedition.",
		promptVerb = "Take cell",
		weight = 0.5,
		stackSize = 8,
		essential = false,
		quickUsable = true,
		useSeconds = 1.8,
		model = { shape = "cylinder", size = Vector3.new(0.34, 0.75, 0.34), colour = C(56, 60, 66), material = Enum.Material.Metal, accent = C(196, 152, 58) },
		effect = { flashlightCharge = 55 },
		lootWeight = 30,
		lootTier = 1,
		icon = "battery",
	}),
	fusebox_fuse = item({
		id = "fusebox_fuse",
		name = "Ceramic Fuse",
		category = "component",
		description = "Heavy-duty fuse for station distribution boards. Without one, the lights stay off.",
		promptVerb = "Take fuse",
		weight = 0.2,
		stackSize = 4,
		essential = true,
		quickUsable = false,
		model = { shape = "cylinder", size = Vector3.new(0.28, 0.5, 0.28), colour = C(214, 200, 168), material = Enum.Material.Concrete, accent = C(150, 120, 60) },
		effect = { repairs = "fusebox" },
		lootWeight = 8,
		lootTier = 2,
		icon = "fuse",
	}),
	flare = item({
		id = "flare",
		name = "Signal Flare",
		category = "consumable",
		description = "Burns hot and red for half a minute. The Signal-Eater will not cross a lit flare, and your crew can see you from a long way off.",
		promptVerb = "Take flare",
		weight = 0.3,
		stackSize = 5,
		essential = false,
		quickUsable = true,
		useSeconds = 0.8,
		model = { shape = "cylinder", size = Vector3.new(0.24, 0.8, 0.24), colour = C(178, 54, 48), material = Enum.Material.SmoothPlastic, accent = C(255, 132, 70), emissive = 0.2 },
		effect = { placeFlare = true, denialSeconds = 24, denialRadius = 45 },
		lootWeight = 18,
		lootTier = 2,
		icon = "flare",
	}),
	glowstick = item({
		id = "glowstick",
		name = "Marker Stick",
		category = "consumable",
		description = "Cold green light that lasts for ages. Marks a route without giving anything away.",
		promptVerb = "Take marker",
		weight = 0.1,
		stackSize = 10,
		essential = false,
		quickUsable = true,
		useSeconds = 0.5,
		model = { shape = "cylinder", size = Vector3.new(0.16, 0.62, 0.16), colour = C(118, 196, 128), material = Enum.Material.Neon, emissive = 0.9 },
		effect = { placeMarker = true, lifetimeSeconds = 420 },
		lootWeight = 22,
		lootTier = 1,
		icon = "stick",
	}),

	--------------------------------------------------------------------
	-- Train supplies
	--------------------------------------------------------------------
	fuel_can = item({
		id = "fuel_can",
		name = "Jerry Can",
		category = "fuel",
		description = "Twenty litres of diesel. Heavy enough that carrying two means carrying nothing else.",
		promptVerb = "Take jerry can",
		weight = 9.0,
		stackSize = 1,
		essential = true,
		quickUsable = false,
		useSeconds = 4.5,
		model = { shape = "jerrycan", size = Vector3.new(0.7, 1.25, 0.42), colour = C(78, 84, 70), material = Enum.Material.Metal, accent = C(40, 42, 38) },
		effect = { trainFuel = 26 },
		lootWeight = 16,
		lootTier = 1,
		icon = "can",
	}),
	repair_kit = item({
		id = "repair_kit",
		name = "Repair Kit",
		category = "tool",
		description = "Gaskets, clamps and wire. Restores locomotive condition at the engine bay.",
		promptVerb = "Take repair kit",
		weight = 3.2,
		stackSize = 2,
		essential = true,
		quickUsable = false,
		useSeconds = 7.0,
		model = { shape = "case", size = Vector3.new(1.0, 0.5, 0.65), colour = C(102, 98, 88), material = Enum.Material.DiamondPlate, accent = C(196, 152, 58) },
		effect = { trainCondition = 22 },
		lootWeight = 12,
		lootTier = 2,
		icon = "case-wrench",
	}),
	coolant = item({
		id = "coolant",
		name = "Coolant Flask",
		category = "fuel",
		description = "Stops the engine running hot on the long grade. Cheaper than a repair kit, and only works before the damage is done.",
		promptVerb = "Take coolant",
		weight = 2.0,
		stackSize = 2,
		essential = false,
		quickUsable = false,
		useSeconds = 3.5,
		model = { shape = "bottle", size = Vector3.new(0.4, 0.9, 0.4), colour = C(96, 128, 150), material = Enum.Material.SmoothPlastic, accent = C(220, 220, 214) },
		effect = { trainCondition = 9, preventOverheatSeconds = 420 },
		lootWeight = 14,
		lootTier = 1,
		icon = "bottle",
	}),

	--------------------------------------------------------------------
	-- Tools and components
	--------------------------------------------------------------------
	crowbar = item({
		id = "crowbar",
		name = "Crowbar",
		category = "tool",
		description = "Opens seized doors and jammed lockers. Also an honest weapon, if it comes to that.",
		promptVerb = "Take crowbar",
		weight = 2.6,
		stackSize = 1,
		essential = false,
		quickUsable = true,
		model = { shape = "bar", size = Vector3.new(0.18, 2.6, 0.18), colour = C(120, 74, 56), material = Enum.Material.Metal },
		effect = { opens = "seized", asWeapon = "crowbar" },
		lootWeight = 10,
		lootTier = 2,
		icon = "bar",
	}),
	bolt_cutters = item({
		id = "bolt_cutters",
		name = "Bolt Cutters",
		category = "tool",
		description = "Removes chained gates and padlocks. Bulky, and there is usually another way round.",
		promptVerb = "Take bolt cutters",
		weight = 4.1,
		stackSize = 1,
		essential = false,
		quickUsable = false,
		useSeconds = 3.0,
		model = { shape = "cutters", size = Vector3.new(0.5, 2.2, 0.3), colour = C(84, 88, 92), material = Enum.Material.Metal, accent = C(168, 48, 44) },
		effect = { opens = "chained" },
		lootWeight = 7,
		lootTier = 2,
		icon = "cutters",
	}),
	relay = item({
		id = "relay",
		name = "Signal Relay",
		category = "component",
		description = "Line-side relay module. The signal tower cannot be cleared without a working one.",
		promptVerb = "Take relay",
		weight = 1.8,
		stackSize = 2,
		essential = true,
		quickUsable = false,
		model = { shape = "box", size = Vector3.new(0.62, 0.5, 0.38), colour = C(66, 72, 78), material = Enum.Material.Metal, accent = C(110, 160, 190), emissive = 0.1 },
		effect = { repairs = "signal_relay" },
		lootWeight = 5,
		lootTier = 3,
		icon = "relay",
	}),
	hydraulic_valve = item({
		id = "hydraulic_valve",
		name = "Hydraulic Valve",
		category = "component",
		description = "Heavy brass valve from the bridge lift gear. There is exactly one spare at the depot.",
		promptVerb = "Take valve",
		weight = 5.5,
		stackSize = 1,
		essential = true,
		quickUsable = false,
		model = { shape = "valve", size = Vector3.new(0.8, 0.8, 0.6), colour = C(158, 126, 62), material = Enum.Material.Metal },
		effect = { repairs = "bridge_hydraulics" },
		lootWeight = 3,
		lootTier = 3,
		icon = "valve",
	}),
	radio_part = item({
		id = "radio_part",
		name = "Transmitter Valve",
		category = "component",
		description = "Glass valve for a high-power transmitter. Fragile, irreplaceable, and the whole reason you are going to the relay station.",
		promptVerb = "Take transmitter valve",
		weight = 0.9,
		stackSize = 1,
		essential = true,
		quickUsable = false,
		model = { shape = "vial", size = Vector3.new(0.36, 0.85, 0.36), colour = C(190, 186, 178), material = Enum.Material.Glass, accent = C(210, 160, 90), emissive = 0.25 },
		effect = { repairs = "transmitter" },
		lootWeight = 1,
		lootTier = 3,
		icon = "valve-glass",
	}),

	--------------------------------------------------------------------
	-- Ammunition
	--------------------------------------------------------------------
	ammo_pistol = item({
		id = "ammo_pistol",
		name = ".38 Cartridges",
		category = "ammo",
		description = "Six to a box. For the service revolver.",
		promptVerb = "Take cartridges",
		weight = 0.35,
		stackSize = 8,
		essential = false,
		quickUsable = false,
		model = { shape = "box", size = Vector3.new(0.4, 0.22, 0.3), colour = C(140, 118, 86), material = Enum.Material.Cardboard, accent = C(196, 152, 58) },
		effect = { ammo = "pistol", rounds = 6 },
		lootWeight = 20,
		lootTier = 1,
		icon = "ammo",
	}),
	ammo_shell = item({
		id = "ammo_shell",
		name = "12 Gauge Shells",
		category = "ammo",
		description = "Four to a sleeve. Loud, and loud has consequences out here.",
		promptVerb = "Take shells",
		weight = 0.5,
		stackSize = 6,
		essential = false,
		quickUsable = false,
		model = { shape = "box", size = Vector3.new(0.46, 0.24, 0.3), colour = C(132, 66, 60), material = Enum.Material.Cardboard, accent = C(196, 152, 58) },
		effect = { ammo = "shell", rounds = 4 },
		lootWeight = 12,
		lootTier = 2,
		icon = "ammo",
	}),
	ammo_rifle = item({
		id = "ammo_rifle",
		name = "Rifle Rounds",
		category = "ammo",
		description = "Five stripper-clipped rounds for the surveyor's rifle.",
		promptVerb = "Take rounds",
		weight = 0.4,
		stackSize = 6,
		essential = false,
		quickUsable = false,
		model = { shape = "box", size = Vector3.new(0.44, 0.22, 0.26), colour = C(96, 104, 84), material = Enum.Material.Cardboard, accent = C(196, 152, 58) },
		effect = { ammo = "rifle", rounds = 5 },
		lootWeight = 8,
		lootTier = 2,
		icon = "ammo",
	}),
	flare_shell = item({
		id = "flare_shell",
		name = "Flare Cartridge",
		category = "ammo",
		description = "For the flare pistol. Denies ground at range instead of up close.",
		promptVerb = "Take flare cartridge",
		weight = 0.25,
		stackSize = 6,
		essential = false,
		quickUsable = false,
		model = { shape = "cylinder", size = Vector3.new(0.22, 0.34, 0.22), colour = C(178, 54, 48), material = Enum.Material.SmoothPlastic },
		effect = { ammo = "flare", rounds = 1 },
		lootWeight = 10,
		lootTier = 2,
		icon = "ammo",
	}),

	--------------------------------------------------------------------
	-- Story and collectibles
	--------------------------------------------------------------------
	dispatch_log = item({
		id = "dispatch_log",
		name = "Dispatch Log Page",
		category = "story",
		description = "A torn page from a station dispatch log. Read it in your journal whenever you like; nothing is gated behind reading it.",
		promptVerb = "Read page",
		weight = 0.05,
		stackSize = 20,
		essential = false,
		quickUsable = false,
		model = { shape = "page", size = Vector3.new(0.6, 0.02, 0.8), colour = C(206, 196, 170), material = Enum.Material.Fabric },
		effect = { collectible = "dispatch_log" },
		lootWeight = 12,
		lootTier = 1,
		icon = "page",
	}),
	conductor_ticket = item({
		id = "conductor_ticket",
		name = "Punched Ticket",
		category = "story",
		description = "A ticket punched for a service that never ran. Collected during the Lost Conductor event.",
		promptVerb = "Take ticket",
		weight = 0.02,
		stackSize = 50,
		essential = false,
		quickUsable = false,
		model = { shape = "page", size = Vector3.new(0.32, 0.02, 0.5), colour = C(212, 186, 140), material = Enum.Material.Fabric, accent = C(120, 60, 50) },
		effect = { eventToken = "lost_conductor" },
		lootWeight = 0, -- never in normal loot; only the event spawns these
		lootTier = 3,
		icon = "ticket",
	}),
	signal_key = item({
		id = "signal_key",
		name = "Interlocking Key",
		category = "story",
		description = "Brass key for the signal tower interlocking frame. One per tower, kept by the signalman.",
		promptVerb = "Take key",
		weight = 0.15,
		stackSize = 1,
		essential = true,
		quickUsable = false,
		model = { shape = "key", size = Vector3.new(0.1, 0.5, 0.1), colour = C(180, 146, 74), material = Enum.Material.Metal },
		effect = { unlocks = "signal_frame" },
		lootWeight = 0,
		lootTier = 3,
		icon = "key",
	}),
	recorder = item({
		id = "recorder",
		name = "Portable Recorder",
		category = "story",
		description = "Still has tape in it. Plays what somebody recorded here before the line went quiet.",
		promptVerb = "Play recording",
		weight = 0.6,
		stackSize = 1,
		essential = false,
		quickUsable = true,
		useSeconds = 1.0,
		model = { shape = "box", size = Vector3.new(0.5, 0.16, 0.34), colour = C(72, 70, 68), material = Enum.Material.SmoothPlastic, accent = C(160, 156, 150) },
		effect = { collectible = "recording", playsAudio = true },
		lootWeight = 4,
		lootTier = 3,
		icon = "recorder",
	}),
}

--------------------------------------------------------------------------
-- Indexes
--------------------------------------------------------------------------

local ItemRegistry = {}

ItemRegistry.Items = TableUtil.deepFreeze(ITEMS) :: { [string]: ItemDef }

function ItemRegistry.get(id: string): ItemDef?
	return ITEMS[id]
end

--- Never returns nil. Used in display paths where a missing item must not
--- crash a panel; the caller gets an obviously-wrong placeholder instead.
function ItemRegistry.getOrFallback(id: string): ItemDef
	local def = ITEMS[id]
	if def then
		return def
	end
	return {
		id = id,
		name = "Unknown Item",
		category = "consumable",
		description = "This item is not in the registry. That is a bug; please report the item id.",
		promptVerb = "Take",
		weight = 0.1,
		stackSize = 1,
		essential = false,
		quickUsable = false,
		model = { shape = "box", size = Vector3.new(0.5, 0.5, 0.5), colour = C(200, 60, 200), material = Enum.Material.Neon },
		lootWeight = 0,
		lootTier = 1,
	}
end

function ItemRegistry.exists(id: string): boolean
	return ITEMS[id] ~= nil
end

function ItemRegistry.byCategory(category: ItemCategory): { ItemDef }
	local out: { ItemDef } = {}
	for _, def in ITEMS do
		if def.category == category then
			table.insert(out, def)
		end
	end
	table.sort(out, function(a, b)
		return a.id < b.id
	end)
	return out
end

--- Items eligible for a random loot roll at the given tier.
function ItemRegistry.lootPool(tier: number): { ItemDef }
	local out: { ItemDef } = {}
	for _, def in ITEMS do
		if def.lootTier == tier and def.lootWeight > 0 then
			table.insert(out, def)
		end
	end
	table.sort(out, function(a, b)
		return a.id < b.id
	end)
	return out
end

--- Rolls one item id from a tier, or nil when the pool is empty.
function ItemRegistry.rollLoot(tier: number, rng: Random?): string?
	local pool = ItemRegistry.lootPool(tier)
	local picked = TableUtil.weightedPick(pool, function(def)
		return (def :: ItemDef).lootWeight
	end, rng)
	return if picked then (picked :: ItemDef).id else nil
end

return ItemRegistry
