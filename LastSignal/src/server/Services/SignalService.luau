--!strict
--[[
	SignalService
	-------------
	The Signal Integrity Analyzer, server side: signal calls at stations, the
	evidence a crew gathers, the confidence it supports, and what happens
	when the crew acts on a call.

	FAIRNESS
	--------
	The truth of a call never leaves the server. Clients receive the caller's
	words, the evidence the crew has gathered, and a label computed only from
	that evidence. The bearing channel is real geometry: two sweeps from
	different places are triangulated against the call's actual source, with
	noise from the analyzer's fidelity and the call's interference. A careful
	crew can always reach the right answer; a hasty one can be fooled.

	EVERY CHANNEL WORKS SOLO
	------------------------
	Sweeping, analysing, asking, examining and comparing are all one-player
	actions. Nothing needs two people.

	CONSEQUENCES
	------------
	  Go     the crew answers the call in person at the place the caller
	         named: a survivor, a recording, a harmless anomaly, or a trap.
	  Mark   the crew marks it a mimic: correct, and the bait it was using is
	         safe to take; wrong, and a real person is lost.
	  Leave  nothing happens.
	A verdict that matches the truth pays 15 RIP Coin, once per call per run,
	and counts towards the analyzer's fidelity upgrade.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local Shared = ReplicatedStorage.LastSignal

local Guard = require(Shared.Core.Guard)
local Logger = require(Shared.Core.Logger)
local Net = require(Shared.Core.Net)
local Protect = require(Shared.Core.Protect)
local StationRegistry = require(Shared.Registry.StationRegistry)

local CreatureService = require(script.Parent.CreatureService)
local DataService = require(script.Parent.DataService)
local ExpeditionService = require(script.Parent.ExpeditionService)
local HorrorDirector = require(script.Parent.HorrorDirector)
local InteractionService = require(script.Parent.InteractionService)
local InventoryService = require(script.Parent.InventoryService)
local ProgressionService = require(script.Parent.ProgressionService)
local WorldService = require(script.Parent.WorldService)
local SignalRegistry = require(script.Parent.Parent.Journey.SignalRegistry)

local log = Logger.new("SignalService")
local C = Color3.fromRGB

local SignalService = {}

-- Bearing noise in degrees, by analyzer fidelity. Fidelity 2 is earned by
-- reaching the right verdict on five calls.
local FIDELITY_NOISE = { 12, 5 }
local FIDELITY_2_AFTER = 5
local VERIFY_REWARD = 15
local INTERFERENCE_NOISE = 22

type EvidenceItem = { channel: string, text: string, weight: { number } }

type Call = {
	def: SignalRegistry.CallDef,
	status: string, -- "live" | "resolved"
	outcome: string?,
	verdict: string?,
	correct: boolean?,
	evidence: { EvidenceItem },
	readings: { { position: Vector3, bearing: number, strength: number } },
	estimate: Vector3?,
	uncertainty: number?,
	asked: { [number]: boolean },
	compared: { [string]: boolean },
	analysed: { [string]: boolean },
	sourcePosition: Vector3,
	claimPosition: Vector3,
	props: { Instance },
}

type State = {
	calls: { [string]: Call },
	order: { string },
	rescued: { string },
	paid: { [string]: boolean },
	traps: number,
}

local states: { [string]: State } = {}

--------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------

local function stateFor(expedition: any): State
	local s = states[expedition.id]
	if not s then
		s = { calls = {}, order = {}, rescued = {}, paid = {}, traps = 0 }
		states[expedition.id] = s
	end
	return s
end

local function ground(position: Vector3): Vector3
	local hit = Workspace:Raycast(position + Vector3.new(0, 60, 0), Vector3.new(0, -160, 0))
	return if hit then hit.Position else position
end

local function landmark(expedition: any, stationIndex: number, id: string): (Vector3?, string)
	local built = expedition.lane.stations[stationIndex]
	local def = StationRegistry.byIndex(stationIndex)
	local name = id
	if def then
		for _, mark in def.layout.landmarks do
			if mark.id == id then
				name = mark.name
			end
		end
	end
	if built and built.landmarks[id] then
		return built.landmarks[id], name
	end
	return nil, name
end

local function nearestLandmark(expedition: any, stationIndex: number, position: Vector3): (string, number)
	local def = StationRegistry.byIndex(stationIndex)
	local built = expedition.lane.stations[stationIndex]
	local bestName, bestDistance = "nowhere", math.huge
	if def and built then
		for _, mark in def.layout.landmarks do
			local p = built.landmarks[mark.id]
			if p then
				local d = (Vector3.new(p.X, 0, p.Z) - Vector3.new(position.X, 0, position.Z)).Magnitude
				if d < bestDistance then
					bestName, bestDistance = mark.name, d
				end
			end
		end
	end
	return bestName, bestDistance
end

local function fidelityOf(player: Player): number
	local profile = DataService.getProfile(player)
	local verified = if profile then (profile.stats.calls_verified or 0) else 0
	return if verified >= FIDELITY_2_AFTER then 2 else 1
end

--- The label is an inference from the evidence gathered, nothing more.
local function confidence(call: Call): (string, { number })
	local totals = { 0, 0, 0, 0 }
	for _, item in call.evidence do
		for i = 1, 4 do
			totals[i] += item.weight[i] or 0
		end
	end
	if #call.evidence < 2 then
		return "Unverified", totals
	end
	local order = { 1, 2, 3, 4 }
	table.sort(order, function(a, b)
		return totals[a] > totals[b]
	end)
	local best, second = totals[order[1]], totals[order[2]]
	if best <= 1 then
		return "Unknown", totals
	end
	if best - second < 1.5 then
		return "Inconsistent", totals
	end
	local labels = { "Likely human", "Likely a recording", "Likely a mimic", "Likely an anomaly" }
	return labels[order[1]], totals
end

local function addEvidence(call: Call, channel: string, text: string, weight: { number })
	-- One entry per channel (and per question/compare), replaced if retaken.
	for i, item in call.evidence do
		if item.channel == channel then
			call.evidence[i] = { channel = channel, text = text, weight = weight }
			return
		end
	end
	table.insert(call.evidence, { channel = channel, text = text, weight = weight })
end

local function snapshot(expedition: any, viewer: Player?): any
	local s = states[expedition.id]
	if not s then
		return { calls = {} }
	end
	local calls = {}
	for _, id in s.order do
		local call = s.calls[id]
		local def = call.def
		local label = confidence(call)
		local evidence = {}
		for _, item in call.evidence do
			table.insert(evidence, { channel = item.channel, text = item.text })
		end
		local questions = {}
		for i, q in def.questions do
			table.insert(questions, { ask = q.ask, asked = call.asked[i] == true })
		end
		local readings = {}
		for _, r in call.readings do
			table.insert(readings, { bearing = r.bearing, strength = r.strength })
		end
		local _, claimName = landmark(expedition, def.station, def.claims)
		table.insert(calls, {
			id = id,
			caller = def.caller,
			transcript = def.transcript,
			claims = claimName,
			status = call.status,
			outcome = call.outcome,
			verdict = call.verdict,
			label = label,
			evidence = evidence,
			questions = questions,
			readings = readings,
			estimate = call.estimate,
			uncertainty = call.uncertainty,
			waveShape = if call.analysed.waveform then def.waveShape else nil,
			analysed = { waveform = call.analysed.waveform == true, timing = call.analysed.timing == true },
		})
	end
	return {
		calls = calls,
		fidelity = if viewer then fidelityOf(viewer) else 1,
	}
end

local function push(expedition: any)
	for _, player in ExpeditionService.playersOf(expedition) do
		Net.fireClient("SignalState", player, snapshot(expedition, player))
	end
end

local function radio(expedition: any, attribution: string, text: string, duration: number?)
	Net.fireClients("RadioMessage", ExpeditionService.playersOf(expedition), {
		id = "signal",
		source = "other",
		text = text,
		duration = duration or 6,
		attribution = attribution,
		isFalse = false,
	})
end

local function notify(expedition: any, kind: string, title: string, body: string)
	Net.fireClients("Notify", ExpeditionService.playersOf(expedition), { kind = kind, title = title, body = body, duration = 7 })
end

local function prop(name: string, size: Vector3, cf: CFrame, colour: Color3, material: Enum.Material, parent: Instance): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.CFrame = cf
	p.Color = colour
	p.Material = material
	p.Anchored = true
	p.CanCollide = false
	p.Parent = parent
	return p
end

--------------------------------------------------------------------------
-- Calls
--------------------------------------------------------------------------

local function cleanupCall(call: Call)
	for _, p in call.props do
		p:Destroy()
	end
	call.props = {}
end

local function startCall(expedition: any, def: SignalRegistry.CallDef)
	local s = stateFor(expedition)
	if s.calls[def.id] then
		return
	end
	local claimPos = landmark(expedition, def.station, def.claims)
	local sourcePos = landmark(expedition, def.station, def.source)
	if not claimPos or not sourcePos then
		log.warn("call " .. def.id .. " has no landmark here; skipped")
		return
	end
	local call: Call = {
		def = def,
		status = "live",
		evidence = {},
		readings = {},
		asked = {},
		compared = {},
		analysed = {},
		sourcePosition = ground(sourcePos + def.sourceOffset) + Vector3.new(0, 3, 0),
		claimPosition = ground(claimPos) + Vector3.new(0, 0.5, 0),
		props = {},
	}
	s.calls[def.id] = call
	table.insert(s.order, def.id)

	-- The physical clue at the place the caller names.
	local clue = prop("SignalClue", Vector3.new(2, 2, 2), CFrame.new(call.claimPosition + Vector3.new(3, 1, 0)), C(120, 110, 90), Enum.Material.Fabric, expedition.lane.dropContainer)
	clue.Transparency = 0.6
	clue:SetAttribute("SignalCall", def.id)
	clue:SetAttribute("SignalRole", "clue")
	clue:SetAttribute("TaskLabel", "Examine for signs")
	clue:SetAttribute("TaskDetail", "Where the caller says they are")
	clue:SetAttribute("TaskSeconds", 2)
	clue:AddTag("RunTask")
	table.insert(call.props, clue)

	for i, line in def.transcript do
		task.delay((i - 1) * 6.5, function()
			if call.status == "live" then
				radio(expedition, "Unknown signal", line, 6)
			end
		end)
	end
	notify(expedition, "info", "Signal received: " .. def.caller, "Open the Signal Integrity Analyzer (V) to examine it before you act.")
	push(expedition)
	log.info(string.format("%s: call %s started", expedition.id, def.id))
end

local function resolve(expedition: any, call: Call, verdict: string, by: Player?)
	if call.status ~= "live" then
		return
	end
	local def = call.def
	local s = stateFor(expedition)
	call.status = "resolved"
	call.verdict = verdict
	local truth = def.truth
	local correct = (verdict == "go" and truth ~= "mimic") or (verdict == "mark" and truth == "mimic")
	call.correct = if verdict == "leave" then nil else correct
	local result = if verdict == "mark" then def.onMark elseif verdict == "go" then def.onGo else "left:Nobody answered."
	local kind, text = string.match(result, "^(%a+):(.*)$")
	call.outcome = text or result
	cleanupCall(call)

	if kind == "survivor" then
		table.insert(s.rescued, def.caller)
		-- A survivor rides with the crew for the rest of the run, and brings
		-- what they had.
		local carriage = expedition.train.built.carriages[1]
		if carriage then
			local seat
			for _, d in carriage:GetDescendants() do
				if d:IsA("Seat") and not d.Occupant and not d:GetAttribute("SurvivorSeat") then
					seat = d
					break
				end
			end
			if seat then
				seat:SetAttribute("SurvivorSeat", true)
				local figure = prop("Survivor", Vector3.new(1.8, 3.4, 1.0), seat.CFrame * CFrame.new(0, 2.1, 0.2), C(110, 96, 80), Enum.Material.Fabric, carriage)
				figure.Anchored = false
				figure.Massless = true
				local weld = Instance.new("WeldConstraint")
				weld.Part0 = expedition.train.built.root
				weld.Part1 = figure
				weld.Parent = figure
				local head = prop("SurvivorHead", Vector3.new(1, 1.2, 1), figure.CFrame * CFrame.new(0, 2.3, 0), C(196, 166, 138), Enum.Material.SmoothPlastic, figure)
				head.Anchored = false
				head.Massless = true
				local hw = Instance.new("WeldConstraint")
				hw.Part0 = figure
				hw.Part1 = head
				hw.Parent = head
			end
		end
		if by then
			InventoryService.add(by, "bandage", 2, true)
			InventoryService.add(by, "battery", 1, true)
		end
		notify(expedition, "info", "Survivor found", call.outcome or "")
	elseif kind == "trap" then
		s.traps += 1
		HorrorDirector.addThreat(expedition.id, 25)
		CreatureService.hearNoise(expedition.id, call.claimPosition, 14)
		Net.fireClients("HorrorCue", ExpeditionService.playersOf(expedition), { cue = "creature_near", position = call.claimPosition })
		notify(expedition, "danger", "It was not a person", call.outcome or "")
	elseif kind == "cache" then
		-- The bait was real; with the mimic named, it is safe to take.
		local container = expedition.lane.dropContainer
		WorldService.buildDroppedItem("fuel_can", 1, CFrame.new(call.claimPosition + Vector3.new(0, 1, 2)), container)
		WorldService.buildDroppedItem("relay", 1, CFrame.new(call.claimPosition + Vector3.new(2, 1, 0)), container)
		notify(expedition, "info", "Mimic named", call.outcome or "")
	elseif kind == "lost" then
		notify(expedition, "warning", "The call goes quiet", call.outcome or "")
	else
		notify(expedition, "info", "Signal resolved", call.outcome or "")
	end

	if correct and verdict ~= "leave" and not s.paid[def.id] then
		s.paid[def.id] = true
		for _, player in ExpeditionService.playersOf(expedition) do
			ProgressionService.award(player, { credits = VERIFY_REWARD, source = "signal:" .. def.id }, expedition.crewSize)
			ProgressionService.addStat(player, "calls_verified", 1)
		end
	end
	log.info(string.format("%s: call %s %s (truth %s, %s)", expedition.id, def.id, verdict, truth, if correct then "correct" else "wrong"))
	push(expedition)
end

--- Leaving a station ends its calls unanswered.
local function closeStation(expedition: any, stationIndex: number)
	local s = states[expedition.id]
	if not s then
		return
	end
	for _, call in s.calls do
		if call.status == "live" and call.def.station == stationIndex then
			call.status = "resolved"
			call.verdict = "leave"
			call.outcome = "The train left. Nobody answered."
			cleanupCall(call)
		end
	end
	push(expedition)
end

--------------------------------------------------------------------------
-- Channels
--------------------------------------------------------------------------

local function bearingTo(from: Vector3, to: Vector3): number
	local d = to - from
	return math.deg(math.atan2(d.X, -d.Z)) % 360
end

local function triangulate(call: Call): (Vector3?, number?)
	local r = call.readings
	if #r < 2 then
		return nil, nil
	end
	-- The most recent reading against the earlier one with the widest
	-- baseline: two rays in XZ, intersected.
	local last = r[#r]
	local best, baseline = nil, 0
	for i = 1, #r - 1 do
		local b = (Vector3.new(r[i].position.X, 0, r[i].position.Z) - Vector3.new(last.position.X, 0, last.position.Z)).Magnitude
		if b > baseline then
			best, baseline = r[i], b
		end
	end
	if not best or baseline < 15 then
		return nil, nil
	end
	local function dir(deg: number): Vector2
		local rad = math.rad(deg)
		return Vector2.new(math.sin(rad), -math.cos(rad))
	end
	local p1 = Vector2.new(best.position.X, best.position.Z)
	local p2 = Vector2.new(last.position.X, last.position.Z)
	local d1, d2 = dir(best.bearing), dir(last.bearing)
	local denom = d1.X * d2.Y - d1.Y * d2.X
	if math.abs(denom) < 0.08 then
		return nil, nil -- nearly parallel: move further across, not along
	end
	local t = ((p2.X - p1.X) * d2.Y - (p2.Y - p1.Y) * d2.X) / denom
	if t < 0 then
		return nil, nil
	end
	local hit = p1 + d1 * t
	local uncertainty = math.clamp(t * 0.25, 8, 120)
	return Vector3.new(hit.X, last.position.Y, hit.Y), uncertainty
end

local function command(player: Player, rawCommand: any, rawCall: any, rawArg: any): any
	local commandName: string? = Guard.enum(rawCommand, { "state", "sweep", "waveform", "timing", "challenge", "compare", "verdict" })
	local expedition = ExpeditionService.forPlayer(player)
	if not commandName or not expedition then
		return { ok = false, error = "NO_EXPEDITION" }
	end
	if commandName == "state" then
		return { ok = true, state = snapshot(expedition, player) }
	end
	local s = states[expedition.id]
	local callId = Guard.string(rawCall, 64)
	local call = if s and callId then s.calls[callId] else nil
	if not call then
		return { ok = false, error = "NO_CALL" }
	end
	local def = call.def
	if call.status ~= "live" and commandName ~= "compare" then
		return { ok = false, error = "RESOLVED" }
	end

	local which: string = tostring(commandName)
	if which == "sweep" then
		local root = Guard.aliveRoot(player)
		if not root then
			return { ok = false, error = "NOT_ALIVE" }
		end
		local last = call.readings[#call.readings]
		if last and (root.Position - last.position).Magnitude < 4 then
			return { ok = false, error = "MOVE_FIRST" }
		end
		local noise = FIDELITY_NOISE[fidelityOf(player)] + def.interference * INTERFERENCE_NOISE
		local antenna = DataService.getProfile(player)
		if antenna and antenna.upgrades.signal_antenna then
			noise = math.max(2, noise - 4)
		end
		local trueBearing = bearingTo(root.Position, call.sourcePosition)
		local bearing = (trueBearing + (math.random() * 2 - 1) * noise) % 360
		local distance = (root.Position - call.sourcePosition).Magnitude
		table.insert(call.readings, { position = root.Position, bearing = bearing, strength = math.clamp(120 / math.max(distance, 1), 0.05, 1) })
		while #call.readings > 6 do
			table.remove(call.readings, 1)
		end
		local estimate, uncertainty = triangulate(call)
		if estimate then
			call.estimate = estimate
			call.uncertainty = uncertainty
			local near, nearDistance = nearestLandmark(expedition, def.station, estimate)
			local _, claimName = landmark(expedition, def.station, def.claims)
			local claimDistance = (Vector3.new(estimate.X, 0, estimate.Z) - Vector3.new(call.claimPosition.X, 0, call.claimPosition.Z)).Magnitude
			local text, weight
			if claimDistance <= math.max(35, (uncertainty or 0)) then
				text = string.format("Triangulated near %s (within about %d studs): where the caller says they are.", claimName, math.floor(uncertainty or 0))
				weight = { 1, 1, -1, 0 }
			elseif nearDistance > 70 then
				text = string.format("Triangulated out in the trees, nowhere near %s (within about %d studs).", claimName, math.floor(uncertainty or 0))
				weight = { -1, 0, 2, 0 }
			else
				text = string.format("Triangulated near %s, not %s as claimed (within about %d studs).", near, claimName, math.floor(uncertainty or 0))
				weight = { -1, 0, 2, 0 }
			end
			addEvidence(call, "bearing", text, weight)
		end
		push(expedition)
		return { ok = true, bearing = bearing, needsMore = estimate == nil }
	elseif which == "waveform" then
		call.analysed.waveform = true
		addEvidence(call, "waveform", def.waveform.text, def.waveform.weight)
	elseif which == "timing" then
		call.analysed.timing = true
		addEvidence(call, "timing", def.timing.text, def.timing.weight)
	elseif which == "challenge" then
		local index = tonumber(rawArg)
		local q = if index then def.questions[index] else nil
		if not q or call.asked[index :: number] then
			return { ok = false, error = "BAD_QUESTION" }
		end
		call.asked[index :: number] = true
		radio(expedition, player.DisplayName, q.ask, 4)
		task.delay(3, function()
			radio(expedition, "Unknown signal", q.reply, 6)
		end)
		addEvidence(call, "challenge:" .. tostring(index), string.format("Asked \"%s\" Reply: \"%s\"", q.ask, q.reply), q.weight)
	elseif which == "compare" then
		local otherId = Guard.string(rawArg, 64)
		local other = if otherId and s then s.calls[otherId] else nil
		if not other or other == call then
			return { ok = false, error = "BAD_COMPARE" }
		end
		local shared = nil
		for _, p in def.phrases do
			if table.find(other.def.phrases, p) then
				shared = p
			end
		end
		local text, weight
		if shared and def.truth == "human" then
			-- A real person can repeat what they heard, as a warning.
			text = string.format("Shares \"%s\" with %s, but here it is quoted, as a warning.", shared, other.def.caller)
			weight = { 1, 0, -1, 0 }
		elseif shared then
			text = string.format("Uses the same phrase as %s: \"%s\". Different callers, the same words.", other.def.caller, shared)
			weight = { -1, 1, 2, 0 }
		else
			text = string.format("Nothing in common with %s.", other.def.caller)
			weight = { 0, 0, 0, 0 }
		end
		if call.status == "live" then
			addEvidence(call, "compare:" .. other.def.id, text, weight)
		end
	elseif which == "verdict" then
		local verdict = Guard.enum(rawArg, { "go", "mark", "leave" })
		if not verdict then
			return { ok = false, error = "BAD_VERDICT" }
		end
		if verdict == "go" then
			-- Going is physical: a meeting point at the place the caller
			-- named, which resolves the call when someone reaches it.
			if call.verdict == "going" then
				return { ok = true }
			end
			call.verdict = "going"
			local point = prop("SignalMeeting", Vector3.new(1.6, 4, 1.6), CFrame.new(call.claimPosition + Vector3.new(-3, 2, 0)), C(255, 200, 120), Enum.Material.Neon, expedition.lane.dropContainer)
			point.Transparency = 0.5
			point:SetAttribute("SignalCall", def.id)
			point:SetAttribute("SignalRole", "meeting")
			point:SetAttribute("TaskLabel", "Answer the call here")
			point:SetAttribute("TaskDetail", def.caller)
			point:SetAttribute("TaskSeconds", 2)
			point:AddTag("RunTask")
			local light = Instance.new("PointLight")
			light.Color = C(255, 200, 120)
			light.Range = 14
			light.Parent = point
			table.insert(call.props, point)
			notify(expedition, "info", "Answering " .. def.caller, "Go to the marked place the caller named.")
		else
			resolve(expedition, call, verdict, player)
			return { ok = true }
		end
	end
	push(expedition)
	return { ok = true }
end

--------------------------------------------------------------------------

function SignalService.summary(expedition: any): any
	local s = states[expedition.id]
	if not s then
		return nil
	end
	local total, correct, answered = 0, 0, 0
	for _, call in s.calls do
		total += 1
		if call.verdict and call.verdict ~= "leave" then
			answered += 1
		end
		if call.correct then
			correct += 1
		end
	end
	return { calls = total, answered = answered, correct = correct, rescued = s.rescued, traps = s.traps }
end

function SignalService.start()
	ExpeditionService.resultsSignals = SignalService.summary

	ExpeditionService.StationReached:Connect(function(expedition, index)
		for _, def in SignalRegistry.forStation(index) do
			task.delay(def.delay, function()
				if expedition.state ~= "closed" and expedition.stationIndex == index and (expedition.state == "onstation" or expedition.state == "climax") then
					Protect.call(startCall, expedition, def)
				end
			end)
		end
	end)

	ExpeditionService.StateChanged:Connect(function(expedition, state)
		if state == "travelling" and expedition.stationIndex > 0 then
			closeStation(expedition, expedition.stationIndex)
		end
	end)

	-- A retry plays the station again, calls included.
	ExpeditionService.Retried:Connect(function(expedition)
		local s = states[expedition.id]
		if not s then
			return
		end
		for i = #s.order, 1, -1 do
			local id = s.order[i]
			local call = s.calls[id]
			if call.def.station >= expedition.stationIndex then
				cleanupCall(call)
				s.calls[id] = nil
				s.paid[id] = s.paid[id]
				table.remove(s.order, i)
			end
		end
		push(expedition)
		local index = expedition.stationIndex
		for _, def in SignalRegistry.forStation(index) do
			task.delay(def.delay, function()
				if expedition.state ~= "closed" and expedition.stationIndex == index then
					Protect.call(startCall, expedition, def)
				end
			end)
		end
	end)

	ExpeditionService.Ended:Connect(function(expedition)
		local s = states[expedition.id]
		if s then
			for _, call in s.calls do
				cleanupCall(call)
			end
		end
		states[expedition.id] = nil
	end)

	-- Examining the clue, and reaching a meeting point.
	InteractionService.RunTaskDone:Connect(function(player, part)
		local id = part:GetAttribute("SignalCall")
		if type(id) ~= "string" then
			return
		end
		local expedition = ExpeditionService.forPlayer(player)
		local s = if expedition then states[expedition.id] else nil
		local call = if s then s.calls[id] else nil
		if not expedition or not call or call.status ~= "live" then
			return
		end
		if part:GetAttribute("SignalRole") == "clue" then
			addEvidence(call, "clue", call.def.clue.text, call.def.clue.weight)
			part:RemoveTag("RunTask")
			push(expedition)
		elseif part:GetAttribute("SignalRole") == "meeting" then
			resolve(expedition, call, "go", player)
		end
	end)

	Net.onServerInvoke("SignalCommand", command)

	Players.PlayerAdded:Connect(function() end)
	log.info(string.format("started with %d authored calls", #SignalRegistry.Calls))
end

return SignalService
