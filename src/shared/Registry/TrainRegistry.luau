--!strict
--[[
	TrainRegistry
	-------------
	The four trains, and the liveries and interior kits that dress them.

	A variant is not a recolour. Each entry carries a `build` block that changes
	the locomotive's proportions, nose profile, bogie count, carriage count and
	carriage layout, so the trains read differently at a glance and handle
	differently in the cab. Liveries are the recolours, and they are separate.

	Handling numbers are multipliers applied on top of Balance.Train, so a
	global re-tune of train physics still affects every variant consistently.
]]

local TableUtil = require(script.Parent.Parent.Core.TableUtil)

local C = Color3.fromRGB

export type CarriageKind = "passenger" | "supply" | "workshop" | "flat" | "guard"

export type CarriageSpec = {
	kind: CarriageKind,
	length: number,
	-- Interior fitting density; drives how much seating and storage is built.
	seats: number,
	racks: number,
	crates: number,
	-- Carriages with this flag get a working roof hatch, used for optional
	-- risky routes and for one of the station puzzles.
	roofHatch: boolean?,
}

export type TrainBuild = {
	-- Locomotive -------------------------------------------------------
	locoLength: number,
	locoWidth: number,
	locoHeight: number,
	nose: "blunt" | "raked" | "bonnet" | "armoured",
	bogies: number, -- per locomotive
	axlesPerBogie: number,
	wheelRadius: number,
	cabPosition: "front" | "centre",
	exhaustStacks: number,
	-- Exterior detail density. Higher values add more grilles, pipes,
	-- handrails and rivet strips during the procedural build.
	detailLevel: number,
	carriages: { CarriageSpec },
}

export type TrainHandling = {
	maxSpeedMultiplier: number,
	accelerationMultiplier: number,
	brakingMultiplier: number,
	fuelUseMultiplier: number,
	conditionDriftMultiplier: number,
	damageResistance: number, -- 1.0 is baseline; higher takes less condition damage
	inventoryBonusSlots: number,
	headlightRangeMultiplier: number,
}

export type TrainDef = {
	id: string,
	name: string,
	class: string,
	tagline: string,
	description: string,
	build: TrainBuild,
	handling: TrainHandling,
	defaultLivery: string,
	unlockLevel: number,
	creditCost: number,
	-- The starter must always be enough to finish the chapter. Enforced by a
	-- check in ExpeditionService, not just by intent.
	isStarter: boolean,
}

local function train(def: TrainDef): TrainDef
	return def
end

--------------------------------------------------------------------------
-- Trains
--------------------------------------------------------------------------

