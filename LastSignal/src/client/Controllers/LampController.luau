--!strict
--[[
	LampController
	--------------
	Points your own lamp where you are looking. The beam itself is made and
	switched by the server (AppearanceService) so everyone sees it; a head does
	not tilt with the camera, so without this the beam would light your feet
	when you look up at the treeline. Other players' beams follow their heads.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local LampController = {}

local player = Players.LocalPlayer

function LampController.start()
	RunService.RenderStepped:Connect(function()
		local character = player.Character
		local head = if character then character:FindFirstChild("Head") else nil
		local attachment = if head then head:FindFirstChild("LampAttachment") else nil
		local camera = Workspace.CurrentCamera
		if not head or not head:IsA("BasePart") or not attachment or not attachment:IsA("Attachment") or not camera then
			return
		end
		local origin = head.Position + camera.CFrame.LookVector * 0.6
		attachment.WorldCFrame = CFrame.lookAt(origin, origin + camera.CFrame.LookVector)
	end)
end

return LampController
