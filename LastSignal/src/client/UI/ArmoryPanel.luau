--!strict
--[[
	ArmoryPanel
	-----------
	The lobby armory: every weapon you can carry, inspectable, with what it is
	good and bad at, and the four Game Passes with exactly what they include.

	HONESTY RULES THE PANEL FOLLOWS
	-------------------------------
	  - Prices are the live Roblox price fetched by the server, never a number
	    written here. Until it arrives the card says so.
	  - A pass that does not exist on Roblox yet says "Not available yet", and
	    there is no buy button. Nothing pretends a purchase happened.
	  - Ownership comes from the server's profile mirror of Roblox. If Roblox
	    could not be asked, the panel says that and offers to ask again,
	    instead of showing a wrong "not owned".
	  - Owning a weapon is permanent. Equipping it chooses what you carry on
	    your next run, and only one primary weapon can be carried.
	  - A purchase prompt opens only from the Buy button.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("LastSignal")

local CosmeticRegistry = require(Shared.Registry.CosmeticRegistry)
local Format = require(Shared.Core.Format)
local Monetization = require(Shared.Config.Monetization)
local Net = require(Shared.Core.Net)
local WeaponModels = require(Shared.Registry.WeaponModels)
local WeaponRegistry = require(Shared.Registry.WeaponRegistry)

local StateController = require(script.Parent.Parent.Controllers.StateController)
local Theme = require(script.Parent.Theme)
local Widgets = require(script.Parent.Widgets)

local ArmoryPanel = {}

local C = Color3.fromRGB
local player = Players.LocalPlayer

-- The Conductor Collection is equipped as three loadout slots at once.
local CONDUCTOR_SET: { [string]: string } = { finish = "finish_conductor", lamp = "lantern_conductor", patch = "badge_conductor" }
local STANDARD_SET: { [string]: string } = { finish = "finish_standard", lamp = "lantern_standard", patch = "" }

local tab = "premium"

--- A turntable preview: the real weapon model, slowly turning, and draggable.
local function preview(parent: Instance, def: WeaponRegistry.WeaponDef, finish: WeaponModels.Finish?, order: number)
	local viewport = Instance.new("ViewportFrame")
	viewport.Name = "Preview"
	viewport.Size = UDim2.new(1, 0, 0, 150)
	viewport.BackgroundColor3 = C(18, 20, 22)
	viewport.LayoutOrder = order
	viewport.Ambient = C(150, 150, 160)
	viewport.LightColor = C(255, 240, 220)
	viewport.LightDirection = Vector3.new(-1, -1.2, -0.6)
	viewport.Parent = parent
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = viewport

	local built = WeaponModels.build(def, finish)
	built.root.Anchored = true
	built.model.Parent = viewport
	for _, part in built.glow do
		-- The arc's capacitor glows in the armory, as if fully charged.
		if part.Name == "Capacitor" then
			part.Material = Enum.Material.Neon
			part.Color = C(170, 230, 255)
		end
	end
	local camera = Instance.new("Camera")
	camera.FieldOfView = 30
	camera.Parent = viewport
	viewport.CurrentCamera = camera
	local _, size = built.model:GetBoundingBox()
	local distance = math.max(size.X, size.Y, size.Z) * 1.45 + 0.5

	local yaw = math.rad(70)
	local dragging = false
	local lastX = 0
	viewport.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			lastX = input.Position.X
		end
	end)
	viewport.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end)
	viewport.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			yaw += (input.Position.X - lastX) * 0.02
			lastX = input.Position.X
		end
	end)

	local centre = built.model:GetBoundingBox().Position
	local connection: RBXScriptConnection? = nil
	connection = RunService.RenderStepped:Connect(function(dt: number)
		if not viewport.Parent then
			if connection then
				connection:Disconnect()
			end
			return
		end
		if not dragging then
			yaw += dt * 0.5
		end
		local eye = centre + Vector3.new(math.sin(yaw), 0.35, math.cos(yaw)).Unit * distance
		camera.CFrame = CFrame.lookAt(eye, centre)
	end)
end

local function bullets(parent: Instance, heading: string, lines: { string }?, colour: Color3, order: number)
	if not lines or #lines == 0 then
		return
	end
	local text = heading
	for _, line in lines do
		text ..= "\n  •  " .. line
	end
	Widgets.label({ text = text, size = "small", colour = colour, wrap = true, parent = parent, layoutOrder = order })
end

local function finishFromLoadout(): WeaponModels.Finish?
	local profile = StateController.profile()
	local def = if profile and profile.loadout then CosmeticRegistry.get(profile.loadout.finish) else nil
	if not def or def.slot ~= "finish" then
		return nil
	end
	return { body = def.body, accent = def.accent, material = def.material }
end

--- The price and ownership line for one pass, filled in once the server's
--- live catalogue arrives.
type PassUi = { status: TextLabel, buy: Widgets.Button }

