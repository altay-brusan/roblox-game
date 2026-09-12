--!strict
--[[
	InputController
	---------------
	Every input the game reads, and the on-screen controls for touch devices.

	ONE BINDING TABLE
	-----------------
	Actions are declared once with their keyboard key, gamepad button and
	whether they appear on the touch layout. ContextActionService binds them,
	which means a single action works identically on a keyboard, a controller
	and a phone, and the settings panel can list them without a second table
	that would drift out of date.

	TOUCH
	-----
	The touch layout is not a keyboard rendered as buttons. It is a small set
	of large targets placed where thumbs actually are, with the frequently used
	actions on the right and the occasional ones tucked into a tray. Every
	target meets the platform minimum size from Theme, and the layout respects
	the safe area so nothing sits under a home indicator or a notch.

	Drag-and-drop is deliberately not used anywhere in this project. Every
	inventory action is a tap on an item followed by a tap on an action, which
	works identically with a mouse, a thumb and a gamepad.
]]

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("LastSignal")

local Logger = require(Shared.Core.Logger)
local Net = require(Shared.Core.Net)
local Signal = require(Shared.Core.Signal)
local Theme = require(script.Parent.Parent.UI.Theme)
local Widgets = require(script.Parent.Parent.UI.Widgets)
local StateController = require(script.Parent.StateController)

local log = Logger.new("InputController")
local player = Players.LocalPlayer

local InputController = {}

export type ActionDef = {
	id: string,
	label: string,
	description: string,
	-- Omitted for actions that are mouse-only on desktop.
	key: Enum.KeyCode?,
	gamepad: Enum.KeyCode?,
	-- Where the action appears on the touch layout, if at all.
	touch: string?, -- "primary" | "secondary" | "tray"
	-- Held actions report press and release; tapped actions report press only.
	held: boolean?,
	-- Actions that remain available while a panel is open.
	worksInMenu: boolean?,
}

local ACTIONS: { ActionDef } = {
	{ id = "interact", label = "Interact", description = "Use, search or pick up what you are looking at.", key = Enum.KeyCode.E, gamepad = Enum.KeyCode.ButtonX, touch = "primary", held = true },
	{ id = "sprint", label = "Sprint", description = "Run, while you have the stamina.", key = Enum.KeyCode.LeftShift, gamepad = Enum.KeyCode.ButtonL3, touch = "primary", held = true },
	{ id = "crouch", label = "Crouch", description = "Move slowly and quietly.", key = Enum.KeyCode.C, gamepad = Enum.KeyCode.ButtonB, touch = "secondary", held = true },
	{ id = "flashlight", label = "Lamp", description = "Toggle your lamp.", key = Enum.KeyCode.F, gamepad = Enum.KeyCode.DPadUp, touch = "primary" },
	{ id = "fire", label = "Attack", description = "Fire or swing your equipped weapon.", gamepad = Enum.KeyCode.ButtonR2, touch = "primary", held = true },
	{ id = "aim", label = "Aim", description = "Steady your aim.", gamepad = Enum.KeyCode.ButtonL2, touch = "secondary", held = true },
	{ id = "reload", label = "Reload", description = "Reload the equipped firearm.", key = Enum.KeyCode.R, gamepad = Enum.KeyCode.ButtonY, touch = "secondary" },
	{ id = "inventory", label = "Inventory", description = "Open your inventory.", key = Enum.KeyCode.Tab, gamepad = Enum.KeyCode.ButtonSelect, touch = "primary", worksInMenu = true },
	{ id = "crew", label = "Crew", description = "Open the crew panel.", key = Enum.KeyCode.G, gamepad = Enum.KeyCode.DPadLeft, touch = "tray", worksInMenu = true },
	{ id = "objectives", label = "Objectives", description = "Expand the objective list.", key = Enum.KeyCode.J, gamepad = Enum.KeyCode.DPadRight, touch = "tray", worksInMenu = true },
	{ id = "ping", label = "Ping", description = "Mark what you are looking at for your crew.", key = Enum.KeyCode.Q, gamepad = Enum.KeyCode.DPadDown, touch = "primary" },
	{ id = "menu", label = "Menu", description = "Open the main menu.", key = Enum.KeyCode.M, gamepad = Enum.KeyCode.ButtonStart, touch = "tray", worksInMenu = true },
	{ id = "skip", label = "Skip", description = "Skip the opening sequence.", key = Enum.KeyCode.Space, gamepad = Enum.KeyCode.ButtonA, touch = "primary", worksInMenu = true },
	{ id = "revive", label = "Revive", description = "Revive a downed crew member.", key = Enum.KeyCode.E, gamepad = Enum.KeyCode.ButtonX, touch = "primary", held = true },
	{ id = "quick1", label = "Slot 1", description = "Use quick slot one.", key = Enum.KeyCode.One, touch = "tray" },
	{ id = "quick2", label = "Slot 2", description = "Use quick slot two.", key = Enum.KeyCode.Two, touch = "tray" },
	{ id = "quick3", label = "Slot 3", description = "Use quick slot three.", key = Enum.KeyCode.Three, touch = "tray" },
	{ id = "quick4", label = "Slot 4", description = "Use quick slot four.", key = Enum.KeyCode.Four, touch = "tray" },
	{ id = "quick5", label = "Slot 5", description = "Use quick slot five.", key = Enum.KeyCode.Five, touch = "tray" },
}

