--!strict
--[[
	CinematicController
	-------------------
	The opening sequence: letterbox, titles, rain, the radio warning, and the
	handover to first-person control.

	SYNCHRONISED, SKIPPABLE, AND ALWAYS RECOVERABLE
	----------------------------------------------
	The server starts and ends the sequence for the whole crew at once, so
	everybody sees the same thing at the same time. Skipping is a crew vote:
	half the crew is enough, which stops one person forcing it on everybody and
	stops one person holding everybody up.

	Every exit path ends at the same function. Whether the sequence finished,
	was skipped, the player died during it, the expedition ended, or the client
	simply lost the message that should have ended it, `finish` runs and hands
	control back. The camera controller has its own watchdog on top of that.

	REDUCED MOTION
	--------------
	With reduced motion enabled the camera does not fly. The same shots are
	shown as held frames with hard cuts, at the same timings, so the sequence
	still tells its story without the movement that causes motion sickness.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Shared = ReplicatedStorage:WaitForChild("LastSignal")

local GameConfig = require(Shared.Config.GameConfig)
local Logger = require(Shared.Core.Logger)
local Net = require(Shared.Core.Net)
local Theme = require(script.Parent.Parent.UI.Theme)
local Widgets = require(script.Parent.Parent.UI.Widgets)
local AudioController = require(script.Parent.AudioController)
local CameraController = require(script.Parent.CameraController)
local HUDController = require(script.Parent.HUDController)
local InputController = require(script.Parent.InputController)
local StateController = require(script.Parent.StateController)

local log = Logger.new("CinematicController")
local player = Players.LocalPlayer

local CinematicController = {}

local gui: ScreenGui?
local root: Frame?
local topBar: Frame?
local bottomBar: Frame?
local titleLabel: TextLabel?
local subtitleLabel: TextLabel?
local skipLabel: TextLabel?
local fadeFrame: Frame?

local running = false
local startedAt = 0
local skipAllowedAt = 0
local sequenceThread: thread? = nil

--------------------------------------------------------------------------
-- Build
--------------------------------------------------------------------------

local function build()
	local playerGui = player:WaitForChild("PlayerGui")
	local screen = Widgets.screen("LastSignalCinematic", Theme.Layer.cinematic, playerGui)
	screen.IgnoreGuiInset = true
	gui = screen

	local frame = Instance.new("Frame")
	frame.Name = "Root"
	frame.BackgroundTransparency = 1
	frame.Size = UDim2.fromScale(1, 1)
	frame.Visible = false
	frame.Parent = screen
	root = frame

	-- Letterbox bars. They animate in, and out again on every exit path.
	local top = Instance.new("Frame")
	top.Name = "TopBar"
	top.BorderSizePixel = 0
	top.BackgroundColor3 = Color3.new(0, 0, 0)
	top.Size = UDim2.new(1, 0, 0, 0)
	top.Parent = frame
	topBar = top

	local bottom = Instance.new("Frame")
	bottom.Name = "BottomBar"
	bottom.BorderSizePixel = 0
	bottom.BackgroundColor3 = Color3.new(0, 0, 0)
	bottom.AnchorPoint = Vector2.new(0, 1)
	bottom.Position = UDim2.fromScale(0, 1)
	bottom.Size = UDim2.new(1, 0, 0, 0)
	bottom.Parent = frame
	bottomBar = bottom

	-- A full-screen fade, used for the open, the cuts and the handover.
	local fade = Instance.new("Frame")
	fade.Name = "Fade"
	fade.BorderSizePixel = 0
	fade.BackgroundColor3 = Color3.new(0, 0, 0)
	fade.Size = UDim2.fromScale(1, 1)
	fade.BackgroundTransparency = 0
	fade.Parent = frame
	fadeFrame = fade

	local title = Widgets.label({
		text = "",
		size = "display",
		font = Theme.Font.display,
		align = Enum.TextXAlignment.Center,
		parent = frame,
		name = "Title",
	})
	title.AnchorPoint = Vector2.new(0.5, 0.5)
	title.Position = UDim2.fromScale(0.5, 0.44)
	title.Size = UDim2.new(0.8, 0, 0, 0)
	title.TextTransparency = 1
	titleLabel = title

	local subtitle = Widgets.label({
		text = "",
		size = "body",
		colour = Theme.colour("textMuted"),
		align = Enum.TextXAlignment.Center,
		parent = frame,
		name = "Subtitle",
	})
	subtitle.AnchorPoint = Vector2.new(0.5, 0)
	subtitle.Position = UDim2.fromScale(0.5, 0.52)
	subtitle.Size = UDim2.new(0.7, 0, 0, 0)
	subtitle.TextTransparency = 1
	subtitleLabel = subtitle

	local skip = Widgets.label({
		text = "",
		size = "small",
		colour = Theme.colour("textFaint"),
		align = Enum.TextXAlignment.Right,
		parent = frame,
		name = "Skip",
	})
	skip.AnchorPoint = Vector2.new(1, 1)
	skip.Position = UDim2.new(1, -Theme.space(3), 1, -Theme.space(3))
	skip.Size = UDim2.new(0, Theme.space(40), 0, 0)
	skip.TextTransparency = 1
	skipLabel = skip
end

--------------------------------------------------------------------------
-- Beats
--------------------------------------------------------------------------

type Beat = { at: number, title: string?, subtitle: string?, fade: number? }

-- The text of the sequence. Timings match the shots in CameraController, so
-- the words land on the right shots. There is no closing fade here: the
-- train running into the tunnel is the fade, sent by the server as a
-- ScreenFade when it is actually inside.
-- The prologue. The title is not here: it comes after the crossing, when
-- the reply arrives (the server sends "title"). Lines in brackets describe
-- sounds; the rest is the driver, who has no recorded voice yet.
local BEATS: { Beat } = {
	{ at = 0.0, fade = 0 },
	{ at = 0.4, subtitle = "02:17, Up Main. The last service out of Tolbridge Yard.", fade = 1 },
	{ at = 2.2, subtitle = "ROLE" },
	{ at = 3.8, subtitle = "[Driver, on the PA] Evening, all. Next stop Marrow Halt. Sit back, it's a quiet one." },
	{ at = 6.6, subtitle = "" },
	{ at = 6.8, subtitle = "[A heavy bang from the rear carriage]" },
	{ at = 8.3, subtitle = "" },
	{ at = 8.8, subtitle = "[The carriage is empty. Every seat.]" },
	{ at = 11.6, subtitle = "[Driver] Control, this is the zero two seventeen. I've lost my passengers. Control?" },
	{ at = 16.0, subtitle = "" },
}

-- Set from the play message: whether this player is the driver.
local isDriver = false

local function applyBeat(beat: Beat)
	local info = Theme.tweenInfo(0.6)
	if beat.title ~= nil and titleLabel then
		titleLabel.Text = beat.title
		TweenService:Create(titleLabel, info, { TextTransparency = if beat.title == "" then 1 else 0 }):Play()
	end
	if beat.subtitle ~= nil and subtitleLabel then
		local text = beat.subtitle
		if text == "ROLE" then
			-- One storyline in co-op: the crew leader is the driver, the rest
			-- are conductors on the same doomed service.
			text = if isDriver then "You are the driver tonight." else "You are a conductor tonight. The driver is up front."
		end
		-- Subtitles follow the setting; without them the scene still plays.
		if text ~= "" and not StateController.setting("subtitles", true) then
			text = ""
		end
		subtitleLabel.Text = text
		TweenService:Create(subtitleLabel, info, { TextTransparency = if beat.subtitle == "" then 1 else 0 }):Play()
	end
	if beat.fade ~= nil and fadeFrame then
		TweenService:Create(fadeFrame, Theme.tweenInfo(1.2), { BackgroundTransparency = beat.fade }):Play()
	end
end

--------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------

local carriageModel: Model? = nil

--- The title, after the crossing, over play: the reply has just come in.
--- It does not take control away; it fades in and out over the world.
local function titleCard()
	local label = titleLabel
	if not label or running then
		return
	end
	if root then
		root.Visible = true
	end
	label.Text = "LAST SIGNAL"
	TweenService:Create(label, Theme.tweenInfo(1.6), { TextTransparency = 0 }):Play()
	task.delay(4.5, function()
		TweenService:Create(label, Theme.tweenInfo(1.6), { TextTransparency = 1 }):Play()
		task.delay(1.7, function()
			if root and not running then
				root.Visible = false
			end
		end)
	end)
end

local function setLetterbox(active: boolean)
	local height = if active then UDim2.new(1, 0, 0.12, 0) else UDim2.new(1, 0, 0, 0)
	local info = Theme.tweenInfo(0.8)
	if topBar then
		TweenService:Create(topBar, info, { Size = height }):Play()
	end
	if bottomBar then
		TweenService:Create(bottomBar, info, { Size = height }):Play()
	end
end

--- The single exit. Every path ends here, which is what makes the handover
--- reliable no matter how the sequence ended.
local function finish()
	if not running then
		return
	end
	running = false

	if sequenceThread then
		task.cancel(sequenceThread)
		sequenceThread = nil
	end

	setLetterbox(false)
	if fadeFrame then
		TweenService:Create(fadeFrame, Theme.tweenInfo(0.8), { BackgroundTransparency = 1 }):Play()
	end
	for _, label in { titleLabel, subtitleLabel, skipLabel } do
		if label then
			TweenService:Create(label, Theme.tweenInfo(0.3), { TextTransparency = 1 }):Play()
		end
	end

	task.delay(0.85, function()
		if root then
			root.Visible = false
		end
	end)

	StateController.setUi("cinematic", false)
	HUDController.setVisible(true)
	CameraController.stopCinematic()
	AudioController.stopLoop("cinematic_music", 1.5)

	log.info("cinematic finished; control restored")
end

local function begin(duration: number, skippableAfter: number, anchor: CFrame?, model: Model?)
	if running then
		return
	end
	running = true
	startedAt = os.clock()
	skipAllowedAt = startedAt + skippableAfter

	StateController.setUi("cinematic", true)
	HUDController.setVisible(false)

	if root then
		root.Visible = true
	end
	if fadeFrame then
		fadeFrame.BackgroundTransparency = 0
	end
	setLetterbox(true)

	-- Reduced motion swaps the moving camera for held frames; the camera
	-- controller handles that itself.
	CameraController.startCinematic(duration, anchor, model, carriageModel)

	AudioController.loop("cinematic_music", "music_departure")

	sequenceThread = task.spawn(function()
		local index = 1
		while running and index <= #BEATS do
			local beat = BEATS[index]
			local elapsed = os.clock() - startedAt
			if elapsed >= beat.at then
				applyBeat(beat)
				index += 1
			else
				task.wait(0.05)
			end

			if skipLabel and os.clock() >= skipAllowedAt and skipLabel.TextTransparency > 0.5 then
				skipLabel.Text = if Theme.isTouch() then "Tap Skip to skip" else "Press Space to skip"
				TweenService:Create(skipLabel, Theme.tweenInfo(0.4), { TextTransparency = 0 }):Play()
			end
		end

		-- A local safety net: if the server's stop message never arrives, the
		-- sequence still ends on its own rather than trapping the player.
		while running and (os.clock() - startedAt) < duration + 3 do
			task.wait(0.2)
		end
		if running then
			log.warn("no stop message received; ending the sequence locally")
			finish()
		end
	end)
end

--------------------------------------------------------------------------

--------------------------------------------------------------------------
-- Screen fade
--------------------------------------------------------------------------

-- A fade that is independent of the cinematic, for the tunnel crossing. It
-- sits above everything and is used whether or not the sequence was skipped.
local screenFade: Frame? = nil
local fadeToken = 0

local function buildScreenFade()
	local playerGui = player:WaitForChild("PlayerGui")
	local screen = Instance.new("ScreenGui")
	screen.Name = "LastSignalFade"
	screen.IgnoreGuiInset = true
	screen.ResetOnSpawn = false
	screen.DisplayOrder = 10000
	screen.Parent = playerGui
	local frame = Instance.new("Frame")
	frame.Name = "Fade"
	frame.BorderSizePixel = 0
	frame.BackgroundColor3 = Color3.new(0, 0, 0)
	frame.BackgroundTransparency = 1
	frame.Size = UDim2.fromScale(1, 1)
	frame.Parent = screen
	screenFade = frame
end

local function fadeScreen(action: string, seconds: number)
	local frame = screenFade
	if not frame then
		return
	end
	fadeToken += 1
	local token = fadeToken
	TweenService:Create(frame, TweenInfo.new(seconds, Enum.EasingStyle.Sine), {
		BackgroundTransparency = if action == "out" then 0 else 1,
	}):Play()
	if action == "out" then
		-- Never left black: if the matching fade-in is lost, clear anyway.
		task.delay(6, function()
			if fadeToken == token then
				fadeScreen("in", 1)
			end
		end)
	end
end

function CinematicController.start()
	build()
	buildScreenFade()

	Net.onClientEvent("ScreenFade", function(payload)
		if type(payload) ~= "table" then
			return
		end
		local seconds = if type(payload.seconds) == "number" then math.clamp(payload.seconds, 0, 5) else 0.6
		fadeScreen(if payload.action == "out" then "out" else "in", seconds)
	end)

	Net.onClientEvent("Cinematic", function(payload)
		if type(payload) ~= "table" then
			return
		end
		if payload.action == "play" then
			local model = if typeof(payload.trainModel) == "Instance" and payload.trainModel:IsA("Model") then payload.trainModel else nil
			local anchor = if typeof(payload.trainCFrame) == "CFrame" then payload.trainCFrame else nil
			carriageModel = if typeof(payload.carriageModel) == "Instance" and payload.carriageModel:IsA("Model") then payload.carriageModel else nil
			isDriver = payload.driverUserId == player.UserId
			begin(payload.duration or GameConfig.CinematicSeconds, payload.skippableAfter or 2, anchor, model)
		elseif payload.action == "stop" then
			finish()
		elseif payload.action == "title" then
			titleCard()
		elseif payload.action == "skipvote" and skipLabel and running then
			skipLabel.Text = string.format("Skipping  %d of %d", payload.votes or 0, payload.needed or 1)
		end
	end)

	InputController.Action:Connect(function(actionId, pressed)
		if actionId ~= "skip" or not pressed or not running then
			return
		end
		if os.clock() < skipAllowedAt then
			return
		end
		Net.fireServer("CinematicSkip")
		Net.fireServer("Analytics", "cinematic_skipped")
		if skipLabel then
			skipLabel.Text = "Skip requested"
		end
	end)

	-- Dying, or the expedition ending, during the sequence also ends it.
	StateController.Changed:Connect(function(key, value)
		if not running then
			return
		end
		if key == "vitals" and type(value) == "table" and value.state == "dead" then
			finish()
		elseif key == "expedition" and type(value) == "table" then
			if value.state == "lobby" or value.state == "results" or value.state == "cancelled" then
				finish()
			end
		end
	end)

	player.CharacterAdded:Connect(function()
		-- A respawn during the sequence would otherwise leave the letterbox up
		-- with no way to clear it.
		if running then
			task.wait(0.3)
			finish()
		end
	end)

	log.info("started")
end

return CinematicController