function ArmoryPanel.build(frame: Frame, rebuild: () -> ())
	local profile = StateController.profile()
	if not profile then
		Widgets.emptyState(frame, "Loading your profile.")
		return
	end
	local column = Widgets.column(frame, 0.8)

	-- Ownership check state, from the server.
	local check = player:GetAttribute("PassCheck")
	local checkText = "One primary weapon per run, whatever you own. Everything in the story can be finished with the free kit."
	if check == "checking" then
		checkText = "Checking your passes with Roblox..."
	elseif check == "failed" then
		checkText = "Roblox could not confirm your passes just now. Anything you own is safe; press Check again."
	end
	Widgets.caption(column, checkText, 1)
	if check == "failed" then
		local again = Widgets.button({ text = "Check again", parent = column, layoutOrder = 2 })
		again.instance.Activated:Connect(function()
			again.setEnabled(false)
			again.setText("Checking...")
			local result = Net.invokeServer("ShopCommand", "refresh_passes")
			if type(result) == "table" and result.error == "WAIT" then
				again.setText("Wait a moment, then try again")
			end
			task.delay(6, rebuild)
		end)
	end

	local _, select = Widgets.tabs(column, { "Premium", "Free kit" }, function(index)
		local wanted = if index == 1 then "premium" else "free"
		if wanted ~= tab then
			tab = wanted
			rebuild()
		end
	end)
	select(if tab == "premium" then 1 else 2)

	local scroll = Widgets.scroll(column, 0.8)
	scroll.LayoutOrder = 10
	local passUis: { [string]: PassUi } = {}

	local function card(order: number): Frame
		local c = Widgets.panel({
			name = "Card",
			size = UDim2.new(1, 0, 0, 0),
			padding = 1.0,
			background = Theme.colour("surface"),
			parent = scroll,
		})
		c.AutomaticSize = Enum.AutomaticSize.Y
		c.LayoutOrder = order
		return Widgets.column(c, 0.4)
	end

	local equipped = profile.loadout.primaryWeapon
	local weapons = WeaponRegistry.all()
	table.sort(weapons, function(a, b)
		return a.name < b.name
	end)

	local order = 0
	for _, def in weapons do
		local premium = def.passKey ~= nil
		if (tab == "premium") ~= premium then
			continue
		end
		order += 1
		local body = card(order)
		local owned = def.startingLoadout or StateController.owns("weapon", def.id)
		local locked = (profile.level or 1) < def.unlockLevel
		preview(body, def, finishFromLoadout(), 1)
		Widgets.label({ text = def.name, size = "heading", font = Theme.Font.heading, parent = body, layoutOrder = 2 })
		Widgets.label({ text = def.description, size = "small", colour = Theme.colour("textMuted"), wrap = true, parent = body, layoutOrder = 3 })
		bullets(body, "Strengths", def.pros, Theme.colour("signalGreen"), 4)
		bullets(body, "Weaknesses", def.cons, Theme.colour("signalAmber"), 5)
		local rules: string
		if def.arc then
			rules = string.format("Heat: %d per burst, overheats at 100 and locks for %d s. Charge %.1f s. Reach %d studs.", def.arc.heatPerBurst, def.arc.overheatLockSeconds, def.arc.chargeSeconds, def.range)
		elseif def.kind == "firearm" then
			rules = string.format("%d-round magazine, %.1f s reload. Ammunition: %s rounds%s.", def.magazineSize or 1, def.reloadSeconds or 0, def.ammoType or "-", if def.startingRounds then string.format(", %d to start each run", def.startingRounds) else "")
		else
			rules = "Melee. Costs stamina per swing."
		end
		Widgets.label({ text = rules, size = "small", font = Theme.Font.mono, wrap = true, parent = body, layoutOrder = 6 })

		local status = Widgets.label({ text = "", size = "small", font = Theme.Font.mono, parent = body, layoutOrder = 7 })
		if owned and not locked then
			status.Text = if premium then "Owned permanently" else "Free"
			status.TextColor3 = Theme.colour("signalGreen")
			local isEquipped = equipped == def.id
			local equip = Widgets.button({
				text = if isEquipped then "Equipped for your next run (unequip)" else "Equip for your next run",
				primary = not isEquipped,
				parent = body,
				layoutOrder = 8,
			})
			equip.instance.Activated:Connect(function()
				equip.setEnabled(false)
				-- Unequipping returns to the free wrench.
				Net.fireServer("SetSetting", "loadout_primary", if isEquipped then "wrench" else def.id)
				task.delay(0.4, rebuild)
			end)
		elseif locked then
			status.Text = string.format("Unlocks at level %d", def.unlockLevel)
			status.TextColor3 = Theme.colour("textMuted")
		elseif premium and def.passKey then
			status.Text = "Checking price..."
			status.TextColor3 = Theme.colour("textMuted")
			local buy = Widgets.button({ text = "Buy pass", primary = true, enabled = false, parent = body, layoutOrder = 8 })
			passUis[def.passKey] = { status = status, buy = buy }
		else
			status.Text = "Buy with RIP Coin at the Phantom Exchange"
			status.TextColor3 = Theme.colour("textMuted")
		end
	end

	-- The Conductor Collection.
	if tab == "premium" then
		order += 1
		local body = card(order)
		local pass = Monetization.get("pass_conductor")
		local owned = StateController.owns("cosmetic", "finish_conductor")
		local revolver = WeaponRegistry.get("revolver")
		local finish = CosmeticRegistry.get("finish_conductor")
		if revolver and finish then
			preview(body, revolver, { body = finish.body, accent = finish.accent, material = finish.material }, 1)
		end
		Widgets.label({ text = "Conductor Collection", size = "heading", font = Theme.Font.heading, parent = body, layoutOrder = 2 })
		Widgets.label({ text = if pass then pass.blurb else "", size = "small", colour = Theme.colour("textMuted"), wrap = true, parent = body, layoutOrder = 3 })
		bullets(body, "Includes", {
			"Conductor finish: black enamel and brass on every weapon (shown above on the revolver)",
			"Conductor's Lamp: brass lantern at the hip, warm beam",
			"Conductor's Badge: enamel CONDUCTOR plate above your head, mark on the crew board",
		}, Theme.colour("text"), 4)
		Widgets.caption(body, "Appearance only. No gameplay advantage.", 5)
		local status = Widgets.label({ text = "", size = "small", font = Theme.Font.mono, parent = body, layoutOrder = 7 })
		if owned then
			status.Text = "Owned permanently"
			status.TextColor3 = Theme.colour("signalGreen")
			local wearing = profile.loadout.finish == CONDUCTOR_SET.finish
			local wear = Widgets.button({
				text = if wearing then "Wearing it (take it off)" else "Wear the collection",
				primary = not wearing,
				parent = body,
				layoutOrder = 8,
			})
			wear.instance.Activated:Connect(function()
				wear.setEnabled(false)
				local set: { [string]: string } = if wearing then STANDARD_SET else CONDUCTOR_SET
				for slot, id in pairs(set) do
					Net.fireServer("SetSetting", "loadout_" .. slot, id)
				end
				task.delay(0.5, rebuild)
			end)
		else
			status.Text = "Checking price..."
			status.TextColor3 = Theme.colour("textMuted")
			local buy = Widgets.button({ text = "Buy pass", primary = true, enabled = false, parent = body, layoutOrder = 8 })
			passUis["pass_conductor"] = { status = status, buy = buy }
		end
	end

	-- Live prices, after the panel is already on screen.
	if next(passUis) then
		task.spawn(function()
			local result = Net.invokeServer("ShopCommand", "catalogue")
			local entries = if type(result) == "table" and type(result.catalogue) == "table" then result.catalogue.entries else nil
			for key, ui in passUis do
				if not ui.status.Parent then
					continue
				end
				local entry: any = nil
				for _, e in entries or {} do
					if e.key == key then
						entry = e
						break
					end
				end
				if not entries then
					ui.status.Text = "Could not reach the stores. Close and reopen to retry."
					ui.status.TextColor3 = Theme.colour("signalRed")
				elseif not entry then
					ui.status.Text = "Not available yet"
				elseif entry.owned then
					ui.status.Text = "Owned permanently"
					ui.status.TextColor3 = Theme.colour("signalGreen")
				elseif entry.purchasable then
					ui.status.Text = Format.price(entry.price) .. "  (live Roblox price)"
					ui.status.TextColor3 = Theme.colour("brass")
					ui.buy.setEnabled(true)
					ui.buy.instance.Activated:Connect(function()
						-- Disabled until Roblox reports the prompt closed, so a
						-- double click cannot open two prompts.
						ui.buy.setEnabled(false)
						ui.buy.setText("Waiting for Roblox...")
						local prompt = Net.invokeServer("ShopCommand", "prompt_robux", key)
						if type(prompt) ~= "table" or not prompt.ok then
							ui.buy.setText("Buy pass")
							ui.buy.setEnabled(true)
							local reason = if type(prompt) == "table" then tostring(prompt.error) else "no answer"
							ui.status.Text = if reason == "BLOCKED" then "Purchases are paused right now." else "Could not open the purchase (" .. reason .. ")."
							ui.status.TextColor3 = Theme.colour("signalRed")
						end
					end)
				else
					ui.status.Text = entry.unavailableReason or "Not available yet"
				end
			end
		end)
	end

	-- A purchase closing, either way, returns the panel to a true state.
	local connection: RBXScriptConnection? = nil
	connection = Net.onClientEvent("PurchaseResult", function(payload)
		if not frame.Parent then
			if connection then
				connection:Disconnect()
			end
			return
		end
		if type(payload) == "table" and payload.ok then
			-- Ownership arrives with the profile once the server has asked
			-- Roblox; rebuild a moment later to show it.
			task.delay(2.5, rebuild)
		else
			rebuild()
		end
	end) :: any
end

return ArmoryPanel
