--!strict
--[[
	CabController
	-------------
	The driving interface.

	WHY THIS EXISTS
	---------------
	TrainService implements the entire locomotive: eight throttle notches, a
	service brake, an emergency brake, a reverser, lights, doors, wipers, a
	horn and an engine start, all validated server-side against whoever is
	actually sitting in the driver's seat.

	None of it was reachable. The first build had no cab interface at all, so
	the train sat parked forever and no expedition could ever progress past the
	opening cinematic. This is that interface.

	HOW IT WORKS
	------------
	Sitting in the driver's seat claims the controls from the server. The panel
	appears, bound to on-screen buttons and to keys, and disappears the moment
	you stand up. The server releases the controls automatically when the seat
	is empty, so there is no way to hold the train hostage by walking away.

	The panel is a strip along the bottom of the screen rather than a full
	modal, because a driver has to be able to see out of the windscreen.
]]

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("LastSignal")

local Format = require(Shared.Core.Format)
local Logger = require(Shared.Core.Logger)
local Net = require(Shared.Core.Net)
local Theme = require(script.Parent.Parent.UI.Theme)
local Widgets = require(script.Parent.Parent.UI.Widgets)
local StateController = require(script.Parent.StateController)

local log = Logger.new("CabController")
local player = Players.LocalPlayer

local CabController = {}

local gui: ScreenGui?
local panel: Frame?
local statusLabel: TextLabel?
local throttleLabel: TextLabel?
local brakeLabel: TextLabel?
local hintLabel: TextLabel?
local toggleButtons: { [string]: any } = {}

local seated = false
local isDriver = false
local seatConnection: RBXScriptConnection? = nil

--------------------------------------------------------------------------
-- Sending
--------------------------------------------------------------------------

local function control(name: string, value: any)
	Net.fireServer("TrainControl", name, value)
end

local function trainState(): { [string]: any }?
	return StateController.get("train")
end

local function currentThrottle(): number
	local state = trainState()
	return if state then state.throttle or 0 else 0
end

local function notches(): number
	local state = trainState()
	return if state then state.notches or 8 else 8
end

--------------------------------------------------------------------------
-- Panel
--------------------------------------------------------------------------

local function build()
	local playerGui = player:WaitForChild("PlayerGui")
	local screen = Widgets.screen("LastSignalCab", Theme.Layer.hud + 1, playerGui)
	gui = screen

	local insets = Theme.safeInsets()
	local frame = Widgets.panel({
		name = "Cab",
		size = UDim2.fromOffset(Theme.space(72), Theme.space(19)),
		position = UDim2.new(0.5, 0, 1, -insets.bottom - Theme.space(1)),
		anchor = Vector2.new(0.5, 1),
		padding = 1.25,
		background = Theme.colour("backdrop"),
		transparency = 0.08,
		parent = screen,
	})
	frame.Visible = false
	panel = frame

	local column = Widgets.column(frame, 0.75)

	-- Status line: what the train is doing right now, in words.
	statusLabel = Widgets.label({
		text = "",
		size = "body",
		font = Theme.Font.heading,
		colour = Theme.colour("brass"),
		align = Enum.TextXAlignment.Center,
		parent = column,
		layoutOrder = 1,
	})

	hintLabel = Widgets.label({
		text = "",
		size = "small",
		colour = Theme.colour("signalAmber"),
		align = Enum.TextXAlignment.Center,
		parent = column,
		layoutOrder = 2,
	})

	-- Row one: throttle and brake, the two controls that matter.
	local driveRow = Widgets.row(column, 0.5)
	driveRow.LayoutOrder = 3

	Widgets.button({
		text = "Throttle -",
		width = UDim.new(0.18, 0),
		parent = driveRow,
		onClick = function()
			control("throttle", math.max(0, currentThrottle() - 1))
		end,
	})

	throttleLabel = Widgets.label({
		text = "0 / 8",
		size = "body",
		font = Theme.Font.mono,
		align = Enum.TextXAlignment.Center,
		parent = driveRow,
		name = "Throttle",
	})
	local resolvedThrottle = throttleLabel :: TextLabel
	resolvedThrottle.Size = UDim2.new(0.14, 0, 1, 0)
	resolvedThrottle.AutomaticSize = Enum.AutomaticSize.None
	resolvedThrottle.TextYAlignment = Enum.TextYAlignment.Center
	resolvedThrottle.LayoutOrder = 2

	Widgets.button({
		text = "Throttle +",
		width = UDim.new(0.18, 0),
		primary = true,
		parent = driveRow,
		layoutOrder = 3,
		onClick = function()
			control("throttle", math.min(notches(), currentThrottle() + 1))
		end,
	})

	brakeLabel = Widgets.label({
		text = "",
		size = "small",
		align = Enum.TextXAlignment.Center,
		parent = driveRow,
		name = "BrakeState",
	})
	local resolvedBrake = brakeLabel :: TextLabel
	resolvedBrake.Size = UDim2.new(0.14, 0, 1, 0)
	resolvedBrake.AutomaticSize = Enum.AutomaticSize.None
	resolvedBrake.TextYAlignment = Enum.TextYAlignment.Center
	resolvedBrake.LayoutOrder = 4

	Widgets.button({
		text = "Brake",
		width = UDim.new(0.16, 0),
		parent = driveRow,
		layoutOrder = 5,
		onClick = function()
			-- Full application, then release by throttling up. A held brake
			-- would need a press-and-release binding that does not work well
			-- on touch, and a driver wants a definite state anyway.
			local state = trainState()
			local applied = if state then (state.serviceBrake or 0) else 0
			control("brake", if applied > 0.05 then 0 else 1)
		end,
	})

	Widgets.button({
		text = "EMERGENCY",
		width = UDim.new(0.2, 0),
		danger = true,
		parent = driveRow,
		layoutOrder = 6,
		onClick = function()
			control("emergency", true)
		end,
	})

	-- Row two: everything else.
	local auxRow = Widgets.row(column, 0.5)
	auxRow.LayoutOrder = 4

	local function auxButton(id: string, label: string, order: number, onClick: () -> ())
		local button = Widgets.button({
			text = label,
			width = UDim.new(0.135, 0),
			parent = auxRow,
			layoutOrder = order,
			onClick = onClick,
		})
		toggleButtons[id] = button
		return button
	end

	auxButton("reverser", "Forward", 1, function()
		local state = trainState()
		local direction = if state then state.direction or 0 else 0
		-- Cycles reverse, neutral, forward. The server refuses a change while
		-- the train is rolling, which is prototypical and stops the reverser
		-- being used as a brake.
		local nextDirection = if direction == 1 then 0 elseif direction == 0 then -1 else 1
		control("reverser", nextDirection)
	end)
	auxButton("horn", "Horn", 2, function()
		control("horn", true)
	end)
	auxButton("headlights", "Lights", 3, function()
		control("headlights", true)
	end)
	auxButton("interior_lights", "Saloon", 4, function()
		control("interior_lights", true)
	end)
	auxButton("wipers", "Wipers", 5, function()
		control("wipers", true)
	end)
	auxButton("doors", "Doors", 6, function()
		control("doors", true)
	end)
	auxButton("start_engine", "Start", 7, function()
		control("start_engine", true)
	end)
