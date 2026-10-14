--!strict
--[[
	HorrorEffectsController
	-----------------------
	The visible half of the horror director: the silhouette at the treeline,
	evidence that something passed by, and lights that fail.

	The director has always sent these cues, and the audio controller has
	always skipped them as "handled by the visual effects controller", but no
	such controller existed: three of the nine director events did nothing at
	all on screen. This is that controller.

	Everything here is local to the player it was sent to. A silhouette seen by
	one crew member and not another is the point: it is something you can try
	to describe and nobody else saw.
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("LastSignal")

local Logger = require(Shared.Core.Logger)
local Net = require(Shared.Core.Net)

local log = Logger.new("HorrorEffectsController")
local player = Players.LocalPlayer

local HorrorEffectsController = {}

local effectsFolder: Folder? = nil

local function folder(): Folder
	if effectsFolder and effectsFolder.Parent then
		return effectsFolder
	end
	local made = Instance.new("Folder")
	made.Name = "LocalHorrorEffects"
	made.Parent = Workspace
	effectsFolder = made
	return made
end

local function ignoreList(): { Instance }
	local list: { Instance } = { folder() }
	if player.Character then
		table.insert(list, player.Character)
	end
	return list
end

--- The ground under a point, so effects stand on whatever is there.
local function groundAt(position: Vector3): Vector3
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ignoreList()
	local hit = Workspace:Raycast(position + Vector3.new(0, 40, 0), Vector3.new(0, -120, 0), params)
	return if hit then hit.Position else position
end

local function piece(name: string, size: Vector3, cf: CFrame, colour: Color3, parent: Instance, shape: Enum.PartType?): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.CFrame = cf
	p.Color = colour
	p.Material = Enum.Material.SmoothPlastic
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	if shape then
		p.Shape = shape
	end
	p.Parent = parent
	return p
end

local function fadeOut(model: Instance, seconds: number)
	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") then
			TweenService:Create(part, TweenInfo.new(seconds), { Transparency = 1 }):Play()
		end
	end
	task.delay(seconds + 0.1, function()
		model:Destroy()
	end)
end

--------------------------------------------------------------------------
-- Silhouette
--------------------------------------------------------------------------

-- Too tall, too thin, arms too long, standing still and facing you. It is
-- built from plain dark shapes because at seventy studs in the dark that is
-- all anyone would see.
local function silhouette(position: Vector3, duration: number)
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	local base = groundAt(position)
	local facing = CFrame.lookAt(base, Vector3.new(camera.CFrame.Position.X, base.Y, camera.CFrame.Position.Z))
	local model = Instance.new("Model")
	model.Name = "Silhouette"
	local dark = Color3.fromRGB(8, 8, 10)
	piece("Body", Vector3.new(1.6, 6.5, 0.9), facing * CFrame.new(0, 7.2, 0), dark, model)
	piece("Legs", Vector3.new(1.3, 4.2, 0.7), facing * CFrame.new(0, 2.1, 0), dark, model)
	piece("Head", Vector3.new(1.3, 1.6, 1.1), facing * CFrame.new(0.15, 11.2, 0) * CFrame.Angles(0, 0, math.rad(-12)), dark, model)
	for _, side in { -1, 1 } do
		piece("Arm", Vector3.new(0.45, 7.8, 0.45), facing * CFrame.new(side * 1.1, 5.6, 0) * CFrame.Angles(0, 0, math.rad(side * 4)), dark, model)
	end
	for _, part in model:GetChildren() do
		if part:IsA("BasePart") then
			part.Transparency = 1
			TweenService:Create(part, TweenInfo.new(0.35), { Transparency = 0.05 }):Play()
		end
	end
	model.Parent = folder()
	task.delay(duration, function()
		if model.Parent then
			fadeOut(model, 0.25)
		end
	end)
end

--------------------------------------------------------------------------
-- Evidence
--------------------------------------------------------------------------

local function footprints(position: Vector3)
	local model = Instance.new("Model")
	model.Name = "Footprints"
	-- A trail that comes from the trees, stops beside you, and goes back.
	local angle = math.random() * math.pi * 2
	local away = Vector3.new(math.cos(angle), 0, math.sin(angle))
	local across = Vector3.new(-away.Z, 0, away.X)
	for i = 0, 7 do
		local stride = position + away * (3 + i * 2.6) + across * (if i % 2 == 0 then 0.7 else -0.7)
		local ground = groundAt(stride)
		piece(
			"Print",
			Vector3.new(0.9, 0.05, 1.9),
			CFrame.lookAt(ground + Vector3.new(0, 0.03, 0), ground + Vector3.new(0, 0.03, 0) - away),
			Color3.fromRGB(26, 22, 18),
			model
		)
	end
	model.Parent = folder()
	task.delay(45, function()
		if model.Parent then
			fadeOut(model, 3)
		end
	end)
end

local function scratches(position: Vector3): boolean
	-- Long gouges on the nearest wall within reach.
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ignoreList()
	local origin = position + Vector3.new(0, 1.5, 0)
	local best: RaycastResult? = nil
	for i = 0, 7 do
		local a = i * math.pi / 4
		local hit = Workspace:Raycast(origin, Vector3.new(math.cos(a), 0, math.sin(a)) * 10, params)
		if hit and math.abs(hit.Normal.Y) < 0.3 and (not best or hit.Distance < (best :: RaycastResult).Distance) then
			best = hit
		end
	end
	if not best then
		return false
	end
	local hit = best :: RaycastResult
	local model = Instance.new("Model")
	model.Name = "Scratches"
	local face = CFrame.lookAt(hit.Position + hit.Normal * 0.04, hit.Position + hit.Normal * 2)
	for i = -1, 1 do
		piece(
			"Gouge",
			Vector3.new(0.12, 3.6, 0.06),
			face * CFrame.new(i * 0.45, 0.6 + math.abs(i) * -0.2, 0) * CFrame.Angles(0, 0, math.rad(18)),
			Color3.fromRGB(150, 140, 120),
			model
		)
	end
	model.Parent = folder()
	task.delay(60, function()
		if model.Parent then
			fadeOut(model, 3)
		end
	end)
	return true
end

--------------------------------------------------------------------------
-- Failing lights
--------------------------------------------------------------------------

local flickering = false

local function flicker(seconds: number)
	if flickering then
		return
	end
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	flickering = true
	local near: { [Light]: boolean } = {}
	for _, light in Workspace:GetDescendants() do
		if light:IsA("Light") and light.Enabled and light.Parent and light.Parent:IsA("BasePart") then
			if ((light.Parent :: BasePart).Position - camera.CFrame.Position).Magnitude < 70 then
				near[light] = true
			end
		end
	end
	task.spawn(function()
		local endsAt = os.clock() + seconds
		while os.clock() < endsAt do
			local on = math.random() < 0.35
			for light in near do
				if light.Parent then
					light.Enabled = on
				end
			end
			task.wait(0.04 + math.random() * 0.16)
		end
		-- Back to what the server says. Lights the server switched off during
		-- the flicker are switched off again by its own update.
		for light in near do
			if light.Parent then
				light.Enabled = true
			end
		end
		flickering = false
	end)
end

--------------------------------------------------------------------------

function HorrorEffectsController.start()
	Net.onClientEvent("HorrorCue", function(payload)
		if type(payload) ~= "table" then
			return
		end
		local position = if typeof(payload.position) == "Vector3" then payload.position else nil
		if payload.cue == "silhouette" and position then
			silhouette(position, if type(payload.duration) == "number" then math.clamp(payload.duration, 0.5, 6) else 2)
		elseif payload.cue == "evidence" and position then
			if payload.variant ~= "scratches" or not scratches(position) then
				footprints(position)
			end
		elseif payload.cue == "lights_flicker" then
			flicker(if type(payload.seconds) == "number" then math.clamp(payload.seconds, 0.5, 8) else 3)
		end
	end)

	-- A new character, a new run: nothing from the last one lingers.
	player.CharacterAdded:Connect(function()
		if effectsFolder then
			effectsFolder:ClearAllChildren()
		end
	end)

	log.info("started")
end

return HorrorEffectsController
