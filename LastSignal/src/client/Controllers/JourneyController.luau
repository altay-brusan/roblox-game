--!strict
--[[
	JourneyController
	-----------------
	The route decision at Tolbridge: a small card with the two routes and what
	each costs. Any crew member can choose; the first choice sets the points
	for everyone, and leaving the station without choosing takes the main line.
	It never blocks play: the card sits at the side and the station work goes
	on around it.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("LastSignal")

local Logger = require(Shared.Core.Logger)
local Net = require(Shared.Core.Net)

local Theme = require(script.Parent.Parent.UI.Theme)
local Widgets = require(script.Parent.Parent.UI.Widgets)

local log = Logger.new("JourneyController")
local JourneyController = {}

local card: ScreenGui? = nil

local function close()
	if card then
		card:Destroy()
		card = nil
	end
end

local function show(payload: any)
	close()
	local gui = Widgets.screen("JourneyChoice", 30, Players.LocalPlayer:WaitForChild("PlayerGui"))
	card = gui
	local panel = Widgets.panel({
		name = "Card",
		size = UDim2.new(0, 340, 0, 0),
		position = UDim2.new(1, -16, 0.5, 0),
		anchor = Vector2.new(1, 0.5),
		padding = 1.0,
		background = Theme.colour("surface"),
		parent = gui,
	})
	panel.AutomaticSize = Enum.AutomaticSize.Y
	local column = Widgets.column(panel, 0.5)
	Widgets.label({ text = tostring(payload.title), size = "heading", font = Theme.Font.heading, parent = column, layoutOrder = 1 })
	Widgets.caption(column, tostring(payload.body), 2)
	for i, option in payload.options or {} do
		Widgets.button({
			text = tostring(option.name),
			subtitle = tostring(option.summary),
			primary = i == 1,
			parent = column,
			layoutOrder = 2 + i,
			onClick = function()
				Net.invokeServer("JourneyCommand", "choose", payload.id, option.id)
			end,
		})
	end
end

function JourneyController.start()
	Net.onClientEvent("JourneyChoice", function(payload)
		if type(payload) ~= "table" then
			return
		end
		if payload.closed then
			close()
		elseif type(payload.options) == "table" then
			show(payload)
		end
	end)
	log.info("started")
end

return JourneyController
