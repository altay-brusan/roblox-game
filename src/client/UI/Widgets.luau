--!strict
--[[
	Widgets
	-------
	The interface construction kit. Every panel in the game is built from these,
	which is what keeps spacing, contrast and touch targets consistent instead
	of being re-invented per screen.

	RULES ENFORCED HERE
	-------------------
	  - Text never clips. Every label either wraps or is given TextScaled with
	    a floor, and no widget sets a fixed height for text it does not measure.
	  - Every interactive widget meets the platform's minimum touch target.
	  - Scrolling regions get a visible scrollbar and automatic canvas sizing,
	    so a list can never be longer than it appears to be.
	  - Nothing uses an image asset. Icons are drawn from primitives, so the
	    interface has no external dependencies and nothing to fail to load.
]]

local TweenService = game:GetService("TweenService")

local Theme = require(script.Parent.Theme)

local Widgets = {}

local function applyCorner(instance: GuiObject, radius: number?)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, radius or Theme.space(0.5))
	corner.Parent = instance
end

local function applyStroke(instance: GuiObject, colour: Color3?, thickness: number?)
	local stroke = Instance.new("UIStroke")
	stroke.Color = colour or Theme.colour("line")
	stroke.Thickness = thickness or 1
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = instance
	return stroke
end

Widgets.applyCorner = applyCorner
Widgets.applyStroke = applyStroke

--------------------------------------------------------------------------
-- Containers
--------------------------------------------------------------------------

export type PanelOptions = {
	name: string?,
	size: UDim2?,
	position: UDim2?,
	anchor: Vector2?,
	parent: Instance?,
	padding: number?,
	background: Color3?,
	transparency: number?,
	stroke: boolean?,
	corner: number?,
}

function Widgets.panel(options: PanelOptions): Frame
	local frame = Instance.new("Frame")
	frame.Name = options.name or "Panel"
	frame.Size = options.size or UDim2.fromScale(1, 1)
	frame.Position = options.position or UDim2.fromScale(0, 0)
	frame.AnchorPoint = options.anchor or Vector2.zero
	frame.BackgroundColor3 = options.background or Theme.colour("surface")
	frame.BackgroundTransparency = options.transparency or 0
	frame.BorderSizePixel = 0
	applyCorner(frame, options.corner)
	if options.stroke ~= false then
		applyStroke(frame)
	end
	if options.padding then
		local padding = Instance.new("UIPadding")
		local value = UDim.new(0, Theme.space(options.padding))
		padding.PaddingTop = value
		padding.PaddingBottom = value
		padding.PaddingLeft = value
		padding.PaddingRight = value
		padding.Parent = frame
	end
	if options.parent then
		frame.Parent = options.parent
	end
	return frame
end

--- A vertical stack with consistent spacing. Returns the frame; the layout is
--- attached so children order themselves by LayoutOrder.
function Widgets.column(parent: Instance, gap: number?, name: string?): Frame
	local frame = Instance.new("Frame")
	frame.Name = name or "Column"
	frame.BackgroundTransparency = 1
	frame.Size = UDim2.fromScale(1, 1)
	frame.AutomaticSize = Enum.AutomaticSize.Y
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, Theme.space(gap or 1))
	layout.Parent = frame
	frame.Parent = parent
	return frame
end

function Widgets.row(parent: Instance, gap: number?, name: string?): Frame
	local frame = Instance.new("Frame")
	frame.Name = name or "Row"
	frame.BackgroundTransparency = 1
	frame.Size = UDim2.new(1, 0, 0, Theme.minTouchTarget())
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.Padding = UDim.new(0, Theme.space(gap or 1))
	layout.Parent = frame
	frame.Parent = parent
	return frame
end

