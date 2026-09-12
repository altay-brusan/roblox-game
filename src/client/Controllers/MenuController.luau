--!strict
--[[
	MenuController
	--------------
	Every full-screen panel: crew, loadout, inventory, shop, quests, rewards,
	achievements, leaderboards, settings, results and the admin console.

	ONE PANEL AT A TIME
	-------------------
	There is a single open panel, tracked in StateController so the HUD, the
	camera and the input layer all agree about it. Opening a second panel closes
	the first. That is what guarantees the mouse is released exactly once and
	recaptured exactly once, which is the failure this design exists to prevent.

	Closing is always available: the close button, the key that opened it, and
	tapping the backdrop. On a gamepad, the menu button closes. There is no
	state from which a player cannot get back to the game.

	NO DRAG AND DROP
	----------------
	Inventory actions are select-then-act. Tap an item, then tap Use, Drop,
	Assign or Give. That works identically with a mouse, a thumb and a stick,
	and it is the reason the inventory needs no separate mobile layout.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("LastSignal")

local Balance = require(Shared.Config.Balance)
local Format = require(Shared.Core.Format)
local GameConfig = require(Shared.Config.GameConfig)
local ItemRegistry = require(Shared.Registry.ItemRegistry)
local Logger = require(Shared.Core.Logger)
local Net = require(Shared.Core.Net)
local TrainRegistry = require(Shared.Registry.TrainRegistry)
local WeaponRegistry = require(Shared.Registry.WeaponRegistry)
local CosmeticRegistry = require(Shared.Registry.CosmeticRegistry)
local Theme = require(script.Parent.Parent.UI.Theme)
local Widgets = require(script.Parent.Parent.UI.Widgets)
local CameraController = require(script.Parent.CameraController)
local InputController = require(script.Parent.InputController)
local StateController = require(script.Parent.StateController)

local log = Logger.new("MenuController")
local player = Players.LocalPlayer

local MenuController = {}

local gui: ScreenGui?
local backdrop: TextButton?
local shell: Frame?
local titleLabel: TextLabel?
local body: Frame?
local currentPanel: string? = nil
local rebuild: (() -> ())? = nil

local selectedItem: string? = nil

--------------------------------------------------------------------------
-- Shell
--------------------------------------------------------------------------

local function clearBody(): Frame
	local frame = body :: Frame
	for _, child in frame:GetChildren() do
		if not child:IsA("UIListLayout") and not child:IsA("UIPadding") then
			child:Destroy()
		end
	end
	return frame
end

function MenuController.close()
	if not currentPanel then
		return
	end
	currentPanel = nil
	rebuild = nil
	selectedItem = nil
	if shell then
		shell.Visible = false
	end
	if backdrop then
		backdrop.Visible = false
	end
	StateController.setUi("openPanel", nil)
	-- The camera and the input layer both react to openPanel, so control is
	-- restored by exactly one path however the panel was closed.
	CameraController.restore()
end

local PANEL_TITLES: { [string]: string } = {
	main = "Menu",
	crew = "Crew",
	loadout = "Loadout",
	inventory = "Inventory",
	shop = "Stores",
	quests = "Orders",
	rewards = "Rewards",
	achievements = "Record",
	leaderboard = "Standings",
	settings = "Settings",
	admin = "Control",
	results = "Expedition Report",
	event = "Event",
}

local builders: { [string]: (Frame) -> () } = {}

function MenuController.open(panel: string)
	if not builders[panel] then
		log.warn("unknown panel:", panel)
		return
	end
	if currentPanel == panel then
		MenuController.close()
		return
	end

	currentPanel = panel
	StateController.setUi("openPanel", panel)
	if shell then
		shell.Visible = true
	end
	if backdrop then
		backdrop.Visible = true
	end
	if titleLabel then
		titleLabel.Text = PANEL_TITLES[panel] or panel
	end

	local frame = clearBody()
	rebuild = function()
		if currentPanel ~= panel then
			return
		end
		local rebuilt = clearBody()
		builders[panel](rebuilt)
	end
	builders[panel](frame)
	CameraController.restore()

	if panel == "shop" then
		Net.fireServer("Analytics", "shop_opened")
	elseif panel == "settings" then
		Net.fireServer("Analytics", "settings_opened")
	elseif panel == "quests" then
		Net.fireServer("Analytics", "quests_opened")
	elseif panel == "crew" then
		Net.fireServer("Analytics", "crew_panel_opened")
	end
end

function MenuController.isOpen(): boolean
	return currentPanel ~= nil
end

--------------------------------------------------------------------------
-- Panel: main menu
--------------------------------------------------------------------------

builders.main = function(frame: Frame)
	local column = Widgets.column(frame, 1)
	local profile = StateController.profile()

	if profile then
		local header = Widgets.panel({
			name = "Header",
			size = UDim2.new(1, 0, 0, 0),
			padding = 1.25,
			background = Theme.colour("surface"),
			parent = column,
		})
		header.AutomaticSize = Enum.AutomaticSize.Y
		header.LayoutOrder = 0
		local headerColumn = Widgets.column(header, 0.5)
		Widgets.label({
			text = string.format("%s  -  Level %d", player.DisplayName, profile.level or 1),
			size = "title",
			font = Theme.Font.display,
			parent = headerColumn,
			layoutOrder = 1,
		})
		Widgets.statRow(headerColumn, "Credits", Format.groupedNumber(profile.credits or 0), 2)
		local xpToNext = profile.xpToNext or 0
		if xpToNext > 0 then
			Widgets.statRow(headerColumn, "Progress to next level", string.format("%d / %d", profile.xp or 0, xpToNext), 3)
			local meter = Widgets.meter(headerColumn, Theme.colour("progress"), Theme.space(1))
			meter.instance.LayoutOrder = 4
			meter.set((profile.xp or 0) / math.max(1, xpToNext))
		end
		if profile.readOnly then
			local warning = Widgets.panel({
				name = "ReadOnly",
				size = UDim2.new(1, 0, 0, 0),
				padding = 1,
				background = Theme.colour("surface"),
				parent = headerColumn,
			})
			warning.AutomaticSize = Enum.AutomaticSize.Y
			warning.LayoutOrder = 5
			Widgets.label({
				text = "Your progress is not being saved this session. Rejoining usually fixes it.",
				size = "small",
				colour = Theme.colour("signalAmber"),
				parent = warning,
			})
		end
	end

	local entries = {
		{ id = "crew", label = "Crew", detail = "Form a crew and depart." },
		{ id = "loadout", label = "Loadout", detail = "Train, livery, weapons and appearance." },
		{ id = "shop", label = "Stores", detail = "Liveries, cosmetics and supplies." },
		{ id = "quests", label = "Orders", detail = "Daily and weekly objectives." },
		{ id = "rewards", label = "Rewards", detail = "Daily login and playtime." },
		{ id = "achievements", label = "Record", detail = "Achievements and statistics." },
		{ id = "leaderboard", label = "Standings", detail = "Global boards." },
		{ id = "settings", label = "Settings", detail = "Audio, accessibility and controls." },
	}

	local eventState = StateController.get("event")
	if eventState and eventState.active then
		table.insert(entries, 4, { id = "event", label = eventState.name or "Event", detail = eventState.tagline or "" })
	end

	local admin = StateController.get("admin")
	if admin and admin.role and admin.role ~= "player" then
		table.insert(entries, { id = "admin", label = "Control", detail = "Administrative commands." })
	end

	for index, entry in entries do
		local button = Widgets.button({
			text = entry.label,
			parent = column,
			layoutOrder = index + 10,
			onClick = function()
				MenuController.open(entry.id)
			end,
		})
		button.instance.Size = UDim2.new(1, 0, 0, math.max(Theme.minTouchTarget(), Theme.space(6)))
	end
end

--------------------------------------------------------------------------
-- Panel: crew
--------------------------------------------------------------------------

builders.crew = function(frame: Frame)
	local column = Widgets.column(frame, 1)
	local crew = StateController.get("crew")

	if not crew or crew.state == "closed" then
		Widgets.label({
			text = "You are not in a crew.",
			size = "body",
			parent = column,
			layoutOrder = 1,
		})
		Widgets.caption(column, "A crew of one is a perfectly good crew. Everything in the chapter can be done alone.", 2)

		Widgets.button({
			text = "Depart alone",
			primary = true,
			parent = column,
			layoutOrder = 3,
			onClick = function()
				Net.invokeServer("CrewCommand", "solo")
				MenuController.close()
			end,
		})
		Widgets.button({
			text = "Create a public crew",
			parent = column,
			layoutOrder = 4,
			onClick = function()
				Net.invokeServer("CrewCommand", "create_public")
				if rebuild then
					task.delay(0.2, rebuild)
				end
			end,
		})
		Widgets.button({
			text = "Create a private crew",
			parent = column,
			layoutOrder = 5,
			onClick = function()
				Net.invokeServer("CrewCommand", "create_private")
				if rebuild then
					task.delay(0.2, rebuild)
				end
			end,
		})

		Widgets.divider(column, 6)
		Widgets.heading(column, "Open crews", 7)

		local result = Net.invokeServer("CrewCommand", "browse")
		local list = if type(result) == "table" and result.crews then result.crews else {}
		if #list == 0 then
			Widgets.emptyState(column, "No open crews on this server right now.")
		else
			for index, entry in list do
				local card = Widgets.panel({
					name = "CrewCard",
					size = UDim2.new(1, 0, 0, 0),
					padding = 1,
					background = Theme.colour("surface"),
					parent = column,
				})
				card.AutomaticSize = Enum.AutomaticSize.Y
				card.LayoutOrder = 10 + index
				local cardColumn = Widgets.column(card, 0.5)
				Widgets.label({
					text = string.format("%s  (%d/%d)", entry.name, entry.size, entry.maxSize),
					size = "body",
					font = Theme.Font.heading,
					parent = cardColumn,
					layoutOrder = 1,
				})
				Widgets.caption(cardColumn, string.format("%s  -  %s", entry.trainName, entry.difficulty), 2)
				Widgets.button({
					text = "Join",
					parent = cardColumn,
					layoutOrder = 3,
					onClick = function()
						local joinResult = Net.invokeServer("CrewCommand", "join", entry.id)
						if type(joinResult) == "table" and joinResult.ok and rebuild then
							rebuild()
						end
					end,
				})
			end
		end
		return
	end

	-- In a crew.
	Widgets.label({
		text = crew.name or "Crew",
		size = "title",
		font = Theme.Font.display,
		parent = column,
		layoutOrder = 1,
	})
	Widgets.caption(column, string.format("%s on %s", crew.trainName or "", crew.difficulty or ""), 2)

	local isLeader = crew.leaderUserId == player.UserId

	for index, member in crew.members or {} do
		local card = Widgets.panel({
			name = "Member",
			size = UDim2.new(1, 0, 0, 0),
			padding = 1,
			background = Theme.colour("surface"),
			parent = column,
		})
		card.AutomaticSize = Enum.AutomaticSize.Y
		card.LayoutOrder = 10 + index
		local cardColumn = Widgets.column(card, 0.25)

		local nameText = member.displayName
		if member.isLeader then
			nameText = nameText .. "  (leader)"
		end
		Widgets.label({
			text = nameText,
			size = "body",
			font = Theme.Font.heading,
			colour = if member.ready then Theme.colour("signalGreen") else Theme.colour("text"),
			parent = cardColumn,
			layoutOrder = 1,
		})
		Widgets.caption(cardColumn, string.format("Level %d  -  %s  -  %s", member.level or 1, member.role or "crew", if member.ready then "ready" else "not ready"), 2)

		if isLeader and member.userId ~= player.UserId then
			local row = Widgets.row(cardColumn, 0.5)
			row.LayoutOrder = 3
			Widgets.button({
				text = "Make leader",
				width = UDim.new(0.5, -Theme.space(0.25)),
				parent = row,
				onClick = function()
					Net.invokeServer("CrewCommand", "transfer_leader", member.userId)
					if rebuild then
						task.delay(0.2, rebuild)
					end
				end,
			})
			Widgets.button({
				text = "Remove",
				danger = true,
				width = UDim.new(0.5, -Theme.space(0.25)),
				parent = row,
				onClick = function()
					Net.invokeServer("CrewCommand", "kick", member.userId)
					if rebuild then
						task.delay(0.2, rebuild)
					end
				end,
			})
		end
	end

	Widgets.divider(column, 40)

	local me: any = nil
	for _, member in crew.members or {} do
		if member.userId == player.UserId then
			me = member
		end
	end

	Widgets.button({
		text = if me and me.ready then "Not ready" else "Ready",
		primary = not (me and me.ready),
		parent = column,
		layoutOrder = 41,
		onClick = function()
			Net.invokeServer("CrewCommand", if me and me.ready then "unready" else "ready")
			if rebuild then
				task.delay(0.2, rebuild)
			end
		end,
	})

	if isLeader then
		if crew.state == "departing" then
			Widgets.button({
				text = "Cancel departure",
				danger = true,
				parent = column,
				layoutOrder = 42,
				onClick = function()
					Net.invokeServer("CrewCommand", "cancel_depart")
					if rebuild then
						task.delay(0.2, rebuild)
					end
				end,
			})
		else
			Widgets.button({
				text = "Depart",
				primary = true,
				parent = column,
				layoutOrder = 42,
				onClick = function()
					local result = Net.invokeServer("CrewCommand", "depart")
					if type(result) == "table" and not result.ok then
						local reasons: { [string]: string } = {
							NOT_ALL_READY = "Everybody has to be ready first.",
							CREW_TOO_SMALL = "The crew is empty.",
							NOT_LEADER = "Only the crew leader can depart.",
						}
						Widgets.emptyState(column, reasons[tostring(result.error)] or "Cannot depart right now.")
					else
						MenuController.close()
					end
				end,
			})
		end
	end

	Widgets.button({
		text = "Leave crew",
		parent = column,
		layoutOrder = 43,
		onClick = function()
			Net.invokeServer("CrewCommand", "leave")
			if rebuild then
				task.delay(0.2, rebuild)
			end
		end,
	})
end

--------------------------------------------------------------------------
-- Panel: loadout
--------------------------------------------------------------------------

builders.loadout = function(frame: Frame)
	local profile = StateController.profile()
	if not profile then
		Widgets.emptyState(frame, "Loading your profile.")
		return
	end

	local scroll = Widgets.scroll(frame, 1)
	local order = 0
	local function nextOrder(): number
		order += 1
		return order
	end

	local function section(title: string)
		Widgets.heading(scroll, title, nextOrder())
	end

	local function choiceRow(label: string, owned: boolean, selected: boolean, detail: string, onSelect: () -> ())
		local card = Widgets.panel({
			name = "Choice",
			size = UDim2.new(1, 0, 0, 0),
			padding = 1,
			background = if selected then Theme.colour("surfaceRaised") else Theme.colour("surface"),
			parent = scroll,
		})
		card.AutomaticSize = Enum.AutomaticSize.Y
		card.LayoutOrder = nextOrder()
		local column = Widgets.column(card, 0.25)
		Widgets.label({
			text = label .. (if selected then "   (selected)" else ""),
			size = "body",
			font = Theme.Font.heading,
			colour = if owned then Theme.colour("text") else Theme.colour("textFaint"),
			parent = column,
			layoutOrder = 1,
		})
		if detail ~= "" then
			Widgets.caption(column, detail, 2)
		end
		if owned and not selected then
			Widgets.button({
				text = "Select",
				parent = column,
				layoutOrder = 3,
				onClick = onSelect,
			})
		elseif not owned then
			Widgets.caption(column, "Not owned. Available in Stores.", 3)
		end
	end

	section("Train")
	for _, def in TrainRegistry.allTrains() do
		local owned = StateController.owns("train", def.id)
		choiceRow(
			def.name,
			owned,
			profile.loadout.train == def.id,
			string.format("%s. %s", def.class, def.tagline),
			function()
				Net.invokeServer("CrewCommand", "set_train", def.id)
				Net.fireServer("SetSetting", "loadout_train", def.id)
				if rebuild then
					task.delay(0.2, rebuild)
				end
			end
		)
	end

	section("Livery")
	for _, def in TrainRegistry.allLiveries() do
		local owned = StateController.owns("livery", def.id)
		choiceRow(def.name, owned, profile.loadout.livery == def.id, def.description, function()
			Net.fireServer("SetSetting", "loadout_livery", def.id)
			if rebuild then
				task.delay(0.2, rebuild)
			end
		end)
	end

	section("Interior")
	for _, def in TrainRegistry.allInteriors() do
		local owned = StateController.owns("interior", def.id)
		choiceRow(def.name, owned, profile.loadout.interior == def.id, def.description, function()
			Net.fireServer("SetSetting", "loadout_interior", def.id)
			if rebuild then
				task.delay(0.2, rebuild)
			end
		end)
	end

	section("Weapon")
	for _, def in WeaponRegistry.all() do
		local owned = def.startingLoadout or StateController.owns("weapon", def.id)
		local locked = (profile.level or 1) < def.unlockLevel
		choiceRow(
			def.name,
			owned and not locked,
			profile.loadout.primaryWeapon == def.id,
			if locked then string.format("Unlocks at level %d.", def.unlockLevel) else def.description,
			function()
				Net.fireServer("SetSetting", "loadout_primary", def.id)
				if rebuild then
					task.delay(0.2, rebuild)
				end
			end
		)
	end

	section("Role")
	for _, role in { "crew", "driver", "mechanic", "medic", "scout", "guard" } do
		choiceRow(
			Format.titleFromId(role),
			true,
			profile.loadout.role == role,
			"A preference, not a restriction. Anybody can do anything.",
			function()
				Net.invokeServer("CrewCommand", "set_role", role)
				if rebuild then
					task.delay(0.2, rebuild)
				end
			end
		)
	end

	section("Appearance")
	for _, slot in { "lamp", "outfit", "finish", "patch" } do
		for _, def in CosmeticRegistry.bySlot(slot :: any) do
			local owned = StateController.owns("cosmetic", def.id)
			choiceRow(def.name, owned, profile.loadout[slot] == def.id, def.description, function()
				Net.fireServer("SetSetting", "loadout_" .. slot, def.id)
				if rebuild then
					task.delay(0.2, rebuild)
				end
			end)
		end
	end
end

--------------------------------------------------------------------------
-- Panel: inventory
--------------------------------------------------------------------------

builders.inventory = function(frame: Frame)
	local inventory = StateController.get("inventory")
	if not inventory or not inventory.active then
		Widgets.emptyState(frame, "You carry nothing in the yard. Your inventory is filled on an expedition.")
		return
	end

	local column = Widgets.column(frame, 1)

	local weight = inventory.weight or 0
	local weightLimit = inventory.weightLimit or 1
	local weightMeter = Widgets.meter(column, if weight > weightLimit * 0.85 then Theme.colour("signalAmber") else Theme.colour("brass"), Theme.space(1.25))
	weightMeter.instance.LayoutOrder = 1
	weightMeter.set(weight / math.max(1, weightLimit))
	Widgets.caption(column, string.format("%.1f of %.0f kg   -   %d of %d slots", weight, weightLimit, #(inventory.stacks or {}), inventory.slotLimit or 0), 2)

	local scroll = Widgets.scroll(column, 0.5)
	scroll.LayoutOrder = 3
	scroll.Size = UDim2.new(1, 0, 1, -Theme.space(12))

	if #(inventory.stacks or {}) == 0 then
		Widgets.emptyState(scroll, "Empty. Search lockers, crates and shelves.")
	end

	for index, stack in inventory.stacks or {} do
		local def = ItemRegistry.getOrFallback(stack.id)
		local isSelected = selectedItem == stack.id

		local card = Widgets.panel({
			name = "Item",
			size = UDim2.new(1, 0, 0, 0),
			padding = 1,
			background = if isSelected then Theme.colour("surfaceRaised") else Theme.colour("surface"),
			parent = scroll,
		})
		card.AutomaticSize = Enum.AutomaticSize.Y
		card.LayoutOrder = index

		local icon = Widgets.icon(card, def.icon or "box", Theme.space(4), Theme.colour("brass"))
		icon.Position = UDim2.fromOffset(0, Theme.space(0.25))

		local textColumn = Widgets.column(card, 0.25)
		textColumn.Position = UDim2.fromOffset(Theme.space(5), 0)
		textColumn.Size = UDim2.new(1, -Theme.space(5), 0, 0)

		Widgets.label({
			text = string.format("%s%s", def.name, if stack.quantity > 1 then string.format("  x%d", stack.quantity) else ""),
			size = "body",
			font = Theme.Font.heading,
			parent = textColumn,
			layoutOrder = 1,
		})
		Widgets.caption(textColumn, def.description, 2)
		Widgets.caption(textColumn, string.format("%.1f kg each", def.weight), 3)

		-- Select-then-act: tapping the card selects it and reveals the actions.
		local hit = Instance.new("TextButton")
		hit.Name = "Select"
		hit.Text = ""
		hit.BackgroundTransparency = 1
		hit.Size = UDim2.fromScale(1, 1)
		hit.ZIndex = 0
		hit.Activated:Connect(function()
			selectedItem = if isSelected then nil else stack.id
			if rebuild then
				rebuild()
			end
		end)
		hit.Parent = card

		if isSelected then
			local actions = Widgets.column(textColumn, 0.5)
			actions.LayoutOrder = 4

			if def.quickUsable then
				Widgets.button({
					text = "Use",
					primary = true,
					parent = actions,
					layoutOrder = 1,
					onClick = function()
						Net.invokeServer("InventoryCommand", "use", stack.id)
					end,
				})
				local slotRow = Widgets.row(actions, 0.5)
				slotRow.LayoutOrder = 2
				for slotIndex = 1, Balance.Player.quickSlots do
					Widgets.button({
						text = tostring(slotIndex),
						width = UDim.new(1 / Balance.Player.quickSlots, -Theme.space(0.5)),
						parent = slotRow,
						onClick = function()
							Net.invokeServer("InventoryCommand", "quickslot", slotIndex, stack.id)
						end,
					})
				end
			end

			Widgets.button({
				text = if def.essential then "Store in the train" else "Drop",
				parent = actions,
				layoutOrder = 3,
				onClick = function()
					Net.invokeServer("InventoryCommand", "drop", stack.id, 1)
					selectedItem = nil
					if rebuild then
						task.delay(0.2, rebuild)
					end
				end,
			})

			-- Handing over: one button per nearby crew member.
			local crew = StateController.get("crew")
			if crew and crew.members then
				for _, member in crew.members do
					if member.userId ~= player.UserId and member.connected then
						Widgets.button({
							text = "Give to " .. member.displayName,
							parent = actions,
							layoutOrder = 4,
							onClick = function()
								local result = Net.invokeServer("InventoryCommand", "transfer", stack.id, member.userId)
								if type(result) == "table" and not result.ok then
									log.debug("transfer refused:", tostring(result.error))
								end
								if rebuild then
									task.delay(0.2, rebuild)
								end
							end,
						})
					end
				end
			end
		end
	end
end

--------------------------------------------------------------------------
-- Panel: shop
--------------------------------------------------------------------------

local shopCategory = "featured"

builders.shop = function(frame: Frame)
	local result = Net.invokeServer("ShopCommand", "catalogue")
	local catalogue = if type(result) == "table" and result.catalogue then result.catalogue else StateController.get("shop")
	if not catalogue then
		Widgets.emptyState(frame, "Loading the stores.")
		return
	end

	local column = Widgets.column(frame, 1)

	Widgets.label({
		text = string.format("%s credits", Format.groupedNumber(catalogue.credits or 0)),
		size = "body",
		font = Theme.Font.heading,
		colour = Theme.colour("brass"),
		parent = column,
		layoutOrder = 1,
	})

	if catalogue.promptBlocked then
		Widgets.caption(column, "Robux purchases are paused during this part of the expedition.", 2)
	end
	if not catalogue.anyRobuxConfigured then
		local notice = Widgets.panel({
			name = "NotConfigured",
			size = UDim2.new(1, 0, 0, 0),
			padding = 1,
			background = Theme.colour("surface"),
			parent = column,
		})
		notice.AutomaticSize = Enum.AutomaticSize.Y
		notice.LayoutOrder = 3
		Widgets.label({
			text = "Robux products are not configured on this experience yet, so everything here shows as Unavailable. Credit purchases still work.",
			size = "small",
			colour = Theme.colour("signalAmber"),
			parent = notice,
		})
	end

	local names: { string } = {}
	local ids: { string } = {}
	for _, category in catalogue.categories or {} do
		table.insert(names, category.name)
		table.insert(ids, category.id)
	end

	local scroll = Widgets.scroll(column, 0.5)
	scroll.LayoutOrder = 10
	scroll.Size = UDim2.new(1, 0, 1, -Theme.space(16))

	local function renderCategory(categoryId: string)
		for _, child in scroll:GetChildren() do
			if not child:IsA("UIListLayout") and not child:IsA("UIPadding") then
				child:Destroy()
			end
		end

		local shown = 0
		for index, entry in catalogue.entries or {} do
			local matches = entry.category == categoryId
			if categoryId == "featured" then
				-- Featured shows one of each category, highest value first,
				-- rather than a separate hand-curated list that could drift.
				matches = entry.purchasable and (entry.category == "passes" or entry.category == "liveries")
			end
			if not matches then
				continue
			end
			shown += 1

			local card = Widgets.panel({
				name = "Product",
				size = UDim2.new(1, 0, 0, 0),
				padding = 1.25,
				background = Theme.colour("surface"),
				parent = scroll,
			})
			card.AutomaticSize = Enum.AutomaticSize.Y
			card.LayoutOrder = index

			local cardColumn = Widgets.column(card, 0.4)
			Widgets.label({
				text = entry.name,
				size = "body",
				font = Theme.Font.heading,
				parent = cardColumn,
				layoutOrder = 1,
			})
			Widgets.label({
				text = entry.blurb,
				size = "small",
				colour = Theme.colour("textMuted"),
				parent = cardColumn,
				layoutOrder = 2,
			})

			local priceText: string
			if entry.owned then
				priceText = "Owned"
			elseif entry.currency == "credits" then
				priceText = string.format("%s credits", Format.groupedNumber(entry.price or 0))
			else
				-- The live price from MarketplaceService, or Unavailable. Never
				-- a hard-coded number and never a guess.
				priceText = Format.price(entry.price)
			end
			Widgets.label({
				text = priceText,
				size = "small",
				font = Theme.Font.mono,
				colour = if entry.owned then Theme.colour("signalGreen") else Theme.colour("brass"),
				parent = cardColumn,
				layoutOrder = 3,
			})

			if entry.purchasable then
				Widgets.button({
					text = if entry.currency == "credits" then "Buy with credits" else "Buy",
					primary = entry.currency ~= "credits",
					parent = cardColumn,
					layoutOrder = 4,
					onClick = function()
						if entry.currency == "credits" then
							local buyResult = Net.invokeServer("ShopCommand", "buy_credits", entry.key)
							if type(buyResult) == "table" and buyResult.ok and rebuild then
								rebuild()
							end
						else
							Net.fireServer("Analytics", "prompt_shown")
							Net.invokeServer("ShopCommand", "prompt_robux", entry.key)
						end
					end,
				})
			elseif entry.unavailableReason then
				Widgets.caption(cardColumn, entry.unavailableReason, 4)
			end
		end

		if shown == 0 then
			Widgets.emptyState(scroll, "Nothing here at the moment.")
		end
	end

	local _, select = Widgets.tabs(column, names, function(index)
		shopCategory = ids[index] or "featured"
		Net.fireServer("Analytics", "shop_category_viewed")
		renderCategory(shopCategory)
	end)
	local startIndex = table.find(ids, shopCategory) or 1
	select(startIndex)
end

--------------------------------------------------------------------------
-- Panel: quests
--------------------------------------------------------------------------

builders.quests = function(frame: Frame)
	Net.invokeServer("RewardCommand", "refresh_quests")
	local quests = StateController.get("quests")
	if not quests then
		Widgets.emptyState(frame, "Loading your orders.")
		return
	end

	local scroll = Widgets.scroll(frame, 1)

	local function renderGroup(title: string, list: { any }, resetIn: number?, order: number)
		Widgets.heading(scroll, title, order)
		if resetIn then
			Widgets.caption(scroll, "Resets in " .. Format.duration(resetIn), order + 1)
		end
		if #list == 0 then
			Widgets.emptyState(scroll, "Nothing here yet.")
			return
		end
		for index, quest in list do
			local card = Widgets.panel({
				name = "Quest",
				size = UDim2.new(1, 0, 0, 0),
				padding = 1.25,
				background = Theme.colour("surface"),
				parent = scroll,
			})
			card.AutomaticSize = Enum.AutomaticSize.Y
			card.LayoutOrder = order + 1 + index

			local column = Widgets.column(card, 0.4)
			Widgets.label({
				text = quest.name .. (if quest.cooperative then "   (crew)" else ""),
				size = "body",
				font = Theme.Font.heading,
				parent = column,
				layoutOrder = 1,
			})
			Widgets.caption(column, quest.description, 2)

			local meter = Widgets.meter(column, Theme.colour("progress"), Theme.space(1))
			meter.instance.LayoutOrder = 3
			meter.set((quest.progress or 0) / math.max(1, quest.target or 1))
			Widgets.caption(column, string.format("%d / %d   -   %d credits, %d XP", quest.progress or 0, quest.target or 0, quest.credits or 0, quest.xp or 0), 4)

			if quest.claimed then
				Widgets.caption(column, "Claimed.", 5)
			elseif (quest.progress or 0) >= (quest.target or 1) then
				Widgets.button({
					text = "Claim",
					primary = true,
					parent = column,
					layoutOrder = 5,
					onClick = function()
						Net.invokeServer("RewardCommand", "claim_quest", quest.id)
						if rebuild then
							task.delay(0.3, rebuild)
						end
					end,
				})
			end
		end
	end

	renderGroup("Daily", quests.daily or {}, quests.dailyResetIn, 1)
	renderGroup("Weekly", quests.weekly or {}, quests.weeklyResetIn, 100)
	renderGroup("Chapter milestones", quests.milestones or {}, nil, 200)
end

--------------------------------------------------------------------------
-- Panel: rewards
--------------------------------------------------------------------------

builders.rewards = function(frame: Frame)
	local result = Net.invokeServer("RewardCommand", "reward_state")
	local column = Widgets.column(frame, 1)

	if type(result) ~= "table" or not result.ok then
		Widgets.emptyState(column, "Rewards are unavailable right now.")
		return
	end

	local login = result.login
	local playtime = result.playtime

	Widgets.heading(column, "Daily login", 1)
	Widgets.caption(column, string.format("Current streak: %d days. Best: %d.", login.streak or 0, login.streak or 0), 2)
	Widgets.caption(column, "Missing a day steps your streak back by one. It is never reset, and nothing here can be bought.", 3)

	if login.available then
		Widgets.button({
			text = string.format("Claim %d credits", login.credits or 0),
			primary = true,
			parent = column,
			layoutOrder = 4,
			onClick = function()
				Net.invokeServer("RewardCommand", "claim_login")
				if rebuild then
					task.delay(0.3, rebuild)
				end
			end,
		})
	else
		Widgets.caption(column, "Claimed today. Back in " .. Format.duration(login.resetIn or 0) .. ".", 4)
	end

	Widgets.divider(column, 10)
	Widgets.heading(column, "Playtime", 11)

	local meter = Widgets.meter(column, Theme.colour("progress"), Theme.space(1))
	meter.instance.LayoutOrder = 12
	local interval = Balance.Economy.playtimeRewardIntervalSeconds
	local progress = ((playtime.secondsToday or 0) % interval) / interval
	meter.set(progress)
	Widgets.caption(column, string.format("%d of %d claimed today.", playtime.claimed or 0, playtime.maximum or 0), 13)

	if playtime.available then
		Widgets.button({
			text = string.format("Claim %d credits", Balance.Economy.playtimeRewardCredits),
			primary = true,
			parent = column,
			layoutOrder = 14,
			onClick = function()
				Net.invokeServer("RewardCommand", "claim_playtime")
				if rebuild then
					task.delay(0.3, rebuild)
				end
			end,
		})
	end
end

--------------------------------------------------------------------------
-- Panel: achievements
--------------------------------------------------------------------------

builders.achievements = function(frame: Frame)
	local profile = StateController.profile()
	if not profile then
		Widgets.emptyState(frame, "Loading.")
		return
	end

	local scroll = Widgets.scroll(frame, 1)
	Widgets.heading(scroll, "Statistics", 1)

	local interesting = {
		{ "expeditions_completed", "Expeditions completed" },
		{ "stations_cleared", "Stations cleared" },
		{ "revives_given", "Crew revived" },
		{ "records_found", "Records recovered" },
		{ "discoveries_found", "Discoveries" },
		{ "creature_repelled", "Times it was driven off" },
		{ "false_instructions_ignored", "False transmissions ignored" },
		{ "distance_driven", "Track driven (studs)" },
		{ "times_downed", "Times downed" },
	}
	for index, entry in interesting do
		Widgets.statRow(scroll, entry[2], Format.groupedNumber(profile.stats[entry[1]] or 0), 1 + index)
	end

	Widgets.divider(scroll, 50)
	Widgets.heading(scroll, "Achievements", 51)
	Widgets.caption(scroll, "Unlocked achievements are shown with the date you earned them.", 52)

	for id, unlockedAt in profile.achievements or {} do
		Widgets.statRow(scroll, Format.titleFromId(id), os.date("!%d %b %Y", unlockedAt), 60)
	end
end

--------------------------------------------------------------------------
-- Panel: leaderboard
--------------------------------------------------------------------------

local leaderboardId = "completions"

builders.leaderboard = function(frame: Frame)
	local result = Net.invokeServer("LeaderboardData", leaderboardId)
	if type(result) ~= "table" or not result.ok then
		Widgets.emptyState(frame, "Standings are unavailable right now.")
		return
	end

	local column = Widgets.column(frame, 1)
	local names: { string } = {}
	local ids: { string } = {}
	for _, board in result.boards or {} do
		table.insert(names, board.name)
		table.insert(ids, board.id)
	end

	local scroll = Widgets.scroll(column, 0.25)
	scroll.LayoutOrder = 10
	scroll.Size = UDim2.new(1, 0, 1, -Theme.space(10))

	local function render(entries: { any }, format: string)
		for _, child in scroll:GetChildren() do
			if not child:IsA("UIListLayout") and not child:IsA("UIPadding") then
				child:Destroy()
			end
		end
		if result.available == false then
			Widgets.emptyState(scroll, "Leaderboards need a published place; they are inactive in Studio.")
			return
		end
		if #entries == 0 then
			Widgets.emptyState(scroll, "No entries yet. Be the first.")
			return
		end
		for _, entry in entries do
			local value = if format == "duration" then Format.clock(entry.value) else Format.groupedNumber(entry.value)
			Widgets.statRow(scroll, string.format("%d.  %s", entry.rank, entry.name), value, entry.rank)
		end
	end

	local _, select = Widgets.tabs(column, names, function(index)
		leaderboardId = ids[index] or "completions"
		local refreshed = Net.invokeServer("LeaderboardData", leaderboardId)
		if type(refreshed) == "table" then
			local format = "number"
			for _, board in refreshed.boards or {} do
				if board.id == leaderboardId then
					format = board.format
				end
			end
			render(refreshed.entries or {}, format)
		end
	end)
	select(table.find(ids, leaderboardId) or 1)
end

--------------------------------------------------------------------------
-- Panel: settings
--------------------------------------------------------------------------

local function slider(parent: Instance, label: string, value: number, order: number, onChange: (number) -> ())
	local card = Widgets.panel({
		name = "Slider",
		size = UDim2.new(1, 0, 0, 0),
		padding = 1,
		background = Theme.colour("surface"),
		parent = parent,
	})
	card.AutomaticSize = Enum.AutomaticSize.Y
	card.LayoutOrder = order

	local column = Widgets.column(card, 0.5)
	local text = Widgets.label({
		text = string.format("%s   %d%%", label, math.floor(value * 100 + 0.5)),
		size = "small",
		parent = column,
		layoutOrder = 1,
	})

	-- Stepped buttons rather than a drag track: a drag target is unreliable on
	-- touch and impossible on a gamepad, and precision is not needed here.
	local row = Widgets.row(column, 0.5)
	row.LayoutOrder = 2
	local current = value
	local function apply(delta: number)
		current = math.clamp(current + delta, 0, 1)
		text.Text = string.format("%s   %d%%", label, math.floor(current * 100 + 0.5))
		onChange(current)
	end
	Widgets.button({ text = "-", width = UDim.new(0.5, -Theme.space(0.25)), parent = row, onClick = function()
		apply(-0.1)
	end })
	Widgets.button({ text = "+", width = UDim.new(0.5, -Theme.space(0.25)), parent = row, onClick = function()
		apply(0.1)
	end })
end

local function toggle(parent: Instance, label: string, detail: string, value: boolean, order: number, onChange: (boolean) -> ())
	local card = Widgets.panel({
		name = "Toggle",
		size = UDim2.new(1, 0, 0, 0),
		padding = 1,
		background = Theme.colour("surface"),
		parent = parent,
	})
	card.AutomaticSize = Enum.AutomaticSize.Y
	card.LayoutOrder = order

	local column = Widgets.column(card, 0.4)
	Widgets.label({ text = label, size = "body", font = Theme.Font.heading, parent = column, layoutOrder = 1 })
	if detail ~= "" then
		Widgets.caption(column, detail, 2)
	end
	local current = value
	local button
	button = Widgets.button({
		text = if current then "On" else "Off",
		parent = column,
		layoutOrder = 3,
		onClick = function()
			current = not current
			button.setText(if current then "On" else "Off")
			onChange(current)
		end,
	})
end

builders.settings = function(frame: Frame)
	local scroll = Widgets.scroll(frame, 1)
	local order = 0
	local function nextOrder()
		order += 1
		return order
	end

	local function setSetting(name: string, value: any)
		Net.fireServer("SetSetting", name, value)
	end

	Widgets.heading(scroll, "Audio", nextOrder())
	local volumes = {
		{ "masterVolume", "Master" },
		{ "musicVolume", "Music" },
		{ "ambienceVolume", "Ambience" },
		{ "sfxVolume", "Effects" },
		{ "trainVolume", "Train" },
		{ "voiceVolume", "Radio and voice" },
		{ "uiVolume", "Interface" },
		{ "creatureVolume", "Threat" },
	}
	for _, entry in volumes do
		local key = entry[1]
		slider(scroll, entry[2], StateController.setting(key, 0.8), nextOrder(), function(value)
			setSetting(key, value)
		end)
	end

	Widgets.heading(scroll, "Accessibility", nextOrder())
	toggle(scroll, "Subtitles", "Shows spoken lines and important sounds as text.", StateController.setting("subtitles", true) == true, nextOrder(), function(value)
		setSetting("subtitles", value)
	end)
	toggle(scroll, "Directional sound cues", "Draws an on-screen arrow towards important sounds.", StateController.setting("directionalCues", false) == true, nextOrder(), function(value)
		setSetting("directionalCues", value)
	end)
	toggle(scroll, "Reduced motion", "Removes camera sway, bob and panel animation.", StateController.setting("reducedMotion", false) == true, nextOrder(), function(value)
		setSetting("reducedMotion", value)
		Theme.setReducedMotion(value)
	end)
	toggle(scroll, "Reduced flashing", "Removes rapid light flicker effects.", StateController.setting("reducedFlashing", false) == true, nextOrder(), function(value)
		setSetting("reducedFlashing", value)
		Theme.setReducedFlashing(value)
	end)
	toggle(scroll, "High contrast interface", "Stronger borders and brighter text.", StateController.setting("highContrast", false) == true, nextOrder(), function(value)
		setSetting("highContrast", value)
		Theme.setHighContrast(value)
	end)

	Widgets.heading(scroll, "Camera and controls", nextOrder())
	slider(scroll, "Camera shake", StateController.setting("cameraShake", 1), nextOrder(), function(value)
		setSetting("cameraShake", value)
	end)
	toggle(scroll, "Hold to sprint", "Off means sprint toggles instead.", StateController.setting("holdToSprint", true) == true, nextOrder(), function(value)
		setSetting("holdToSprint", value)
	end)
	toggle(scroll, "Invert vertical look", "", StateController.setting("invertY", false) == true, nextOrder(), function(value)
		setSetting("invertY", value)
	end)

	Widgets.heading(scroll, "Controls reference", nextOrder())
	for _, action in InputController.Actions do
		local keyName = if action.key then action.key.Name else "Mouse"
		Widgets.statRow(scroll, action.label, keyName, nextOrder())
	end

	Widgets.divider(scroll, nextOrder())
	Widgets.caption(scroll, string.format("%s  build %s", GameConfig.GameName, GameConfig.BuildId), nextOrder())
end

--------------------------------------------------------------------------
-- Panel: event
--------------------------------------------------------------------------

builders.event = function(frame: Frame)
	Net.invokeServer("EventCommand", "state")
	local event = StateController.get("event")
	if not event or not event.active then
		Widgets.emptyState(frame, "No event is running at the moment.")
		return
	end

	local scroll = Widgets.scroll(frame, 1)
	Widgets.label({
		text = event.name,
		size = "title",
		font = Theme.Font.display,
		colour = Theme.colour("brass"),
		parent = scroll,
		layoutOrder = 1,
	})
	Widgets.caption(scroll, event.tagline or "", 2)
	Widgets.label({ text = event.description or "", size = "small", colour = Theme.colour("textMuted"), parent = scroll, layoutOrder = 3 })

	Widgets.statRow(scroll, event.tokenName or "Tokens", Format.groupedNumber(event.tokens or 0), 4)
	if not event.accepting then
		Widgets.caption(scroll, "The event has ended. You can still claim what you earned.", 5)
	end

	for index, reward in event.rewards or {} do
		local card = Widgets.panel({
			name = "Reward",
			size = UDim2.new(1, 0, 0, 0),
			padding = 1.25,
			background = Theme.colour("surface"),
			parent = scroll,
		})
		card.AutomaticSize = Enum.AutomaticSize.Y
		card.LayoutOrder = 10 + index

		local column = Widgets.column(card, 0.4)
		Widgets.label({ text = reward.title, size = "body", font = Theme.Font.heading, parent = column, layoutOrder = 1 })
		Widgets.caption(column, reward.description, 2)
		local meter = Widgets.meter(column, Theme.colour("brass"), Theme.space(1))
		meter.instance.LayoutOrder = 3
		meter.set(math.clamp((event.tokens or 0) / math.max(1, reward.threshold), 0, 1))
		Widgets.caption(column, string.format("%d / %d", math.min(event.tokens or 0, reward.threshold), reward.threshold), 4)

		if reward.claimed then
			Widgets.caption(column, "Claimed.", 5)
		elseif reward.earned then
			Widgets.button({
				text = "Claim",
				primary = true,
				parent = column,
				layoutOrder = 5,
				onClick = function()
					Net.invokeServer("EventCommand", "claim", reward.threshold)
					if rebuild then
						task.delay(0.3, rebuild)
					end
				end,
			})
		end
	end
end

--------------------------------------------------------------------------
-- Panel: results
--------------------------------------------------------------------------

local lastResults: { [string]: any }? = nil

builders.results = function(frame: Frame)
	local results = lastResults
	if not results then
		Widgets.emptyState(frame, "No report available.")
		return
	end

	local scroll = Widgets.scroll(frame, 1)
	Widgets.label({
		text = if results.success then "The signal is out" else "The line went quiet",
		size = "display",
		font = Theme.Font.display,
		colour = if results.success then Theme.colour("signalGreen") else Theme.colour("signalRed"),
		parent = scroll,
		layoutOrder = 1,
	})
	Widgets.caption(scroll, if results.success then "Chapter One complete." else "The expedition ended early.", 2)

	Widgets.statRow(scroll, "Time", Format.clock(results.elapsed or 0), 3)
	Widgets.statRow(scroll, "Stations cleared", string.format("%d of %d", results.stationsCleared or 0, results.stationCount or 5), 4)
	Widgets.statRow(scroll, "Optional objectives", tostring(results.optionalCleared or 0), 5)
	Widgets.statRow(scroll, "Discoveries", tostring(results.discoveries or 0), 6)
	Widgets.statRow(scroll, "Crew revived", tostring(results.revives or 0), 7)
	Widgets.statRow(scroll, "Times downed", tostring(results.downs or 0), 8)
	Widgets.statRow(scroll, "False transmissions ignored", tostring(results.falseIgnored or 0), 9)
	Widgets.statRow(scroll, "False transmissions followed", tostring(results.falseFollowed or 0), 10)
	Widgets.divider(scroll, 11)
	Widgets.statRow(scroll, "Credits earned", Format.groupedNumber(results.credits or 0), 12)
	Widgets.statRow(scroll, "XP earned", Format.groupedNumber(results.xp or 0), 13)
	if (results.levelsGained or 0) > 0 then
		Widgets.statRow(scroll, "Levels gained", string.format("%d  (now %d)", results.levelsGained, results.level), 14)
	end

	Widgets.button({
		text = "Back to the yard",
		primary = true,
		parent = scroll,
		layoutOrder = 20,
		onClick = function()
			MenuController.close()
		end,
	})
end

--------------------------------------------------------------------------
-- Panel: admin
--------------------------------------------------------------------------

builders.admin = function(frame: Frame)
	local admin = StateController.get("admin")
	if not admin or not admin.role or admin.role == "player" then
		Widgets.emptyState(frame, "You do not have administrative access.")
		return
	end

	local column = Widgets.column(frame, 1)
	Widgets.caption(column, string.format("Signed in as %s.", admin.role), 1)
	Widgets.caption(column, "Every command is re-checked on the server against your user ID. This panel is a convenience, not an authorisation.", 2)

	local input = Instance.new("TextBox")
	input.Name = "Command"
	input.Size = UDim2.new(1, 0, 0, Theme.minTouchTarget())
	input.BackgroundColor3 = Theme.colour("surfaceRaised")
	input.BorderSizePixel = 0
	input.FontFace = Theme.Font.mono
	input.TextSize = Theme.textSize("body")
	input.TextColor3 = Theme.colour("text")
	input.PlaceholderText = "command argument argument"
	input.ClearTextOnFocus = false
	input.LayoutOrder = 3
	Widgets.applyCorner(input)
	input.Parent = column

	local output = Widgets.label({
		text = "",
		size = "small",
		font = Theme.Font.mono,
		colour = Theme.colour("textMuted"),
		parent = column,
		layoutOrder = 4,
	})

	local function run()
		local text = input.Text
		if text == "" then
			return
		end
		local parts: { string } = {}
		for word in string.gmatch(text, "%S+") do
			table.insert(parts, word)
		end
		local command = table.remove(parts, 1)
		local a, b, c = parts[1], parts[2], parts[3]
		-- Numeric arguments are sent as numbers so the server's guards accept
		-- them without having to parse strings.
		local result = Net.invokeServer("AdminCommand", command, tonumber(a) or a, tonumber(b) or b, tonumber(c) or c)
		if type(result) == "table" then
			if result.ok then
				output.Text = tostring(result.message or "ok")
				output.TextColor3 = Theme.colour("signalGreen")
			else
				output.Text = tostring(result.message or result.error or "failed")
				output.TextColor3 = Theme.colour("signalRed")
			end
		end
		input.Text = ""
	end

	input.FocusLost:Connect(function(enterPressed)
		if enterPressed then
			run()
		end
	end)
	Widgets.button({ text = "Run", primary = true, parent = column, layoutOrder = 5, onClick = run })

	Widgets.divider(column, 6)
	Widgets.heading(column, "Commands", 7)
	local scroll = Widgets.scroll(column, 0.25)
	scroll.LayoutOrder = 8
	scroll.Size = UDim2.new(1, 0, 1, -Theme.space(24))
	for index, entry in admin.commands or {} do
		Widgets.statRow(scroll, entry.usage, entry.description, index)
	end
end

--------------------------------------------------------------------------

function MenuController.start()
	local playerGui = player:WaitForChild("PlayerGui")
	local screen = Widgets.screen("LastSignalMenu", Theme.Layer.panel, playerGui)
	gui = screen

	backdrop = Widgets.modalBackdrop(screen, function()
		MenuController.close()
	end)
	;(backdrop :: TextButton).Visible = false

	local insets = Theme.safeInsets()
	-- On a phone the panel is full width; on a desktop it is a centred column,
	-- because a full-width panel on a wide screen is unreadable.
	local width = if Theme.platform() == "phone" then UDim.new(1, -insets.left - insets.right) else UDim.new(0, Theme.space(60))

	local frame = Widgets.panel({
		name = "Shell",
		size = UDim2.new(width, UDim.new(1, -insets.top - insets.bottom - Theme.space(2))),
		position = UDim2.fromScale(0.5, 0.5),
		anchor = Vector2.new(0.5, 0.5),
		padding = 1.5,
		background = Theme.colour("backdrop"),
		parent = screen,
	})
	frame.Visible = false
	shell = frame

	local header = Instance.new("Frame")
	header.Name = "Header"
	header.BackgroundTransparency = 1
	header.Size = UDim2.new(1, 0, 0, Theme.minTouchTarget())
	header.Parent = frame

	titleLabel = Widgets.label({
		text = "",
		size = "title",
		font = Theme.Font.display,
		parent = header,
	})
	local resolvedTitle = titleLabel :: TextLabel
	resolvedTitle.Size = UDim2.new(1, -Theme.minTouchTarget(), 1, 0)
	resolvedTitle.AutomaticSize = Enum.AutomaticSize.None
	resolvedTitle.TextYAlignment = Enum.TextYAlignment.Center

	Widgets.button({
		text = "Close",
		width = UDim.new(0, Theme.space(9)),
		parent = header,
		onClick = function()
			MenuController.close()
		end,
	}).instance.Position = UDim2.new(1, -Theme.space(9), 0, 0)

	local bodyFrame = Instance.new("Frame")
	bodyFrame.Name = "Body"
	bodyFrame.BackgroundTransparency = 1
	bodyFrame.Position = UDim2.fromOffset(0, Theme.minTouchTarget() + Theme.space(1))
	bodyFrame.Size = UDim2.new(1, 0, 1, -Theme.minTouchTarget() - Theme.space(1))
	bodyFrame.ClipsDescendants = true
	bodyFrame.Parent = frame
	body = bodyFrame

	InputController.Action:Connect(function(actionId, pressed)
		if not pressed then
			return
		end
		if actionId == "menu" then
			MenuController.open("main")
		elseif actionId == "inventory" then
			MenuController.open(if StateController.isOnExpedition() then "inventory" else "loadout")
		elseif actionId == "crew" then
			MenuController.open("crew")
		elseif actionId == "objectives" then
			MenuController.open("quests")
		end
	end)

	Net.onClientEvent("ExpeditionState", function(payload)
		if type(payload) == "table" and payload.state == "results" then
			lastResults = payload
			MenuController.open("results")
		end
	end)

	Net.onClientEvent("PurchaseResult", function(payload)
		if type(payload) ~= "table" then
			return
		end
		if currentPanel == "shop" and rebuild then
			task.delay(0.5, rebuild)
		end
	end)

	log.info("started")
end

return MenuController
