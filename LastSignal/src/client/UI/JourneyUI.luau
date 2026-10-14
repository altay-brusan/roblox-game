--!strict
--[[
	JourneyUI
	---------
	Night runs on screen: the choice between the story and a night run on the
	crew panel, and the night-run report on the results screen.

	The crew panel says plainly what a night run is: the same line and
	stations as the story, with seeded emergencies and a route decision, for
	playing again. Tiers show what they change and what unlocks them.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("LastSignal")

local JourneyRegistry = require(Shared.Registry.JourneyRegistry)
local Net = require(Shared.Core.Net)

local Theme = require(script.Parent.Theme)
local Widgets = require(script.Parent.Widgets)

local JourneyUI = {}

--- The Journey section at the top of the crew panel.
function JourneyUI.crewSection(parent: Instance, order: number, rebuild: () -> ())
	local info = Net.invokeServer("JourneyCommand", "get")
	if type(info) ~= "table" or not info.ok then
		Widgets.caption(parent, "Night runs are unavailable right now. The story is unaffected.", order)
		return
	end
	local panel = Widgets.panel({
		name = "Journey",
		size = UDim2.new(1, 0, 0, 0),
		padding = 1.0,
		background = Theme.colour("surface"),
		parent = parent,
	})
	panel.AutomaticSize = Enum.AutomaticSize.Y
	panel.LayoutOrder = order
	local column = Widgets.column(panel, 0.5)
	local prefs = info.prefs
	local nightrun = prefs.mode == "nightrun"

	Widgets.label({ text = "Journey", size = "heading", font = Theme.Font.heading, parent = column, layoutOrder = 1 })
	local row = Widgets.row(column, 0.5)
	row.LayoutOrder = 2
	for _, mode in { { id = "story", text = "Story" }, { id = "nightrun", text = "Night run" } } do
		Widgets.button({
			text = mode.text,
			primary = prefs.mode == mode.id,
			width = UDim.new(0.5, -4),
			parent = row,
			onClick = function()
				Net.invokeServer("JourneyCommand", "set", "mode", mode.id)
				rebuild()
			end,
		})
	end
	Widgets.caption(
		column,
		if nightrun
			then "Night run: the same line and stations as the story, with a seeded set of emergencies on the way and a route decision at Tolbridge. Built for playing again."
			else "Story: Chapter One as written. Start here.",
		3
	)
	if not nightrun then
		return
	end

	for i, tier in info.tiers do
		local selected = prefs.tier == tier.id
		Widgets.button({
			text = if tier.unlocked
				then tier.name .. (if tier.streak and tier.streak > 0 then string.format("  (night %d, best %d)", math.min(tier.streak, 4) + 1, tier.best or 0) else "") .. (if selected then "  (selected)" else "")
				elseif tier.requiresStory then tier.name .. "  (reach the end of the story)"
				else tier.name .. string.format("  (after %d night runs)", tier.unlockAfter),
			primary = selected,
			enabled = tier.unlocked,
			subtitle = tier.summary,
			parent = column,
			layoutOrder = 3 + i,
			onClick = function()
				Net.invokeServer("JourneyCommand", "set", "tier", tier.id)
				rebuild()
			end,
		})
	end

	local seedRow = Widgets.row(column, 0.5)
	seedRow.LayoutOrder = 10
	Widgets.button({
		text = if prefs.seed then "Seed " .. tostring(prefs.seed) else "Random seed",
		primary = prefs.seed == nil,
		width = UDim.new(0.5, -4),
		parent = seedRow,
		onClick = function()
			Net.invokeServer("JourneyCommand", "set", "seed", nil)
			rebuild()
		end,
	})
	if info.lastSeed then
		Widgets.button({
			text = "Replay last seed (" .. tostring(info.lastSeed) .. ")",
			width = UDim.new(0.5, -4),
			parent = seedRow,
			onClick = function()
				Net.invokeServer("JourneyCommand", "set", "seed", info.lastSeed)
				rebuild()
			end,
		})
	end

	local earned = {}
	for _, unlock in JourneyRegistry.Unlocks do
		table.insert(earned, string.format("%s %s (%d)", if (info.completed or 0) >= unlock.after then "[x]" else "[ ]", unlock.name, unlock.after))
	end
	Widgets.caption(
		column,
		string.format("Night runs completed: %d. Earned by playing, never sold: %s.", info.completed or 0, table.concat(earned, ", ")),
		11
	)
	if not info.saved then
		Widgets.caption(column, "Your progress cannot be saved this session. Night runs still play.", 12)
	end
end

--- The night-run block on the results screen.
function JourneyUI.results(parent: Instance, order: number, journey: any)
	if type(journey) == "table" and journey.endlessUnlocked then
		Widgets.caption(parent, "The line does not end at Ward Hill. Endless Railway is open: Night run, on the crew panel.", order)
		return
	end
	if type(journey) ~= "table" or journey.mode ~= "nightrun" then
		return
	end
	Widgets.divider(parent, order)
	Widgets.label({
		text = string.format("%s, seed %s", tostring(journey.tier), tostring(journey.seed)),
		size = "heading",
		font = Theme.Font.heading,
		parent = parent,
		layoutOrder = order + 1,
	})
	if type(journey.endless) == "table" then
		Widgets.statRow(parent, "Endless", string.format("night %d; %d in a row, best %d", journey.endless.night, journey.endless.streak, journey.endless.best), order + 2)
	end
	Widgets.statRow(parent, "Route", string.format("%s (%s)", tostring(journey.route), if journey.routeChosenBy == "default" then "default" else "chosen by " .. tostring(journey.routeChosenBy)), order + 2)
	local lines = {}
	for _, e in journey.events or {} do
		local mark = if e.status == "resolved" then "dealt with" elseif e.status == "failed" then "FAILED" elseif e.status == "skipped" then "did not happen" else tostring(e.status)
		table.insert(lines, string.format("%s: %s%s%s", e.name, mark, if e.outcome and e.outcome ~= "" then " - " .. e.outcome else "", if e.chainedFrom then " (caused by " .. e.chainedFrom .. ")" else ""))
	end
	Widgets.label({ text = table.concat(lines, "\n"), size = "small", wrap = true, parent = parent, layoutOrder = order + 3 })
	if journey.fallback then
		Widgets.caption(parent, "This seed could not produce a valid night, so the standard fallback night was used.", order + 4)
	end
	if (journey.bonus or 0) > 0 then
		Widgets.statRow(parent, "Night run bonus", tostring(journey.bonus) .. " RIP Coin", order + 5)
	end
	if (journey.inspectionCredits or 0) > 0 then
		Widgets.statRow(parent, "Inspection", tostring(journey.inspectionCredits) .. " RIP Coin", order + 6)
	end
	if journey.unlocked and #journey.unlocked > 0 then
		Widgets.statRow(parent, "Earned", table.concat(journey.unlocked, ", "), order + 7)
	end
	if journey.alreadyCredited then
		Widgets.caption(parent, "This run was already rewarded.", order + 8)
	elseif not journey.saved then
		Widgets.caption(parent, "Progress could not be saved this session, so this run is not counted.", order + 8)
	end
	Widgets.button({
		text = "Ride this seed again",
		parent = parent,
		layoutOrder = order + 9,
		onClick = function()
			Net.invokeServer("JourneyCommand", "set", "mode", "nightrun")
			Net.invokeServer("JourneyCommand", "set", "seed", journey.seed)
		end,
	})
end

return JourneyUI