InputController.Actions = ACTIONS

--- Fired for every action. `pressed` is false on release for held actions.
InputController.Action = Signal.new() :: Signal.Signal<string, boolean>

local suppressed = false

--- While a panel is open, gameplay actions are suppressed. Actions flagged
--- worksInMenu still fire, which is how Tab closes the inventory it opened.
function InputController.setSuppressed(value: boolean)
	suppressed = value
end

--------------------------------------------------------------------------
-- Binding
--------------------------------------------------------------------------

local function defFor(id: string): ActionDef?
	for _, def in ACTIONS do
		if def.id == id then
			return def
		end
	end
	return nil
end

local function handle(actionName: string, inputState: Enum.UserInputState): Enum.ContextActionResult
	local def = defFor(actionName)
	if not def then
		return Enum.ContextActionResult.Pass
	end
	if suppressed and not def.worksInMenu then
		return Enum.ContextActionResult.Pass
	end

	if inputState == Enum.UserInputState.Begin then
		InputController.Action:Fire(def.id, true)
	elseif inputState == Enum.UserInputState.End and def.held then
		InputController.Action:Fire(def.id, false)
	end
	return Enum.ContextActionResult.Sink
end

--------------------------------------------------------------------------
-- Touch layout
--------------------------------------------------------------------------

local touchGui: ScreenGui? = nil
local touchButtons: { [string]: TextButton } = {}
local trayOpen = false

local function buildTouchButton(parent: Instance, def: ActionDef, size: number): TextButton
	local button = Instance.new("TextButton")
	button.Name = "Touch_" .. def.id
	button.Text = ""
	button.AutoButtonColor = false
	button.BackgroundColor3 = Theme.colour("surfaceRaised")
	button.BackgroundTransparency = 0.25
	button.BorderSizePixel = 0
	button.Size = UDim2.fromOffset(size, size)
	Widgets.applyCorner(button, size * 0.5)
	Widgets.applyStroke(button, Theme.colour("lineStrong"), 1.5)

	local label = Instance.new("TextLabel")
	label.Name = "Label"
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Text = def.label
	label.FontFace = Theme.Font.heading
	label.TextSize = Theme.textSize("tiny")
	label.TextColor3 = Theme.colour("text")
	label.TextWrapped = true
	label.Parent = button

	-- Touch buttons report press and release, so a held action such as sprint
	-- behaves the same as holding the key.
	button.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
			button.BackgroundTransparency = 0.05
			handle(def.id, Enum.UserInputState.Begin)
		end
	end)
	button.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
			button.BackgroundTransparency = 0.25
			handle(def.id, Enum.UserInputState.End)
		end
	end)

	button.Parent = parent
	touchButtons[def.id] = button
	return button