end

--------------------------------------------------------------------------
-- Refresh
--------------------------------------------------------------------------

local function refresh()
	local frame = panel
	if not frame then
		return
	end
	frame.Visible = seated and isDriver
	if not frame.Visible then
		return
	end

	local state = trainState()
	if not state then
		return
	end

	if throttleLabel then
		throttleLabel.Text = string.format("%d / %d", state.throttle or 0, state.notches or 8)
	end

	local brakeApplied = (state.serviceBrake or 0) > 0.05
	if brakeLabel then
		brakeLabel.Text = if state.emergencyBrake then "EMERG" elseif brakeApplied then "BRAKE ON" else "released"
		brakeLabel.TextColor3 = if state.emergencyBrake or brakeApplied then Theme.colour("signalRed") else Theme.colour("textMuted")
	end

	if statusLabel then
		local direction = state.direction or 0
		local directionText = if direction == 1 then "Forward" elseif direction == -1 then "Reverse" else "Neutral"
		statusLabel.Text = string.format(
			"%s   %s km/h   fuel %s   condition %s",
			directionText,
			Format.speedKph(state.speed or 0),
			Format.percent((state.fuel or 0) / math.max(1, state.maxFuel or 1)),
			Format.percent((state.condition or 0) / math.max(1, state.maxCondition or 1))
		)
	end

	-- The hint is the single most useful thing on this panel. A stationary
	-- train is almost always stationary for one of four nameable reasons, and
	-- saying which removes the guesswork.
	if hintLabel then
		local hint = ""
		if not state.engineRunning then
			hint = "The engine is not running. Press Start."
		elseif (state.direction or 0) == 0 then
			hint = "The reverser is in neutral. Set it to Forward."
		elseif state.emergencyBrake then
			hint = "Emergency brake applied. It releases itself once stopped."
		elseif brakeApplied then
			hint = "The brake is on. Release it, then open the throttle."
		elseif (state.throttle or 0) == 0 and (state.speed or 0) < 1 then
			hint = "Open the throttle to move off."
		elseif state.doorsOpen then
			hint = "Doors are open. She will not exceed walking pace."
		end
		hintLabel.Text = hint
		hintLabel.Visible = hint ~= ""
	end

	local toggle = toggleButtons.reverser
	if toggle then
		local direction = state.direction or 0
		toggle.setText(if direction == 1 then "Forward" elseif direction == -1 then "Reverse" else "Neutral")
	end
	if toggleButtons.headlights then
		toggleButtons.headlights.setText(if state.headlights then "Lights on" else "Lights off")
	end
	if toggleButtons.doors then
		toggleButtons.doors.setText(if state.doorsOpen then "Close doors" else "Open doors")
	end
	if toggleButtons.wipers then
		toggleButtons.wipers.setText(if state.wipers then "Wipers on" else "Wipers off")
	end
	if toggleButtons.start_engine then
		toggleButtons.start_engine.setEnabled(not state.engineRunning)
	end
