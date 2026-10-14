--!strict
--[[
	Prologue
	--------
	The opening of the story, staged on the real train (V2 section 12).

	The 02:17 leaves the yard as an ordinary service: passengers in the
	seats, warm light, the driver on the PA. A bang from the rear carriage,
	the lights stutter, and when the camera looks back down the aisle every
	passenger is gone, their bags and hats and newspapers still on the seats.
	The tunnel is the crossing. On the other side the belongings are still
	there, the yard's own nameboard stands alone in the forest where the yard
	should be, the driver calls Control and gets nothing, and then a reply
	arrives that is too quick and too calm. Title. First task: take the
	controls.

	This module builds the people and things for that; ExpeditionService
	runs the timing, and CinematicController and CameraController film it.
]]

local BuildKit = require(script.Parent.BuildKit)

local C = Color3.fromRGB

local Prologue = {}

-- Coats, skin and hats for a carriage of ordinary people. Picked in turn,
-- not at random, so the same seats always hold the same people.
local COATS = { C(70, 64, 58), C(42, 52, 70), C(96, 70, 52), C(58, 66, 54), C(110, 40, 44), C(48, 48, 52), C(140, 120, 90) }
local SKIN = { C(234, 192, 160), C(196, 150, 112), C(140, 96, 66), C(98, 64, 44), C(222, 180, 140) }
local BELONGINGS = { "bag", "hat", "paper", "bag", "coat", "paper", "flask" }

local function part(name: string, size: Vector3, cf: CFrame, colour: Color3, material: Enum.Material, parent: Instance, root: BasePart): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.CFrame = cf
	p.Color = colour
	p.Material = material
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Massless = true
	p.Parent = parent
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = root
	weld.Part1 = p
	weld.Parent = p
	return p
end

local function seats(train: any): { Seat }
	local out: { Seat } = {}
	for _, carriage in train.built.carriages do
		for _, d in carriage:GetDescendants() do
			if d:IsA("Seat") and d:HasTag("TrainSeat") then
				table.insert(out, d)
			end
		end
	end
	table.sort(out, function(a, b)
		return a:GetFullName() < b:GetFullName()
	end)
	return out
end