end

local function buildTouchLayout()
	if not Theme.isTouch() then
		return
	end
	local playerGui = player:WaitForChild("PlayerGui")
	local gui = Widgets.screen("LastSignalTouch", Theme.Layer.hud + 2, playerGui)
	touchGui = gui

	local insets = Theme.safeInsets()
	local primarySize = math.max(Theme.minTouchTarget(), Theme.space(8))
	local secondarySize = math.max(Theme.minTouchTarget(), Theme.space(6))

	-- Right cluster: the actions a thumb reaches without moving.
	local rightCluster = Instance.new("Frame")
	rightCluster.Name = "Primary"
	rightCluster.BackgroundTransparency = 1
	rightCluster.AnchorPoint = Vector2.new(1, 1)
	rightCluster.Position = UDim2.new(1, -insets.right, 1, -insets.bottom)
	rightCluster.Size = UDim2.fromOffset(primarySize * 3 + Theme.space(2), primarySize * 2 + Theme.space(1))
	rightCluster.Parent = gui

	local rightGrid = Instance.new("UIGridLayout")
	rightGrid.CellSize = UDim2.fromOffset(primarySize, primarySize)
	rightGrid.CellPadding = UDim2.fromOffset(Theme.space(1), Theme.space(1))
	rightGrid.HorizontalAlignment = Enum.HorizontalAlignment.Right
	rightGrid.VerticalAlignment = Enum.VerticalAlignment.Bottom
	rightGrid.SortOrder = Enum.SortOrder.LayoutOrder
	rightGrid.Parent = rightCluster

	-- Left side, above the thumbstick: the occasional actions.
	local leftCluster = Instance.new("Frame")
	leftCluster.Name = "Secondary"
	leftCluster.BackgroundTransparency = 1
	leftCluster.AnchorPoint = Vector2.new(0, 1)
	leftCluster.Position = UDim2.new(0, insets.left, 1, -insets.bottom - Theme.space(14))
	leftCluster.Size = UDim2.fromOffset(secondarySize, secondarySize * 3 + Theme.space(2))
	leftCluster.Parent = gui

	local leftList = Instance.new("UIListLayout")
	leftList.FillDirection = Enum.FillDirection.Vertical
	leftList.Padding = UDim.new(0, Theme.space(1))
	leftList.VerticalAlignment = Enum.VerticalAlignment.Bottom
	leftList.SortOrder = Enum.SortOrder.LayoutOrder
	leftList.Parent = leftCluster

	-- The tray: quick slots and panels, hidden until opened, so the play area
	-- is not covered by fifteen buttons.
	local tray = Instance.new("Frame")
	tray.Name = "Tray"
	tray.BackgroundColor3 = Theme.colour("backdrop")
	tray.BackgroundTransparency = 0.15
	tray.BorderSizePixel = 0
	tray.AnchorPoint = Vector2.new(1, 1)
	tray.Position = UDim2.new(1, -insets.right, 1, -insets.bottom - primarySize * 2 - Theme.space(3))
	tray.Size = UDim2.fromOffset(secondarySize * 5 + Theme.space(6), secondarySize + Theme.space(2))
	tray.Visible = false
	Widgets.applyCorner(tray)
	tray.Parent = gui

	local trayList = Instance.new("UIListLayout")
	trayList.FillDirection = Enum.FillDirection.Horizontal
	trayList.Padding = UDim.new(0, Theme.space(1))
	trayList.HorizontalAlignment = Enum.HorizontalAlignment.Center
	trayList.VerticalAlignment = Enum.VerticalAlignment.Center
	trayList.SortOrder = Enum.SortOrder.LayoutOrder
	trayList.Parent = tray

	for index, def in ACTIONS do
		if def.touch == "primary" then
			local button = buildTouchButton(rightCluster, def, primarySize)
			button.LayoutOrder = index
		elseif def.touch == "secondary" then
			local button = buildTouchButton(leftCluster, def, secondarySize)
			button.LayoutOrder = index
		elseif def.touch == "tray" then
			local button = buildTouchButton(tray, def, secondarySize)
			button.LayoutOrder = index
		end
	end

	-- The tray toggle.
	local toggle = Instance.new("TextButton")
	toggle.Name = "TrayToggle"
	toggle.Text = ""
	toggle.AutoButtonColor = false
	toggle.BackgroundColor3 = Theme.colour("surface")
	toggle.BackgroundTransparency = 0.25
	toggle.BorderSizePixel = 0
	toggle.AnchorPoint = Vector2.new(1, 1)
	toggle.Position = UDim2.new(1, -insets.right, 1, -insets.bottom - primarySize * 2 - Theme.space(1.5))
	toggle.Size = UDim2.fromOffset(secondarySize * 1.6, secondarySize * 0.7)
	Widgets.applyCorner(toggle)
	Widgets.applyStroke(toggle, Theme.colour("line"))
	local toggleLabel = Instance.new("TextLabel")
	toggleLabel.BackgroundTransparency = 1
	toggleLabel.Size = UDim2.fromScale(1, 1)
	toggleLabel.Text = "More"
	toggleLabel.FontFace = Theme.Font.heading
	toggleLabel.TextSize = Theme.textSize("tiny")
	toggleLabel.TextColor3 = Theme.colour("textMuted")
	toggleLabel.Parent = toggle
	toggle.Activated:Connect(function()
		trayOpen = not trayOpen
		tray.Visible = trayOpen
		toggleLabel.Text = if trayOpen then "Close" else "More"
	end)
	toggle.Parent = gui

	log.info(string.format("touch layout built for %s", Theme.platform()))
