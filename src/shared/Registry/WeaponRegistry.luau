--!strict
--[[
	WeaponRegistry
	--------------
	Melee and firearm definitions.

	Combat in LAST SIGNAL is a pressure valve, not the main verb. Weapons exist
	so that a bad situation can be survived, not so that the forest can be
	cleared. That shows up in the numbers:

	  - Nothing here kills the Signal-Eater. Damage fills its drive-off meter.
	  - Ammunition is scarce and every firearm is loud, which raises threat.
	  - Reload times are mechanism-accurate and long enough to be a commitment.
	  - Melee costs stamina, so it competes with running away.

	Every field marked "server" is validated server-side on each shot. The
	client never decides whether a hit landed, only where it aimed.
]]

local TableUtil = require(script.Parent.Parent.Core.TableUtil)

export type WeaponKind = "melee" | "firearm"
export type ReloadStyle = "cylinder" | "shell" | "clip" | "single" | "none"

export type WeaponDef = {
	id: string,
	name: string,
	kind: WeaponKind,
	description: string,

	damage: number, -- server authoritative
	range: number, -- server authoritative, studs
	-- Seconds between shots or swings. Server enforces with a small grace.
	fireInterval: number,

	-- Firearm only -------------------------------------------------------
	ammoType: string?,
	magazineSize: number?,
	reloadStyle: ReloadStyle,
	reloadSeconds: number?, -- whole-magazine styles
	reloadPerRoundSeconds: number?, -- shell-at-a-time styles
	pellets: number?, -- shotgun spread
	spreadDegrees: number?,
	recoilVertical: number?,
	recoilHorizontal: number?,
	aimSpreadMultiplier: number?,
	noiseRadius: number,

	-- Melee only ---------------------------------------------------------
	swingArcDegrees: number?,
	staminaCost: number?,
	-- Melee can hit more than one target in the arc; firearms cannot.
	maxTargets: number?,

	-- Handling -------------------------------------------------------------
	weight: number,
	moveSpeedMultiplier: number,
	equipSeconds: number,

	-- Presentation ---------------------------------------------------------
	model: { [string]: any },
	fireCue: string,
	dryCue: string?,
	reloadCue: string?,
	impactCue: string,
	-- Viewmodel motion, consumed by the first-person weapon controller.
	viewmodel: {
		restOffset: Vector3,
		aimOffset: Vector3,
		swayScale: number,
		bobScale: number,
		recoilKick: Vector3,
		recoilRecovery: number,
	},

	-- Availability ---------------------------------------------------------
	startingLoadout: boolean, -- selectable in the lobby loadout screen
	unlockLevel: number,
	creditCost: number,
}

local C = Color3.fromRGB

local function weapon(def: WeaponDef): WeaponDef
	return def
end

