--!strict
--[[
	InteractionController
	---------------------
	The prompt the player looks at, and the hold that fills it.

	WHY CUSTOM PROMPTS
	------------------
	Roblox's default prompt UI is fine but it is not this game's typography, it
	cannot show a required item, and it cannot show the hold progress the server
	is actually tracking. The prompts themselves are still ProximityPrompts, so
	all the distance, occlusion and input handling Roblox does well is kept;
	only the appearance is ours, via Custom style.

	NO FLOATING LABELS
	------------------
	A prompt appears only for the single nearest eligible object, only when it
	is close, and it disappears the moment it is not. There are no persistent
	name boards over items in the world: a jerry can is recognisable because it
	looks like a jerry can.

	REVIVING
	--------
	A downed teammate is an interaction like any other, with its own prompt and
	its own hold. It is deliberately the same verb and the same button, so under
	pressure there is nothing new to learn.
]]

local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("LastSignal")

local ItemRegistry = require(Shared.Registry.ItemRegistry)
local Logger = require(Shared.Core.Logger)
local Net = require(Shared.Core.Net)
local Theme = require(script.Parent.Parent.UI.Theme)
local Widgets = require(script.Parent.Parent.UI.Widgets)
local InputController = require(script.Parent.InputController)
local StateController = require(script.Parent.StateController)

local log = Logger.new("InteractionController")
local player = Players.LocalPlayer

local InteractionController = {}

local gui: ScreenGui? = nil
local promptFrame: Frame? = nil
local promptLabel: TextLabel? = nil
local promptDetail: TextLabel? = nil
local promptKey: TextLabel? = nil
local holdFill: Frame? = nil

local activePrompt: ProximityPrompt? = nil
local holdStartedAt: number? = nil
local holdDuration = 0
local holdTarget: Instance? = nil
local holdAction: string? = nil

local reviveTarget: Player? = nil

--------------------------------------------------------------------------
-- Interface
--------------------------------------------------------------------------

local function build()
	local playerGui = player:WaitForChild("PlayerGui")
	local screen = Widgets.screen("LastSignalPrompt", Theme.Layer.interaction, playerGui)
	gui = screen

	local frame = Widgets.panel({
		name = "Prompt",
		size = UDim2.fromOffset(Theme.space(38), Theme.space(9)),
		position = UDim2.fromScale(0.5, 0.62),
		anchor = Vector2.new(0.5, 0.5),
		padding = 1.25,
		background = Theme.colour("backdrop"),
		transparency = 0.12,
		parent = screen,
	})
	frame.Visible = false
	promptFrame = frame

	local keyBadge = Widgets.panel({
		name = "Key",
		size = UDim2.fromOffset(Theme.space(4), Theme.space(4)),
		position = UDim2.fromScale(0, 0.5),
		anchor = Vector2.new(0, 0.5),
		background = Theme.colour("surfaceRaised"),
		parent = frame,
	})
	local key = Widgets.label({
		text = "E",
		size = "heading",
		font = Theme.Font.heading,
		align = Enum.TextXAlignment.Center,
		parent = keyBadge,
	})
	key.Size = UDim2.fromScale(1, 1)
	key.AutomaticSize = Enum.AutomaticSize.None
	key.TextYAlignment = Enum.TextYAlignment.Center
	promptKey = key

	local action = Widgets.label({
		text = "",
		size = "body",
		font = Theme.Font.heading,
		parent = frame,
		name = "Action",
	})
	action.Position = UDim2.fromOffset(Theme.space(5.5), 0)
	action.Size = UDim2.new(1, -Theme.space(6), 0, 0)
	promptLabel = action

	local detail = Widgets.label({
		text = "",
		size = "small",
		colour = Theme.colour("textMuted"),
		parent = frame,
		name = "Detail",
	})
	detail.Position = UDim2.fromOffset(Theme.space(5.5), Theme.space(2.5))
	detail.Size = UDim2.new(1, -Theme.space(6), 0, 0)
	promptDetail = detail

	-- The hold bar sits along the bottom edge of the prompt.
	local track = Instance.new("Frame")
	track.Name = "HoldTrack"
	track.BorderSizePixel = 0
	track.BackgroundColor3 = Theme.colour("void")
	track.BackgroundTransparency = 0.3
	track.AnchorPoint = Vector2.new(0.5, 1)
	track.Position = UDim2.new(0.5, 0, 1, Theme.space(1))
	track.Size = UDim2.new(1, 0, 0, 3)
	track.Visible = false
	track.Parent = frame

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.BorderSizePixel = 0
	fill.BackgroundColor3 = Theme.colour("brass")
	fill.Size = UDim2.fromScale(0, 1)
	fill.Parent = track
	holdFill = fill
end

local function showPrompt(action: string, detail: string, keyText: string)
	local frame = promptFrame
	if not frame then
		return
	end
	frame.Visible = true
	if promptLabel then
		promptLabel.Text = action
	end
	if promptDetail then
		promptDetail.Text = detail
		promptDetail.Visible = detail ~= ""
	end
	if promptKey then
		promptKey.Text = keyText
	end