end

--- Shows or hides a touch button by action id. Used to hide Attack when no
--- weapon is equipped, and Revive unless a downed teammate is in reach.
function InputController.setTouchVisible(actionId: string, visible: boolean)
	local button = touchButtons[actionId]
	if button then
		button.Visible = visible
	end
end

function InputController.setTouchLabel(actionId: string, text: string)
	local button = touchButtons[actionId]
	if button then
		local label = button:FindFirstChild("Label") :: TextLabel?
		if label then
			label.Text = text
		end
	end
end

--------------------------------------------------------------------------

function InputController.start()
	for _, def in ACTIONS do
		local keys: { any } = {}
		if def.key then
			table.insert(keys, def.key)
		end
		if def.gamepad then
			table.insert(keys, def.gamepad)
		end
		-- Attack and aim are mouse buttons on desktop.
		if def.id == "fire" then
			table.insert(keys, Enum.UserInputType.MouseButton1)
		elseif def.id == "aim" then
			table.insert(keys, Enum.UserInputType.MouseButton2)
		end
		if #keys > 0 then
			ContextActionService:BindAction(def.id, handle, false, table.unpack(keys))
		end
	end

	buildTouchLayout()

	-- Report the platform once, so the analytics funnel can tell a phone
	-- session from a desktop one without collecting anything identifying.
	local platform = Theme.platform()
	Net.fireServer("Analytics", platform .. "_session")

	-- A device that rotates or attaches a keyboard changes category; the
	-- layout is rebuilt rather than left wrong.
	UserInputService.LastInputTypeChanged:Connect(function()
		local previous = Theme.platform()
		Theme.refreshPlatform()
		if Theme.platform() ~= previous then
			if touchGui then
				touchGui:Destroy()
				touchGui = nil
				table.clear(touchButtons)
			end
			buildTouchLayout()
		end
	end)

	StateController.Changed:Connect(function(key)
		if key == "ui" then
			InputController.setSuppressed(StateController.ui("openPanel") ~= nil)
		end
	end)

	log.info(string.format("started with %d actions", #ACTIONS))
end

return InputController