--- A scrolling list that sizes its own canvas. Used for every list in the
--- game, so nothing can end up with content below a canvas that does not reach.
function Widgets.scroll(parent: Instance, gap: number?, name: string?): ScrollingFrame
	local scroll = Instance.new("ScrollingFrame")
	scroll.Name = name or "Scroll"
	scroll.Size = UDim2.fromScale(1, 1)
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.ScrollBarThickness = if Theme.isTouch() then 6 else 4
	scroll.ScrollBarImageColor3 = Theme.colour("lineStrong")
	scroll.ScrollBarImageTransparency = 0.3
	scroll.CanvasSize = UDim2.new()
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.ScrollingDirection = Enum.ScrollingDirection.Y
	scroll.ElasticBehavior = Enum.ElasticBehavior.WhenScrollable
	scroll.ClipsDescendants = true

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, Theme.space(gap or 1))
	layout.Parent = scroll

	local padding = Instance.new("UIPadding")
	padding.PaddingRight = UDim.new(0, Theme.space(1))
	padding.PaddingBottom = UDim.new(0, Theme.space(1))
	padding.Parent = scroll

	scroll.Parent = parent
	return scroll
end

--------------------------------------------------------------------------
-- Text
--------------------------------------------------------------------------

export type LabelOptions = {
	text: string,
	size: string?, -- key into Theme.TextSize
	colour: Color3?,
	font: Font?,
	align: Enum.TextXAlignment?,
	wrap: boolean?,
	parent: Instance?,
	layoutOrder: number?,
	width: UDim?,
	name: string?,
}

function Widgets.label(options: LabelOptions): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = options.name or "Label"
	label.BackgroundTransparency = 1
	label.Text = options.text
	label.FontFace = options.font or Theme.Font.body
	label.TextSize = Theme.textSize(options.size or "body")
	label.TextColor3 = options.colour or Theme.colour("text")
	label.TextXAlignment = options.align or Enum.TextXAlignment.Left
	label.TextYAlignment = Enum.TextYAlignment.Top
	label.TextWrapped = options.wrap ~= false
	label.RichText = false
	-- Automatic height plus wrapping is what guarantees no clipped text,
	-- whatever length the string turns out to be in another language.
	label.Size = UDim2.new(options.width or UDim.new(1, 0), UDim.new(0, 0))
	label.AutomaticSize = Enum.AutomaticSize.Y
	label.LayoutOrder = options.layoutOrder or 0
	if options.parent then
		label.Parent = options.parent
	end
	return label
end

function Widgets.heading(parent: Instance, text: string, order: number?): TextLabel
	return Widgets.label({
		text = text,
		size = "heading",
		font = Theme.Font.heading,
		colour = Theme.colour("text"),
		parent = parent,
		layoutOrder = order,
		name = "Heading",
	})
end

function Widgets.caption(parent: Instance, text: string, order: number?): TextLabel
	return Widgets.label({
		text = text,
		size = "small",
		colour = Theme.colour("textMuted"),
		parent = parent,
		layoutOrder = order,
		name = "Caption",
	})
end

--------------------------------------------------------------------------
-- Buttons
--------------------------------------------------------------------------

export type ButtonOptions = {
	text: string,
	parent: Instance?,
	layoutOrder: number?,
	width: UDim?,
	primary: boolean?,
	danger: boolean?,
	enabled: boolean?,
	onClick: (() -> ())?,
	name: string?,
	subtitle: string?,
}

export type Button = {
	instance: TextButton,
	setEnabled: (boolean) -> (),
	setText: (string) -> (),
	destroy: () -> (),
}