end

local function hidePrompt()
	local frame = promptFrame
	if frame then
		frame.Visible = false
	end
	local fill = holdFill
	if fill then
		local track = fill.Parent :: Frame
		track.Visible = false
		fill.Size = UDim2.fromScale(0, 1)
	end
end

--------------------------------------------------------------------------
-- Target resolution
--------------------------------------------------------------------------

--- The action name the server expects for a given tagged object. The client
--- picks the verb; the server validates it against the object regardless.
local function actionFor(instance: Instance): (string?, string, string)
	if instance:HasTag("LootNode") then
		local searched = instance:GetAttribute("Searched")
		if searched == true then
			return nil, "", ""
		end
		local kind = instance:GetAttribute("LootKind")
		local label = if kind == "body" then "Search the remains" else "Search"
		return "search", label, ""
	end
	if instance:HasTag("StationFixture") then
		local kind = instance:GetAttribute("FixtureKind")
		local labels: { [string]: string } = {
			generator = "Start the generator",
			breaker = "Throw the breaker",
			fusebox = "Fit the fuse",
			lever = "Pull the lever",
			controls = "Use the controls",
			fuel_point = "Draw fuel",
			interlocking_frame = "Read the frame",
			relay_bay = "Fit the relay",
			stores_cage = "Open the stores",
			hydraulics = "Fit the valve",
			transmitter = "Work the transmitter",
		}
		return "operate", labels[tostring(kind)] or "Use", ""
	end
	if instance:HasTag("TrainFuelPoint") then
		return "refuel_train", "Refuel the locomotive", "Needs a jerry can"
	end
	if instance:HasTag("TrainRepairPoint") then
		return "repair_train", "Repair the locomotive", "Needs a repair kit"
	end
	if instance:HasTag("SupplyRack") then
		return "store", "Open the supply rack", ""
	end
	if instance:HasTag("RadioSet") then
		return "read", "Play a recording", ""
	end
	if instance:HasTag("EventToken") then
		return nil, "", "" -- the event's own prompt handles this
	end

	-- Lobby fixtures. These are how a player reaches the crew panel, the shop,
	-- the loadout and the notice board without knowing a keyboard shortcut.
	if instance:HasTag("CrewBoard") then
		return "lobby", "Form a crew and depart", "The expedition starts here"
	end
	if instance:HasTag("NoticeBoard") then
		return "lobby", "Read the notices", "Orders, rewards and events"
	end
	if instance:HasTag("StoresCounter") then
		return "lobby", "Browse the stores", "Liveries, cosmetics and supplies"
	end
	if instance:HasTag("WorkshopBench") then
		return "lobby", "Open your loadout", "Train, livery, weapon and appearance"
	end

	local model = instance:FindFirstAncestorOfClass("Model")
	if model and model:HasTag("DroppedItem") then
		local itemId = model:GetAttribute("ItemId")
		if type(itemId) == "string" then
			local def = ItemRegistry.getOrFallback(itemId)
			local quantity = model:GetAttribute("Quantity")
			local detail = if type(quantity) == "number" and quantity > 1 then string.format("%d", quantity) else ""
			return "pickup", def.promptVerb, detail
		end
		return "pickup", "Take", ""
	end

	if instance:HasTag("Discovery") then
		return "discover", "Look closer", ""
	end

	return nil, "", ""
end

--------------------------------------------------------------------------
-- Downed teammates
--------------------------------------------------------------------------

local function findDownedNearby(): Player?
	local character = player.Character
	local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
	if not root or not root:IsA("BasePart") then
		return nil
	end
	-- Downed crew members are found by their humanoid state rather than by a
	-- replicated list, so this works even if a state update is in flight.
	for _, other in Players:GetPlayers() do
		if other == player then
			continue
		end
		local otherCharacter = other.Character
		local otherRoot = if otherCharacter then otherCharacter:FindFirstChild("HumanoidRootPart") else nil
		local humanoid = if otherCharacter then otherCharacter:FindFirstChildOfClass("Humanoid") else nil
		if otherRoot and otherRoot:IsA("BasePart") and humanoid then
			local isDowned = humanoid.WalkSpeed <= 4 and humanoid.Health <= 1
			if isDowned and (otherRoot.Position - root.Position).Magnitude < 10 then
				return other
			end
		end
	end
	return nil
end

--------------------------------------------------------------------------
-- Hold handling
--------------------------------------------------------------------------

local function beginHold(target: Instance, action: string, duration: number)
	holdTarget = target
	holdAction = action
	holdDuration = duration
	holdStartedAt = os.clock()
	local fill = holdFill
	if fill then
		(fill.Parent :: Frame).Visible = true
		fill.Size = UDim2.fromScale(0, 1)
	end
end

local function cancelHold()
	if holdTarget then
		Net.fireServer("Interact", holdTarget, "cancel")
	end
	holdTarget = nil
	holdAction = nil
	holdStartedAt = nil
	local fill = holdFill
	if fill then
		(fill.Parent :: Frame).Visible = false
		fill.Size = UDim2.fromScale(0, 1)
	end
