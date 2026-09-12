--!strict
--[[
	AudioController
	---------------
	The mixer, the cue player, the ducking, and the subtitles.

	WHAT WORKS WITHOUT ANY ASSET IDS
	--------------------------------
	Everything except the sound itself. The bus structure, the per-bus volume
	sliders, the ducking rules, distance attenuation, enclosure filtering,
	speed-reactive layering, directional indicators and the full subtitle system
	are all implemented and running. A cue with no configured asset ID plays
	nothing, logs once, and still fires its subtitle, so a player with subtitles
	on gets the complete informational experience of the game with no audio
	configured at all.

	That is deliberate: it means filling in the asset IDs later is purely an
	improvement, and never a prerequisite for the game being playable or
	understandable. Config.Audio explains why the IDs ship empty.

	SUBTITLES AND ACCESSIBILITY
	---------------------------
	Every cue that carries information a player needs has a subtitle, and the
	informational ones can additionally render a directional arrow, which is
	the alternative to hearing where a sound came from. Both are settings.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("LastSignal")

local Audio = require(Shared.Config.Audio)
local Logger = require(Shared.Core.Logger)
local Net = require(Shared.Core.Net)
local Spring = require(Shared.Core.Spring)
local Theme = require(script.Parent.Parent.UI.Theme)
local Widgets = require(script.Parent.Parent.UI.Widgets)
local StateController = require(script.Parent.StateController)

local log = Logger.new("AudioController")
local player = Players.LocalPlayer

local AudioController = {}

--------------------------------------------------------------------------
-- Buses
--------------------------------------------------------------------------

local busGroups: { [string]: SoundGroup } = {}
local busGain: { [string]: number } = {}
local busDuck: { [string]: number } = {}
local busActive: { [string]: number } = {} -- how many cues are playing on each

local warnedCues: { [string]: boolean } = {}

local function buildBuses()
	for id, info in Audio.Buses do
		local group = Instance.new("SoundGroup")
		group.Name = "Bus_" .. id
		group.Volume = info.default
		group.Parent = SoundService
		busGroups[id] = group
		busGain[id] = info.default
		busDuck[id] = 1
		busActive[id] = 0
	end
end

--- Applies gain and any active ducking to every bus.
local function refreshBuses()
	local master = busGain.master or 1
	for id, group in busGroups do
		local gain = busGain[id] or 1
		local duck = busDuck[id] or 1
		group.Volume = if id == "master" then master else master * gain * duck
	end
end

function AudioController.setBusVolume(bus: string, volume: number)
	busGain[bus] = math.clamp(volume, 0, 1)
	refreshBuses()
end

--- Reads the eight volume settings off the profile.
local function applySettings()
	local map: { [string]: string } = {
		master = "masterVolume",
		music = "musicVolume",
		ambience = "ambienceVolume",
		sfx = "sfxVolume",
		train = "trainVolume",
		voice = "voiceVolume",
		ui = "uiVolume",
		creature = "creatureVolume",
	}
	for bus, settingName in map do
		local value = StateController.setting(settingName, Audio.Buses[bus].default)
		if type(value) == "number" then
			busGain[bus] = math.clamp(value, 0, 1)
		end
	end
	refreshBuses()
end

--------------------------------------------------------------------------
-- Ducking
--------------------------------------------------------------------------

local duckSprings: { [string]: Spring.Spring } = {}

local function stepDucking(deltaTime: number)
	-- Reset targets, then let each rule pull its targets down.
	local targets: { [string]: number } = {}
	for id in busGroups do
		targets[id] = 1
	end

	for _, rule in Audio.Ducking do
		if (busActive[rule.trigger] or 0) > 0 then
			for _, target in rule.duck do
				targets[target] = math.min(targets[target] or 1, 1 - rule.amount)
			end
		end
	end

	for id, target in targets do
		local spring = duckSprings[id]
		if not spring then
			spring = Spring.new(1, 60, 14)
			duckSprings[id] = spring
		end
		spring:setTarget(target)
		busDuck[id] = spring:step(deltaTime)
	end
	refreshBuses()
end

--------------------------------------------------------------------------
-- Cue playback
--------------------------------------------------------------------------

export type PlayOptions = {
	position: Vector3?,
	parent: Instance?,
	volumeScale: number?,
	pitchScale: number?,
	looped: boolean?,
}

local activeLoops: { [string]: Sound } = {}

--- Plays a cue. Returns the Sound when one was created, or nil when the cue
--- is not configured. Callers must tolerate nil, which every caller does.
function AudioController.play(cueName: string, options: PlayOptions?): Sound?
	local def = Audio.Cues[cueName]
	if not def then
		log.warn("unknown cue:", cueName)
		return nil
	end

	-- Subtitles fire whether or not the audio exists, which is the whole point.
	if def.subtitle then
		AudioController.subtitle(def.subtitle, if options then options.position else nil, def.directionalHint == true)
	end

	if def.id <= 0 then
		if not warnedCues[cueName] then
			warnedCues[cueName] = true
			log.debug(string.format("cue '%s' has no asset ID; nothing will play", cueName))
		end
		return nil
	end

	local opts: PlayOptions = options or {}
	local sound = Instance.new("Sound")
	sound.Name = "Cue_" .. cueName
	sound.SoundId = "rbxassetid://" .. tostring(def.id)
	sound.Volume = def.volume * (opts.volumeScale or 1)
	sound.Looped = if opts.looped ~= nil then opts.looped else (def.looped == true)
	sound.SoundGroup = busGroups[def.bus]
	sound.RollOffMode = Enum.RollOffMode.InverseTapered
	sound.RollOffMinDistance = def.rollOffMin or 10
	sound.RollOffMaxDistance = def.rollOffMax or 250

	local pitch = (def.pitch or 1) * (opts.pitchScale or 1)
	if def.pitchVariance then
		-- Per-play pitch variance, so a repeated footstep or impact does not
		-- machine-gun.
		pitch *= 1 + (math.random() - 0.5) * 2 * def.pitchVariance
	end
	if pitch ~= 1 then
		local effect = Instance.new("PitchShiftSoundEffect")
		effect.Octave = pitch
		effect.Parent = sound
	end

	-- Positional cues get an anchored emitter; non-positional ones play on the
	-- listener.
	if opts.position then
		local emitter = Instance.new("Part")
		emitter.Name = "Emitter"
		emitter.Size = Vector3.one
		emitter.Transparency = 1
		emitter.Anchored = true
		emitter.CanCollide = false
		emitter.CanQuery = false
		emitter.CanTouch = false
		emitter.CFrame = CFrame.new(opts.position)
		emitter.Parent = Workspace
		sound.Parent = emitter
		sound.Ended:Once(function()
			emitter:Destroy()
		end)
		if not sound.Looped then
			task.delay(30, function()
				if emitter.Parent then
					emitter:Destroy()
				end
			end)
		end
	else
		sound.Parent = opts.parent or SoundService
	end

	busActive[def.bus] = (busActive[def.bus] or 0) + 1
	sound.Ended:Once(function()
		busActive[def.bus] = math.max(0, (busActive[def.bus] or 1) - 1)
		if not sound.Looped then
			sound:Destroy()
		end
	end)

	sound:Play()
	return sound
end

--- Starts or updates a persistent loop, keyed by name so a second call does
--- not stack a second copy.
function AudioController.loop(key: string, cueName: string, options: PlayOptions?): Sound?
	local existing = activeLoops[key]
	if existing and existing.Parent then
		return existing
	end
	local opts: PlayOptions = options or {}
	opts.looped = true
	local sound = AudioController.play(cueName, opts)
	if sound then
		activeLoops[key] = sound
	end
	return sound
end

function AudioController.stopLoop(key: string, fadeSeconds: number?)
	local sound = activeLoops[key]
	if not sound then
		return
	end
	activeLoops[key] = nil
	if not sound.Parent then
		return
	end
	local def = Audio.Cues[(string.gsub(sound.Name, "^Cue_", ""))]
	if def then
		busActive[def.bus] = math.max(0, (busActive[def.bus] or 1) - 1)
	end
	local tween = TweenService:Create(sound, TweenInfo.new(fadeSeconds or 0.4), { Volume = 0 })
	tween.Completed:Once(function()
		sound:Destroy()
	end)
	tween:Play()
end

--- Adjusts a running loop's pitch and volume. This is what makes the engine
--- and the wheels track the train's actual speed.
function AudioController.tuneLoop(key: string, volumeScale: number?, pitchScale: number?)
	local sound = activeLoops[key]
	if not sound or not sound.Parent then
		return
	end
	local def = Audio.Cues[(string.gsub(sound.Name, "^Cue_", ""))]
	if def and volumeScale then
		sound.Volume = def.volume * volumeScale
	end
	if pitchScale then
		local existing = sound:FindFirstChildOfClass("PitchShiftSoundEffect")
		local effect: PitchShiftSoundEffect
		if existing then
			effect = existing
		else
			effect = Instance.new("PitchShiftSoundEffect")
			effect.Parent = sound
		end
		effect.Octave = pitchScale
	end
end

--------------------------------------------------------------------------
-- Enclosure
--------------------------------------------------------------------------

-- Being inside the train or a building muffles the outside world. This is a
-- single low-pass on the ambience and effects buses rather than per-sound
-- occlusion, which would be far more expensive for a barely noticeable gain.
local enclosureFilter: EqualizerSoundEffect? = nil
local enclosureAmount = 0
local enclosureSpring = Spring.new(0, 20, 8)

function AudioController.setEnclosed(enclosed: boolean)
	enclosureSpring:setTarget(if enclosed then 1 else 0)
end

local function stepEnclosure(deltaTime: number)
	enclosureAmount = enclosureSpring:step(deltaTime)
	local filter = enclosureFilter
	if not filter then
		return
	end
	-- Roll off the top end and lift the low end, which is what a wall does.
	filter.HighGain = -18 * enclosureAmount
	filter.MidGain = -4 * enclosureAmount
	filter.LowGain = 2 * enclosureAmount
end

--------------------------------------------------------------------------
-- Subtitles
--------------------------------------------------------------------------

local subtitleGui: ScreenGui? = nil
local subtitleStack: Frame? = nil
local directionalHolder: Frame? = nil

local function buildSubtitleUi()
	local playerGui = player:WaitForChild("PlayerGui")
	local gui = Widgets.screen("LastSignalSubtitles", Theme.Layer.subtitles, playerGui)
	subtitleGui = gui

	local insets = Theme.safeInsets()
	local stack = Instance.new("Frame")
	stack.Name = "Stack"
	stack.BackgroundTransparency = 1
	stack.AnchorPoint = Vector2.new(0.5, 1)
	stack.Position = UDim2.new(0.5, 0, 1, -insets.bottom - Theme.space(10))
	stack.Size = UDim2.new(0.7, 0, 0, 0)
	stack.AutomaticSize = Enum.AutomaticSize.Y
	stack.Parent = gui

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.VerticalAlignment = Enum.VerticalAlignment.Bottom
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.Padding = UDim.new(0, Theme.space(0.5))
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = stack
	subtitleStack = stack

	local holder = Instance.new("Frame")
	holder.Name = "Directional"
	holder.BackgroundTransparency = 1
	holder.AnchorPoint = Vector2.new(0.5, 0.5)
	holder.Position = UDim2.fromScale(0.5, 0.5)
	holder.Size = UDim2.fromScale(1, 1)
	holder.Parent = gui
	directionalHolder = holder
end

--- Shows a subtitle. Position and directional are used for the accessibility
--- arrow that replaces hearing where a sound came from.
function AudioController.subtitle(text: string, position: Vector3?, directional: boolean?)
	if not StateController.setting("subtitles", true) then
		return
	end
	local stack = subtitleStack
	if not stack then
		return
	end

	local line = Widgets.panel({
		name = "Subtitle",
		size = UDim2.new(1, 0, 0, 0),
		padding = 1,
		background = Theme.colour("void"),
		transparency = 0.25,
		stroke = false,
		parent = stack,
	})
	line.AutomaticSize = Enum.AutomaticSize.Y

	local label = Widgets.label({
		text = text,
		size = "body",
		colour = Theme.colour("text"),
		align = Enum.TextXAlignment.Center,
		parent = line,
	})
	label.TextStrokeTransparency = 0.6

	-- Older lines fade upward as new ones arrive, so the newest is always at
	-- the bottom and readable.
	task.delay(4.5, function()
		if line.Parent then
			Widgets.fade(line, 1, 0.5)
			task.delay(0.6, function()
				line:Destroy()
			end)
		end
	end)

	if directional and position and StateController.setting("directionalCues", false) then
		AudioController.directionalIndicator(position)
	end
end

--- A short-lived arrow at the screen edge pointing at a sound. This is the
--- alternative for a player who cannot use positional audio.
function AudioController.directionalIndicator(position: Vector3)
	local holder = directionalHolder
	local camera = Workspace.CurrentCamera
	if not holder or not camera then
		return
	end

	local marker = Instance.new("Frame")
	marker.Name = "Arrow"
	marker.BackgroundColor3 = Theme.colour("signalAmber")
	marker.BorderSizePixel = 0
	marker.AnchorPoint = Vector2.new(0.5, 0.5)
	marker.Size = UDim2.fromOffset(Theme.space(1.5), Theme.space(4))
	Widgets.applyCorner(marker, Theme.space(0.5))
	marker.Parent = holder

	local startedAt = os.clock()
	local connection
	connection = RunService.RenderStepped:Connect(function()
		local elapsed = os.clock() - startedAt
		if elapsed > 3 or not marker.Parent then
			connection:Disconnect()
			marker:Destroy()
			return
		end
		local currentCamera = Workspace.CurrentCamera
		if not currentCamera then
			return
		end
		-- Angle from the camera's forward direction to the sound, projected
		-- onto the horizontal plane, then placed on a circle near the edge.
		local toSound = position - currentCamera.CFrame.Position
		local flat = Vector3.new(toSound.X, 0, toSound.Z)
		if flat.Magnitude < 0.1 then
			return
		end
		local forward = currentCamera.CFrame.LookVector
		local flatForward = Vector3.new(forward.X, 0, forward.Z).Unit
		local right = Vector3.new(flatForward.Z, 0, -flatForward.X)
		local angle = math.atan2(flat.Unit:Dot(right), flat.Unit:Dot(flatForward))

		local radius = 0.34
		marker.Position = UDim2.fromScale(0.5 + math.sin(angle) * radius, 0.5 - math.cos(angle) * radius * 0.9)
		marker.Rotation = math.deg(angle)
		marker.BackgroundTransparency = math.clamp(elapsed / 3, 0, 1)
	end)
end

--------------------------------------------------------------------------
-- Reactive layers
--------------------------------------------------------------------------

local function stepTrainAudio()
	local trainState = StateController.get("train")
	if not trainState then
		AudioController.stopLoop("engine_idle")
		AudioController.stopLoop("engine_load")
		AudioController.stopLoop("wheels")
		AudioController.stopLoop("brake")
		return
	end

	local speed = trainState.speed or 0
	local maxSpeed = math.max(1, trainState.maxSpeed or 1)
	local throttle = (trainState.throttle or 0) / math.max(1, trainState.notches or 8)
	local running = trainState.engineRunning == true

	if running then
		AudioController.loop("engine_idle", "train_engine_idle")
		AudioController.loop("engine_load", "train_engine_load")
		-- Idle and load crossfade on throttle; both track engine speed.
		AudioController.tuneLoop("engine_idle", 1 - throttle * 0.8, 0.9 + throttle * 0.15)
		AudioController.tuneLoop("engine_load", throttle, 0.85 + throttle * 0.4)
	else
		AudioController.stopLoop("engine_idle")
		AudioController.stopLoop("engine_load")
	end

	local speedFraction = speed / maxSpeed
	if speed > 1 then
		AudioController.loop("wheels", "train_wheels_roll")
		AudioController.tuneLoop("wheels", math.clamp(speedFraction * 1.2, 0.1, 1), 0.7 + speedFraction * 0.6)
	else
		AudioController.stopLoop("wheels")
	end

	if (trainState.serviceBrake or 0) > 0.05 and speed > 3 then
		AudioController.loop("brake", "train_brake_apply")
		AudioController.tuneLoop("brake", math.clamp(speedFraction, 0.2, 1), 0.8 + speedFraction * 0.5)
	else
		AudioController.stopLoop("brake", 0.25)
	end
end

--- The music bed follows the threat band the server reports.
local currentBand = -1
local function setBand(band: number)
	if band == currentBand then
		return
	end
	currentBand = band
	if band >= 2 then
		AudioController.stopLoop("music_travel", 2)
		AudioController.loop("music_tension", "music_tension")
	else
		AudioController.stopLoop("music_tension", 3)
		AudioController.loop("music_travel", "music_travel")
	end
end

--------------------------------------------------------------------------

function AudioController.start()
	buildBuses()
	buildSubtitleUi()

	-- The enclosure filter lives on the ambience bus.
	local ambience = busGroups.ambience
	if ambience then
		local equalizer = Instance.new("EqualizerSoundEffect")
		equalizer.Name = "Enclosure"
		equalizer.Parent = ambience
		enclosureFilter = equalizer
	end

	StateController.Changed:Connect(function(key)
		if key == "profile" then
			applySettings()
			Theme.setHighContrast(StateController.setting("highContrast", false) == true)
			Theme.setReducedMotion(StateController.setting("reducedMotion", false) == true)
			Theme.setReducedFlashing(StateController.setting("reducedFlashing", false) == true)
			local hudScale = StateController.setting("hudScale", 1)
			if type(hudScale) == "number" then
				Theme.setUserScale(hudScale)
			end
		end
	end)

	Net.onClientEvent("HorrorCue", function(payload)
		if type(payload) ~= "table" then
			return
		end
		if payload.cue == "band" then
			setBand(payload.band or 0)
			return
		end
		if payload.cue == "lights_flicker" or payload.cue == "silhouette" or payload.cue == "evidence" then
			-- Handled by the visual effects controller; no audio here.
			return
		end
		AudioController.play(payload.cue, { position = payload.position })
	end)

	Net.onClientEvent("RadioMessage", function(payload)
		if type(payload) ~= "table" then
			return
		end
		-- The radio always shows its text, regardless of the subtitle setting:
		-- radio lines are dialogue, and the attribution is the tell that
		-- separates the dispatcher from what is imitating him.
		AudioController.play("radio_open")
		if payload.cue then
			AudioController.play(payload.cue)
		end
	end)

	Net.onClientEvent("WeaponEffect", function(payload)
		if type(payload) ~= "table" then
			return
		end
		if payload.kind == "fire" then
			local WeaponRegistry = require(Shared.Registry.WeaponRegistry)
			local def = WeaponRegistry.get(payload.weaponId or "")
			if def then
				AudioController.play(def.fireCue, { position = payload.origin })
				if payload.hitPosition and (payload.damage or 0) > 0 then
					AudioController.play(def.impactCue, { position = payload.hitPosition })
				end
			end
		elseif payload.kind == "melee" then
			local WeaponRegistry = require(Shared.Registry.WeaponRegistry)
			local def = WeaponRegistry.get(payload.weaponId or "")
			if def then
				AudioController.play(def.fireCue, { position = payload.origin })
				if (payload.hits or 0) > 0 then
					AudioController.play(def.impactCue, { position = payload.origin })
				end
			end
		end
	end)

	-- Ambience follows where the player is.
	task.spawn(function()
		while true do
			task.wait(1)
			local onExpedition = StateController.isOnExpedition()
			if onExpedition then
				AudioController.loop("forest", "forest_night")
				AudioController.loop("wind", "wind_forest")
				AudioController.loop("rain", "rain_light")
				AudioController.stopLoop("lobby_music", 2)
			else
				AudioController.stopLoop("forest", 2)
				AudioController.stopLoop("wind", 2)
				AudioController.stopLoop("rain", 2)
				AudioController.stopLoop("music_travel", 2)
				AudioController.stopLoop("music_tension", 2)
				AudioController.loop("lobby_music", "music_lobby")
				currentBand = -1
			end
		end
	end)

	RunService.Heartbeat:Connect(function(deltaTime)
		stepDucking(deltaTime)
		stepEnclosure(deltaTime)
	end)

	task.spawn(function()
		while true do
			task.wait(0.25)
			stepTrainAudio()
		end
	end)

	local audit = Audio.audit()
	log.info(string.format("started; %d of %d cues configured", audit.configured, audit.total))
	if audit.configured == 0 then
		log.info("No audio asset IDs are set. Subtitles carry every informational cue.")
	end
end

return AudioController