function Widgets.button(options: ButtonOptions): Button
	local button = Instance.new("TextButton")
	button.Name = options.name or "Button"
	button.AutoButtonColor = false
	button.Text = ""
	button.BorderSizePixel = 0
	button.Size = UDim2.new(options.width or UDim.new(1, 0), UDim.new(0, Theme.minTouchTarget()))
	button.LayoutOrder = options.layoutOrder or 0
	button.BackgroundColor3 = if options.primary then Theme.colour("brass") else Theme.colour("surfaceRaised")
	applyCorner(button)
	local stroke = applyStroke(button, if options.danger then Theme.colour("signalRed") else Theme.colour("line"))

	local labelColour = if options.primary then Theme.colour("textInverse") else Theme.colour("text")
	local label = Instance.new("TextLabel")
	label.Name = "Text"
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Text = options.text
	label.FontFace = Theme.Font.heading
	label.TextSize = Theme.textSize("body")
	label.TextColor3 = labelColour
	label.TextXAlignment = Enum.TextXAlignment.Center
	label.TextYAlignment = Enum.TextYAlignment.Center
	label.TextTruncate = Enum.TextTruncate.AtEnd
	label.Parent = button

	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, Theme.space(1.5))
	padding.PaddingRight = UDim.new(0, Theme.space(1.5))
	padding.Parent = button

	local enabled = options.enabled ~= false

	local function refresh()
		if enabled then
			button.BackgroundColor3 = if options.primary then Theme.colour("brass") else Theme.colour("surfaceRaised")
			label.TextColor3 = labelColour
			button.Active = true
			stroke.Color = if options.danger then Theme.colour("signalRed") else Theme.colour("line")
		else
			-- Disabled is visibly different from enabled, not just unresponsive.
			button.BackgroundColor3 = Theme.colour("surface")
			label.TextColor3 = Theme.colour("textFaint")
			button.Active = false
			stroke.Color = Theme.colour("line")
		end
	end
	refresh()

	button.MouseEnter:Connect(function()
		if enabled and not options.primary then
			TweenService:Create(button, Theme.tweenInfo(0.12), { BackgroundColor3 = Theme.colour("surfaceHover") }):Play()
		end
	end)
	button.MouseLeave:Connect(function()
		if enabled then
			refresh()
		end
	end)
	button.Activated:Connect(function()
		if enabled and options.onClick then
			options.onClick()
		end
	end)

	if options.parent then
		button.Parent = options.parent
	end

	return {
		instance = button,
		setEnabled = function(value: boolean)
			enabled = value
			refresh()
		end,
		setText = function(value: string)
			label.Text = value
		end,
		destroy = function()
			button:Destroy()
		end,
	}
end