end

--------------------------------------------------------------------------
-- Key bindings, active only while driving
--------------------------------------------------------------------------

local CAB_ACTIONS = "LastSignalCabKeys"

local function handleKey(_actionName: string, inputState: Enum.UserInputState, input: InputObject): Enum.ContextActionResult
	if inputState ~= Enum.UserInputState.Begin then
		return Enum.ContextActionResult.Pass
	end
	local key = input.KeyCode
	if key == Enum.KeyCode.W then
		control("throttle", math.min(notches(), currentThrottle() + 1))
	elseif key == Enum.KeyCode.S then
		control("throttle", math.max(0, currentThrottle() - 1))
	elseif key == Enum.KeyCode.Space then
		local state = trainState()
		local applied = if state then (state.serviceBrake or 0) else 0
		control("brake", if applied > 0.05 then 0 else 1)
	elseif key == Enum.KeyCode.X then
		control("emergency", true)
	elseif key == Enum.KeyCode.H then
		control("horn", true)
	elseif key == Enum.KeyCode.L then
		control("headlights", true)
	elseif key == Enum.KeyCode.O then
		control("doors", true)
	end
	return Enum.ContextActionResult.Sink
end

local function bindKeys()
	ContextActionService:BindAction(
		CAB_ACTIONS,
		handleKey,
		false,
		Enum.KeyCode.W,
		Enum.KeyCode.S,
		Enum.KeyCode.Space,
		Enum.KeyCode.X,
		Enum.KeyCode.H,
		Enum.KeyCode.L,
		Enum.KeyCode.O
	)
end

local function unbindKeys()
	ContextActionService:UnbindAction(CAB_ACTIONS)
end

--------------------------------------------------------------------------
-- Seat tracking
--------------------------------------------------------------------------

local function leaveControls()
	if not seated then
		return
	end
	seated = false
	if isDriver then
		Net.invokeServer("TrainCommand", "release_driver")
	end
	isDriver = false
	unbindKeys()
	refresh()
	log.debug("left the controls")
end

local function takeControls()
	if seated then
		return
	end
	seated = true
	local result = Net.invokeServer("TrainCommand", "claim_driver")
	if type(result) == "table" and result.ok then
		isDriver = true
		bindKeys()
		log.debug("took the controls")
	else
		isDriver = false
		local reason = if type(result) == "table" then tostring(result.error) else "UNAVAILABLE"
		if reason == "OCCUPIED" then
			local HUDController = require(script.Parent.HUDController)
			HUDController.notify({
				kind = "warning",
				title = "Somebody else is driving",
				body = "Only one crew member can be at the controls at a time.",
				duration = 5,
			})
		end
	end
	refresh()
end

local function watchHumanoid(character: Model)
	if seatConnection then
		seatConnection:Disconnect()
		seatConnection = nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end

	seatConnection = humanoid.Seated:Connect(function(active, seat)
		if active and seat and seat:HasTag("DriverSeat") then
			takeControls()
		else
			leaveControls()
		end
	end)

	-- Cover the case where the character is already seated when this runs,
	-- such as after a respawn directly into the cab.
	if humanoid.SeatPart and humanoid.SeatPart:HasTag("DriverSeat") then
		takeControls()
	end
end

--------------------------------------------------------------------------

function CabController.isDriving(): boolean
	return seated and isDriver
end

function CabController.start()
	build()

	if player.Character then
		watchHumanoid(player.Character)
	end
	player.CharacterAdded:Connect(function(character)
		task.wait(0.2)
		leaveControls()
		watchHumanoid(character)
	end)

	StateController.Changed:Connect(function(key)
		if key == "train" then
			refresh()
		elseif key == "expedition" then
			-- Leaving an expedition must drop the controls, or the panel would
			-- linger in the lobby driving a train that no longer exists.
			local expedition = StateController.get("expedition")
			if not expedition or expedition.state == "lobby" or expedition.state == "results" then
				leaveControls()
			end
		end
	end)

	log.info("started")
end

return CabController