local TRAINS: { [string]: TrainDef } = {
	warden = train({
		id = "warden",
		name = "Warden",
		class = "Class 24 Mixed Traffic",
		tagline = "The one that always comes back.",
		description = "Yard workhorse. Nothing about it is exceptional, which is exactly why it is the one the crews trust. Two carriages, honest brakes, and enough fuel margin to make a mistake and survive it.",
		build = {
			locoLength = 46,
			locoWidth = 12,
			locoHeight = 14,
			nose = "blunt",
			bogies = 2,
			axlesPerBogie = 3,
			wheelRadius = 2.1,
			cabPosition = "front",
			exhaustStacks = 2,
			detailLevel = 3,
			carriages = {
				{ kind = "passenger", length = 52, seats = 12, racks = 6, crates = 2 },
				{ kind = "supply", length = 46, seats = 2, racks = 4, crates = 10, roofHatch = true },
			},
		},
		handling = {
			maxSpeedMultiplier = 1.0,
			accelerationMultiplier = 1.0,
			brakingMultiplier = 1.0,
			fuelUseMultiplier = 1.0,
			conditionDriftMultiplier = 1.0,
			damageResistance = 1.0,
			inventoryBonusSlots = 0,
			headlightRangeMultiplier = 1.0,
		},
		defaultLivery = "livery_depot",
		unlockLevel = 0,
		creditCost = 0,
		isStarter = true,
	}),

	packhorse = train({
		id = "packhorse",
		name = "Packhorse",
		class = "Heavy Freight Consist",
		tagline = "Bring everything. Arrive late.",
		description = "A freight hauler with three carriages and a flat wagon. Storage for days and a brake that means it. Slow to build speed and slower to stop, so every station approach has to be planned two minutes early.",
		build = {
			locoLength = 54,
			locoWidth = 13,
			locoHeight = 15,
			nose = "bonnet",
			bogies = 2,
			axlesPerBogie = 3,
			wheelRadius = 2.0,
			cabPosition = "centre",
			exhaustStacks = 3,
			detailLevel = 4,
			carriages = {
				{ kind = "passenger", length = 48, seats = 10, racks = 4, crates = 2 },
				{ kind = "supply", length = 54, seats = 0, racks = 8, crates = 18, roofHatch = true },
				{ kind = "flat", length = 44, seats = 0, racks = 2, crates = 12 },
			},
		},
		handling = {
			maxSpeedMultiplier = 0.82,
			accelerationMultiplier = 0.68,
			brakingMultiplier = 0.74,
			fuelUseMultiplier = 1.18,
			conditionDriftMultiplier = 0.85,
			damageResistance = 1.25,
			inventoryBonusSlots = 8,
			headlightRangeMultiplier = 0.95,
		},
		defaultLivery = "livery_freight",
		unlockLevel = 10,
		creditCost = 6500,
		isStarter = false,
	}),

	kestrel = train({
		id = "kestrel",
		name = "Kestrel",
		class = "Light Rail Express",
		tagline = "Outrun the schedule. Nothing else.",
		description = "A stripped express unit on a single short carriage. It moves, and it stops, faster than anything else on the line. It also breaks if you look at it wrong, and it carries almost nothing.",
		build = {
			locoLength = 40,
			locoWidth = 11,
			locoHeight = 12.5,
			nose = "raked",
			bogies = 2,
			axlesPerBogie = 2,
			wheelRadius = 1.8,
			cabPosition = "front",
			exhaustStacks = 1,
			detailLevel = 3,
			carriages = {
				{ kind = "passenger", length = 44, seats = 8, racks = 4, crates = 4, roofHatch = true },
			},
		},
		handling = {
			maxSpeedMultiplier = 1.34,
			accelerationMultiplier = 1.45,
			brakingMultiplier = 1.3,
			fuelUseMultiplier = 0.88,
			conditionDriftMultiplier = 1.55,
			damageResistance = 0.7,
			inventoryBonusSlots = -4,
			headlightRangeMultiplier = 1.15,
		},
		defaultLivery = "livery_express",
		unlockLevel = 18,
		creditCost = 11000,
		isStarter = false,
	}),

	bulwark = train({
		id = "bulwark",
		name = "Bulwark",
		class = "Armoured Permanent Way Unit",
		tagline = "Let it come to the windows.",
		description = "Plated engineering stock with a guard's van and shuttered windows. Takes punishment that would strand anything else, keeps its interior lights through a failure, and drinks fuel doing it.",
		build = {
			locoLength = 50,
			locoWidth = 13.5,
			locoHeight = 15,
			nose = "armoured",
			bogies = 2,
			axlesPerBogie = 3,
			wheelRadius = 2.2,
			cabPosition = "front",
			exhaustStacks = 2,
			detailLevel = 5,
			carriages = {
				{ kind = "guard", length = 40, seats = 6, racks = 4, crates = 4 },
				{ kind = "passenger", length = 50, seats = 12, racks = 6, crates = 4 },
				{ kind = "workshop", length = 46, seats = 2, racks = 6, crates = 8, roofHatch = true },
			},
		},
		handling = {
			maxSpeedMultiplier = 0.9,
			accelerationMultiplier = 0.8,
			brakingMultiplier = 0.95,
			fuelUseMultiplier = 1.4,
			conditionDriftMultiplier = 0.6,
			damageResistance = 1.7,
			inventoryBonusSlots = 2,
			headlightRangeMultiplier = 1.1,
		},
		defaultLivery = "livery_engineering",
		unlockLevel = 26,
		creditCost = 16500,
		isStarter = false,
	}),
}

--------------------------------------------------------------------------
-- Liveries
--------------------------------------------------------------------------

export type LiveryDef = {
	id: string,
	name: string,
	description: string,
	body: Color3,
	roof: Color3,
	trim: Color3,
	underframe: Color3,
	stripe: Color3?,
	-- Running-light tint. Kept within a readable range so no livery can make a
	-- train harder for other players to see in fog.
	lampColour: Color3,
	-- Optional chevron or hazard pattern drawn on the nose and carriage ends.
	pattern: string?,
	source: "default" | "credits" | "robux" | "event",
	creditCost: number?,
	productKey: string?, -- key into Config.Monetization when source is "robux"
	eventId: string?,
}

local function livery(def: LiveryDef): LiveryDef
	return def
end

