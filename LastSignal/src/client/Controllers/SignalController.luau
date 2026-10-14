--!strict
--[[
	SignalController
	----------------
	The Signal Integrity Analyzer on screen: a dispatcher's instrument with a
	bearing dial and a waveform screen, and the crew's shared notebook of
	calls. Opened with V (or the right stick press).

	The analyzer only shows what the server has established from the crew's
	own evidence. It never knows the truth of a call, so it never says it.
	The movement keys keep working while it is open, because triangulation
	means walking between sweeps.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("LastSignal")

local Logger = require(Shared.Core.Logger)
local Net = require(Shared.Core.Net)

local InputController = require(script.Parent.InputController)
local Theme = require(script.Parent.Parent.UI.Theme)
local Widgets = require(script.Parent.Parent.UI.Widgets)

local log = Logger.new("SignalController")
local C = Color3.fromRGB
local player = Players.LocalPlayer

local SignalController = {}

local GREEN = C(120, 255, 160)
local DIM = C(40, 90, 60)
local LABEL_COLOURS: { [string]: Color3 } = {
	["Unverified"] = C(170, 170, 170),
	["Unknown"] = C(170, 170, 170),
	["Inconsistent"] = C(240, 190, 80),
	["Likely human"] = C(120, 220, 140),
	["Likely a recording"] = C(140, 180, 255),
	["Likely a mimic"] = C(255, 110, 90),
	["Likely an anomaly"] = C(200, 160, 255),
}

local gui: ScreenGui? = nil
local state: any = { calls = {}, fidelity = 1 }
local selected: string? = nil
local needle: Frame? = nil
local bars: { Frame } = {}
local lastBearing: number? = nil
local currentShape: string? = nil
local message = ""

local render: () -> ()

local function call(command: string, a: any?, b: any?): any
	local result = Net.invokeServer("SignalCommand", command, a, b)
	if type(result) == "table" and result.ok == false then
		local errors: { [string]: string } = {
			MOVE_FIRST = "Move at least a few studs before sweeping again.",
			RESOLVED = "That call is over.",
			NO_EXPEDITION = "No signals out here.",
		}
		message = errors[tostring(result.error)] or tostring(result.error)
	end
	return result
end

local function selectedCall(): any
	for _, c in state.calls or {} do
		if c.id == selected then
			return c
		end
	end
	return nil
end

local function cameraYaw(): number
	local camera = Workspace.CurrentCamera
	if not camera then
		return 0
	end
	local look = camera.CFrame.LookVector
	return math.deg(math.atan2(look.X, -look.Z))
end

local function close()
	if gui then
		gui:Destroy()
		gui = nil
	end
	needle = nil
	bars = {}
end

local function instrument(parent: Instance, c: any, order: number)
	local row = Instance.new("Frame")
	row.Name = "Instrument"
	row.BackgroundTransparency = 1
	row.Size = UDim2.new(1, 0, 0, 120)
	row.LayoutOrder = order
	row.Parent = parent

	-- The bearing dial. The needle points along the last sweep, turned to
	-- the player's own heading, so it shows which way to walk.
	local dial = Instance.new("Frame")
	dial.Name = "Dial"
	dial.Size = UDim2.fromOffset(110, 110)
	dial.Position = UDim2.fromOffset(4, 5)
	dial.BackgroundColor3 = C(8, 22, 14)
	dial.Parent = row
	local round = Instance.new("UICorner")
	round.CornerRadius = UDim.new(1, 0)
	round.Parent = dial
	local ring = Instance.new("UIStroke")
	ring.Color = DIM
	ring.Thickness = 2
	ring.Parent = dial
	for i = 0, 7 do
		local tick = Instance.new("Frame")
		tick.Size = UDim2.fromOffset(2, 8)
		tick.AnchorPoint = Vector2.new(0.5, 0.5)
		local a = math.rad(i * 45)
		tick.Position = UDim2.new(0.5, math.sin(a) * 48, 0.5, -math.cos(a) * 48)
		tick.Rotation = i * 45
		tick.BackgroundColor3 = DIM
		tick.BorderSizePixel = 0
		tick.Parent = dial
	end
	local n = Instance.new("Frame")
	n.Name = "Needle"
	n.AnchorPoint = Vector2.new(0.5, 1)
	n.Position = UDim2.fromScale(0.5, 0.5)
	n.Size = UDim2.fromOffset(3, 46)
	n.BackgroundColor3 = GREEN
	n.BorderSizePixel = 0
	n.Visible = #c.readings > 0
	n.Parent = dial
	needle = n
	local reading = c.readings[#c.readings]
	lastBearing = if reading then reading.bearing else nil
	local hub = Instance.new("TextLabel")
	hub.BackgroundTransparency = 1
	hub.Size = UDim2.fromScale(1, 0.3)
	hub.Position = UDim2.fromScale(0, 0.7)
	hub.Font = Enum.Font.Code
	hub.TextColor3 = GREEN
	hub.TextSize = 11
	hub.Text = if reading then string.format("%03d  %d%%", math.floor(reading.bearing), math.floor(reading.strength * 100)) else "NO FIX"
	hub.Parent = dial

	-- The waveform screen.
	local screen = Instance.new("Frame")
	screen.Name = "Waveform"
	screen.Size = UDim2.new(1, -128, 0, 110)
	screen.Position = UDim2.fromOffset(124, 5)
	screen.BackgroundColor3 = C(8, 22, 14)
	screen.ClipsDescendants = true
	screen.Parent = row
	local sc = Instance.new("UICorner")
	sc.CornerRadius = UDim.new(0, 6)
	sc.Parent = screen
	bars = {}
	for i = 1, 28 do
		local bar = Instance.new("Frame")
		bar.AnchorPoint = Vector2.new(0, 0.5)
		bar.Position = UDim2.new((i - 1) / 28, 1, 0.5, 0)
		bar.Size = UDim2.new(1 / 28, -2, 0, 2)
		bar.BackgroundColor3 = GREEN
		bar.BorderSizePixel = 0
		bar.Parent = screen
		table.insert(bars, bar)
	end
	currentShape = c.waveShape
	local caption = Instance.new("TextLabel")
	caption.BackgroundTransparency = 1
	caption.Size = UDim2.new(1, -8, 0, 14)
	caption.Position = UDim2.fromOffset(4, 2)
	caption.Font = Enum.Font.Code
	caption.TextSize = 11
	caption.TextXAlignment = Enum.TextXAlignment.Left
	caption.TextColor3 = DIM
	caption.Text = if currentShape then "SPECTRUM: " .. string.upper(currentShape) else "SPECTRUM: NOT ANALYSED"
	caption.Parent = screen
end

local function button(parent: Instance, text: string, order: number, onClick: () -> (), primary: boolean?, enabled: boolean?)
	Widgets.button({
		text = text,
		primary = primary,
		enabled = enabled ~= false,
		parent = parent,
		layoutOrder = order,
		fit = true,
		onClick = function()
			onClick()
			render()
		end,
	})
end

--- A column that is as tall as its contents (Widgets.column fills its parent).
local function column(parent: Instance, gap: number, order: number): Frame
	local c = Widgets.column(parent, gap)
	c.Size = UDim2.new(1, 0, 0, 0)
	c.AutomaticSize = Enum.AutomaticSize.Y
	c.LayoutOrder = order
	return c
end

function render()
	if not gui then
		return
	end
	local root = gui:FindFirstChild("Panel")
	if root then
		root:Destroy()
	end
	local panel = Widgets.panel({
		name = "Panel",
		size = UDim2.new(0, 400, 1, -140),
		position = UDim2.new(0, 16, 0, 70),
		padding = 0.8,
		background = C(14, 18, 16),
		parent = gui,
	})
	local scroll = Widgets.scroll(panel, 0.5)
	scroll.Size = UDim2.fromScale(1, 1)

	local top = Widgets.row(scroll, 0.5)
	top.LayoutOrder = 1
	Widgets.label({ text = "SIGNAL INTEGRITY ANALYZER", size = "small", font = Theme.Font.mono, colour = GREEN, parent = top, width = UDim.new(1, -70) })
	local closeButton = Widgets.button({ text = "Close", width = UDim.new(0, 64), parent = top, onClick = close })
	-- A modal button frees the mouse from first-person lock while open.
	closeButton.instance.Modal = true

	Widgets.caption(scroll, string.format("Fidelity %d of 2. %s", state.fidelity or 1, if (state.fidelity or 1) < 2 then "Five correct verdicts sharpen the bearing." else "Bearing at full resolution."), 2)

	local calls = state.calls or {}
	if #calls == 0 then
		Widgets.caption(scroll, "No signals logged. Calls arrive at stations; this notebook is shared with your crew.", 3)
		return
	end

	local tabs = column(scroll, 0.3, 3)
	for i, c in calls do
		local mark = if c.status == "live" then "LIVE" else "closed"
		button(tabs, string.format("%s   [%s]   %s", c.caller, mark, c.label), i, function()
			selected = c.id
		end, c.id == selected)
	end

	local c = selectedCall()
	if not c then
		Widgets.caption(scroll, "Select a call.", 4)
		return
	end

	Widgets.divider(scroll, 5)
	Widgets.label({ text = c.label, size = "heading", font = Theme.Font.heading, colour = LABEL_COLOURS[c.label] or GREEN, parent = scroll, layoutOrder = 6 })
	Widgets.label({ text = "\"" .. table.concat(c.transcript, " ") .. "\"", size = "small", wrap = true, colour = Theme.colour("textMuted"), parent = scroll, layoutOrder = 7 })
	Widgets.caption(scroll, "Claims to be at " .. tostring(c.claims) .. ".", 8)

	instrument(scroll, c, 9)
	if message ~= "" then
		Widgets.caption(scroll, message, 10)
	end

	local live = c.status == "live"
	if live then
		local channels = column(scroll, 0.3, 11)
		button(channels, if #c.readings == 0 then "Sweep for bearing here" else "Sweep again from a new spot", 1, function()
			message = ""
			local r = call("sweep", c.id)
			if type(r) == "table" and r.ok then
				message = if r.needsMore then "Bearing taken. Move well to one side and sweep again to triangulate." else "Source triangulated."
			end
		end)
		button(channels, "Analyse waveform", 2, function()
			call("waveform", c.id)
		end, false, not c.analysed.waveform)
		button(channels, "Check time, ID and kilometre post", 3, function()
			call("timing", c.id)
		end, false, not c.analysed.timing)
		for qi, q in c.questions do
			button(channels, "Ask: " .. q.ask, 3 + qi, function()
				call("challenge", c.id, qi)
			end, false, not q.asked)
		end
		local k = 10
		for _, other in calls do
			if other.id ~= c.id then
				k += 1
				button(channels, "Compare with: " .. other.caller, k, function()
					call("compare", c.id, other.id)
				end)
			end
		end
	end

	Widgets.label({ text = "Evidence", size = "small", font = Theme.Font.heading, parent = scroll, layoutOrder = 12 })
	if #c.evidence == 0 then
		Widgets.caption(scroll, "Nothing gathered yet. Sweep, analyse, ask, and examine the place the caller names.", 13)
	else
		local lines = {}
		for _, e in c.evidence do
			table.insert(lines, "• " .. e.text)
		end
		Widgets.label({ text = table.concat(lines, "\n"), size = "small", wrap = true, parent = scroll, layoutOrder = 13 })
	end

	if live then
		local verdicts = column(scroll, 0.3, 14)
		if c.verdict == "going" then
			Widgets.caption(verdicts, "Answering: go to the marked place the caller named.", 1)
		else
			button(verdicts, "Answer it: go to " .. tostring(c.claims), 1, function()
				call("verdict", c.id, "go")
			end, true)
		end
		button(verdicts, "Mark it as a mimic", 2, function()
			call("verdict", c.id, "mark")
		end)
		button(verdicts, "Leave it", 3, function()
			call("verdict", c.id, "leave")
		end)
	else
		Widgets.label({ text = tostring(c.outcome or ""), size = "small", wrap = true, colour = GREEN, parent = scroll, layoutOrder = 14 })
	end
end

local function open()
	local playerGui = player:FindFirstChildOfClass("PlayerGui")
	if not playerGui then
		return
	end
	gui = Widgets.screen("SignalAnalyzer", 25, playerGui)
	message = ""
	local result = Net.invokeServer("SignalCommand", "state")
	if type(result) == "table" and result.ok then
		state = result.state
	end
	if not selected and state.calls and #state.calls > 0 then
		selected = state.calls[#state.calls].id
	end
	render()
end

function SignalController.start()
	InputController.Action:Connect(function(actionId, pressed)
		if actionId ~= "analyzer" or not pressed then
			return
		end
		if gui then
			close()
		else
			open()
		end
	end)

	Net.onClientEvent("SignalState", function(payload)
		if type(payload) ~= "table" then
			return
		end
		state = payload
		if not selected and #(payload.calls or {}) > 0 then
			selected = payload.calls[#payload.calls].id
		end
		if gui then
			render()
		end
	end)

	-- The dial and the screen are alive while the analyzer is open.
	RunService.RenderStepped:Connect(function()
		if not gui then
			return
		end
		local n = needle
		if n and lastBearing then
			n.Rotation = lastBearing - cameraYaw()
		end
		local t = os.clock()
		for i, bar in bars do
			local h = 2
			local shape = currentShape
			if shape == "clean" then
				h = 10 + math.abs(math.sin(t * 3 + i * 0.5)) * 40 * (0.6 + 0.4 * math.noise(i * 0.3, t))
			elseif shape == "loop" then
				-- The same pattern, exactly, over and over.
				h = 10 + math.abs(math.sin((i % 7) * 0.9 + math.floor(t * 2) * 0)) * 45
			elseif shape == "phase" then
				h = 10 + math.abs(math.sin(t * 3 - i * 0.5)) * 40 * (if i % 2 == 0 then 1 else 0.3)
			elseif shape == "noise" then
				h = 4 + math.random() * 60
			elseif shape == "mechanical" then
				h = if math.floor(t * 2 + i / 4) % 2 == 0 then 50 else 6
			end
			bar.Size = UDim2.new(1 / 28, -2, 0, h)
		end
	end)

	log.info("started")
end

return SignalController