local WEAPONS: { [string]: WeaponDef } = {

	--------------------------------------------------------------------
	-- Melee
	--------------------------------------------------------------------
	wrench = weapon({
		id = "wrench",
		name = "Pipe Wrench",
		kind = "melee",
		description = "Depot issue. Slow, heavy, and it lands hard enough to buy you the two seconds you need.",
		damage = 34,
		range = 8.5,
		fireInterval = 0.95,
		reloadStyle = "none",
		noiseRadius = 55,
		swingArcDegrees = 70,
		staminaCost = 9,
		maxTargets = 1,
		weight = 3.0,
		moveSpeedMultiplier = 0.96,
		equipSeconds = 0.45,
		model = {
			shape = "wrench",
			length = 2.4,
			colour = C(96, 100, 106),
			gripColour = C(52, 44, 38),
			material = Enum.Material.Metal,
		},
		fireCue = "melee_swing",
		impactCue = "melee_hit_flesh",
		viewmodel = {
			restOffset = Vector3.new(0.85, -0.75, -1.15),
			aimOffset = Vector3.new(0.55, -0.55, -0.9),
			swayScale = 1.0,
			bobScale = 1.0,
			recoilKick = Vector3.new(-0.12, 0.05, -0.3),
			recoilRecovery = 10,
		},
		startingLoadout = true,
		unlockLevel = 0,
		creditCost = 0,
	}),
	crowbar = weapon({
		id = "crowbar",
		name = "Crowbar",
		kind = "melee",
		description = "Faster than the wrench and it opens seized doors. Less damage, more uses.",
		damage = 26,
		range = 9.0,
		fireInterval = 0.7,
		reloadStyle = "none",
		noiseRadius = 50,
		swingArcDegrees = 60,
		staminaCost = 7,
		maxTargets = 1,
		weight = 2.6,
		moveSpeedMultiplier = 0.98,
		equipSeconds = 0.35,
		model = {
			shape = "crowbar",
			length = 2.6,
			colour = C(120, 74, 56),
			gripColour = C(60, 40, 32),
			material = Enum.Material.Metal,
		},
		fireCue = "melee_swing",
		impactCue = "melee_hit_flesh",
		viewmodel = {
			restOffset = Vector3.new(0.8, -0.72, -1.1),
			aimOffset = Vector3.new(0.5, -0.52, -0.85),
			swayScale = 0.95,
			bobScale = 0.95,
			recoilKick = Vector3.new(-0.1, 0.04, -0.25),
			recoilRecovery = 12,
		},
		startingLoadout = true,
		unlockLevel = 0,
		creditCost = 0,
	}),
	axe = weapon({
		id = "axe",
		name = "Felling Axe",
		kind = "melee",
		description = "From the logging camp. Enormous damage, enormous commitment; miss and you are still swinging when it reaches you.",
		damage = 58,
		range = 9.5,
		fireInterval = 1.5,
		reloadStyle = "none",
		noiseRadius = 65,
		swingArcDegrees = 85,
		staminaCost = 16,
		maxTargets = 2,
		weight = 4.6,
		moveSpeedMultiplier = 0.9,
		equipSeconds = 0.7,
		model = {
			shape = "axe",
			length = 3.0,
			colour = C(128, 104, 72),
			headColour = C(112, 116, 120),
			material = Enum.Material.Wood,
		},
		fireCue = "melee_swing",
		impactCue = "melee_hit_flesh",
		viewmodel = {
			restOffset = Vector3.new(0.9, -0.8, -1.25),
			aimOffset = Vector3.new(0.6, -0.6, -1.0),
			swayScale = 1.25,
			bobScale = 1.2,
			recoilKick = Vector3.new(-0.22, 0.08, -0.45),
			recoilRecovery = 8,
		},
		startingLoadout = false,
		unlockLevel = 4,
		creditCost = 900,
	}),

	--------------------------------------------------------------------
	-- Firearms
	--------------------------------------------------------------------
	revolver = weapon({
		id = "revolver",
		name = "Service Revolver",
		kind = "firearm",
		description = "Six rounds of .38. Reliable, accurate, and the reload is a genuine six seconds of standing still.",
		damage = 30,
		range = 220,
		fireInterval = 0.55,
		ammoType = "pistol",
		magazineSize = 6,
		reloadStyle = "cylinder",
		reloadSeconds = 3.4,
		spreadDegrees = 1.6,
		recoilVertical = 1.8,
		recoilHorizontal = 0.55,
		aimSpreadMultiplier = 0.35,
		noiseRadius = 620,
		weight = 1.2,
		moveSpeedMultiplier = 1.0,
		equipSeconds = 0.4,
		model = {
			shape = "revolver",
			length = 1.1,
			colour = C(58, 60, 64),
			gripColour = C(74, 52, 38),
			material = Enum.Material.Metal,
		},
		fireCue = "gun_revolver",
		dryCue = "gun_dry",
		reloadCue = "reload_revolver",
		impactCue = "bullet_impact",
		viewmodel = {
			restOffset = Vector3.new(0.55, -0.6, -1.0),
			aimOffset = Vector3.new(0, -0.32, -0.7),
			swayScale = 0.7,
			bobScale = 0.75,
			recoilKick = Vector3.new(-0.35, 0.12, -0.22),
			recoilRecovery = 14,
		},
		startingLoadout = true,
		unlockLevel = 0,
		creditCost = 0,
	}),
	shotgun = weapon({
		id = "shotgun",
		name = "Break Shotgun",
		kind = "firearm",
		description = "Two barrels, loaded one shell at a time. Devastating inside a carriage, useless past thirty metres, and audible from the next station.",
		damage = 17, -- per pellet
		range = 95,
		fireInterval = 0.8,
		ammoType = "shell",
		magazineSize = 2,
		reloadStyle = "shell",
		reloadPerRoundSeconds = 1.05,
		pellets = 7,
		spreadDegrees = 7.5,
		recoilVertical = 4.2,
		recoilHorizontal = 1.1,
		aimSpreadMultiplier = 0.7,
		noiseRadius = 720,
		weight = 3.4,
		moveSpeedMultiplier = 0.94,
		equipSeconds = 0.6,
		model = {
			shape = "shotgun",
			length = 2.7,
			colour = C(62, 64, 68),
			gripColour = C(88, 62, 42),
			material = Enum.Material.Metal,
		},
		fireCue = "gun_shotgun",
		dryCue = "gun_dry",
		reloadCue = "reload_shotgun_shell",
		impactCue = "bullet_impact",
		viewmodel = {
			restOffset = Vector3.new(0.7, -0.68, -1.2),
			aimOffset = Vector3.new(0, -0.36, -0.85),
			swayScale = 1.1,
			bobScale = 1.05,
			recoilKick = Vector3.new(-0.8, 0.25, -0.5),
			recoilRecovery = 9,
		},
		startingLoadout = false,
		unlockLevel = 8,
		creditCost = 2400,
	}),
	rifle = weapon({
		id = "rifle",
		name = "Surveyor's Rifle",
		kind = "firearm",
		description = "Bolt action, five rounds. It reaches across a clearing, and you will work the bolt between every shot.",
		damage = 62,
		range = 600,
		fireInterval = 1.35, -- includes working the bolt
		ammoType = "rifle",
		magazineSize = 5,
		reloadStyle = "clip",
		reloadSeconds = 4.2,
		spreadDegrees = 0.6,
		recoilVertical = 3.4,
		recoilHorizontal = 0.4,
		aimSpreadMultiplier = 0.12,
		noiseRadius = 820,
		weight = 4.0,
		moveSpeedMultiplier = 0.92,
		equipSeconds = 0.75,
		model = {
			shape = "rifle",
			length = 3.3,
			colour = C(70, 60, 50),
			gripColour = C(96, 68, 44),
			material = Enum.Material.Wood,
		},
		fireCue = "gun_rifle",
		dryCue = "gun_dry",
		reloadCue = "reload_bolt",
		impactCue = "bullet_impact",
		viewmodel = {
			restOffset = Vector3.new(0.65, -0.66, -1.3),
			aimOffset = Vector3.new(0, -0.3, -0.95),
			swayScale = 1.2,
			bobScale = 1.1,
			recoilKick = Vector3.new(-0.65, 0.18, -0.6),
			recoilRecovery = 10,
		},
		startingLoadout = false,
		unlockLevel = 16,
		creditCost = 4200,
	}),
	flare_gun = weapon({
		id = "flare_gun",
		name = "Flare Pistol",
		kind = "firearm",
		description = "Not really a weapon. Puts burning light exactly where you need it, at range, and the Signal-Eater will not walk through it.",
		damage = 8,
		range = 160,
		fireInterval = 1.6,
		ammoType = "flare",
		magazineSize = 1,
		reloadStyle = "single",
		reloadSeconds = 1.9,
		spreadDegrees = 2.5,
		recoilVertical = 2.0,
		recoilHorizontal = 0.6,
		aimSpreadMultiplier = 0.5,
		noiseRadius = 260,
		weight = 1.0,
		moveSpeedMultiplier = 1.0,
		equipSeconds = 0.4,
		model = {
			shape = "flaregun",
			length = 1.2,
			colour = C(150, 68, 52),
			gripColour = C(52, 44, 40),
			material = Enum.Material.SmoothPlastic,
		},
		fireCue = "gun_flare",
		dryCue = "gun_dry",
		reloadCue = "reload_revolver",
		impactCue = "bullet_impact",
		viewmodel = {
			restOffset = Vector3.new(0.55, -0.6, -1.0),
			aimOffset = Vector3.new(0, -0.32, -0.7),
			swayScale = 0.75,
			bobScale = 0.8,
			recoilKick = Vector3.new(-0.4, 0.1, -0.2),
			recoilRecovery = 12,
		},
		startingLoadout = true,
		unlockLevel = 2,
		creditCost = 650,
	}),
}

