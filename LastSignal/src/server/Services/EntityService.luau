--!strict
--[[
	EntityService
	-------------
	The things on the line besides the Caller (the Signal-Eater, in
	CreatureService). Each has its own look, sound, rule and answer, so a
	player who learns them can survive them; none kills without warning.

	  THE WINDOW PASSENGER   Appears outside a carriage window only where no
	                         one is looking. Look at it and it is gone. Left
	                         unwatched, it puts that carriage's lights out.
	  THE HOLLOW CONDUCTOR   Announced ("Tickets, please", blue light). Walks
	                         the train from the back to the front. It passes
	                         anyone who is seated, or not in its carriage. It
	                         punches the ticket of anyone standing in its way.
	  THE SWITCHKEEPER       A figure at a lineside signal showing a false
	                         red, its lamp flickering. Stop for it and it works
	                         the couplings. Drive past, or sound the horn, and
	                         it is nothing. Control's real signals have a
	                         telephone, and Control on the radio; its do not.
	  THE DISPATCHER         Ward Hill. The man whose voice is on the loop.
	                         While the tape plays he walks towards the crew.
	                         Stop the tape in the relay hall and he stops.
	  THE INTRUSION          Between Hallow Bridge and Ward Hill, a warned
	                         attempt to come aboard. Twenty seconds to shut
	                         every door. Shut, it fails; open, it gets into
	                         that carriage, and the crew must leave it.

	Every entity is cleaned up by a retry and by the end of the run, and
	re-arms after a retry's checkpoint.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.LastSignal

local Logger = require(Shared.Core.Logger)
local Net = require(Shared.Core.Net)
local Protect = require(Shared.Core.Protect)
local StationRegistry = require(Shared.Registry.StationRegistry)

local ExpeditionService = require(script.Parent.ExpeditionService)
local HorrorDirector = require(script.Parent.HorrorDirector)
local InteractionService = require(script.Parent.InteractionService)
local SurvivalService = require(script.Parent.SurvivalService)
local TrainService = require(script.Parent.TrainService)

local log = Logger.new("EntityService")
local C = Color3.fromRGB

local EntityService = {}

-- Where each travelling entity appears: train distance, and the segment
-- (destination station) it belongs to, for retry re-arming.
local SCHEDULE = {
	{ kind = "window", at = 2600, segment = 2 },
	{ kind = "conductor", at = 5400, segment = 3 },
	{ kind = "switchkeeper", at = 8400, segment = 4 },
	{ kind = "window", at = 9300, segment = 4 },
	{ kind = "intrusion", at = 11300, segment = 5 },
	{ kind = "conductor", at = 12600, segment = 5 },
}

type Active = { kind: string, cleanup: () -> (), tick: ((number) -> ())?, isDone: () -> boolean }

type State = {
	fired: { [number]: boolean },
	active: { Active },
	dispatcherDone: boolean,
}

local states: { [string]: State } = {}

local function stateFor(expedition: any): State
	local s = states[expedition.id]
	if not s then
		s = { fired = {}, active = {}, dispatcherDone = false }
		states[expedition.id] = s
	end
	return s
end

local function crew(expedition: any): { Player }
	return ExpeditionService.playersOf(expedition)
end

local function notify(expedition: any, kind: string, title: string, body: string)
	Net.fireClients("Notify", crew(expedition), { kind = kind, title = title, body = body, duration = 7 })
end

local function radio(expedition: any, attribution: string, text: string, source: string?)
	Net.fireClients("RadioMessage", crew(expedition), { id = "entity", source = source or "other", text = text, duration = 6, attribution = attribution, isFalse = false })
end

local function cue(expedition: any, name: string, position: Vector3, extra: { [string]: any }?)
	local payload: { [string]: any } = { cue = name, position = position }
	for k, v in pairs(extra or {}) do
		payload[k] = v
	end
	Net.fireClients("HorrorCue", crew(expedition), payload)
end

local function piece(name: string, size: Vector3, colour: Color3, material: Enum.Material, parent: Instance): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.Color = colour
	p.Material = material
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Parent = parent
	return p
end

--- A figure from parts, posed by a CFrame each frame. `shape` sets the
--- proportions; everything is tall and wrong in one way or another.
local function figure(name: string, parent: Instance, coat: Color3, extras: boolean?): (Model, (CFrame) -> ())
	local model = Instance.new("Model")
	model.Name = name
	local body = piece("Body", Vector3.new(1.6, 5.6, 1.0), coat, Enum.Material.Fabric, model)
	local head = piece("Head", Vector3.new(1.1, 1.4, 1.0), C(214, 210, 200), Enum.Material.SmoothPlastic, model)
	local cap = piece("Cap", Vector3.new(1.3, 0.4, 1.4), C(20, 20, 24), Enum.Material.Fabric, model)
	local legs = piece("Legs", Vector3.new(1.2, 3.4, 0.8), C(20, 20, 24), Enum.Material.Fabric, model)
	local armL = piece("Arm", Vector3.new(0.4, 5.2, 0.4), coat, Enum.Material.Fabric, model)
	local armR = piece("Arm", Vector3.new(0.4, 5.2, 0.4), coat, Enum.Material.Fabric, model)
	local lamp: Part? = nil
	if extras then
		local l = piece("Lantern", Vector3.new(0.6, 0.8, 0.6), C(120, 170, 255), Enum.Material.Neon, model)
		local light = Instance.new("PointLight")
		light.Color = C(120, 170, 255)
		light.Range = 16
		light.Brightness = 2
		light.Parent = l
		lamp = l
	end
	model.Parent = parent
	local function pose(cf: CFrame)
		legs.CFrame = cf * CFrame.new(0, 1.7, 0)
		body.CFrame = cf * CFrame.new(0, 6.2, 0)
		head.CFrame = cf * CFrame.new(0, 9.8, 0)
		cap.CFrame = cf * CFrame.new(0, 10.6, -0.05)
		armL.CFrame = cf * CFrame.new(-1.05, 5.4, 0)
		armR.CFrame = cf * CFrame.new(1.05, 5.4, 0)
		if lamp then
			lamp.CFrame = cf * CFrame.new(1.05, 2.6, -0.4)
		end
	end
	return model, pose
end

local function carriageLights(carriage: Model, on: boolean, colour: Color3?)
	for _, d in carriage:GetDescendants() do
		if d:IsA("Light") then
			d.Enabled = on
			if colour then
				d.Color = colour
			end
		end
	end
end

local function anyDoorOpen(train: any): (boolean, any?)
	if train.doorsOpen then
		return true, train.built.doors[1]
	end
	for _, door in train.built.doors do
		local angle = tonumber(door.hinge:GetAttribute("OpenAngle")) or 0
		if math.abs(angle) > 0.2 then
			return true, door
		end
	end
	return false, nil
end

local function seated(player: Player): boolean
	local character = player.Character
	local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
	return humanoid ~= nil and humanoid.SeatPart ~= nil
end

local function rootOf(player: Player): BasePart?
	local character = player.Character
	local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
	return if root and root:IsA("BasePart") then root else nil
end

--------------------------------------------------------------------------
-- The Window Passenger
--------------------------------------------------------------------------

local windowSeen: { [string]: boolean } = {}

local function windowPassenger(expedition: any): Active?
	local train = expedition.train
	local carriages = train.built.carriages
	if #carriages == 0 then
		return nil
	end
	local index = math.random(1, #carriages)
	local carriage = carriages[index]
	-- Pressed to the outside of one of the carriage's real windows.
	local cf = carriage:GetBoundingBox()
	local glass: { BasePart } = {}
	for _, d in carriage:GetDescendants() do
		if d:IsA("BasePart") and d.Name == "Glass" then
			table.insert(glass, d)
		end
	end
	if #glass == 0 then
		return nil
	end
	local pane = glass[math.random(1, #glass)]
	local rel = cf:PointToObjectSpace(pane.Position)
	local side = if rel.X >= 0 then 1 else -1
	local offset = Vector3.new(rel.X + side * 0.7, rel.Y - 0.3, rel.Z)
	local token = expedition.id .. ":" .. tostring(os.clock())
	windowSeen[token] = false
	cue(expedition, "window_passenger", train.built.root.Position, { carriage = carriage, offset = offset, token = token })
	log.info(expedition.id .. ": window passenger at carriage " .. index)
	local started = os.clock()
	local done = false
	return {
		kind = "window",
		isDone = function()
			return done
		end,
		tick = function()
			if done then
				return
			end
			if windowSeen[token] then
				done = true
				cue(expedition, "window_passenger_gone", train.built.root.Position, { token = token })
			elseif os.clock() - started > 25 then
				-- Unwatched for too long: that carriage goes dark for a while.
				done = true
				cue(expedition, "window_passenger_gone", train.built.root.Position, { token = token })
				carriageLights(carriage, false)
				cue(expedition, "lights_flicker", carriage:GetPivot().Position, { seconds = 1.5 })
				HorrorDirector.addThreat(expedition.id, 12)
				notify(expedition, "warning", "A carriage has gone dark", "Something was at the window, and nobody looked.")
				task.delay(30, function()
					if expedition.state ~= "closed" then
						TrainService.applyLights(train)
					end
				end)
			end
		end,
		cleanup = function()
			windowSeen[token] = nil
			cue(expedition, "window_passenger_gone", train.built.root.Position, { token = token })
		end,
	}
end

--------------------------------------------------------------------------
-- The Hollow Conductor
--------------------------------------------------------------------------

local conductorWarned: { [string]: boolean } = {}

local function hollowConductor(expedition: any): Active?
	local train = expedition.train
	local carriages = train.built.carriages
	if #carriages == 0 then
		return nil
	end
	-- The warning: blue light, the punch clicking, the words.
	for _, carriage in carriages do
		carriageLights(carriage, true, C(140, 170, 255))
	end
	radio(expedition, "Somewhere in the train", "[A ticket punch, clicking.] Tickets, please. Tickets.", "other")
	if not conductorWarned[expedition.id] then
		conductorWarned[expedition.id] = true
		notify(expedition, "danger", "Tickets, please", "Something is checking tickets. Sit down, or get out of its carriage, until it has passed.")
	end
	local model, pose = figure("HollowConductor", train.built.model, C(28, 30, 40), true)
	local folder = model
	local punched: { [number]: boolean } = {}
	local startAt = os.clock() + 6
	-- Rear carriage to the front, end to end, at a walk.
	local route: { { carriage: Model, z: number } } = {}
	for i = #carriages, 1, -1 do
		table.insert(route, { carriage = carriages[i], z = 1 })
	end
	local leg = 1
	local progress = 0
	local hidden = true
	for _, p in folder:GetChildren() do
		if p:IsA("BasePart") then
			p.Transparency = 1
		end
	end
	local finished = false
	return {
		kind = "conductor",
		isDone = function()
			return finished
		end,
		tick = function(dt: number)
			if finished or os.clock() < startAt then
				return
			end
			if hidden then
				hidden = false
				for _, p in folder:GetChildren() do
					if p:IsA("BasePart") then
						p.Transparency = 0
					end
				end
			end
			local step = route[leg]
			if not step then
				finished = true
				folder:Destroy()
				TrainService.applyLights(train)
				for _, carriage in carriages do
					carriageLights(carriage, train.interiorLights, C(255, 226, 180))
				end
				return
			end
			local cf, size = step.carriage:GetBoundingBox()
			progress += dt * 5 / size.Z
			if progress >= 1 then
				progress = 0
				leg += 1
				return
			end
			local floorY = -size.Y * 0.5 + 2.6
			local z = size.Z * (0.5 - progress)
			local at = cf * CFrame.new(0, floorY, z) * CFrame.Angles(0, 0, 0)
			pose(CFrame.lookAt(at.Position, (cf * CFrame.new(0, floorY, z - 4)).Position))
			for _, player in crew(expedition) do
				local root = rootOf(player)
				if root and not punched[player.UserId] and not seated(player) then
					local rel = cf:PointToObjectSpace(root.Position)
					if math.abs(rel.X) < 3 and math.abs(rel.Z - z) < 3 and math.abs(rel.Y) < size.Y * 0.5 then
						punched[player.UserId] = true
						SurvivalService.damage(player, 30, "hollow_conductor")
						cue(expedition, "creature_attack", root.Position)
						Net.fireClient("Notify", player, { kind = "danger", title = "Your ticket was punched", body = "It passes the seated.", duration = 6 })
					end
				end
			end
		end,
		cleanup = function()
			if folder.Parent then
				folder:Destroy()
			end
			for _, carriage in carriages do
				carriageLights(carriage, train.interiorLights, C(255, 226, 180))
			end
			TrainService.applyLights(train)
		end,
	}
end

--------------------------------------------------------------------------
-- The Switchkeeper
--------------------------------------------------------------------------

local function switchkeeper(expedition: any): Active?
	local train = expedition.train
	local postDistance = train.distance + 420
	local nextIndex = ExpeditionService.nextStationIndex(expedition)
	local nextStation = if nextIndex then StationRegistry.byIndex(nextIndex) else nil
	if nextStation and postDistance > nextStation.distance - 150 then
		return nil
	end
	local folder = Instance.new("Folder")
	folder.Name = "Switchkeeper"
	folder.Parent = expedition.lane.dropContainer
	local base = train.origin * CFrame.new(-8, 0, -postDistance)
	local post = piece("SignalPost", Vector3.new(0.6, 14, 0.6), C(40, 40, 42), Enum.Material.Metal, folder)
	post.CFrame = base * CFrame.new(0, 7, 0)
	local head = piece("SignalHead", Vector3.new(1.6, 3.2, 1.0), C(24, 24, 26), Enum.Material.Metal, folder)
	head.CFrame = base * CFrame.new(0, 13.5, 0)
	local aspect = piece("Aspect", Vector3.new(0.9, 0.9, 0.3), C(255, 40, 30), Enum.Material.Neon, folder)
	aspect.CFrame = base * CFrame.new(0, 13.5, 0.55)
	local light = Instance.new("PointLight")
	light.Color = C(255, 40, 30)
	light.Range = 22
	light.Parent = aspect
	local _, pose = figure("TheSwitchkeeper", folder, C(30, 26, 22), false)
	pose(base * CFrame.new(1.6, 0, 0) * CFrame.Angles(0, math.rad(90), 0))
	log.info(expedition.id .. ": switchkeeper at " .. math.floor(postDistance))
	local stoppedFor = 0
	local finished = false
	local horned = false
	local hornConnection = TrainService.HornSounded:Connect(function(t)
		if t == train and train.distance > postDistance - 300 then
			horned = true
		end
	end)
	local function vanish(note: string?)
		finished = true
		hornConnection:Disconnect()
		if folder.Parent then
			folder:Destroy()
		end
		if note then
			notify(expedition, "info", "The red signal", note)
		end
	end
	return {
		kind = "switchkeeper",
		isDone = function()
			return finished
		end,
		tick = function(dt: number)
			if finished then
				return
			end
			-- The lamp flickers; Control's lamps never do.
			aspect.Transparency = if math.random() < 0.15 then 0.8 else 0
			if horned then
				cue(expedition, "creature_repelled", aspect.Position)
				vanish("It went at the horn. The signal was lit by nothing.")
				return
			end
			if train.distance > postDistance + 30 then
				vanish("You drove past it. Nothing happened: it was lit by nothing.")
				return
			end
			local near = postDistance - train.distance < 260
			if near and train.speed < 2 then
				stoppedFor += dt
				if stoppedFor > 7 then
					train.condition = math.max(5, train.condition - 12)
					HorrorDirector.addThreat(expedition.id, 15)
					cue(expedition, "train_coupler", train.built.root.Position)
					vanish("While you waited, something worked the couplings. Condition lost.")
				end
			end
		end,
		cleanup = function()
			if not finished then
				vanish(nil)
			end
		end,
	}
end

--------------------------------------------------------------------------
-- The intrusion
--------------------------------------------------------------------------

local function intrusion(expedition: any): Active?
	local train = expedition.train
	radio(expedition, "Control?", "Contr... zero two seventeen... several of them... converging... shut... shut everything...", "other")
	notify(expedition, "danger", "Something is coming aboard", "Twenty seconds. Shut every door: the cab door control, and any door that will not latch.")
	cue(expedition, "creature_near", train.built.root.Position + Vector3.new(0, 10, 0))
	local startedAt = os.clock()
	local phase = "warning"
	local breached: Model? = nil
	local lastHit = 0
	local over = false
	return {
		kind = "intrusion",
		isDone = function()
			return over
		end,
		tick = function()
			if over then
				return
			end
			local t = os.clock() - startedAt
			if phase == "warning" then
				if math.floor(t) % 3 == 0 then
					cue(expedition, "footsteps_outside", (train.built.root.CFrame * CFrame.new(0, 7, (math.random() - 0.5) * 60)).Position)
				end
				if t >= 20 then
					local open, door = anyDoorOpen(train)
					if open and door then
						phase = "breach"
						breached = train.built.carriages[door.carriage] or train.built.carriages[1]
						if breached then
							carriageLights(breached, false)
						end
						cue(expedition, "creature_attack", door.hinge.Position)
						notify(expedition, "danger", "It is inside", "A door was open. Get out of that carriage: forward to the next one, or the cab.")
					else
						phase = "failed"
						cue(expedition, "creature_repelled", train.built.root.Position + Vector3.new(0, 8, 0))
						notify(expedition, "info", "It tried every door", "Nothing open. It has gone back into the trees.")
						over = true
					end
				end
			elseif phase == "breach" then
				local carriage = breached
				if carriage and os.clock() - lastHit > 2 then
					lastHit = os.clock()
					local cf, size = carriage:GetBoundingBox()
					for _, player in crew(expedition) do
						local root = rootOf(player)
						if root then
							local rel = cf:PointToObjectSpace(root.Position)
							if math.abs(rel.X) < size.X * 0.5 and math.abs(rel.Z) < size.Z * 0.5 and math.abs(rel.Y) < size.Y * 0.5 then
								SurvivalService.damage(player, 12, "intrusion")
							end
						end
					end
				end
				if t >= 38 then
					over = true
					TrainService.applyLights(train)
					notify(expedition, "info", "It has gone", "Whatever came in has left the carriage.")
				end
			end
		end,
		cleanup = function()
			over = true
			TrainService.applyLights(train)
		end,
	}
end

--------------------------------------------------------------------------
-- The Dispatcher (Ward Hill)
--------------------------------------------------------------------------

local function dispatcher(expedition: any): Active?
	local built = expedition.lane.stations[StationRegistry.count()]
	if not built then
		return nil
	end
	local mast = built.landmarks.mast
	local hall = built.landmarks.relay_hall
	if not mast or not hall then
		return nil
	end
	local folder = Instance.new("Folder")
	folder.Name = "Dispatcher"
	folder.Parent = expedition.lane.dropContainer
	local _, pose = figure("TheDispatcher", folder, C(46, 52, 64), false)
	local position = mast + Vector3.new(0, 0, -6)
	pose(CFrame.new(position))
	local tape = piece("LoopTape", Vector3.new(2.2, 1.6, 1.4), C(60, 54, 46), Enum.Material.Metal, folder)
	tape.CFrame = CFrame.new(hall + Vector3.new(0, 3.5, 0))
	tape.CanQuery = true
	tape:SetAttribute("TaskLabel", "Stop the tape")
	tape:SetAttribute("TaskDetail", "The loop that has been speaking as Control")
	tape:SetAttribute("TaskSeconds", 3)
	tape:AddTag("RunTask")
	local reel = piece("Reel", Vector3.new(0.2, 1.1, 1.1), C(176, 142, 74), Enum.Material.Metal, folder)
	reel.CFrame = tape.CFrame * CFrame.new(-1.15, 0.2, 0)
	notify(expedition, "danger", "Someone is walking down from the mast", "He walks while the tape plays. The tape is in the relay hall.")
	radio(expedition, "Control (recording)", "Control to the zero two seventeen. I have you leaving the yard. You are the last one out.", "recording")
	local stopped = false
	local lastHit = 0
	local lastLine = os.clock()
	local connection = InteractionService.RunTaskDone:Connect(function(_player, part)
		if part == tape and not stopped then
			stopped = true
			radio(expedition, "Control (recording)", "You are the last one... out...", "recording")
			notify(expedition, "info", "The tape has stopped", "He stands where he is, and then he is not there.")
			task.delay(3, function()
				if folder.Parent then
					folder:Destroy()
				end
			end)
		end
	end)
	return {
		kind = "dispatcher",
		isDone = function()
			return stopped and folder.Parent == nil
		end,
		tick = function(dt: number)
			if stopped then
				return
			end
			reel.CFrame = reel.CFrame * CFrame.Angles(math.rad(240) * dt, 0, 0)
			if os.clock() - lastLine > 14 then
				lastLine = os.clock()
				radio(expedition, "Control (recording)", "Control to the zero two seventeen. You are the last one out.", "recording")
			end
			-- He walks towards the nearest of the crew, slowly, and does not stop.
			local target: BasePart? = nil
			local best = math.huge
			for _, player in crew(expedition) do
				local root = rootOf(player)
				if root then
					local d = (root.Position - position).Magnitude
					if d < best then
						target, best = root, d
					end
				end
			end
			if target then
				local flat = Vector3.new(target.Position.X - position.X, 0, target.Position.Z - position.Z)
				if flat.Magnitude > 3 then
					position += flat.Unit * math.min(flat.Magnitude - 3, 3.2 * dt)
				end
				pose(CFrame.lookAt(position, Vector3.new(target.Position.X, position.Y, target.Position.Z)))
				if best < 5 and os.clock() - lastHit > 2 then
					lastHit = os.clock()
					local player = Players:GetPlayerFromCharacter(target.Parent)
					if player then
						SurvivalService.damage(player, 15, "dispatcher")
					end
				end
			end
		end,
		cleanup = function()
			connection:Disconnect()
			if folder.Parent then
				folder:Destroy()
			end
		end,
	}
end

--------------------------------------------------------------------------

local SPAWN: { [string]: (any) -> Active? } = {
	window = windowPassenger,
	conductor = hollowConductor,
	switchkeeper = switchkeeper,
	intrusion = intrusion,
}

local function clear(expedition: any)
	local s = states[expedition.id]
	if not s then
		return
	end
	for _, a in s.active do
		Protect.call(a.cleanup)
	end
	s.active = {}
end

function EntityService.start()
	Net.onServerEvent("EntitySeen", function(player, rawToken)
		if type(rawToken) == "string" and windowSeen[rawToken] == false then
			local expedition = ExpeditionService.forPlayer(player)
			if expedition and string.sub(rawToken, 1, #expedition.id + 1) == expedition.id .. ":" then
				windowSeen[rawToken] = true
			end
		end
	end)

	ExpeditionService.StationReached:Connect(function(expedition, index)
		if index == StationRegistry.count() then
			local s = stateFor(expedition)
			if not s.dispatcherDone then
				s.dispatcherDone = true
				task.delay(30, function()
					if expedition.state == "climax" then
						local a = dispatcher(expedition)
						if a then
							table.insert(s.active, a)
						end
					end
				end)
			end
		end
	end)

	ExpeditionService.Retried:Connect(function(expedition)
		clear(expedition)
		local s = stateFor(expedition)
		for i, entry in SCHEDULE do
			if entry.segment > expedition.stationIndex then
				s.fired[i] = nil
			end
		end
		if expedition.stationIndex >= StationRegistry.count() then
			s.dispatcherDone = false
		end
	end)

	ExpeditionService.Ended:Connect(function(expedition)
		clear(expedition)
		states[expedition.id] = nil
		conductorWarned[expedition.id] = nil
	end)

	RunService.Heartbeat:Connect(function(dt)
		for _, expedition in ExpeditionService.all() do
			local s = states[expedition.id]
			-- Studio test hook: a server-set "EntityTest" attribute on a crew
			-- member spawns that entity now. Does nothing outside Studio.
			if RunService:IsStudio() then
				for _, player in crew(expedition) do
					local kind = player:GetAttribute("EntityTest")
					if type(kind) == "string" then
						player:SetAttribute("EntityTest", nil)
						local spawn = if kind == "dispatcher" then dispatcher else SPAWN[kind]
						if spawn then
							local ok, a = Protect.call(spawn, expedition)
							if ok and a then
								table.insert(stateFor(expedition).active, a)
								log.warn("TEST spawned " .. kind)
							end
						end
					end
				end
				s = states[expedition.id]
			end
			if expedition.state == "travelling" then
				s = stateFor(expedition)
				local busy = #s.active > 0
				for i, entry in SCHEDULE do
					if not s.fired[i] and not busy and expedition.train.distance >= entry.at and expedition.train.distance < entry.at + 900 then
						s.fired[i] = true
						local ok, a = Protect.call(SPAWN[entry.kind], expedition)
						if ok and a then
							table.insert(s.active, a)
							busy = true
						end
					end
				end
			end
			if s then
				for i = #s.active, 1, -1 do
					local a = s.active[i]
					local ok = true
					if a.tick then
						ok = Protect.call(a.tick, dt)
					end
					if not ok or a.isDone() then
						Protect.call(a.cleanup)
						table.remove(s.active, i)
					end
				end
			end
		end
	end)

	log.info("started")
end

return EntityService
