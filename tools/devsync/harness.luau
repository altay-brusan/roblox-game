--!nocheck
-- Dev test harness (client, Play mode). Paste into execute_luau. Installs _G.T.
-- Interactions are sent through the same Interact remote the prompts use
-- (developer-assisted: the character is placed next to each target).
local R = game.ReplicatedStorage.LastSignal.Remotes
local CS = game:GetService("CollectionService")
local StationRegistry = require(game.ReplicatedStorage.LastSignal.Registry.StationRegistry)
local plr = game.Players.LocalPlayer
local T = {}
_G.T = T
T.log = {}
local function say(s) table.insert(T.log, s) end
function T.root() return plr.Character.HumanoidRootPart end
function T.hum() return plr.Character.Humanoid end
function T.lane()
	for _, m in CS:GetTagged("Train") do
		if m.PrimaryPart and m.PrimaryPart.Position.Z < -10000 then return m end
	end
end
function T.state() local r = R.ExpeditionCommand:InvokeServer("state") return r and r.expedition end
function T.objectives()
	local e = T.state() if not e then return "no expedition" end
	local out = { e.state .. " @" .. tostring(e.stationName) }
	for _, o in e.objectives do
		table.insert(out, string.format("  %s %s %d/%d %s", o.complete and "[x]" or "[ ]", o.id, o.progress, o.target, o.stepText or ""))
	end
	return table.concat(out, "\n")
end
local lastResult = {}
R.InteractResult.OnClientEvent:Connect(function(p)
	if type(p) == "table" then
		lastResult = p
		if p.action == "read_code" then T.code = p.code end
	end
end)
function T.act(part, action, hold)
	T.hum().Sit = false
	T.root().CFrame = CFrame.new(part.Position + Vector3.new(0, 3, 0)) * CFrame.new(0, 0, 3)
	task.wait(0.35)
	lastResult = {}
	R.Interact:FireServer(part, action)
	task.wait(0.4)
	local started = lastResult.action == "hold_start"
	local duration = tonumber(lastResult.duration) or hold or 0
	if started then task.wait(duration + 0.3) R.Interact:FireServer(part, action) task.wait(0.4) end
	return lastResult
end
function T.station()
	local e = T.state()
	local def = e and StationRegistry.byIndex(e.stationIndex)
	if not def then return nil, nil end
	return def, workspace.LastSignalWorld.Lane1:FindFirstChild("Station_" .. def.id)
end
function T.fixture(model, name)
	for _, p in CS:GetTagged("StationFixture") do if p:IsDescendantOf(model) and p.Name == name then return p end end
end
local inventory = {}
R.Inventory.OnClientEvent:Connect(function(p) if type(p) == "table" and type(p.stacks) == "table" then inventory = p.stacks end end)
R.InventoryCommand:InvokeServer("refresh")
function T.inv(item)
	local n = 0
	for _, s in inventory do if type(s) == "table" and s.id == item then n += s.quantity or 1 end end
	return n
end
-- Search every unsearched loot node in the station until the item is held.
function T.find(model, item)
	if T.inv(item) > 0 then return true end
	for _, p in CS:GetTagged("LootNode") do
		if p:IsDescendantOf(model) and p:GetAttribute("Searched") ~= true then
			T.act(p, "search")
			task.wait(0.3)
			if T.inv(item) > 0 then say("found " .. item .. " in " .. p.Name) return true end
		end
	end
	say("could not find " .. item)
	return false
end
function T.board()
	T.hum().Sit = false
	T.hum():ChangeState(Enum.HumanoidStateType.GettingUp)
	task.wait(0.4)
	local lane = T.lane()
	for _, d in lane:GetDescendants() do
		if d:IsA("Seat") and d.Name == "DriverSeat" then
			T.root().CFrame = d.CFrame * CFrame.new(1.6, 2.5, 0)
			task.wait(0.4)
			R.Interact:FireServer(d, "sit")
			task.wait(0.8)
			R.TrainControl:FireServer("brake", 0)
			R.TrainControl:FireServer("throttle", 6)
			return
		end
	end
end
-- Solve the current station's required objectives.
function T.solve()
	T.log = {}
	local def, model = T.station()
	if not def or not model then return "no station" end
	for _ = 1, 30 do
		local e = T.state()
		if not e or (e.state ~= "onstation" and e.state ~= "climax") then break end
		local progressed = false
		for _, o in e.objectives do
			if o.complete or o.optional then continue end
			local od
			for _, c in def.objectives do if c.id == o.id then od = c end end
			if not od then continue end
			if od.kind == "sequence" then
				local step = od.params.steps[(o.progress or 0) + 1]
				if step then
					if step.kind == "collect" then
						T.find(model, step.item) task.wait(1.5)
					else
						if step.needsFuel and T.inv("fuel_can") == 0 then T.find(model, "fuel_can") end
						if step.item and T.inv(step.item) == 0 then T.find(model, step.item) end
						local f = T.fixture(model, step.fixture)
						local r = T.act(f, "operate", step.seconds)
						say(step.id .. " -> " .. tostring(r.ok) .. " " .. tostring(r.error or ""))
						if step.kind == "defend" then
							say("defending " .. step.seconds .. "s")
							task.wait(step.seconds + 2)
						end
					end
					progressed = true
				end
			elseif od.kind == "deliver" then
				if od.params.item and T.inv(od.params.item) == 0 then T.find(model, od.params.item) end
				local r = T.act(T.fixture(model, od.params.fixture), "operate", od.params.seconds)
				say(o.id .. " -> " .. tostring(r.ok) .. " " .. tostring(r.error or ""))
				progressed = true
			elseif od.kind == "simultaneous" then
				for _, name in od.params.holdFixtures do T.act(T.fixture(model, name), "operate") end
				local r = T.act(T.fixture(model, od.params.thenFixture), "operate", od.params.thenSeconds)
				say(o.id .. " -> " .. tostring(r.ok) .. " " .. tostring(r.error or ""))
				progressed = true
			elseif od.kind == "relay" then
				T.code = nil
				T.act(T.fixture(model, od.params.readerFixture), "operate")
				local code = T.code
				say("code " .. (code and table.concat(code, "") or "nil"))
				if code then
					for i, name in od.params.leverFixtures do
						local lever = T.fixture(model, name)
						for _ = 1, 3 do
							if (lever:GetAttribute("Position") or 1) == code[i] then break end
							T.act(lever, "operate")
						end
					end
				end
				progressed = true
			elseif od.kind == "collect" and od.params.deliverTo == "train_fuel_point" then
				T.find(model, "fuel_can")
				local fp
				for _, p in CS:GetTagged("TrainFuelPoint") do if p:IsDescendantOf(T.lane()) then fp = p end end
				while T.inv("fuel_can") > 0 do
					local r = T.act(fp, "refuel_train")
					say("refuel train -> " .. tostring(r.ok) .. " " .. tostring(r.error or ""))
				end
				progressed = true
			end
			break
		end
		if not progressed then break end
	end
	return table.concat(T.log, "\n") .. "\n" .. T.objectives()
end
return T
