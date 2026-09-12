--!strict
--[[
	Audio
	-----
	The sound design of LAST SIGNAL expressed as named cues, mixer buses and
	playback behaviour. Every system asks for a cue by name; none of them ever
	touch an asset ID.

	WHY THE IDS ARE EMPTY
	--------------------
	Roblox sounds are asset IDs on Roblox's servers. This project cannot create,
	upload or verify audio assets, and shipping guessed numeric IDs is worse than
	shipping none: a wrong ID is either silence, an error, or somebody else's
	audio playing in your game without permission.

	So every cue below has `id = 0`, and AudioService treats zero as "cue not
	configured": it plays nothing, logs once, and the game continues normally.
	Nothing crashes, nothing waits, and no cue is faked.

	FILLING THEM IN
	---------------
	docs/AUDIO.md lists every cue with the search terms to use in the Studio
	Toolbox audio browser and the licence rules that apply. Roblox-created audio
	is free to use in your own experiences; third-party audio is not, unless its
	licence says so. Paste the ID into the `id` field for the cue.

	The mixer, ducking, occlusion, distance behaviour, speed-reactive layering
	and subtitles below are all implemented and working. They are what makes the
	soundscape coherent once the cues are populated.
]]

local Audio = {}

--------------------------------------------------------------------------
-- Mixer buses
--------------------------------------------------------------------------

-- Player-facing volume sliders map onto these buses. A cue names its bus and
-- AudioService applies the bus gain, the master gain and any active ducking.
export type BusId = "master" | "music" | "ambience" | "sfx" | "train" | "voice" | "ui" | "creature"

Audio.Buses = {
	master = { name = "Master", default = 0.85 },
	music = { name = "Music", default = 0.6 },
	ambience = { name = "Ambience", default = 0.8 },
	sfx = { name = "Effects", default = 0.9 },
	train = { name = "Train", default = 0.85 },
	voice = { name = "Radio & Voice", default = 1.0 },
	ui = { name = "Interface", default = 0.7 },
	creature = { name = "Threat", default = 1.0 },
}

-- When a bus in `trigger` is playing, buses in `duck` drop by `amount` over
-- `attack` seconds and recover over `release`. Radio lines must always be
-- intelligible; that is the entire reason this exists.
Audio.Ducking = {
	{ trigger = "voice", duck = { "music", "ambience", "train" }, amount = 0.45, attack = 0.12, release = 0.8 },
	{ trigger = "creature", duck = { "music" }, amount = 0.7, attack = 0.05, release = 1.6 },
}

--------------------------------------------------------------------------
-- Cue definitions
--------------------------------------------------------------------------

export type CueDef = {
	id: number,
	bus: BusId,
	volume: number,
	pitch: number?,
	looped: boolean?,
	rollOffMin: number?,
	rollOffMax: number?,
	-- Random pitch spread applied per play, so repeated cues do not machine-gun.
	pitchVariance: number?,
	-- Subtitle text shown when accessibility subtitles are enabled. Cues that
	-- carry gameplay information must have one; that is the accessibility
	-- requirement for "alternatives for essential audio cues".
	subtitle: string?,
	-- Marks a cue as gameplay-critical. AudioService additionally surfaces these
	-- as a directional on-screen indicator when the player enables it.
	directionalHint: boolean?,
	description: string,
}

local function cue(def: CueDef): CueDef
	return def
end