--------------------------------------------------------------------------

local WeaponRegistry = {}

WeaponRegistry.Weapons = TableUtil.deepFreeze(WEAPONS) :: { [string]: WeaponDef }

function WeaponRegistry.get(id: string): WeaponDef?
	return WEAPONS[id]
end

function WeaponRegistry.exists(id: string): boolean
	return WEAPONS[id] ~= nil
end

function WeaponRegistry.all(): { WeaponDef }
	local out: { WeaponDef } = {}
	for _, def in WEAPONS do
		table.insert(out, def)
	end
	table.sort(out, function(a, b)
		if a.kind ~= b.kind then
			return a.kind < b.kind
		end
		return a.unlockLevel < b.unlockLevel
	end)
	return out
end

--- Weapons a player of this level may select in the lobby loadout screen.
function WeaponRegistry.selectableAt(level: number, owned: { [string]: boolean }?): { WeaponDef }
	local out: { WeaponDef } = {}
	for _, def in WEAPONS do
		local unlocked = def.startingLoadout or (owned and owned[def.id]) or false
		if unlocked and level >= def.unlockLevel then
			table.insert(out, def)
		end
	end
	table.sort(out, function(a, b)
		return a.id < b.id
	end)
	return out
end

--- Total time a full reload takes, accounting for per-shell styles. Used by
--- both the client animation and the server's reload-state validation, so the
--- two can never disagree about when a reload finishes.
function WeaponRegistry.reloadDuration(def: WeaponDef, roundsMissing: number): number
	if def.reloadStyle == "shell" then
		local per = def.reloadPerRoundSeconds or 1.0
		return per * math.max(1, roundsMissing)
	end
	return def.reloadSeconds or 2.0
end

return WeaponRegistry
