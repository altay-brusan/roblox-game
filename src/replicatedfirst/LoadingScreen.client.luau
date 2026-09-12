--!strict
--[[
	LoadingScreen
	-------------
	The first thing a player sees, before anything else has replicated.

	This lives in ReplicatedFirst so it runs before the default loading screen
	and before any other script. It removes Roblox's default screen, shows the
	game's own, and takes itself down once the client is genuinely ready rather
	than after a fixed delay.

	It also has a hard timeout. A loading screen that can never be dismissed is
	worse than one that lets a player into a half-loaded world, because the
	half-loaded world resolves itself in a few seconds and the stuck screen
	never does.
]]

local ContentProvider = game:GetService("ContentProvider")
local Players = game:GetService("Players")
local ReplicatedFirst = game:GetService("ReplicatedFirst")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

ReplicatedFirst:RemoveDefaultLoadingScreen()

--------------------------------------------------------------------------

local gui = Instance.new("ScreenGui")
gui.Name = "LastSignalLoading"
gui.IgnoreGuiInset = true
gui.DisplayOrder = 90
gui.ResetOnSpawn = false
gui.Parent = playerGui

local backdrop = Instance.new("Frame")
backdrop.Name = "Backdrop"
backdrop.BorderSizePixel = 0
backdrop.BackgroundColor3 = Color3.fromRGB(8, 9, 11)
backdrop.Size = UDim2.fromScale(1, 1)
backdrop.Parent = gui

-- A single lamp in the dark: a soft radial glow, built from stacked frames
-- rather than an image so there is nothing to download.
for i = 1, 6 do
	local glow = Instance.new("Frame")
	glow.Name = "Glow" .. i
	glow.BorderSizePixel = 0
	glow.AnchorPoint = Vector2.new(0.5, 0.5)
	glow.Position = UDim2.fromScale(0.5, 0.42)
	glow.Size = UDim2.fromOffset(60 + i * 70, 60 + i * 70)
	glow.BackgroundColor3 = Color3.fromRGB(198, 158, 78)
	glow.BackgroundTransparency = 0.86 + i * 0.022
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = glow
	glow.Parent = backdrop
end

local title = Instance.new("TextLabel")
title.Name = "Title"
title.BackgroundTransparency = 1
title.AnchorPoint = Vector2.new(0.5, 0.5)
title.Position = UDim2.fromScale(0.5, 0.42)
title.Size = UDim2.fromScale(0.8, 0.12)
title.Text = "LAST SIGNAL"
title.FontFace = Font.fromEnum(Enum.Font.GothamBold)
title.TextScaled = true
title.TextColor3 = Color3.fromRGB(232, 228, 218)
title.Parent = backdrop

local sizeConstraint = Instance.new("UITextSizeConstraint")
sizeConstraint.MaxTextSize = 52
sizeConstraint.MinTextSize = 20
sizeConstraint.Parent = title

local subtitle = Instance.new("TextLabel")
subtitle.Name = "Subtitle"
subtitle.BackgroundTransparency = 1
subtitle.AnchorPoint = Vector2.new(0.5, 0)
subtitle.Position = UDim2.fromScale(0.5, 0.52)
subtitle.Size = UDim2.fromScale(0.8, 0.05)
subtitle.Text = "A RIPGAMES production"
subtitle.FontFace = Font.fromEnum(Enum.Font.Gotham)
subtitle.TextScaled = true
subtitle.TextColor3 = Color3.fromRGB(158, 156, 150)
subtitle.Parent = backdrop

local subtitleConstraint = Instance.new("UITextSizeConstraint")
subtitleConstraint.MaxTextSize = 18
subtitleConstraint.MinTextSize = 11
subtitleConstraint.Parent = subtitle

local status = Instance.new("TextLabel")
status.Name = "Status"
status.BackgroundTransparency = 1
status.AnchorPoint = Vector2.new(0.5, 1)
status.Position = UDim2.fromScale(0.5, 0.88)
status.Size = UDim2.fromScale(0.8, 0.05)
status.Text = "Connecting"
status.FontFace = Font.fromEnum(Enum.Font.Gotham)
status.TextScaled = true
status.TextColor3 = Color3.fromRGB(108, 108, 104)
status.Parent = backdrop

local statusConstraint = Instance.new("UITextSizeConstraint")
statusConstraint.MaxTextSize = 15
statusConstraint.MinTextSize = 10
statusConstraint.Parent = status

--------------------------------------------------------------------------

local dismissed = false

local function dismiss(reason: string)
	if dismissed then
		return
	end
	dismissed = true
	status.Text = reason
	local tween = TweenService:Create(backdrop, TweenInfo.new(0.8), { BackgroundTransparency = 1 })
	for _, child in backdrop:GetDescendants() do
		if child:IsA("TextLabel") then
			TweenService:Create(child, TweenInfo.new(0.5), { TextTransparency = 1 }):Play()
		elseif child:IsA("Frame") then
			TweenService:Create(child, TweenInfo.new(0.6), { BackgroundTransparency = 1 }):Play()
		end
	end
	tween.Completed:Once(function()
		gui:Destroy()
	end)
	tween:Play()
end

-- The hard timeout. Whatever else happens, the player gets into the game.
task.delay(25, function()
	dismiss("Ready")
end)

task.spawn(function()
	status.Text = "Waiting for the yard"

	-- Wait for the shared module tree, which is the first thing the server
	-- replicates and a reliable signal that the world is coming.
	local shared = ReplicatedStorage:WaitForChild("LastSignal", 20)
	if not shared then
		dismiss("Ready")
		return
	end

	status.Text = "Preloading"
	-- Preloading the world is not appropriate here: the expedition lanes are
	-- enormous and stream in as needed. Only the lobby matters at this point.
	local lobby = workspace:FindFirstChild("LastSignalWorld")
	if lobby then
		local toPreload: { Instance } = {}
		local lobbyModel = lobby:FindFirstChild("Lobby")
		if lobbyModel then
			for _, descendant in lobbyModel:GetChildren() do
				table.insert(toPreload, descendant)
				if #toPreload >= 60 then
					break
				end
			end
		end
		if #toPreload > 0 then
			pcall(function()
				ContentProvider:PreloadAsync(toPreload)
			end)
		end
	end

	status.Text = "Waiting for your character"
	local deadline = os.clock() + 12
	while os.clock() < deadline do
		if player.Character and player.Character:FindFirstChild("HumanoidRootPart") then
			break
		end
		task.wait(0.2)
	end

	-- A short settle so the first frame the player sees is a lit yard rather
	-- than an un-streamed grey box.
	task.wait(1)
	dismiss("Ready")
end)