local LIVERIES: { [string]: LiveryDef } = {
	livery_depot = livery({
		id = "livery_depot",
		name = "Depot Green",
		description = "Standard regional livery. Faded, chipped, and entirely unremarkable.",
		body = C(62, 76, 66),
		roof = C(48, 52, 50),
		trim = C(196, 152, 58),
		underframe = C(38, 38, 36),
		stripe = C(214, 206, 180),
		lampColour = C(255, 240, 208),
		source = "default",
	}),
	livery_freight = livery({
		id = "livery_freight",
		name = "Freight Brown",
		description = "Bauxite brown with black underframe. Built for work, never for photographs.",
		body = C(88, 58, 44),
		roof = C(54, 46, 42),
		trim = C(168, 150, 120),
		underframe = C(34, 32, 30),
		lampColour = C(255, 236, 200),
		source = "default",
	}),
	livery_express = livery({
		id = "livery_express",
		name = "Express Blue",
		description = "Pre-collapse intercity blue with a grey band.",
		body = C(44, 62, 92),
		roof = C(58, 62, 68),
		trim = C(206, 206, 210),
		underframe = C(36, 38, 42),
		stripe = C(230, 232, 236),
		lampColour = C(244, 246, 255),
		source = "default",
	}),
	livery_engineering = livery({
		id = "livery_engineering",
		name = "Engineering Yellow",
		description = "Permanent-way yellow. Designed to be seen, which is not always what you want.",
		body = C(178, 148, 52),
		roof = C(56, 54, 50),
		trim = C(40, 40, 40),
		underframe = C(34, 34, 32),
		pattern = "chevron",
		lampColour = C(255, 236, 190),
		source = "default",
	}),

	-- Earned with credits
	livery_ashline = livery({
		id = "livery_ashline",
		name = "Ash Line",
		description = "Soot grey over matte black. Earned, not bought.",
		body = C(64, 66, 70),
		roof = C(42, 44, 48),
		trim = C(140, 142, 146),
		underframe = C(30, 30, 32),
		lampColour = C(248, 244, 232),
		source = "credits",
		creditCost = 3200,
	}),
	livery_pinewatch = livery({
		id = "livery_pinewatch",
		name = "Pinewatch",
		description = "Deep forest green with copper trim, from the old forestry board stock.",
		body = C(40, 58, 46),
		roof = C(44, 48, 44),
		trim = C(158, 106, 62),
		underframe = C(32, 34, 32),
		stripe = C(186, 168, 128),
		lampColour = C(255, 238, 204),
		source = "credits",
		creditCost = 4800,
	}),

	-- Robux liveries. productKey must match Config.Monetization, and the shop
	-- will not offer any of these while that product has no configured ID.
	livery_ember = livery({
		id = "livery_ember",
		name = "Ember Line",
		description = "Oxblood panels and brass trim, with warm running lights that carry through fog.",
		body = C(108, 42, 40),
		roof = C(52, 40, 38),
		trim = C(198, 156, 78),
		underframe = C(36, 30, 28),
		stripe = C(226, 186, 126),
		lampColour = C(255, 216, 160),
		source = "robux",
		productKey = "livery_ember",
	}),
	livery_permafrost = livery({
		id = "livery_permafrost",
		name = "Permafrost",
		description = "Frost-bitten white over grey steel, with ice-blue signal lamps.",
		body = C(206, 210, 214),
		roof = C(150, 156, 162),
		trim = C(92, 116, 134),
		underframe = C(58, 62, 66),
		stripe = C(120, 148, 170),
		lampColour = C(212, 232, 255),
		source = "robux",
		productKey = "livery_permafrost",
	}),
	livery_nightpost = livery({
		id = "livery_nightpost",
		name = "Night Post",
		description = "Matte black with reflective hazard chevrons that catch your own headlights as you walk the length of the train.",
		body = C(30, 31, 34),
		roof = C(24, 25, 27),
		trim = C(196, 176, 72),
		underframe = C(22, 22, 24),
		pattern = "chevron",
		lampColour = C(255, 228, 176),
		source = "robux",
		productKey = "livery_nightpost",
	}),

	-- Event-limited
	livery_lostconductor = livery({
		id = "livery_lostconductor",
		name = "Sleeper Maroon",
		description = "The maroon of a night sleeper service that stopped running long before the collapse. Awarded during the Lost Conductor.",
		body = C(92, 40, 46),
		roof = C(48, 40, 42),
		trim = C(186, 162, 116),
		underframe = C(34, 30, 30),
		stripe = C(212, 196, 158),
		lampColour = C(255, 226, 186),
		source = "event",
		eventId = "lost_conductor",
	}),
}

--------------------------------------------------------------------------
-- Interior kits
--------------------------------------------------------------------------

export type InteriorDef = {
	id: string,
	name: string,
	description: string,
	wall: Color3,
	floor: Color3,
	seat: Color3,
	seatMaterial: Enum.Material,
	trim: Color3,
	lampColour: Color3,
	lampBrightness: number,
	source: "default" | "credits" | "robux" | "event",
	creditCost: number?,
	productKey: string?,
	eventId: string?,
}

