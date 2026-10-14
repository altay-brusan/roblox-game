--!strict
--[[
	JourneyEvents
	-------------
	What each night-run emergency does, as a small state machine run by
	JourneyService. Each has the same shape:

	  start      onset and evidence: what changes, and what the player can see
	             and hear that tells them what is wrong. Returns false if the
	             event cannot start here, and JourneyService records that and
	             moves on (the runtime fallback).
	  onTask     the player's action, a held RunTask job.
	  escalate   what gets worse when it is ignored.
	  fail       the consequence of ignoring it for too long.
	  cleanup    everything the event put in the world or changed on the train
	             is put back. Called on resolve, fail, retry and run end.

	Several events act on each other on purpose, so a night is a situation
	rather than a list:
	  - The signal post telephone runs off the train's power: during a
	    carriage blackout it is dead until the breaker is reset.
	  - An electrical fire left to burn takes the lights out: a blackout.
	  - The thing on the roof, if it finds a door open or a dark train, forces
	    a door: a door that will not latch.
	  - Dragging brakes burn fuel, which matters most on the cut-off, where
	    there is no refuelling stop.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.LastSignal

local Balance = require(Shared.Config.Balance)

local C = Color3.fromRGB

export type Ctx = {
	expedition: any,
	train: any,
	state: { [string]: any },
	elapsed: number,
	-- Services, handed in by JourneyService so this file has no requires on
	-- the service graph.
	notify: (kind: string, title: string, body: string) -> (),
	radio: (source: string, attribution: string, text: string, duration: number) -> (),
	cue: (name: string, position: Vector3?) -> (),
	threat: (amount: number) -> (),
	noise: (position: Vector3, loudness: number) -> (),
	holdTrain: (studsAhead: number) -> number,
	releaseTrain: () -> (),
	applyLights: () -> (),
	setDoor: (door: any, angle: number) -> (),
	chain: (templateId: string) -> (),
	isActive: (templateId: string) -> boolean,
	award: (credits: number, fuel: number) -> (),
	stationFixtures: () -> { BasePart },
	rng: Random,
	resolve: (outcome: string) -> (),
	fail: (outcome: string) -> (),
}

export type EventImpl = {
	start: (Ctx) -> boolean,
	tick: ((Ctx, number) -> ())?,
	onTask: ((Ctx, BasePart, boolean) -> ())?,
	onHorn: ((Ctx) -> ())?,
	escalate: ((Ctx) -> ())?,
	fail: ((Ctx) -> ())?,
	cleanup: (Ctx) -> (),
}

--------------------------------------------------------------------------
-- Props
--------------------------------------------------------------------------

local function prop(name: string, size: Vector3, cf: CFrame, colour: Color3, material: Enum.Material, parent: Instance): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.CFrame = cf
	p.Color = colour
	p.Material = material
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = true
	p.CanTouch = false
	p.Parent = parent
	return p
end

--- Welds a prop to the train so it rides along.
local function ride(p: BasePart, train: any)
	p.Anchored = false
	p.Massless = true
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = train.built.root
	weld.Part1 = p
	weld.Parent = p
end

--- Makes a part a held night-run job (see InteractionService "run_task").
local function makeTask(p: BasePart, label: string, detail: string, seconds: number, extra: { [string]: any }?)
	p:SetAttribute("TaskLabel", label)
	p:SetAttribute("TaskDetail", detail)
	p:SetAttribute("TaskSeconds", seconds)
	for k, v in pairs(extra or {}) do
		p:SetAttribute(k, v)
	end
	p:AddTag("RunTask")
end

local function trainCF(train: any, distance: number): CFrame
	return train.origin * CFrame.new(0, 0, -distance)
end

local function carriageBox(train: any, index: number): (CFrame?, Vector3?)
	local carriage = train.built.carriages[index]
	if not carriage then
		return nil, nil
	end
	return carriage:GetBoundingBox()
end

--------------------------------------------------------------------------

local Events: { [string]: EventImpl } = {}

-- 1. Carriage blackout -----------------------------------------------------
Events.carriage_blackout = {
	start = function(ctx)
		local cf, size = carriageBox(ctx.train, 1)
		if not cf or not size then
			return false
		end
		ctx.state.wasLit = ctx.train.interiorLights
		ctx.train.interiorLights = false
		ctx.applyLights()
		-- The breaker box glows red: the one lit thing in a dark carriage.
		local box = prop("CarriageBreaker", Vector3.new(0.6, 1.6, 1.2), cf * CFrame.new(size.X * 0.5 - 1.0, -size.Y * 0.5 + 4.6, -size.Z * 0.5 + 3), C(40, 42, 44), Enum.Material.Metal, ctx.train.built.model)
		local lamp = prop("BreakerLamp", Vector3.new(0.65, 0.3, 0.3), box.CFrame * CFrame.new(0, 0.5, 0), C(255, 50, 40), Enum.Material.Neon, box)
		local light = Instance.new("PointLight")
		light.Color = C(255, 60, 40)
		light.Range = 10
		light.Brightness = 2
		light.Parent = lamp
		ride(box, ctx.train)
		ride(lamp, ctx.train)
		makeTask(box, "Reset the carriage breaker", "Carriage breaker", 3)
		ctx.state.box = box
		ctx.cue("breaker_throw", box.Position)
		ctx.notify("warning", "The carriages are dark", "The carriage breaker has tripped. It is on the wall of the first carriage, lit red.")
		ctx.radio("dispatch", "Dispatch", "Control. I am reading your carriage circuit as dead. Breaker, first carriage. A dark train is an open door out there.", 7)
		return true
	end,
	tick = function(ctx)
		-- Other effects (a flicker ending) must not switch the lights back on
		-- while the breaker is out.
		if ctx.train.interiorLights then
			ctx.train.interiorLights = false
			ctx.applyLights()
		end
	end,
	onTask = function(ctx, part)
		if part == ctx.state.box then
			ctx.cue("breaker_throw", part.Position)
			ctx.resolve("Breaker reset; the lights came back")
		end
	end,
	escalate = function(ctx)
		ctx.threat(20)
		ctx.notify("warning", "Something has noticed the dark train", "")
	end,
	fail = function(ctx)
		ctx.threat(25)
	end,
	cleanup = function(ctx)
		if ctx.state.box then
			ctx.state.box:Destroy()
		end
		ctx.train.interiorLights = true
		ctx.applyLights()
	end,
}

-- 2. Signal at danger -------------------------------------------------------
Events.signal_fault = {
	start = function(ctx)
		local holdAt = ctx.holdTrain(320)
		local base = trainCF(ctx.train, holdAt + 30) * CFrame.new(7.5, 0, 0)
		local model = Instance.new("Model")
		model.Name = "SignalAtDanger"
		model.Parent = ctx.expedition.lane.dropContainer
		prop("SignalPost", Vector3.new(0.6, 14, 0.6), base * CFrame.new(0, 7, 0), C(40, 40, 42), Enum.Material.Metal, model)
		prop("SignalHead", Vector3.new(1.6, 3.2, 1.0), base * CFrame.new(0, 13.5, 0), C(24, 24, 26), Enum.Material.Metal, model)
		local aspect = prop("Aspect", Vector3.new(0.9, 0.9, 0.3), base * CFrame.new(0, 13.5, 0.55), C(255, 40, 30), Enum.Material.Neon, model)
		local light = Instance.new("PointLight")
		light.Color = C(255, 40, 30)
		light.Range = 24
		light.Brightness = 3
		light.Parent = aspect
		local phone = prop("SignalPhone", Vector3.new(1.0, 1.6, 0.8), base * CFrame.new(0, 3.6, 0.7), C(170, 40, 30), Enum.Material.Metal, model)
		phone.CanCollide = true
		makeTask(phone, "Ring Control", "Signal post telephone", 3)
		ctx.state.model = model
		ctx.state.aspect = aspect
		ctx.state.light = light
		ctx.state.phone = phone
		ctx.notify("info", "Signal at danger", "The signal ahead is red. Ring Control from the telephone on the signal post, or wait for the timetable.")
		ctx.radio("dispatch", "Dispatch", "Control. You will have a red ahead of you; my board has lost the section. Ring me from the post and I will clear you by hand.", 7)
		return true
	end,
	tick = function(ctx)
		-- The post telephone is fed from the train's circuit.
		local phone = ctx.state.phone
		if phone then
			phone:SetAttribute("TaskBlocked", if ctx.isActive("carriage_blackout") then "The line is dead. The post telephone runs off the train's power: reset the carriage breaker first." else "")
		end
		if ctx.state.clearingAt and os.clock() >= ctx.state.clearingAt then
			ctx.resolve("Control cleared the signal by telephone")
		end
	end,
	onTask = function(ctx, part)
		if part == ctx.state.phone and not ctx.state.clearingAt then
			part:RemoveTag("RunTask")
			ctx.radio("dispatch", "Dispatch", "Control. I hear you. Clearing the section now. Give it a moment.", 5)
			ctx.state.clearingAt = os.clock() + 6
		end
	end,
	escalate = function(ctx)
		ctx.threat(10)
		ctx.notify("warning", "Still held at the signal", "The forest is getting closer while you wait.")
	end,
	fail = function(ctx)
		-- The timetable clears it eventually; the cost was the wait.
		ctx.radio("dispatch", "Dispatch", "Control. Timetable has released the section. You have lost time.", 5)
	end,
	cleanup = function(ctx)
		if ctx.state.aspect then
			ctx.state.aspect.Color = C(60, 255, 120)
			ctx.state.light.Color = C(60, 255, 120)
		end
		local model = ctx.state.model
		if model then
			task.delay(4, function()
				model:Destroy()
			end)
		end
		ctx.releaseTrain()
	end,
}

-- 3. Dragging brakes --------------------------------------------------------
Events.brake_drag = {
	start = function(ctx)
		local train = ctx.train
		ctx.state.cap = 34
		train.speedCap = ctx.state.cap
		train.fuelMultiplier = 1.8
		-- Sparks at the leading bogie, and the valve on the locomotive side.
		local root = train.built.root
		local sparks = prop("BrakeSparks", Vector3.new(2, 0.4, 2), root.CFrame * CFrame.new(3.4, -3.2, -4), C(255, 150, 60), Enum.Material.Neon, train.built.model)
		ride(sparks, train)
		local fx = Instance.new("Sparkles")
		fx.SparkleColor = C(255, 160, 80)
		fx.Parent = sparks
		local valve = prop("BrakeValve", Vector3.new(0.5, 1.4, 1.4), root.CFrame * CFrame.new(5.6, -1.4, -6), C(200, 60, 40), Enum.Material.Metal, train.built.model)
		ride(valve, train)
		makeTask(valve, "Release the brake valve", "Brake cylinder, locomotive side", 5)
		ctx.state.sparks = sparks
		ctx.state.valve = valve
		ctx.cue("train_brake_apply", root.Position)
		ctx.notify("warning", "The brakes are dragging", "Half speed and heavy fuel burn until the valve on the outside of the locomotive is released. Stop first.")
		return true
	end,
	onTask = function(ctx, part)
		if part == ctx.state.valve then
			ctx.resolve("Brake valve released")
		end
	end,
	escalate = function(ctx)
		-- Heat in the binding shoe takes the cap lower still.
		ctx.state.cap = 24
		ctx.train.speedCap = 24
		ctx.notify("warning", "The brakes are binding harder", "Down to a crawl. The valve is on the outside of the locomotive.")
	end,
	cleanup = function(ctx)
		ctx.train.speedCap = nil
		ctx.train.fuelMultiplier = nil
		for _, key in { "sparks", "valve" } do
			if ctx.state[key] then
				ctx.state[key]:Destroy()
			end
		end
	end,
}

-- 4. Tree across the line ---------------------------------------------------
Events.fallen_tree = {
	start = function(ctx)
		local holdAt = ctx.holdTrain(300)
		local base = trainCF(ctx.train, holdAt + 22)
		local model = Instance.new("Model")
		model.Name = "FallenTree"
		model.Parent = ctx.expedition.lane.dropContainer
		local trunk = prop("Trunk", Vector3.new(26, 2.6, 2.6), base * CFrame.new(1, 1.4, 0) * CFrame.Angles(0, math.rad(8), math.rad(4)), C(84, 62, 44), Enum.Material.Wood, model)
		trunk.Shape = Enum.PartType.Cylinder
		trunk.CanCollide = true
		for i = 1, 5 do
			prop("Branch", Vector3.new(0.6, 5, 0.6), trunk.CFrame * CFrame.new(-10 + i * 4, 1.6, 0) * CFrame.Angles(math.rad(25), 0, math.rad(i * 20)), C(70, 54, 40), Enum.Material.Wood, model)
			prop("Needles", Vector3.new(4, 3, 4), trunk.CFrame * CFrame.new(-10 + i * 4, 3.6, 0), C(36, 54, 38), Enum.Material.Grass, model)
		end
		local cuts = {}
		for i, x in { -4.5, 4.5 } do
			local cut = prop("CutPoint", Vector3.new(1.2, 3.2, 3.2), trunk.CFrame * CFrame.new(x, 0, 0), C(150, 112, 70), Enum.Material.Wood, model)
			makeTask(cut, "Cut through the trunk", string.format("Cut %d of 2", i), 6, { TaskNoise = 8 })
			cuts[cut] = true
		end
		ctx.state.model = model
		ctx.state.cuts = cuts
		ctx.state.left = 2
		ctx.notify("warning", "Tree across the line", "The train is held short of it. Two cuts clear it, and the forest hears every one.")
		ctx.radio("crew", "Crew", "Pine down across both rails. We are not getting past that without cutting it.", 5)
		return true
	end,
	onTask = function(ctx, part)
		if ctx.state.cuts[part] then
			ctx.state.cuts[part] = nil
			part:Destroy()
			ctx.state.left -= 1
			ctx.noise(part.Position, 10)
			if ctx.state.left <= 0 then
				ctx.resolve("Tree cut and cleared")
			end
		end
	end,
	escalate = function(ctx)
		ctx.threat(15)
	end,
	cleanup = function(ctx)
		if ctx.state.model then
			ctx.state.model:Destroy()
		end
		ctx.releaseTrain()
	end,
}

-- 5. Electrical fire --------------------------------------------------------
Events.electrical_fire = {
	start = function(ctx)
		local index = if ctx.train.built.carriages[2] then 2 else 1
		local cf, size = carriageBox(ctx.train, index)
		if not cf or not size then
			return false
		end
		local heater = prop("BurningHeater", Vector3.new(2.4, 1.4, 1.2), cf * CFrame.new(-size.X * 0.5 + 1.4, -size.Y * 0.5 + 1.6, 0), C(46, 40, 36), Enum.Material.Metal, ctx.train.built.model)
		ride(heater, ctx.train)
		local fire = Instance.new("Fire")
		fire.Size = 4
		fire.Heat = 6
		fire.Parent = heater
		local smoke = Instance.new("Smoke")
		smoke.Opacity = 0.25
		smoke.RiseVelocity = 3
		smoke.Parent = heater
		local glow = Instance.new("PointLight")
		glow.Color = C(255, 120, 50)
		glow.Range = 16
		glow.Brightness = 2
		glow.Parent = heater
		makeTask(heater, "Beat out the fire", "Burning heater (a coolant canister smothers it fast)", 6, {
			TaskFastItem = "coolant",
			TaskFastSeconds = 2,
			TaskFastConsumes = true,
		})
		ctx.state.heater = heater
		ctx.state.fire = fire
		ctx.notify("danger", "Fire in the carriage", "A heater has shorted. Beat it out, or spend a coolant canister to smother it.")
		ctx.cue("breaker_throw", heater.Position)
		return true
	end,
	onTask = function(ctx, part, usedFast)
		if part == ctx.state.heater then
			ctx.resolve(if usedFast then "Smothered with a coolant canister" else "Beaten out by hand")
		end
	end,
	escalate = function(ctx)
		if ctx.state.fire then
			ctx.state.fire.Size = 8
		end
		ctx.train.condition = math.max(5, ctx.train.condition - 6)
		ctx.notify("danger", "The fire is spreading", "It is eating the carriage. The train's condition is dropping.")
	end,
	fail = function(ctx)
		-- It burns through the lighting circuit.
		ctx.train.condition = math.max(5, ctx.train.condition - 10)
		ctx.chain("carriage_blackout")
	end,
	cleanup = function(ctx)
		if ctx.state.heater then
			ctx.state.heater:Destroy()
		end
	end,
}

-- 6. A door that will not latch ---------------------------------------------
Events.door_jam = {
	start = function(ctx)
		local doors = ctx.train.built.doors
		if #doors == 0 or ctx.train.doorsOpen then
			return false
		end
		local door = doors[ctx.rng:NextInteger(1, #doors)]
		ctx.state.door = door
		ctx.setDoor(door, math.rad(65))
		ctx.train.speedCap = Balance.Train.boardingSpeedLimit * 1.5
		local handle = prop("DoorCatch", Vector3.new(0.6, 1.4, 0.6), door.hinge.CFrame * CFrame.new(0, 0, 0), C(196, 158, 82), Enum.Material.Metal, ctx.train.built.model)
		handle.Transparency = 0.4
		ride(handle, ctx.train)
		makeTask(handle, "Force the door shut", "Jammed carriage door (quick with a crowbar)", 6, { TaskFastItem = "crowbar", TaskFastSeconds = 2 })
		ctx.state.handle = handle
		ctx.cue("train_door", door.hinge.Position)
		ctx.notify("warning", "A door will not latch", "Train protection holds you to a crawl until it is forced shut. A crowbar makes it quick.")
		return true
	end,
	onTask = function(ctx, part)
		if part == ctx.state.handle then
			ctx.resolve("Door forced shut")
		end
	end,
	escalate = function(ctx)
		ctx.threat(10)
	end,
	cleanup = function(ctx)
		if ctx.state.door then
			ctx.setDoor(ctx.state.door, 0)
		end
		if ctx.state.handle then
			ctx.state.handle:Destroy()
		end
		ctx.train.speedCap = nil
	end,
}

-- 7. Something on the roof --------------------------------------------------
Events.roof_visitor = {
	start = function(ctx)
		ctx.state.step = 0
		ctx.cue("creature_near", ctx.train.built.root.Position + Vector3.new(0, 8, 0))
		ctx.notify("danger", "Something is on the roof", "Sound the horn to throw it off, or keep every door shut and the lights on until it gives up.")
		return true
	end,
	tick = function(ctx)
		-- Footsteps walking the length of the roof, every two seconds.
		ctx.state.nextStep = ctx.state.nextStep or 0
		if os.clock() >= ctx.state.nextStep then
			ctx.state.nextStep = os.clock() + 2
			ctx.state.step += 1
			local _, size = ctx.train.built.model:GetBoundingBox()
			local along = ((ctx.state.step * 9) % size.Z) - size.Z * 0.5
			ctx.cue("footsteps_outside", (ctx.train.built.root.CFrame * CFrame.new(0, 7, along)).Position)
		end
	end,
	onHorn = function(ctx)
		ctx.cue("creature_repelled", ctx.train.built.root.Position + Vector3.new(0, 8, 0))
		ctx.resolve("Thrown off by the horn")
	end,
	escalate = function(ctx)
		ctx.cue("creature_attack", ctx.train.built.root.Position + Vector3.new(0, 8, 0))
		ctx.notify("danger", "It is trying the doors", "")
	end,
	fail = function(ctx)
		-- It gives up only if the train stayed sealed and lit.
		if ctx.train.doorsOpen or not ctx.train.interiorLights or ctx.isActive("door_jam") then
			ctx.train.condition = math.max(5, ctx.train.condition - 8)
			ctx.chain("door_jam")
			ctx.notify("danger", "It forced a door", "")
		else
			ctx.notify("info", "It has gone", "A sealed, lit train was not worth the effort.")
		end
	end,
	cleanup = function(_ctx) end,
}

-- 8. Unscheduled inspection (station) ---------------------------------------
Events.inspection = {
	start = function(ctx)
		local spots = ctx.stationFixtures()
		if #spots == 0 then
			return false
		end
		-- A valid spot: next to one of the station's own fixtures, picked by
		-- the seed, so it is somewhere the crew goes anyway.
		local at = spots[ctx.rng:NextInteger(1, #spots)]
		local book = prop("InspectorsLog", Vector3.new(1.4, 0.3, 1.0), at.CFrame * CFrame.new(0, at.Size.Y * 0.5 + 0.4, 0), C(120, 30, 30), Enum.Material.Fabric, ctx.expedition.lane.dropContainer)
		local glow = Instance.new("PointLight")
		glow.Color = C(255, 220, 160)
		glow.Range = 8
		glow.Brightness = 1
		glow.Parent = book
		makeTask(book, "Sign the inspector's log", "Unscheduled inspection", 2)
		ctx.state.book = book
		ctx.radio("dispatch", "Dispatch", "Control. Inspection notice for this station: the inspector's log is here somewhere. Sign it before you leave and I will see you are refuelled for it.", 7)
		ctx.notify("info", "Unscheduled inspection", "Find and sign the inspector's log at this station. Optional: fuel and credits if you do.")
		return true
	end,
	onTask = function(ctx, part)
		if part == ctx.state.book then
			ctx.award(150, 20)
			ctx.resolve("Log signed: +20 fuel, +150 credits")
		end
	end,
	cleanup = function(ctx)
		if ctx.state.book then
			ctx.state.book:Destroy()
		end
	end,
}

return Events
