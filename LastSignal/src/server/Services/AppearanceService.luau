--!strict
--[[
	AppearanceService
	-----------------
	What a crew member visibly carries: their lamp and their badge.

	THE LAMP
	--------
	The lamp has always had a battery, a meter, a toggle on F and a flicker
	when it runs low, but nothing ever produced light. This service gives every
	character a real beam: a SpotLight in the head that follows the vitals
	(on, off, flickering when low), and the lantern itself hanging at the hip.
	Lamp cosmetics colour the lantern and tint the beam. Range, angle and
	brightness come from Balance and are the same for everyone, as
	CosmeticRegistry promises.

	The server owns the light so every player sees every lamp. The owning
	client turns its own beam to follow the camera (LampController), because
	the head does not look up and down with the view.

	THE BADGE
	---------
	The Conductor's badge is a small enamel plate above the character's head,
	seen by other players. It is a patch-slot cosmetic, so it also appears
	beside the player's name on the crew board.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.LastSignal

local Balance = require(Shared.Config.Balance)
local CosmeticRegistry = require(Shared.Registry.CosmeticRegistry)
local Logger = require(Shared.Core.Logger)

local DataService = require(script.Parent.DataService)
local LoadoutService = require(script.Parent.LoadoutService)
local SurvivalService = require(script.Parent.SurvivalService)

local log = Logger.new("AppearanceService")
local C = Color3.fromRGB

local AppearanceService = {}

local DEFAULT_BEAM = C(255, 240, 214)

local function part(name: string, size: Vector3, colour: Color3, material: Enum.Material, parent: Instance): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.Color = colour
	p.Material = material
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Massless = true
	p.CastShadow = false
	p.Parent = parent
	return p
end

local function weldTo(base: BasePart, p: BasePart, offset: CFrame)
	p.CFrame = base.CFrame * offset
	local weld = Instance.new("Weld")
	weld.Part0 = base
	weld.Part1 = p
	weld.C0 = offset
	weld.Parent = p
end

--- Builds (or rebuilds) the lamp and badge for a character from the profile.
function AppearanceService.dress(player: Player)
	local character = player.Character
	local profile = DataService.getProfile(player)
	if not character or not profile then
		return
	end
	local head = character:FindFirstChild("Head")
	local hip = character:FindFirstChild("LowerTorso") or character:FindFirstChild("Torso")
	if not head or not head:IsA("BasePart") or not hip or not hip:IsA("BasePart") then
		return
	end
	for _, name in { "Lantern", "Badge" } do
		local old = character:FindFirstChild(name)
		if old then
			old:Destroy()
		end
	end
	local oldAttachment = head:FindFirstChild("LampAttachment")
	if oldAttachment then
		oldAttachment:Destroy()
	end

	-- The beam.
	local lampDef = CosmeticRegistry.get(profile.loadout.lamp)
	local tint = if lampDef and lampDef.beamTint then lampDef.beamTint else DEFAULT_BEAM
	local attachment = Instance.new("Attachment")
	attachment.Name = "LampAttachment"
	attachment.Position = Vector3.new(0, 0.1, -0.5)
	attachment.Parent = head
	local beam = Instance.new("SpotLight")
	beam.Name = "Lamp"
	beam.Face = Enum.NormalId.Front
	-- SpotLight range stops at 60 studs, below the balance figure.
	beam.Range = math.min(60, Balance.Flashlight.range)
	beam.Angle = Balance.Flashlight.angle
	beam.Brightness = Balance.Flashlight.brightness
	beam.Color = tint
	beam.Shadows = true
	beam.Enabled = false
	beam.Parent = attachment

	-- The lantern at the hip.
	local lantern = Instance.new("Model")
	lantern.Name = "Lantern"
	local body = if lampDef and lampDef.body then lampDef.body else C(70, 72, 70)
	local accent = if lampDef and lampDef.accent then lampDef.accent else C(150, 120, 64)
	local side = if hip.Name == "LowerTorso" then 1.15 else 1.2
	local case = part("Case", Vector3.new(0.5, 0.65, 0.5), body, (lampDef and lampDef.material) or Enum.Material.Metal, lantern)
	weldTo(hip, case, CFrame.new(side, -0.35, -0.1))
	local lens = part("Lens", Vector3.new(0.38, 0.4, 0.52), tint, Enum.Material.Neon, lantern)
	weldTo(hip, lens, CFrame.new(side, -0.35, -0.12))
	local cap = part("Cap", Vector3.new(0.58, 0.1, 0.58), accent, Enum.Material.Metal, lantern)
	weldTo(hip, cap, CFrame.new(side, 0.0, -0.1))
	local handle = part("Handle", Vector3.new(0.08, 0.3, 0.4), accent, Enum.Material.Metal, lantern)
	weldTo(hip, handle, CFrame.new(side, 0.18, -0.1))
	lantern.Parent = character

	-- The badge.
	local patch = CosmeticRegistry.get(profile.loadout.patch)
	if patch and patch.id == "badge_conductor" then
		local gui = Instance.new("BillboardGui")
		gui.Name = "Badge"
		gui.Size = UDim2.fromOffset(120, 26)
		gui.StudsOffset = Vector3.new(0, 2.4, 0)
		gui.MaxDistance = 70
		gui.Adornee = head
		local plate = Instance.new("Frame")
		plate.Size = UDim2.fromScale(1, 1)
		plate.BackgroundColor3 = C(26, 28, 32)
		plate.Parent = gui
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 5)
		corner.Parent = plate
		local stroke = Instance.new("UIStroke")
		stroke.Color = patch.accent or C(196, 158, 82)
		stroke.Thickness = 2
		stroke.Parent = plate
		local label = Instance.new("TextLabel")
		label.Size = UDim2.fromScale(1, 1)
		label.BackgroundTransparency = 1
		label.Font = Enum.Font.GothamBold
		label.TextSize = 13
		label.TextColor3 = patch.accent or C(196, 158, 82)
		label.Text = "CONDUCTOR"
		label.Parent = plate
		gui.Parent = character
	end
end

--- Matches every lamp to its owner's vitals: on, off, or failing.
local function updateLamps()
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local head = if character then character:FindFirstChild("Head") else nil
		local attachment = if head then head:FindFirstChild("LampAttachment") else nil
		local beam = if attachment then attachment:FindFirstChild("Lamp") else nil
		if not beam or not beam:IsA("SpotLight") then
			continue
		end
		local vitals = SurvivalService.get(player)
		local on = vitals ~= nil and vitals.state ~= "dead" and vitals.flashlightOn and vitals.flashlight > 0
		local brightness = Balance.Flashlight.brightness
		if on and vitals and vitals.flashlight < Balance.Flashlight.lowChargeWarning then
			-- Failing: it stutters, more often the lower it gets.
			local failing = 1 - vitals.flashlight / Balance.Flashlight.lowChargeWarning
			if math.random() < 0.25 + failing * 0.5 then
				brightness *= math.random() * 0.4
			end
		end
		beam.Enabled = on
		beam.Brightness = brightness
		local lantern = if character then character:FindFirstChild("Lantern") else nil
		local lens = if lantern then lantern:FindFirstChild("Lens") else nil
		if lens and lens:IsA("BasePart") then
			lens.Material = if on then Enum.Material.Neon else Enum.Material.Glass
			lens.Transparency = if on then 0 else 0.3
		end
	end
end

function AppearanceService.start()
	local function watch(player: Player)
		player.CharacterAdded:Connect(function(character)
			character:WaitForChild("Head", 10)
			task.wait(0.3)
			AppearanceService.dress(player)
		end)
		if player.Character then
			task.defer(AppearanceService.dress, player)
		end
	end
	Players.PlayerAdded:Connect(watch)
	for _, player in Players:GetPlayers() do
		watch(player)
	end
	DataService.ProfileLoaded:Connect(function(player)
		AppearanceService.dress(player)
	end)
	-- A new lamp or badge chosen in the loadout shows straight away.
	LoadoutService.Changed:Connect(function(player, slot)
		if slot == "lamp" or slot == "patch" then
			AppearanceService.dress(player)
		end
	end)

	task.spawn(function()
		while true do
			task.wait(0.25)
			updateLamps()
		end
	end)
	log.info("started")
end

return AppearanceService
