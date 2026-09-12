--!strict
--[[
	HUDController
	-------------
	The heads-up display: vitals, objective, quick slots, ammunition, the
	downed state and the notification feed.

	WHAT IS ON SCREEN, AND WHY THAT IS ALL
	--------------------------------------
	Bottom left   health, stamina, lamp. The three things that decide whether
	              you keep playing in the next thirty seconds.
	Bottom right  quick slots and ammunition. Only visible when relevant.
	Top left      the objective, in a corner, two lines at most.
	Top right     the train's fuel and condition, only while on an expedition.
	Centre        nothing, except a crosshair when a weapon is drawn, and the
	              downed bleedout ring when you are down.

	The brief asks that the objective sit in a corner and never cover half the
	screen. It is capped at two lines, and the expanded list is a key press
	away rather than always open.

	The HUD hides itself entirely during the cinematic and while a full panel
	is open, so the game is never showing two layers of interface at once.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("LastSignal")

local Balance = require(Shared.Config.Balance)
local Format = require(Shared.Core.Format)
local ItemRegistry = require(Shared.Registry.ItemRegistry)
local Logger = require(Shared.Core.Logger)
local Net = require(Shared.Core.Net)
local Theme = require(script.Parent.Parent.UI.Theme)
local Widgets = require(script.Parent.Parent.UI.Widgets)
local InputController = require(script.Parent.InputController)
local StateController = require(script.Parent.StateController)

local log = Logger.new("HUDController")
local player = Players.LocalPlayer

local HUDController = {}

local gui: ScreenGui?
local root: Frame?
local vitalsPanel: Frame?
local healthMeter, staminaMeter, lampMeter
local objectivePanel: Frame?
local objectiveTitle: TextLabel?
local objectiveDetail: TextLabel?
local objectiveProgress: TextLabel?
local trainPanel: Frame?
local fuelMeter, conditionMeter
local speedLabel: TextLabel?
local quickSlotFrames: { Frame } = {}
local ammoLabel: TextLabel?
local ammoPanel: Frame?
local crosshair: Frame?
local downedPanel: Frame?
local downedRing: Frame?
local downedText: TextLabel?
local selfReviveButton
local departurePanel: Frame?
local departureTitle: TextLabel?
local departureDetail: TextLabel?
local departureMeter
local notificationStack: Frame?
local crewStrip: Frame?

--------------------------------------------------------------------------
-- Build
--------------------------------------------------------------------------

local function buildVitals(parent: Instance)
	local insets = Theme.safeInsets()
	local panel = Widgets.panel({
		name = "Vitals",
		size = UDim2.fromOffset(Theme.space(26), Theme.space(9)),
		position = UDim2.new(0, insets.left, 1, -insets.bottom),
		anchor = Vector2.new(0, 1),
		padding = 1,
		background = Theme.colour("backdrop"),
		transparency = 0.25,
		parent = parent,
	})
	vitalsPanel = panel

	local column = Widgets.column(panel, 0.75)
	healthMeter = Widgets.meter(column, Theme.colour("health"), Theme.space(1.5), "Health")
	staminaMeter = Widgets.meter(column, Theme.colour("stamina"), Theme.space(1), "Stamina")
	lampMeter = Widgets.meter(column, Theme.colour("flashlight"), Theme.space(1), "Lamp")
end

local function buildObjective(parent: Instance)
	local insets = Theme.safeInsets()
	local panel = Widgets.panel({
		name = "Objective",
		size = UDim2.fromOffset(Theme.space(34), 0),
		position = UDim2.new(0, insets.left, 0, insets.top),
		padding = 1,
		background = Theme.colour("backdrop"),
		transparency = 0.3,
		parent = parent,
	})
	panel.AutomaticSize = Enum.AutomaticSize.Y
	objectivePanel = panel

	local column = Widgets.column(panel, 0.25)

	objectiveTitle = Widgets.label({
		text = "",
		size = "body",
		font = Theme.Font.heading,
		colour = Theme.colour("brass"),
		parent = column,
		layoutOrder = 1,
	})

	local detail = Widgets.label({
		text = "",
		size = "small",
		colour = Theme.colour("textMuted"),
		parent = column,
		layoutOrder = 2,
	})
	-- Two lines maximum, so the objective can never grow into the play area.
	detail.TextTruncate = Enum.TextTruncate.AtEnd
	objectiveDetail = detail

	objectiveProgress = Widgets.label({
		text = "",
		size = "tiny",
		colour = Theme.colour("textFaint"),
		parent = column,
		layoutOrder = 3,
	})
end

local function buildTrain(parent: Instance)
	local insets = Theme.safeInsets()
	local panel = Widgets.panel({
		name = "Train",
		size = UDim2.fromOffset(Theme.space(22), Theme.space(9)),
		position = UDim2.new(1, -insets.right, 0, insets.top),
		anchor = Vector2.new(1, 0),
		padding = 1,
		background = Theme.colour("backdrop"),
		transparency = 0.3,
		parent = parent,
	})
	panel.Visible = false
	trainPanel = panel

	local column = Widgets.column(panel, 0.5)
	speedLabel = Widgets.label({
		text = "0 km/h",
		size = "body",
		font = Theme.Font.mono,
		align = Enum.TextXAlignment.Right,
		parent = column,
		layoutOrder = 1,
	})
	fuelMeter = Widgets.meter(column, Theme.colour("fuel"), Theme.space(1), "Fuel")
	conditionMeter = Widgets.meter(column, Theme.colour("condition"), Theme.space(1), "Condition")
end

local function buildQuickSlots(parent: Instance)
	local insets = Theme.safeInsets()
	local strip = Instance.new("Frame")
	strip.Name = "QuickSlots"
	strip.BackgroundTransparency = 1
	strip.AnchorPoint = Vector2.new(1, 1)
	-- On touch the slots sit above the button cluster so nothing overlaps.
	local bottomOffset = insets.bottom + (if Theme.isTouch() then Theme.space(22) else 0)
	strip.Position = UDim2.new(1, -insets.right, 1, -bottomOffset)
	strip.Size = UDim2.fromOffset(Theme.space(6) * Balance.Player.quickSlots, Theme.space(6))
	strip.Parent = parent

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.Padding = UDim.new(0, Theme.space(0.5))
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Right
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = strip

	for index = 1, Balance.Player.quickSlots do
		local slot = Widgets.panel({
			name = "Slot" .. index,
			size = UDim2.fromOffset(Theme.space(5.5), Theme.space(5.5)),
			background = Theme.colour("surface"),
			transparency = 0.2,
			parent = strip,
		})
		slot.LayoutOrder = index

		local number = Widgets.label({
			text = tostring(index),
			size = "tiny",
			colour = Theme.colour("textFaint"),
			parent = slot,
			name = "Number",
		})
		number.Position = UDim2.fromOffset(Theme.space(0.4), Theme.space(0.2))

		local count = Widgets.label({
			text = "",
			size = "tiny",
			colour = Theme.colour("text"),
			align = Enum.TextXAlignment.Right,
			parent = slot,
			name = "Count",
		})
		count.Position = UDim2.new(1, -Theme.space(3.4), 1, -Theme.space(2))
		count.Size = UDim2.fromOffset(Theme.space(3), Theme.space(1.6))
		count.AutomaticSize = Enum.AutomaticSize.None

		table.insert(quickSlotFrames, slot)
	end
end

local function buildAmmo(parent: Instance)
	local insets = Theme.safeInsets()
	local panel = Widgets.panel({
		name = "Ammo",
		size = UDim2.fromOffset(Theme.space(14), Theme.space(5)),
		position = UDim2.new(1, -insets.right, 1, -insets.bottom - (if Theme.isTouch() then Theme.space(29) else Theme.space(7))),
		anchor = Vector2.new(1, 1),
		padding = 0.75,
		background = Theme.colour("backdrop"),
		transparency = 0.3,
		parent = parent,
	})
	panel.Visible = false
	ammoPanel = panel

	local label = Widgets.label({
		text = "",
		size = "title",
		font = Theme.Font.mono,
		align = Enum.TextXAlignment.Right,
		parent = panel,
	})
	label.Size = UDim2.fromScale(1, 1)
	label.AutomaticSize = Enum.AutomaticSize.None
	label.TextYAlignment = Enum.TextYAlignment.Center
	ammoLabel = label
end

local function buildCrosshair(parent: Instance)
	local frame = Instance.new("Frame")
	frame.Name = "Crosshair"
	frame.BackgroundTransparency = 1
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = UDim2.fromScale(0.5, 0.5)
	frame.Size = UDim2.fromOffset(Theme.space(3), Theme.space(3))
	frame.Visible = false
	frame.Parent = parent

	-- A four-tick reticle with a gap, which reads clearly against dark
	-- foliage without obscuring what is being aimed at.
	for _, spec in { { 0.5, 0.15, 0.08, 0.22 }, { 0.5, 0.85, 0.08, 0.22 }, { 0.15, 0.5, 0.22, 0.08 }, { 0.85, 0.5, 0.22, 0.08 } } do
		local tick = Instance.new("Frame")
		tick.BorderSizePixel = 0
		tick.BackgroundColor3 = Theme.colour("text")
		tick.BackgroundTransparency = 0.25
		tick.AnchorPoint = Vector2.new(0.5, 0.5)
		tick.Position = UDim2.fromScale(spec[1], spec[2])
		tick.Size = UDim2.fromScale(spec[3], spec[4])
		tick.Parent = frame
	end
	crosshair = frame
end

local function buildDowned(parent: Instance)
	local panel = Widgets.panel({
		name = "Downed",
		size = UDim2.fromOffset(Theme.space(40), Theme.space(16)),
		position = UDim2.fromScale(0.5, 0.72),
		anchor = Vector2.new(0.5, 0.5),
		padding = 1.5,
		background = Theme.colour("void"),
		transparency = 0.15,
		parent = parent,
	})
	panel.Visible = false
	downedPanel = panel

	local column = Widgets.column(panel, 0.75)

	Widgets.label({
		text = "You are down",
		size = "title",
		font = Theme.Font.display,
		colour = Theme.colour("signalRed"),
		align = Enum.TextXAlignment.Center,
		parent = column,
		layoutOrder = 1,
	})

	local text = Widgets.label({
		text = "Crawl to cover. A crew member can bring you back up.",
		size = "small",
		colour = Theme.colour("textMuted"),
		align = Enum.TextXAlignment.Center,
		parent = column,
		layoutOrder = 2,
	})
	downedText = text

	local track = Instance.new("Frame")
	track.Name = "BleedTrack"
	track.BorderSizePixel = 0
	track.BackgroundColor3 = Theme.colour("surface")
	track.Size = UDim2.new(1, 0, 0, Theme.space(1))
	track.LayoutOrder = 3
	Widgets.applyCorner(track, Theme.space(0.25))
	track.Parent = column

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.BorderSizePixel = 0
	fill.BackgroundColor3 = Theme.colour("signalRed")
	fill.Size = UDim2.fromScale(1, 1)
	Widgets.applyCorner(fill, Theme.space(0.25))
	fill.Parent = track
	downedRing = fill

	selfReviveButton = Widgets.button({
		text = "Emergency Stimulant",
		parent = column,
		layoutOrder = 4,
		enabled = false,
		onClick = function()
			Net.invokeServer("ReviveCommand", "buy_self")
			Net.fireServer("Analytics", "prompt_shown")
		end,
	})
	selfReviveButton.instance.Visible = false
end

local function buildDeparture(parent: Instance)
	-- Shown while a crew is counting down and while the server builds the
	-- expedition lane. Without it the player clicks Depart, the panel closes,
	-- and nothing visible happens for as long as the world takes to build,
	-- which reads as the game having hung.
	local panel = Widgets.panel({
		name = "Departure",
		size = UDim2.fromOffset(Theme.space(46), 0),
		position = UDim2.fromScale(0.5, 0.42),
		anchor = Vector2.new(0.5, 0.5),
		padding = 1.75,
		background = Theme.colour("void"),
		transparency = 0.12,
		parent = parent,
	})
	panel.AutomaticSize = Enum.AutomaticSize.Y
	panel.Visible = false
	departurePanel = panel

	local column = Widgets.column(panel, 0.75)

	departureTitle = Widgets.label({
		text = "Preparing the line",
		size = "title",
		font = Theme.Font.display,
		colour = Theme.colour("brass"),
		align = Enum.TextXAlignment.Center,
		parent = column,
		layoutOrder = 1,
	})

	departureDetail = Widgets.label({
		text = "",
		size = "small",
		colour = Theme.colour("textMuted"),
		align = Enum.TextXAlignment.Center,
		parent = column,
		layoutOrder = 2,
	})

	departureMeter = Widgets.meter(column, Theme.colour("brass"), Theme.space(1.25))
	departureMeter.instance.LayoutOrder = 3
end

local function buildNotifications(parent: Instance)
	local insets = Theme.safeInsets()
	local stack = Instance.new("Frame")
	stack.Name = "Notifications"
	stack.BackgroundTransparency = 1
	stack.AnchorPoint = Vector2.new(0.5, 0)
	stack.Position = UDim2.new(0.5, 0, 0, insets.top + Theme.space(1))
	stack.Size = UDim2.new(0, Theme.space(44), 0, 0)
	stack.AutomaticSize = Enum.AutomaticSize.Y
	stack.Parent = parent

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.Padding = UDim.new(0, Theme.space(0.5))
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = stack
	notificationStack = stack
end

local function buildCrewStrip(parent: Instance)
	local insets = Theme.safeInsets()
	local strip = Instance.new("Frame")
	strip.Name = "Crew"
	strip.BackgroundTransparency = 1
	strip.AnchorPoint = Vector2.new(0, 0.5)
	strip.Position = UDim2.new(0, insets.left, 0.5, 0)
	strip.Size = UDim2.fromOffset(Theme.space(20), Theme.space(24))
	strip.Parent = parent

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.Padding = UDim.new(0, Theme.space(0.5))
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = strip
	crewStrip = strip
end

--------------------------------------------------------------------------
-- Notifications
--------------------------------------------------------------------------

local KIND_COLOUR: { [string]: string } = {
	info = "cold",
	objective = "brass",
	warning = "signalAmber",
	error = "signalRed",
	achievement = "brass",
	event = "brass",
	announcement = "text",
	reward_ready = "signalGreen",
}

function HUDController.notify(payload: { [string]: any })
	local stack = notificationStack
	if not stack or payload.silent then
		return
	end

	local accent = Theme.colour(KIND_COLOUR[tostring(payload.kind)] or "text")
	local card = Widgets.panel({
		name = "Notification",
		size = UDim2.new(1, 0, 0, 0),
		padding = 1,
		background = Theme.colour("backdrop"),
		transparency = 0.1,
		parent = stack,
	})
	card.AutomaticSize = Enum.AutomaticSize.Y

	local bar = Instance.new("Frame")
	bar.Name = "Accent"
	bar.BorderSizePixel = 0
	bar.BackgroundColor3 = accent
	bar.Size = UDim2.new(0, 3, 1, 0)
	bar.Parent = card

	local column = Widgets.column(card, 0.25)
	column.Position = UDim2.fromOffset(Theme.space(1), 0)
	column.Size = UDim2.new(1, -Theme.space(1), 0, 0)

	Widgets.label({
		text = tostring(payload.title or ""),
		size = "body",
		font = Theme.Font.heading,
		colour = accent,
		parent = column,
		layoutOrder = 1,
	})
	if payload.body then
		Widgets.label({
			text = tostring(payload.body),
			size = "small",
			colour = Theme.colour("textMuted"),
			parent = column,
			layoutOrder = 2,
		})
	end

	local duration = tonumber(payload.duration) or 5
	task.delay(duration, function()
		if card.Parent then
			Widgets.fade(card, 1, 0.4)
			task.delay(0.5, function()
				card:Destroy()
			end)
		end
	end)

	-- The stack is capped, so a burst of events cannot fill the screen.
	local children = {}
	for _, child in stack:GetChildren() do
		if child:IsA("Frame") then
			table.insert(children, child)
		end
	end
	while #children > 4 do
		local oldest = table.remove(children, 1)
		if oldest then
			oldest:Destroy()
		end
	end
end

--------------------------------------------------------------------------
-- Refresh
--------------------------------------------------------------------------

local function refreshVitals()
	local vitals = StateController.get("vitals")
	local panel = vitalsPanel
	if not panel then
		return
	end
	if not vitals then
		panel.Visible = false
		return
	end
	panel.Visible = true

	local health = (vitals.health or 0) / math.max(1, vitals.maxHealth or 1)
	local stamina = (vitals.stamina or 0) / math.max(1, vitals.maxStamina or 1)
	local lamp = (vitals.flashlight or 0) / math.max(1, vitals.maxFlashlight or 1)

	healthMeter.set(health, string.format("Health  %d", math.ceil(vitals.health or 0)))
	staminaMeter.set(stamina, if vitals.exhausted then "Exhausted" else "Stamina")
	lampMeter.set(lamp, if vitals.flashlightOn then "Lamp" else "Lamp off")

	-- Colour carries the warning as well as the length, for players who
	-- cannot easily judge a short bar.
	healthMeter.setColour(if health < 0.3 then Theme.colour("signalRed") else Theme.colour("health"))
	lampMeter.setColour(
		if lamp * 100 <= Balance.Flashlight.criticalCharge
			then Theme.colour("signalRed")
			elseif lamp * 100 <= Balance.Flashlight.lowChargeWarning then Theme.colour("signalAmber")
			else Theme.colour("flashlight")
	)
end

local function refreshObjective()
	local expedition = StateController.get("expedition")
	local panel = objectivePanel
	if not panel then
		return
	end
	if not expedition or not expedition.objectives or #expedition.objectives == 0 then
		panel.Visible = false
		return
	end

	-- The first incomplete required objective is the one shown. Optional
	-- objectives never take the corner slot.
	local current: any = nil
	for _, objective in expedition.objectives do
		if not objective.complete and not objective.optional then
			current = objective
			break
		end
	end
	if not current then
		for _, objective in expedition.objectives do
			if not objective.complete then
				current = objective
				break
			end
		end
	end
	if not current then
		panel.Visible = false
		return
	end

	panel.Visible = true
	if objectiveTitle then
		objectiveTitle.Text = tostring(expedition.stationName or "") .. " - " .. tostring(current.title)
	end
	if objectiveDetail then
		objectiveDetail.Text = tostring(current.stepText or current.detail or "")
	end
	if objectiveProgress then
		if current.target and current.target > 1 then
			objectiveProgress.Text = string.format("%d of %d", current.progress or 0, current.target)
			objectiveProgress.Visible = true
		elseif current.stepProgress and current.stepProgress > 0 then
			objectiveProgress.Text = Format.percent(current.stepProgress)
			objectiveProgress.Visible = true
		else
			objectiveProgress.Visible = false
		end
	end
end

local function refreshTrain()
	local trainState = StateController.get("train")
	local panel = trainPanel
	if not panel then
		return
	end
	if not trainState or not StateController.isOnExpedition() then
		panel.Visible = false
		return
	end
	panel.Visible = true
	if speedLabel then
		speedLabel.Text = Format.speedKph(trainState.speed or 0) .. " km/h"
	end
	local fuel = (trainState.fuel or 0) / math.max(1, trainState.maxFuel or 1)
	local condition = (trainState.condition or 0) / math.max(1, trainState.maxCondition or 1)
	fuelMeter.set(fuel, "Fuel")
	conditionMeter.set(condition, "Condition")
	fuelMeter.setColour(if fuel < 0.2 then Theme.colour("signalRed") else Theme.colour("fuel"))
	conditionMeter.setColour(if condition < 0.4 then Theme.colour("signalAmber") else Theme.colour("condition"))
end

local function refreshQuickSlots()
	local inventory = StateController.get("inventory")
	for index, slot in quickSlotFrames do
		local count = slot:FindFirstChild("Count") :: TextLabel?
		local existingIcon = slot:FindFirstChild("Glyph")
		if existingIcon then
			existingIcon:Destroy()
		end

		local itemId = if inventory and inventory.quickSlots then inventory.quickSlots[index] else nil
		if type(itemId) == "string" then
			local def = ItemRegistry.getOrFallback(itemId)
			local icon = Widgets.icon(slot, def.icon or "box", Theme.space(3), Theme.colour("text"))
			icon.Name = "Glyph"
			icon.AnchorPoint = Vector2.new(0.5, 0.5)
			icon.Position = UDim2.fromScale(0.5, 0.45)

			local quantity = 0
			if inventory and inventory.stacks then
				for _, stack in inventory.stacks do
					if stack.id == itemId then
						quantity += stack.quantity
					end
				end
			end
			if count then
				count.Text = if quantity > 1 then tostring(quantity) else ""
			end
			slot.BackgroundTransparency = 0.1
		else
			if count then
				count.Text = ""
			end
			slot.BackgroundTransparency = 0.45
		end
	end
end

local function refreshWeapon()
	local weapon = StateController.get("weapon")
	local panel = ammoPanel
	local reticle = crosshair
	if not panel or not reticle then
		return
	end
	if not weapon or not weapon.equipped then
		panel.Visible = false
		reticle.Visible = false
		InputController.setTouchVisible("fire", false)
		InputController.setTouchVisible("reload", false)
		return
	end

	InputController.setTouchVisible("fire", true)
	reticle.Visible = StateController.isOnExpedition() and not StateController.isDowned()

	if weapon.magazineSize then
		panel.Visible = true
		InputController.setTouchVisible("reload", true)
		if ammoLabel then
			if weapon.reloading then
				ammoLabel.Text = "reloading"
				ammoLabel.TextColor3 = Theme.colour("signalAmber")
			else
				ammoLabel.Text = string.format("%d / %d", weapon.magazine or 0, weapon.reserve or 0)
				ammoLabel.TextColor3 = if (weapon.magazine or 0) == 0 then Theme.colour("signalRed") else Theme.colour("text")
			end
		end
	else
		panel.Visible = false
		InputController.setTouchVisible("reload", false)
	end
end

local function refreshDowned()
	local vitals = StateController.get("vitals")
	local panel = downedPanel
	if not panel then
		return
	end
	if not vitals or vitals.state ~= "downed" then
		panel.Visible = false
		return
	end

	panel.Visible = true
	local remaining = vitals.bleedoutRemaining or 0
	local total = math.max(1, vitals.bleedoutTotal or 1)
	if downedRing then
		downedRing.Size = UDim2.fromScale(math.clamp(remaining / total, 0, 1), 1)
	end
	if downedText then
		if vitals.reviverUserId then
			downedText.Text = string.format("Being helped up. %s", Format.percent(vitals.reviveProgress or 0))
		else
			downedText.Text = string.format("Crawl to cover. %s until you bleed out.", Format.clock(remaining))
		end
	end

	-- The paid self-revive is only ever shown when the server says it is
	-- available, which excludes the case where somebody is already reviving.
	if selfReviveButton then
		local offered = vitals.selfReviveOffered == true
		selfReviveButton.instance.Visible = offered
		selfReviveButton.setEnabled(offered)
		if (vitals.bankedSelfRevives or 0) > 0 then
			selfReviveButton.setText("Use Emergency Stimulant")
		else
			selfReviveButton.setText("Emergency Stimulant")
		end
	end
end

local function refreshDeparture()
	local panel = departurePanel
	if not panel then
		return
	end

	local expedition = StateController.get("expedition")
	local crew = StateController.get("crew")

	-- The lane is being built. This is the long one, so it gets the bar.
	if expedition and expedition.state == "preparing" then
		panel.Visible = true
		if departureTitle then
			departureTitle.Text = "Preparing the line"
		end
		if departureDetail then
			departureDetail.Text = tostring(expedition.label or "Claiming the line")
		end
		if departureMeter then
			departureMeter.set(tonumber(expedition.progress) or 0)
		end
		return
	end

	-- The crew countdown, which is the other moment a player is waiting.
	if crew and crew.state == "departing" and crew.countdownEndsAt then
		local remaining = math.max(0, (crew.countdownEndsAt :: number) - os.time())
		panel.Visible = true
		if departureTitle then
			departureTitle.Text = string.format("Departing in %d", math.ceil(remaining))
		end
		if departureDetail then
			departureDetail.Text = "Board the train. The leader can still cancel."
		end
		if departureMeter then
			departureMeter.set(1 - math.clamp(remaining / 10, 0, 1))
		end
		return
	end

	panel.Visible = false
end

local function refreshCrew()
	local strip = crewStrip
	local crew = StateController.get("crew")
	if not strip then
		return
	end
	strip:ClearAllChildren()
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.Padding = UDim.new(0, Theme.space(0.5))
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = strip

	if not crew or not crew.members or not StateController.isOnExpedition() then
		strip.Visible = false
		return
	end
	strip.Visible = #crew.members > 1

	for index, member in crew.members do
		local card = Widgets.panel({
			name = "Member",
			size = UDim2.new(1, 0, 0, Theme.space(3.5)),
			padding = 0.5,
			background = Theme.colour("backdrop"),
			transparency = 0.35,
			stroke = false,
			parent = strip,
		})
		card.LayoutOrder = index

		local name = Widgets.label({
			text = tostring(member.displayName),
			size = "small",
			colour = if member.connected then Theme.colour("text") else Theme.colour("textFaint"),
			parent = card,
		})
		name.Size = UDim2.new(1, 0, 1, 0)
		name.AutomaticSize = Enum.AutomaticSize.None
		name.TextYAlignment = Enum.TextYAlignment.Center
		name.TextTruncate = Enum.TextTruncate.AtEnd

		if not member.connected then
			Widgets.caption(card, "reconnecting")
		end
	end
end

--------------------------------------------------------------------------

local function setVisible(visible: boolean)
	local frame = root
	if frame then
		frame.Visible = visible
	end
end

function HUDController.setVisible(visible: boolean)
	setVisible(visible)
end

function HUDController.start()
	local playerGui = player:WaitForChild("PlayerGui")
	local screen = Widgets.screen("LastSignalHUD", Theme.Layer.hud, playerGui)
	gui = screen

	local frame = Instance.new("Frame")
	frame.Name = "Root"
	frame.BackgroundTransparency = 1
	frame.Size = UDim2.fromScale(1, 1)
	frame.Parent = screen
	root = frame

	buildVitals(frame)
	buildObjective(frame)
	buildTrain(frame)
	buildQuickSlots(frame)
	buildAmmo(frame)
	buildCrosshair(frame)
	buildDowned(frame)
	buildDeparture(frame)
	buildNotifications(frame)
	buildCrewStrip(frame)

	Net.onClientEvent("Notify", function(payload)
		if type(payload) == "table" then
			HUDController.notify(payload)
		end
	end)

	Net.onClientEvent("RewardGranted", function(payload)
		if type(payload) ~= "table" then
			return
		end
		local parts = {}
		if (payload.credits or 0) ~= 0 then
			table.insert(parts, string.format("%+d credits", payload.credits))
		end
		if (payload.xp or 0) > 0 then
			table.insert(parts, string.format("%+d XP", payload.xp))
		end
		if #parts == 0 and #(payload.unlocked or {}) == 0 then
			return
		end
		local body = table.concat(parts, "   ")
		if payload.multiplierReasons and #payload.multiplierReasons > 0 then
			body = body .. "\n" .. table.concat(payload.multiplierReasons, ", ")
		end
		HUDController.notify({
			kind = "objective",
			title = if (payload.levelsGained or 0) > 0 then string.format("Level %d", payload.level) else "Rewarded",
			body = body,
			duration = 5,
		})
	end)

	StateController.Changed:Connect(function(key)
		if key == "vitals" then
			refreshVitals()
			refreshDowned()
		elseif key == "expedition" then
			refreshObjective()
			refreshTrain()
			refreshCrew()
			refreshDeparture()
		elseif key == "train" then
			refreshTrain()
		elseif key == "inventory" then
			refreshQuickSlots()
		elseif key == "weapon" then
			refreshWeapon()
		elseif key == "crew" then
			refreshCrew()
			refreshDeparture()
		elseif key == "ui" then
			-- The HUD hides whenever a full panel or the cinematic is showing,
			-- so there is never a second layer of interface behind a menu.
			setVisible(StateController.ui("openPanel") == nil and not StateController.ui("cinematic"))
		end
	end)

	-- A slow tick keeps the bleedout clock and the speed readout live without
	-- needing a network update for every frame.
	task.spawn(function()
		while true do
			task.wait(0.1)
			if StateController.isDowned() then
				refreshDowned()
			end
			refreshDeparture()
		end
	end)

	refreshVitals()
	refreshObjective()
	refreshTrain()
	refreshQuickSlots()
	refreshWeapon()
	refreshCrew()
	refreshDeparture()

	log.info("started")
end

return HUDController