Audio.Cues = {
	--------------------------------------------------------------------
	-- Train: locomotive and rolling stock
	--------------------------------------------------------------------
	train_engine_idle = cue({
		id = 0,
		bus = "train",
		volume = 0.55,
		looped = true,
		rollOffMin = 12,
		rollOffMax = 320,
		description = "Diesel idle loop at the engine bay. Pitch and volume track throttle notch.",
	}),
	train_engine_load = cue({
		id = 0,
		bus = "train",
		volume = 0.7,
		looped = true,
		rollOffMin = 12,
		rollOffMax = 420,
		description = "Engine under load. Crossfaded over idle proportionally to notch.",
	}),
	train_wheels_roll = cue({
		id = 0,
		bus = "train",
		volume = 0.6,
		looped = true,
		rollOffMin = 8,
		rollOffMax = 260,
		description = "Rail roll loop under each bogie. Playback speed tracks train speed.",
	}),
	train_rail_joint = cue({
		id = 0,
		bus = "train",
		volume = 0.5,
		pitchVariance = 0.08,
		rollOffMin = 8,
		rollOffMax = 200,
		description = "Single rail joint clack. Scheduled by distance travelled, not by timer.",
	}),
	train_brake_apply = cue({
		id = 0,
		bus = "train",
		volume = 0.75,
		looped = true,
		rollOffMin = 10,
		rollOffMax = 300,
		description = "Brake squeal loop while the service brake is applied above walking speed.",
	}),
	train_brake_emergency = cue({
		id = 0,
		bus = "train",
		volume = 1.0,
		rollOffMin = 15,
		rollOffMax = 700,
		subtitle = "[Emergency brakes screaming]",
		description = "Emergency brake. Loud, ugly, and heard from a long way off.",
	}),
	train_horn = cue({
		id = 0,
		bus = "train",
		volume = 1.0,
		rollOffMin = 30,
		rollOffMax = 1400,
		subtitle = "[Train horn]",
		description = "Air horn. Also the creature repel tool, so it must read at distance.",
	}),
	train_door = cue({
		id = 0,
		bus = "train",
		volume = 0.6,
		pitchVariance = 0.05,
		rollOffMin = 5,
		rollOffMax = 60,
		description = "Pneumatic carriage door cycle.",
	}),
	train_coupler = cue({
		id = 0,
		bus = "train",
		volume = 0.8,
		rollOffMin = 10,
		rollOffMax = 220,
		description = "Coupler slack taking up. Plays once when the train starts moving.",
	}),
	train_wiper = cue({
		id = 0,
		bus = "train",
		volume = 0.35,
		rollOffMin = 3,
		rollOffMax = 25,
		description = "Windscreen wiper sweep, cab interior only.",
	}),
	train_stall = cue({
		id = 0,
		bus = "train",
		volume = 0.9,
		subtitle = "[The engine dies]",
		description = "Engine stall when fuel runs dry or condition fails.",
	}),
	train_start = cue({
		id = 0,
		bus = "train",
		volume = 0.85,
		description = "Engine crank and catch.",
	}),

	--------------------------------------------------------------------
	-- Weather and forest ambience
	--------------------------------------------------------------------
	rain_light = cue({ id = 0, bus = "ambience", volume = 0.5, looped = true, description = "Light rain bed, exterior." }),
	rain_heavy = cue({ id = 0, bus = "ambience", volume = 0.75, looped = true, description = "Heavy rain bed, exterior." }),
	rain_on_roof = cue({ id = 0, bus = "ambience", volume = 0.6, looped = true, description = "Rain on the carriage roof, interior only." }),
	wind_forest = cue({ id = 0, bus = "ambience", volume = 0.45, looped = true, description = "Wind through conifers." }),
	forest_night = cue({ id = 0, bus = "ambience", volume = 0.4, looped = true, description = "Distant night forest bed. Goes quiet when threat is high." }),
	thunder_distant = cue({ id = 0, bus = "ambience", volume = 0.7, subtitle = "[Distant thunder]", description = "Occasional distant thunder." }),
	station_hum = cue({ id = 0, bus = "ambience", volume = 0.35, looped = true, description = "Failing fluorescent hum at powered stations." }),
	tunnel_tone = cue({ id = 0, bus = "ambience", volume = 0.5, looped = true, description = "Low enclosed tone inside the service tunnel." }),

	--------------------------------------------------------------------
	-- Player
	--------------------------------------------------------------------
	footstep_metal = cue({ id = 0, bus = "sfx", volume = 0.4, pitchVariance = 0.1, description = "Footstep on carriage decking." }),
	footstep_gravel = cue({ id = 0, bus = "sfx", volume = 0.4, pitchVariance = 0.1, description = "Footstep on ballast." }),
	footstep_wood = cue({ id = 0, bus = "sfx", volume = 0.35, pitchVariance = 0.1, description = "Footstep on sleepers and boardwalk." }),
	footstep_soil = cue({ id = 0, bus = "sfx", volume = 0.3, pitchVariance = 0.1, description = "Footstep on forest floor." }),
	footstep_concrete = cue({ id = 0, bus = "sfx", volume = 0.4, pitchVariance = 0.1, description = "Footstep on platform concrete." }),
	breath_tired = cue({ id = 0, bus = "sfx", volume = 0.5, looped = true, description = "Exhausted breathing when stamina bottoms out." }),
	heartbeat = cue({ id = 0, bus = "sfx", volume = 0.6, looped = true, description = "Heartbeat under low health and during a chase." }),
	hurt = cue({ id = 0, bus = "sfx", volume = 0.7, pitchVariance = 0.08, description = "Player takes damage." }),
	downed = cue({ id = 0, bus = "sfx", volume = 0.8, subtitle = "[A crew member goes down]", directionalHint = true, description = "A crew member is downed." }),
	revive = cue({ id = 0, bus = "sfx", volume = 0.7, description = "Revive completes." }),
	flashlight_click = cue({ id = 0, bus = "sfx", volume = 0.5, description = "Flashlight toggle." }),
	flashlight_die = cue({ id = 0, bus = "sfx", volume = 0.5, description = "Flashlight battery gives out." }),

	--------------------------------------------------------------------
	-- Items, tools and machinery
	--------------------------------------------------------------------
	item_pickup = cue({ id = 0, bus = "sfx", volume = 0.5, description = "Generic pickup." }),
	item_drop = cue({ id = 0, bus = "sfx", volume = 0.45, description = "Generic drop." }),
	item_fuel_pour = cue({ id = 0, bus = "sfx", volume = 0.6, description = "Refuelling the locomotive." }),
	item_bandage = cue({ id = 0, bus = "sfx", volume = 0.5, description = "Applying a bandage." }),
	item_battery = cue({ id = 0, bus = "sfx", volume = 0.5, description = "Loading a battery." }),
	repair_wrench = cue({ id = 0, bus = "sfx", volume = 0.55, pitchVariance = 0.1, description = "Repair progress tick." }),
	generator_start = cue({ id = 0, bus = "sfx", volume = 0.8, subtitle = "[Generator coughs into life]", description = "Generator start." }),
	generator_run = cue({ id = 0, bus = "sfx", volume = 0.55, looped = true, description = "Generator running loop." }),
	breaker_throw = cue({ id = 0, bus = "sfx", volume = 0.7, description = "Heavy electrical breaker." }),
	lever_switch = cue({ id = 0, bus = "sfx", volume = 0.6, description = "Track switch lever." }),
	door_wood_open = cue({ id = 0, bus = "sfx", volume = 0.5, pitchVariance = 0.06, description = "Building door opening." }),
	door_metal_open = cue({ id = 0, bus = "sfx", volume = 0.55, pitchVariance = 0.06, description = "Metal door opening." }),
	locker_open = cue({ id = 0, bus = "sfx", volume = 0.45, description = "Searching a locker or crate." }),

	--------------------------------------------------------------------
	-- Weapons
	--------------------------------------------------------------------
	melee_swing = cue({ id = 0, bus = "sfx", volume = 0.55, pitchVariance = 0.12, description = "Melee swing through air." }),
	melee_hit_flesh = cue({ id = 0, bus = "sfx", volume = 0.7, pitchVariance = 0.1, description = "Melee connecting with a creature." }),
	melee_hit_hard = cue({ id = 0, bus = "sfx", volume = 0.65, pitchVariance = 0.1, description = "Melee connecting with metal or wood." }),
	gun_revolver = cue({ id = 0, bus = "sfx", volume = 1.0, rollOffMax = 900, subtitle = "[Gunshot]", description = "Revolver discharge." }),
	gun_shotgun = cue({ id = 0, bus = "sfx", volume = 1.0, rollOffMax = 1100, subtitle = "[Shotgun blast]", description = "Shotgun discharge." }),
	gun_rifle = cue({ id = 0, bus = "sfx", volume = 1.0, rollOffMax = 1200, subtitle = "[Rifle shot]", description = "Bolt rifle discharge." }),
	gun_flare = cue({ id = 0, bus = "sfx", volume = 0.8, description = "Flare gun launch." }),
	gun_dry = cue({ id = 0, bus = "sfx", volume = 0.5, description = "Dry fire on an empty chamber." }),
	reload_revolver = cue({ id = 0, bus = "sfx", volume = 0.6, description = "Swing-out cylinder, eject, load, close." }),
	reload_shotgun_shell = cue({ id = 0, bus = "sfx", volume = 0.6, pitchVariance = 0.05, description = "Single shell into the tube, one per shell." }),
	reload_bolt = cue({ id = 0, bus = "sfx", volume = 0.6, description = "Bolt cycle." }),
	bullet_impact = cue({ id = 0, bus = "sfx", volume = 0.6, pitchVariance = 0.15, description = "Bullet impact at the hit point." }),

	--------------------------------------------------------------------
	-- Radio and voice
	--------------------------------------------------------------------
	radio_static = cue({ id = 0, bus = "voice", volume = 0.4, looped = true, description = "Carrier static under every radio line." }),
	radio_open = cue({ id = 0, bus = "voice", volume = 0.6, description = "Squelch opening before a transmission." }),
	radio_close = cue({ id = 0, bus = "voice", volume = 0.5, description = "Squelch closing after a transmission." }),
	radio_distort = cue({ id = 0, bus = "voice", volume = 0.7, subtitle = "[The signal warps]", description = "Distortion sting used when a transmission is not the dispatcher." }),
	radio_tune = cue({ id = 0, bus = "voice", volume = 0.5, description = "Tuning the set between frequencies." }),

	--------------------------------------------------------------------
	-- The Signal-Eater
	--------------------------------------------------------------------
	creature_distant = cue({
		id = 0,
		bus = "creature",
		volume = 0.7,
		rollOffMax = 1200,
		subtitle = "[Something calls, far off]",
		directionalHint = true,
		description = "Distant call. The first warning a crew gets, deliberately vague in direction.",
	}),
	creature_near = cue({
		id = 0,
		bus = "creature",
		volume = 0.85,
		rollOffMax = 380,
		subtitle = "[Something is close]",
		directionalHint = true,
		description = "Close proximity vocalisation.",
	}),
	creature_chase = cue({
		id = 0,
		bus = "creature",
		volume = 1.0,
		looped = true,
		rollOffMax = 500,
		subtitle = "[It is hunting]",
		directionalHint = true,
		description = "Chase loop. Unmistakable, because a chase must never be ambiguous.",
	}),
	creature_attack = cue({ id = 0, bus = "creature", volume = 1.0, subtitle = "[It strikes]", description = "Attack." }),
	creature_repelled = cue({ id = 0, bus = "creature", volume = 0.9, subtitle = "[It recoils and retreats]", description = "Driven off by the horn, a flare or sustained damage." }),
	creature_mimic = cue({
		id = 0,
		bus = "creature",
		volume = 0.6,
		rollOffMax = 300,
		subtitle = "[A familiar sound, not quite right]",
		description = "Mimicry cue. Deliberately routed on the creature bus so a careful player can learn to tell.",
	}),
	footsteps_outside = cue({
		id = 0,
		bus = "creature",
		volume = 0.5,
		rollOffMax = 90,
		subtitle = "[Footsteps on the ballast outside]",
		directionalHint = true,
		description = "Footsteps along the outside of the carriage. Nothing is there when you look.",
	}),

	--------------------------------------------------------------------
	-- Music
	--------------------------------------------------------------------
	music_lobby = cue({ id = 0, bus = "music", volume = 0.45, looped = true, description = "Lobby bed. Warm, tired, safe." }),
	music_departure = cue({ id = 0, bus = "music", volume = 0.6, description = "Departure cue under the cinematic." }),
	music_travel = cue({ id = 0, bus = "music", volume = 0.35, looped = true, description = "Sparse travel bed between stations." }),
	music_tension = cue({ id = 0, bus = "music", volume = 0.5, looped = true, description = "Rising bed while threat sits in the upper bands." }),
	music_climax = cue({ id = 0, bus = "music", volume = 0.7, looped = true, description = "Final sequence." }),
	music_resolution = cue({ id = 0, bus = "music", volume = 0.6, description = "Ending cue." }),

	--------------------------------------------------------------------
	-- Interface
	--------------------------------------------------------------------
	ui_hover = cue({ id = 0, bus = "ui", volume = 0.25, description = "Button hover." }),
	ui_click = cue({ id = 0, bus = "ui", volume = 0.4, description = "Button press." }),
	ui_open = cue({ id = 0, bus = "ui", volume = 0.4, description = "Panel opening." }),
	ui_close = cue({ id = 0, bus = "ui", volume = 0.35, description = "Panel closing." }),
	ui_error = cue({ id = 0, bus = "ui", volume = 0.5, description = "Rejected action." }),
	ui_reward = cue({ id = 0, bus = "ui", volume = 0.6, description = "Reward granted." }),
	ui_objective = cue({ id = 0, bus = "ui", volume = 0.5, subtitle = "[Objective updated]", description = "Objective updated." }),
	ui_countdown = cue({ id = 0, bus = "ui", volume = 0.5, description = "Departure countdown tick." }),
} :: { [string]: CueDef }

--------------------------------------------------------------------------
-- Reporting
--------------------------------------------------------------------------

function Audio.audit(): { configured: number, total: number }
	local configured, total = 0, 0
	for _, def in Audio.Cues do
		total += 1
		if def.id > 0 then
			configured += 1
		end
	end
	return { configured = configured, total = total }
end

--- Cues that carry information a player needs. These are the ones that must
--- have subtitles, and the ones AudioService can render as a directional arrow.
function Audio.informationalCues(): { string }
	local out = {}
	for name, def in Audio.Cues do
		if def.subtitle then
			table.insert(out, name)
		end
	end
	table.sort(out)
	return out
end

return Audio