end

local function stepHold()
	local startedAt = holdStartedAt
	local target = holdTarget
	local action = holdAction
	if not startedAt or not target or not action then
		return
	end
	local elapsed = os.clock() - startedAt
	local fraction = math.clamp(elapsed / math.max(0.01, holdDuration), 0, 1)
	local fill = holdFill
	if fill then
		fill.Size = UDim2.fromScale(fraction, 1)
	end
	if fraction >= 1 then
		-- The completion claim. The server re-checks the elapsed time against
		-- its own clock, so this cannot be rushed.
		Net.fireServer("Interact", target, action)
		holdStartedAt = nil
		holdTarget = nil
		holdAction = nil
		if fill then
			(fill.Parent :: Frame).Visible = false
		end
	end
end

--------------------------------------------------------------------------

function InteractionController.start()
	build()

	-- Roblox drives which prompt is shown; we only style it.
	ProximityPromptService.PromptShown:Connect(function(prompt)
		if prompt.Style ~= Enum.ProximityPromptStyle.Custom then
			return
		end
		activePrompt = prompt
		local parent = prompt.Parent
		if not parent then
			return
		end
		local action, label, detail = actionFor(parent)
		if not action then
			-- A tagged object with nothing to do right now shows no prompt at
			-- all, rather than a prompt that does nothing.
			if prompt.ActionText ~= "" then
				showPrompt(prompt.ActionText, prompt.ObjectText, if Theme.isTouch() then "TAP" else "E")
			end
			return
		end
		showPrompt(label, detail, if Theme.isTouch() then "TAP" else "E")
		InputController.setTouchVisible("interact", true)
	end)

	ProximityPromptService.PromptHidden:Connect(function(prompt)
		if activePrompt == prompt then
			activePrompt = nil
			hidePrompt()
			cancelHold()
		end
	end)

	ProximityPromptService.PromptTriggered:Connect(function(prompt, triggeringPlayer)
		if triggeringPlayer ~= player then
			return
		end
		local parent = prompt.Parent
		if not parent then
			return
		end
		local action = actionFor(parent)
		if not action then
			return
		end
		-- The first send tells the server we are starting; it replies with the
		-- duration, and the hold bar runs from that.
		Net.fireServer("Interact", parent, action)
	end)

	-- The server's reply to a hold start carries the authoritative duration.
	Net.onClientEvent("InteractResult", function(payload)
		if type(payload) ~= "table" then
			return
		end
		-- A lobby fixture asks the client to open the matching panel. Required
		-- lazily so this controller does not depend on the menu at load time.
		if payload.action == "open_panel" and type(payload.panel) == "string" then
			local MenuController = require(script.Parent.MenuController)
			MenuController.open(payload.panel)
			return
		end
		if payload.action == "hold_start" and payload.target then
			local action = actionFor(payload.target)
			if action then
				beginHold(payload.target, action, payload.duration or 1)
			end
			return
		end
		if payload.ok == false and payload.error then
			local message = tostring(payload.error)
			if string.sub(message, 1, 6) == "NEEDS:" then
				Net.fireServer("Analytics", "tutorial_prompt_seen")
				showPrompt("You need " .. string.sub(message, 7), "", "!")
				task.delay(2, hidePrompt)
			end
			cancelHold()
		end
	end)

	-- Revive is a separate prompt because a downed player is not a tagged
	-- object; it is another player.
	InputController.Action:Connect(function(actionId, pressed)
		if actionId ~= "revive" and actionId ~= "interact" then
			return
		end
		local target = reviveTarget
		if not target then
			return
		end
		if pressed then
			Net.invokeServer("ReviveCommand", "start", target.UserId)
		else
			Net.invokeServer("ReviveCommand", "stop", target.UserId)
		end
	end)

	RunService.Heartbeat:Connect(function()
		stepHold()

		-- A downed teammate takes priority over any object prompt, because it
		-- is always the more urgent thing.
		local downed = findDownedNearby()
		if downed ~= reviveTarget then
			reviveTarget = downed
			if downed then
				showPrompt("Revive " .. downed.DisplayName, "Hold to bring them back up", if Theme.isTouch() then "TAP" else "E")
				InputController.setTouchLabel("interact", "Revive")
			else
				InputController.setTouchLabel("interact", "Use")
				if not activePrompt then
					hidePrompt()
				end
			end
		end

		-- Revive progress drives the same bar. The reviving player does not
		-- receive the target.s vitals, so the bar runs locally and the server.s
		-- completion is what actually revives them.
		if reviveTarget and holdFill then
			local track = holdFill.Parent :: Frame
			track.Visible = true
			local elapsed = if holdStartedAt then (os.clock() - holdStartedAt) else 0
			holdFill.Size = UDim2.fromScale(math.clamp(elapsed / 12, 0, 1), 1)
		end
	end)

	log.info("started")
end

return InteractionController