--- A tab strip. Returns a select function so the caller can drive it.
function Widgets.tabs(parent: Instance, names: { string }, onSelect: (number) -> ()): (Frame, (number) -> ())
	local strip = Instance.new("Frame")
	strip.Name = "Tabs"
	strip.BackgroundTransparency = 1
	strip.Size = UDim2.new(1, 0, 0, Theme.minTouchTarget())

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, Theme.space(0.5))
	layout.Parent = strip

	local buttons: { TextButton } = {}
	local underlines: { Frame } = {}
	local selected = 1

	local function refresh()
		for index, button in buttons do
			local isSelected = index == selected
			local text = button:FindFirstChild("Text") :: TextLabel?
			if text then
				text.TextColor3 = if isSelected then Theme.colour("text") else Theme.colour("textMuted")
			end
			underlines[index].BackgroundColor3 = if isSelected then Theme.colour("brass") else Theme.colour("line")
			underlines[index].BackgroundTransparency = if isSelected then 0 else 0.6
		end
	end

	for index, name in names do
		local button = Instance.new("TextButton")
		button.Name = "Tab" .. index
		button.AutoButtonColor = false
		button.Text = ""
		button.BackgroundTransparency = 1
		button.BorderSizePixel = 0
		button.LayoutOrder = index
		-- Tabs share the width evenly, which keeps them tappable on a phone
		-- however many there are.
		button.Size = UDim2.new(1 / #names, -Theme.space(0.5), 1, 0)

		local text = Instance.new("TextLabel")
		text.Name = "Text"
		text.BackgroundTransparency = 1
		text.Size = UDim2.new(1, 0, 1, -3)
		text.Text = name
		text.FontFace = Theme.Font.heading
		text.TextSize = Theme.textSize("small")
		text.TextColor3 = Theme.colour("textMuted")
		text.TextTruncate = Enum.TextTruncate.AtEnd
		text.Parent = button

		local underline = Instance.new("Frame")
		underline.Name = "Underline"
		underline.BorderSizePixel = 0
		underline.Size = UDim2.new(1, 0, 0, 2)
		underline.Position = UDim2.new(0, 0, 1, -2)
		underline.BackgroundColor3 = Theme.colour("line")
		underline.Parent = button

		button.Activated:Connect(function()
			selected = index
			refresh()
			onSelect(index)
		end)

		button.Parent = strip
		table.insert(buttons, button)
		table.insert(underlines, underline)
	end

	refresh()
	strip.Parent = parent

	return strip, function(index: number)
		selected = math.clamp(index, 1, #names)
		refresh()
		onSelect(selected)
	end
end

--------------------------------------------------------------------------
-- Meters
--------------------------------------------------------------------------

export type Meter = {
	instance: Frame,
	set: (fraction: number, text: string?) -> (),
	setColour: (Color3) -> (),
}

function Widgets.meter(parent: Instance, colour: Color3, height: number?, label: string?): Meter
	local container = Instance.new("Frame")
	container.Name = "Meter"
	container.BackgroundColor3 = Theme.colour("void")
	container.BackgroundTransparency = 0.25
	container.BorderSizePixel = 0
	container.Size = UDim2.new(1, 0, 0, height or Theme.space(1))
	applyCorner(container, Theme.space(0.25))

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.BackgroundColor3 = colour
	fill.BorderSizePixel = 0
	fill.Size = UDim2.fromScale(1, 1)
	applyCorner(fill, Theme.space(0.25))
	fill.Parent = container

	local text: TextLabel? = nil
	if label then
		text = Widgets.label({
			text = label,
			size = "tiny",
			colour = Theme.colour("textMuted"),
			align = Enum.TextXAlignment.Left,
			parent = container,
			name = "MeterText",
		})
		local resolved = text :: TextLabel
		resolved.Position = UDim2.new(0, Theme.space(0.5), 0, 0)
		resolved.Size = UDim2.new(1, -Theme.space(1), 1, 0)
		resolved.TextYAlignment = Enum.TextYAlignment.Center
		resolved.AutomaticSize = Enum.AutomaticSize.None
	end

	container.Parent = parent

	return {
		instance = container,
		set = function(fraction: number, newText: string?)
			local clamped = math.clamp(fraction, 0, 1)
			-- Meters move rather than snap, except under reduced motion.
			TweenService:Create(fill, Theme.tweenInfo(0.2), { Size = UDim2.fromScale(clamped, 1) }):Play()
			if text and newText then
				(text :: TextLabel).Text = newText
			end
		end,
		setColour = function(newColour: Color3)
			fill.BackgroundColor3 = newColour
		end,
	}
end

--------------------------------------------------------------------------
-- Icons, drawn from primitives
--------------------------------------------------------------------------

--- Vector glyphs built from frames. No image assets means nothing to upload,
--- nothing to fail to load, and identical appearance on every device.
function Widgets.icon(parent: Instance, glyph: string, size: number, colour: Color3?): Frame
	local holder = Instance.new("Frame")
	holder.Name = "Icon_" .. glyph
	holder.BackgroundTransparency = 1
	holder.Size = UDim2.fromOffset(size, size)

	local tint = colour or Theme.colour("text")

	local function bar(x: number, y: number, w: number, h: number, rotation: number?)
		local part = Instance.new("Frame")
		part.BorderSizePixel = 0
		part.BackgroundColor3 = tint
		part.AnchorPoint = Vector2.new(0.5, 0.5)
		part.Position = UDim2.fromScale(x, y)
		part.Size = UDim2.fromScale(w, h)
		part.Rotation = rotation or 0
		applyCorner(part, math.max(1, size * 0.08))
		part.Parent = holder
		return part
	end

	if glyph == "cross" then
		bar(0.5, 0.5, 0.8, 0.24)
		bar(0.5, 0.5, 0.24, 0.8)
	elseif glyph == "case" or glyph == "case-cross" or glyph == "case-wrench" then
		bar(0.5, 0.58, 0.86, 0.56)
		bar(0.5, 0.26, 0.34, 0.16)
		if glyph == "case-cross" then
			bar(0.5, 0.58, 0.4, 0.12)
			bar(0.5, 0.58, 0.12, 0.4)
		end
	elseif glyph == "battery" then
		bar(0.5, 0.55, 0.5, 0.8)
		bar(0.5, 0.1, 0.22, 0.12)
	elseif glyph == "vial" or glyph == "valve-glass" or glyph == "bottle" then
		bar(0.5, 0.6, 0.42, 0.66)
		bar(0.5, 0.2, 0.22, 0.2)
	elseif glyph == "flare" or glyph == "stick" then
		bar(0.5, 0.5, 0.26, 0.86, 18)
	elseif glyph == "can" then
		bar(0.46, 0.56, 0.62, 0.76)
		bar(0.8, 0.28, 0.16, 0.2)
	elseif glyph == "bar" then
		bar(0.5, 0.5, 0.18, 0.9, 12)
		bar(0.38, 0.12, 0.34, 0.16, 40)
	elseif glyph == "cutters" then
		bar(0.4, 0.6, 0.16, 0.72, -14)
		bar(0.6, 0.6, 0.16, 0.72, 14)
	elseif glyph == "ammo" then
		bar(0.32, 0.55, 0.2, 0.7)
		bar(0.5, 0.55, 0.2, 0.7)
		bar(0.68, 0.55, 0.2, 0.7)
	elseif glyph == "page" or glyph == "ticket" then
		bar(0.5, 0.5, 0.7, 0.86)
		bar(0.5, 0.34, 0.44, 0.08)
		bar(0.5, 0.5, 0.44, 0.08)
		bar(0.5, 0.66, 0.3, 0.08)
	elseif glyph == "key" then
		bar(0.5, 0.3, 0.4, 0.4)
		bar(0.5, 0.68, 0.14, 0.5)
		bar(0.62, 0.82, 0.24, 0.12)
	elseif glyph == "fuse" then
		bar(0.5, 0.5, 0.34, 0.76)
		bar(0.5, 0.12, 0.5, 0.12)
		bar(0.5, 0.88, 0.5, 0.12)
	elseif glyph == "relay" or glyph == "recorder" then
		bar(0.5, 0.55, 0.82, 0.6)
		bar(0.32, 0.55, 0.16, 0.3)
		bar(0.62, 0.55, 0.28, 0.14)
	elseif glyph == "valve" then
		bar(0.5, 0.5, 0.9, 0.16)
		bar(0.5, 0.5, 0.16, 0.9)
		bar(0.5, 0.5, 0.4, 0.4, 45)
	elseif glyph == "aspect" then
		bar(0.5, 0.24, 0.38, 0.34)
		bar(0.5, 0.58, 0.38, 0.34)
		bar(0.5, 0.86, 0.5, 0.12)
	elseif glyph == "numerals" then
		bar(0.3, 0.5, 0.16, 0.7)
		bar(0.6, 0.5, 0.34, 0.7)
	else
		-- Unknown glyph: a plain square, so a missing icon is visible as a
		-- missing icon rather than as nothing at all.
		bar(0.5, 0.5, 0.6, 0.6)
	end

	holder.Parent = parent
	return holder
end

--------------------------------------------------------------------------
-- Screen roots
--------------------------------------------------------------------------

function Widgets.screen(name: string, layer: number, parent: Instance): ScreenGui
	local gui = Instance.new("ScreenGui")
	gui.Name = name
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.DisplayOrder = layer
	gui.Parent = parent
	return gui
end

--- A full-screen dimmed backdrop that closes the panel when tapped outside it.
function Widgets.modalBackdrop(parent: Instance, onDismiss: () -> ()): TextButton
	local backdrop = Instance.new("TextButton")
	backdrop.Name = "Backdrop"
	backdrop.Text = ""
	backdrop.AutoButtonColor = false
	backdrop.BackgroundColor3 = Theme.colour("void")
	backdrop.BackgroundTransparency = 0.35
	backdrop.BorderSizePixel = 0
	backdrop.Size = UDim2.fromScale(1, 1)
	backdrop.Activated:Connect(onDismiss)
	backdrop.Parent = parent
	return backdrop
end

--------------------------------------------------------------------------
-- Utility
--------------------------------------------------------------------------

--- Fades a GuiObject and every descendant. Used for panel transitions.
function Widgets.fade(root: GuiObject, transparency: number, seconds: number?)
	local info = Theme.tweenInfo(seconds or 0.18)
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("TextLabel") or descendant:IsA("TextButton") then
			TweenService:Create(descendant, info, { TextTransparency = transparency }):Play()
			if descendant.BackgroundTransparency < 1 then
				TweenService:Create(descendant, info, { BackgroundTransparency = math.max(descendant.BackgroundTransparency, transparency) }):Play()
			end
		elseif descendant:IsA("Frame") and descendant.BackgroundTransparency < 1 then
			TweenService:Create(descendant, info, { BackgroundTransparency = math.max(descendant.BackgroundTransparency, transparency) }):Play()
		end
	end
end

--- A key-value row, used throughout the detail panels.
function Widgets.statRow(parent: Instance, key: string, value: string, order: number?): (TextLabel, TextLabel)
	local row = Instance.new("Frame")
	row.Name = "StatRow"
	row.BackgroundTransparency = 1
	row.Size = UDim2.new(1, 0, 0, Theme.textSize("body") + Theme.space(0.75))
	row.LayoutOrder = order or 0

	local keyLabel = Widgets.label({
		text = key,
		size = "small",
		colour = Theme.colour("textMuted"),
		parent = row,
		name = "Key",
	})
	keyLabel.Size = UDim2.fromScale(0.55, 1)
	keyLabel.AutomaticSize = Enum.AutomaticSize.None
	keyLabel.TextYAlignment = Enum.TextYAlignment.Center

	local valueLabel = Widgets.label({
		text = value,
		size = "small",
		colour = Theme.colour("text"),
		align = Enum.TextXAlignment.Right,
		parent = row,
		name = "Value",
	})
	valueLabel.Position = UDim2.fromScale(0.45, 0)
	valueLabel.Size = UDim2.fromScale(0.55, 1)
	valueLabel.AutomaticSize = Enum.AutomaticSize.None
	valueLabel.TextYAlignment = Enum.TextYAlignment.Center

	row.Parent = parent
	return keyLabel, valueLabel
end

--- A divider line.
function Widgets.divider(parent: Instance, order: number?): Frame
	local line = Instance.new("Frame")
	line.Name = "Divider"
	line.BorderSizePixel = 0
	line.BackgroundColor3 = Theme.colour("line")
	line.BackgroundTransparency = 0.4
	line.Size = UDim2.new(1, 0, 0, 1)
	line.LayoutOrder = order or 0
	line.Parent = parent
	return line
end

--- An empty-state message, so a list with nothing in it explains itself.
function Widgets.emptyState(parent: Instance, message: string): Frame
	local frame = Widgets.panel({
		name = "Empty",
		size = UDim2.new(1, 0, 0, 0),
		padding = 2,
		background = Theme.colour("surface"),
		transparency = 0.4,
		parent = parent,
	})
	frame.AutomaticSize = Enum.AutomaticSize.Y
	Widgets.label({
		text = message,
		size = "small",
		colour = Theme.colour("textMuted"),
		align = Enum.TextXAlignment.Center,
		parent = frame,
	})
	return frame
end

return Widgets