local function belonging(kind: string, seat: Seat, parent: Instance, root: BasePart, i: number)
	local top = seat.CFrame * CFrame.new(0, seat.Size.Y * 0.5, 0)
	if kind == "bag" then
		part("Bag", Vector3.new(1.2, 0.9, 0.6), top * CFrame.new(0.2, 0.45, 0.1), COATS[(i % #COATS) + 1], Enum.Material.Fabric, parent, root)
	elseif kind == "hat" then
		part("HatBrim", Vector3.new(1.1, 0.08, 1.1), top * CFrame.new(-0.2, 0.06, 0), C(40, 36, 34), Enum.Material.Fabric, parent, root)
		part("HatCrown", Vector3.new(0.7, 0.4, 0.7), top * CFrame.new(-0.2, 0.3, 0), C(40, 36, 34), Enum.Material.Fabric, parent, root)
	elseif kind == "paper" then
		part("Newspaper", Vector3.new(1.0, 0.04, 1.3), top * CFrame.new(0, 0.04, 0) * CFrame.Angles(0, math.rad(15 + i * 7), 0), C(214, 208, 192), Enum.Material.SmoothPlastic, parent, root)
	elseif kind == "coat" then
		part("FoldedCoat", Vector3.new(1.3, 0.3, 1.0), top * CFrame.new(0, 0.15, 0), COATS[((i + 3) % #COATS) + 1], Enum.Material.Fabric, parent, root)
	else
		part("Flask", Vector3.new(0.3, 0.7, 0.3), top * CFrame.new(0.3, 0.35, -0.2), C(150, 150, 154), Enum.Material.Metal, parent, root)
	end
end

--- Fills every other seat with a passenger. Returns the folder they are in.
function Prologue.seatPassengers(train: any): Folder
	local folder = Instance.new("Folder")
	folder.Name = "Passengers"
	folder.Parent = train.built.model
	local root = train.built.root
	for i, seat in seats(train) do
		if i % 2 == 1 and not seat.Occupant then
			local person = Instance.new("Model")
			person.Name = "Passenger"
			local coat = COATS[(i % #COATS) + 1]
			local skin = SKIN[(i % #SKIN) + 1]
			local base = seat.CFrame * CFrame.new(0, seat.Size.Y * 0.5, 0)
			part("Hips", Vector3.new(1.6, 0.7, 1.4), base * CFrame.new(0, 0.35, 0.1), C(44, 44, 50), Enum.Material.Fabric, person, root)
			part("Torso", Vector3.new(1.7, 2.0, 1.0), base * CFrame.new(0, 1.7, 0.35), coat, Enum.Material.Fabric, person, root)
			part("Head", Vector3.new(1.0, 1.1, 1.0), base * CFrame.new(0, 3.25, 0.3) * CFrame.Angles(math.rad(-6 + (i % 3) * 6), math.rad((i % 4 - 1.5) * 10), 0), skin, Enum.Material.SmoothPlastic, person, root)
			for _, side in { -1, 1 } do
				part("Thigh", Vector3.new(0.6, 0.6, 1.5), base * CFrame.new(side * 0.42, 0.45, -0.6), C(44, 44, 50), Enum.Material.Fabric, person, root)
				part("Shin", Vector3.new(0.55, 1.5, 0.55), base * CFrame.new(side * 0.42, -0.45, -1.25), C(44, 44, 50), Enum.Material.Fabric, person, root)
				part("Arm", Vector3.new(0.45, 1.7, 0.45), base * CFrame.new(side * 1.05, 1.5, 0.2) * CFrame.Angles(math.rad(-25), 0, 0), coat, Enum.Material.Fabric, person, root)
			end
			if i % 3 == 0 then
				part("Hat", Vector3.new(1.1, 0.35, 1.1), base * CFrame.new(0, 3.95, 0.3), C(40, 36, 34), Enum.Material.Fabric, person, root)
			end
			person:SetAttribute("Belonging", BELONGINGS[(i % #BELONGINGS) + 1])
			person:SetAttribute("Seat", seat:GetFullName())
			person.Parent = folder
		end
	end
	return folder
end

--- Every passenger is gone; what they had is left on the seat.
function Prologue.vanish(train: any)
	local folder = train.built.model:FindFirstChild("Passengers")
	if not folder then
		return
	end
	local left = Instance.new("Folder")
	left.Name = "Belongings"
	left.Parent = train.built.model
	local bySeat: { [string]: Seat } = {}
	for _, seat in seats(train) do
		bySeat[seat:GetFullName()] = seat
	end
	for i, person in folder:GetChildren() do
		local seat = bySeat[tostring(person:GetAttribute("Seat"))]
		if seat then
			belonging(tostring(person:GetAttribute("Belonging")), seat, left, train.built.root, i)
		end
	end
	folder:Destroy()
end

--- The same belongings on the expedition train, so the crossing is seamless.
function Prologue.leaveBelongings(train: any)
	if train.built.model:FindFirstChild("Belongings") then
		return
	end
	local left = Instance.new("Folder")
	left.Name = "Belongings"
	left.Parent = train.built.model
	for i, seat in seats(train) do
		if i % 2 == 1 then
			belonging(BELONGINGS[(i % #BELONGINGS) + 1], seat, left, train.built.root, i)
		end
	end
end

--- The yard's nameboard, alone in the forest, ahead of where the train
--- comes out of the crossing. The yard is not there.
function Prologue.placeNameboard(train: any, parent: Instance)
	local cf = train.origin * CFrame.new(10.5, 0, -(train.distance + 140)) * CFrame.Angles(0, math.rad(-90), 0)
	for _, x in { -3.6, 3.6 } do
		BuildKit.part({
			name = "NameboardPost",
			size = Vector3.new(0.5, 7, 0.5),
			cf = cf * CFrame.new(x, 3.5, 0),
			colour = C(60, 58, 54),
			material = Enum.Material.CorrodedMetal,
			parent = parent,
		})
	end
	BuildKit.sign(cf * CFrame.new(0, 6.4, 0), 8.5, 1.6, "TOLBRIDGE YARD", Enum.NormalId.Front, parent)
end

return Prologue