local INTERIORS: { [string]: InteriorDef } = {
	interior_standard = {
		id = "interior_standard",
		name = "Standard Stock",
		description = "Green vinyl, cream panelling, and a light that buzzes.",
		wall = C(196, 188, 166),
		floor = C(64, 62, 58),
		seat = C(58, 78, 62),
		seatMaterial = Enum.Material.Fabric,
		trim = C(92, 70, 48),
		lampColour = C(255, 232, 186),
		lampBrightness = 1.1,
		source = "default",
	},
	interior_utility = {
		id = "interior_utility",
		name = "Utility Fit",
		description = "Bare steel, rubber matting and cage lamps. Practical and cold.",
		wall = C(108, 112, 116),
		floor = C(48, 48, 50),
		seat = C(72, 74, 78),
		seatMaterial = Enum.Material.Metal,
		trim = C(140, 142, 146),
		lampColour = C(226, 238, 255),
		lampBrightness = 1.3,
		source = "credits",
		creditCost = 2200,
	},
	interior_brass = {
		id = "interior_brass",
		name = "Brass & Walnut",
		description = "Pre-war first class. Walnut veneer, brass fittings and warm shaded lamps.",
		wall = C(102, 72, 48),
		floor = C(58, 42, 32),
		seat = C(96, 46, 44),
		seatMaterial = Enum.Material.Fabric,
		trim = C(186, 148, 76),
		lampColour = C(255, 214, 150),
		lampBrightness = 0.95,
		source = "robux",
		productKey = "workshop_access",
	},
	interior_surveyor = {
		id = "interior_surveyor",
		name = "Surveyor's Office",
		description = "Map tables, drafting lamps and pinned line diagrams.",
		wall = C(150, 146, 128),
		floor = C(72, 64, 54),
		seat = C(86, 74, 56),
		seatMaterial = Enum.Material.Fabric,
		trim = C(118, 104, 78),
		lampColour = C(255, 240, 206),
		lampBrightness = 1.15,
		source = "robux",
		productKey = "workshop_access",
	},
	interior_ashwood = {
		id = "interior_ashwood",
		name = "Ashwood",
		description = "Pale ash panelling and dark leather. Quiet, and slightly too clean for this line.",
		wall = C(186, 174, 152),
		floor = C(66, 58, 50),
		seat = C(48, 42, 40),
		seatMaterial = Enum.Material.Fabric,
		trim = C(148, 132, 108),
		lampColour = C(255, 236, 202),
		lampBrightness = 1.05,
		source = "robux",
		productKey = "workshop_access",
	},
} :: { [string]: InteriorDef }

--------------------------------------------------------------------------

local TrainRegistry = {}

TrainRegistry.Trains = TableUtil.deepFreeze(TRAINS) :: { [string]: TrainDef }
TrainRegistry.Liveries = TableUtil.deepFreeze(LIVERIES) :: { [string]: LiveryDef }
TrainRegistry.Interiors = TableUtil.deepFreeze(INTERIORS) :: { [string]: InteriorDef }

TrainRegistry.StarterTrainId = "warden"

function TrainRegistry.get(id: string): TrainDef?
	return TRAINS[id]
end

function TrainRegistry.getOrStarter(id: string?): TrainDef
	local def = if id then TRAINS[id] else nil
	return def or (TRAINS[TrainRegistry.StarterTrainId] :: TrainDef)
end

function TrainRegistry.getLivery(id: string?): LiveryDef
	local def = if id then LIVERIES[id] else nil
	return def or (LIVERIES.livery_depot :: LiveryDef)
end

function TrainRegistry.getInterior(id: string?): InteriorDef
	local def = if id then INTERIORS[id] else nil
	return def or (INTERIORS.interior_standard :: InteriorDef)
end

function TrainRegistry.allTrains(): { TrainDef }
	local out: { TrainDef } = {}
	for _, def in TRAINS do
		table.insert(out, def)
	end
	table.sort(out, function(a, b)
		return a.unlockLevel < b.unlockLevel
	end)
	return out
end

function TrainRegistry.allLiveries(): { LiveryDef }
	local out: { LiveryDef } = {}
	for _, def in LIVERIES do
		table.insert(out, def)
	end
	table.sort(out, function(a, b)
		return a.id < b.id
	end)
	return out
end

function TrainRegistry.allInteriors(): { InteriorDef }
	local out: { InteriorDef } = {}
	for _, def in INTERIORS do
		table.insert(out, def)
	end
	table.sort(out, function(a, b)
		return a.id < b.id
	end)
	return out
end

--- Total length of a consist, used to lay out the yard and the platforms so a
--- train always fits the space built for it.
function TrainRegistry.consistLength(def: TrainDef): number
	local total = def.build.locoLength
	for _, carriage in def.build.carriages do
		total += carriage.length + 4 -- coupler gap
	end
	return total
end

return TrainRegistry
