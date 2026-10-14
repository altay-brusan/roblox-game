--!strict
--[[
	SignatureMoments
	----------------
	Three scripted beats, one per act of the journey. The horror director
	handles ambient dread; these are the moments a player describes afterwards.
	Each has a setup, a payoff and a consequence that touches the story or how
	you play, and each fires once per run on a fixed trigger, so it is the same
	beat for every crew and can be tested.

	1  THE SECOND DISPATCHER  (on the line between Marrow Halt and Tolbridge)
	   Setup: Control gives a routine instruction. Payoff: five seconds later
	   the same words arrive again, from "Unknown", under failing lights.
	   Control then says plainly that it was not him. Consequence: the false-
	   transmission tells (callsign, attribution) are taught here, before the
	   first station where a false instruction can cost the crew.

	2  THE PASSENGER  (on the line after Ninety-Three)
	   Setup: a figure is sitting in the first carriage, facing forward. Payoff:
	   it is gone when anybody goes to look, the lights fail, and on the seat
	   is a ticket for the 02:17, punched, dated eleven days ago. Consequence:
	   a discovery for the record, and the first hint that this train has made
	   this journey before.

	3  THE RECORDING  (arriving at Ward Hill)
	   Setup: the dispatcher's very first line, from the yard. Payoff: at Ward
	   Hill the same line plays again, from a set in the relay room, and stops,
	   and starts again. The voice that guided the crew was a recording made
	   before the eleven days began. Consequence: it recontextualises every
	   instruction since the yard, and sends the crew to the transmitter.

	Every moment is cancelled by the run ending, and the Passenger is cleared
	and re-armed by a retry so the beat is never left half-played.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.LastSignal

local Logger = require(Shared.Core.Logger)
local Net = require(Shared.Core.Net)
local Protect = require(Shared.Core.Protect)
local StationRegistry = require(Shared.Registry.StationRegistry)

local ExpeditionService = require(script.Parent.ExpeditionService)
local TrainService = require(script.Parent.TrainService)

local log = Logger.new("SignatureMoments")

local SignatureMoments = {}

-- Where on the line each moment fires, as train distance.
local SECOND_DISPATCHER_AT = 2700 -- between Marrow Halt (1750) and Tolbridge (4200)
local PASSENGER_AT = 7700 -- just after leaving Ninety-Three (7100)

-- Per-expedition props that must be cleaned up.
local passengers: { [string]: Model } = {}

local function players(expedition: ExpeditionService.Expedition): { Player }
	return ExpeditionService.playersOf(expedition)
end

local function say(expedition: ExpeditionService.Expedition, source: string, attribution: string, text: string, duration: number, cue: string?)
	Net.fireClients("RadioMessage", players(expedition), {
		id = "signature",
		source = source,
		text = text,
		duration = duration,
		cue = cue,
		attribution = attribution,
		isFalse = source == "other",
	})
end

local function flicker(expedition: ExpeditionService.Expedition, seconds: number)
	local train = expedition.train
	Net.fireClients("HorrorCue", players(expedition), { cue = "lights_flicker", position = train.built.root.Position, seconds = seconds })
	local wasOn = train.interiorLights
	train.interiorLights = false
	TrainService.applyLights(train)
	task.delay(seconds, function()
		if expedition.state ~= "closed" then
			train.interiorLights = wasOn
			TrainService.applyLights(train)
		end
	end)
end

local function alive(expedition: ExpeditionService.Expedition): boolean
	return expedition.state ~= "closed" and expedition.state ~= "ending" and expedition.state ~= "failed"
end

--------------------------------------------------------------------------
-- 1. The second dispatcher
--------------------------------------------------------------------------

local function secondDispatcher(expedition: ExpeditionService.Expedition)
	expedition.firedBeats.sig_second_dispatcher = true
	log.info(string.format("%s: the second dispatcher", expedition.id))
	local words = "Signal at Tolbridge is showing clear. Proceed at line speed, and keep the doors shut."
	say(expedition, "dispatch", "Dispatch", "Control to the zero two seventeen. " .. words, 6)
	task.wait(11)
	if not alive(expedition) then
		return
	end
	flicker(expedition, 4.5)
	Net.fireClients("HorrorCue", players(expedition), { cue = "radio_distort", position = expedition.train.built.root.Position })
	say(expedition, "other", "Unknown", words, 6)
	task.wait(9)
	if not alive(expedition) then
		return
	end
	say(
		expedition,
		"dispatch",
		"Dispatch",
		"Control. That second one was not me. Listen for the callsign. If it does not say Control, it is not Control.",
		7
	)
end

--------------------------------------------------------------------------
-- 2. The passenger
--------------------------------------------------------------------------

local function buildPassenger(seat: BasePart, root: BasePart): Model
	local model = Instance.new("Model")
	model.Name = "Passenger"
	local dark = Color3.fromRGB(14, 14, 16)
	local cf = seat.CFrame * CFrame.new(0, 0.4, 0)
	local function piece(name: string, size: Vector3, offset: CFrame)
		local p = Instance.new("Part")
		p.Name = name
		p.Size = size
		p.CFrame = cf * offset
		p.Color = dark
		p.Material = Enum.Material.Fabric
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.CastShadow = true
		p.Anchored = false
		p.Parent = model
		local weld = Instance.new("WeldConstraint")
		weld.Part0 = root
		weld.Part1 = p
		weld.Parent = p
	end
	-- Seated, very still, a little too tall for the seat.
	piece("Coat", Vector3.new(1.9, 3.6, 1.1), CFrame.new(0, 2.0, 0.4))
	piece("Head", Vector3.new(1.1, 1.4, 1.0), CFrame.new(0, 4.6, 0.3) * CFrame.Angles(math.rad(14), 0, 0))
	piece("Hat", Vector3.new(1.6, 0.25, 1.6), CFrame.new(0, 5.35, 0.25))
	for _, side in { -1, 1 } do
		piece("Leg", Vector3.new(0.6, 0.6, 2.4), CFrame.new(side * 0.45, 0.4, -0.8))
		piece("Hand", Vector3.new(0.35, 0.35, 0.9), CFrame.new(side * 0.8, 0.9, -0.6))
	end
	model.Parent = root.Parent
	return model
end

local function leaveTicket(expedition: ExpeditionService.Expedition, seat: BasePart)
	local ticket = Instance.new("Part")
	ticket.Name = "Ticket"
	ticket.Size = Vector3.new(0.9, 0.05, 0.5)
	ticket.Color = Color3.fromRGB(196, 182, 140)
	ticket.Material = Enum.Material.SmoothPlastic
	ticket.CFrame = seat.CFrame * CFrame.new(0.3, 0.27, 0) * CFrame.Angles(0, math.rad(17), 0)
	ticket.Anchored = false
	ticket.CanCollide = false
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = expedition.train.built.root
	weld.Part1 = ticket
	weld.Parent = ticket
	ticket:SetAttribute("DiscoveryId", "eleven_day_ticket")
	ticket:SetAttribute("DiscoveryTitle", "A ticket for the 02:17")
	ticket:SetAttribute("DiscoveryBody", "Tolbridge Yard to Ward Hill, single. Punched. Dated eleven days ago, the night the line went quiet.")
	-- Station discoveries get their prompt from the station builder; this one
	-- is placed at run time, so it brings its own.
	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Look closer"
	prompt.ObjectText = "Ticket"
	prompt.MaxActivationDistance = 8
	prompt.RequiresLineOfSight = false
	prompt.Style = Enum.ProximityPromptStyle.Custom
	prompt.Parent = ticket
	ticket:AddTag("Discovery")
	ticket.Parent = expedition.train.built.model
end

local function passenger(expedition: ExpeditionService.Expedition)
	expedition.firedBeats.sig_passenger = true
	local train = expedition.train
	local carriage = train.built.carriages[1]
	if not carriage then
		return
	end
	local seat: BasePart? = nil
	for _, d in carriage:GetDescendants() do
		if d:IsA("Seat") and d:HasTag("TrainSeat") and not d.Occupant then
			seat = d
			break
		end
	end
	if not seat then
		return
	end
	local chosen = seat :: BasePart
	local figure = buildPassenger(chosen, train.built.root)
	passengers[expedition.id] = figure
	log.info(string.format("%s: the passenger", expedition.id))

	-- It stays until somebody comes close, or for a minute.
	local deadline = os.clock() + 60
	while alive(expedition) and figure.Parent and os.clock() < deadline do
		local near = false
		for _, player in players(expedition) do
			local character = player.Character
			local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
			if root and root:IsA("BasePart") and (root.Position - chosen.Position).Magnitude < 13 then
				near = true
				break
			end
		end
		if near then
			break
		end
		task.wait(0.25)
	end
	if not figure.Parent then
		return
	end
	flicker(expedition, 2.5)
	task.wait(0.4)
	figure:Destroy()
	passengers[expedition.id] = nil
	if alive(expedition) then
		leaveTicket(expedition, chosen)
	end
end

--------------------------------------------------------------------------
-- 3. The recording
--------------------------------------------------------------------------

local function recording(expedition: ExpeditionService.Expedition)
	expedition.firedBeats.sig_recording = true
	log.info(string.format("%s: the recording", expedition.id))
	task.wait(8)
	if not alive(expedition) then
		return
	end
	-- The set is wherever the transmitter is: the relay room.
	local source = expedition.train.built.root.Position
	local station = expedition.lane.stations[expedition.stationIndex]
	if station then
		local transmitter = station.fixtures.transmitter
		if transmitter then
			source = transmitter.Position
		end
	end
	Net.fireClients("HorrorCue", players(expedition), { cue = "radio_distort", position = source })
	local first = "Control to the zero two seventeen. I have you leaving the yard. You are the last one out."
	say(expedition, "recording", "Recording, relay room", first, 6)
	task.wait(7)
	if not alive(expedition) then
		return
	end
	say(expedition, "recording", "Recording, relay room", "[The tape clicks, rewinds, and starts again.]", 3)
	task.wait(4)
	if not alive(expedition) then
		return
	end
	say(expedition, "recording", "Recording, relay room", first, 6)
	task.wait(8)
	if not alive(expedition) then
		return
	end
	say(
		expedition,
		"crew",
		"Crew",
		"That is the voice from the yard. It has been on a loop up here the whole time. Get to the transmitter.",
		6
	)
end

--------------------------------------------------------------------------

local function run(expedition: ExpeditionService.Expedition, beat: (ExpeditionService.Expedition) -> ())
	task.spawn(function()
		local ok, err = Protect.call(beat, expedition)
		if not ok then
			log.error(string.format("signature moment failed for %s: %s", expedition.id, tostring(err)))
		end
	end)
end

function SignatureMoments.start()
	-- The two moments on the line fire on distance travelled.
	task.spawn(function()
		while true do
			task.wait(0.5)
			for _, expedition in ExpeditionService.all() do
				if expedition.state ~= "travelling" then
					continue
				end
				local distance = expedition.train.distance
				local fired = expedition.firedBeats
				if not fired.sig_second_dispatcher and expedition.stationIndex == 1 and distance >= SECOND_DISPATCHER_AT then
					run(expedition, secondDispatcher)
				elseif not fired.sig_passenger and expedition.stationIndex == 3 and distance >= PASSENGER_AT then
					run(expedition, passenger)
				end
			end
		end
	end)

	-- The recording fires on reaching the last station.
	ExpeditionService.StationReached:Connect(function(expedition, index)
		if index == StationRegistry.count() and not expedition.firedBeats.sig_recording then
			run(expedition, recording)
		end
	end)

	-- A retry clears a half-played Passenger and lets it play again.
	ExpeditionService.Retried:Connect(function(expedition)
		local figure = passengers[expedition.id]
		if figure then
			figure:Destroy()
			passengers[expedition.id] = nil
			expedition.firedBeats.sig_passenger = false
		end
	end)

	ExpeditionService.Ended:Connect(function(expedition)
		local figure = passengers[expedition.id]
		if figure then
			figure:Destroy()
		end
		passengers[expedition.id] = nil
	end)

	log.info("started with 3 moments")
end

return SignatureMoments
