--!strict
--[[
	DepartureService
	----------------
	Runs the yard service train: the 02:17 at Platform 1.

	WHY THIS EXISTS
	---------------
	The first build had no way to board anything. A crew pressed Depart and
	was teleported into a cab twenty thousand studs away, which is why players
	reported that they could not find the train. Now the train they see from
	the spawn is the one they ride:

	  arriving    the next service runs in from the south and draws up at
	              Platform 1 under train protection
	  waiting     doors open, lit, walkable; anyone may look round it
	  boarding    reserved by a crew that has departed; it waits for every
	              member to walk aboard
	  departing   doors closed, the yard pilot takes it out north into the
	              tunnel; the expedition carries the crew across to the line
	              inside the tunnel
	  gone        retired; the next service is called

	The yard train is a normal TrainService train, so it moves, renders and
	carries passengers exactly as the expedition train does. It is worked by
	the yard pilot: players cannot claim its controls or its doors.

	RECOVERY
	--------
	Nothing here can wait forever. A crew that cannot get a train within the
	reservation window is told so. A member who has not boarded when the
	boarding window closes is helped aboard by the guard, and told why. A
	service that fails to arrive is replaced.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.LastSignal

local Logger = require(Shared.Core.Logger)
local Net = require(Shared.Core.Net)
local Protect = require(Shared.Core.Protect)
local TrainRegistry = require(Shared.Registry.TrainRegistry)

local TrainService = require(script.Parent.TrainService)
local WorldService = require(script.Parent.WorldService)

local log = Logger.new("DepartureService")

local DepartureService = {}

export type Phase = "arriving" | "waiting" | "boarding" | "departing" | "gone"

export type Service = {
	key: string,
	train: TrainService.TrainState,
	phase: Phase,
	reservedBy: string?,
	trainId: string,
	liveryId: string,
	interiorId: string,
}

-- How long a departed crew has to walk aboard before the guard helps the
-- stragglers on.
DepartureService.BoardingSeconds = 60
-- How long a crew waits for a service before being told there is none.
DepartureService.ReserveSeconds = 120
-- Gap between one service leaving and the next being called.
DepartureService.TurnaroundSeconds = 18

-- Yard pilot speeds, in studs per second.
local ARRIVAL_SPEED = 22
local DEPARTURE_SPEED = 34
local DEPARTURE_ACCELERATION = 1.4

local current: Service? = nil
local serviceCount = 0
local calling = false

--------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------

local function lobby()
	return WorldService.getLobby()
end

local function setBoard(text: string)
	local built = lobby()
	if built and built.departureStatus then
		built.departureStatus.Text = text
	end
end

--- A yard train carries passengers, nothing else. The cab, supply rack,
--- radio and fuel point are expedition fixtures; in the yard they would offer
--- prompts that do nothing. Run after InteractionService has attached its
--- prompts, which happens on deferred tag signals.
local function stripExpeditionFixtures(model: Model)
	task.wait()
	task.wait()
	if not model.Parent then
		return
	end
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("ProximityPrompt") then
			descendant:Destroy()
		elseif descendant:IsA("Seat") and descendant:HasTag("DriverSeat") then
			descendant.Disabled = true
		end
	end
	for _, tag in { "SupplyRack", "RadioSet", "TrainFuelPoint", "TrainRepairPoint", "DoorLeaf" } do
		for _, descendant in model:GetDescendants() do
			if descendant:HasTag(tag) then
				descendant:RemoveTag(tag)
			end
		end
	end
end

local function aliveRoot(player: Player): BasePart?
	local character = player.Character
	local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
	local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
	if humanoid and humanoid.Health > 0 and root and root:IsA("BasePart") then
		return root
	end
	return nil
end

function DepartureService.isAboard(service: Service, player: Player): boolean
	local root = aliveRoot(player)
	return root ~= nil and TrainService.isInside(service.train, root.Position, 1)
end

--------------------------------------------------------------------------
-- Building and calling services
--------------------------------------------------------------------------

local function spawnService(trainId: string, liveryId: string, interiorId: string, atPlatform: boolean): Service?
	local built = lobby()
	if not built then
		return nil
	end
	serviceCount += 1
	local key = string.format("yard_service_%d", serviceCount)
	local ok, train = Protect.call(
		TrainService.spawn,
		key,
		trainId,
		liveryId,
		interiorId,
		built.serviceOrigin,
		built.model,
		{ doorsOpen = atPlatform, service = true }
	)
	if not ok or not train then
		log.error("yard service failed to build:", tostring(train))
		return nil
	end
	local state = train :: TrainService.TrainState
	state.built.model.Name = "YardService"
	task.spawn(stripExpeditionFixtures, state.built.model)

	local service: Service = {
		key = key,
		train = state,
		phase = if atPlatform then "waiting" else "arriving",
		reservedBy = nil,
		trainId = trainId,
		liveryId = liveryId,
		interiorId = interiorId,
	}

	if atPlatform then
		TrainService.place(state, built.platformDistance)
		state.serviceBrake = 1
	else
		TrainService.place(state, 0)
		TrainService.setStopDistance(state, built.platformDistance)
		TrainService.setPilot(state, ARRIVAL_SPEED, 2.2)
	end
	return service
end

--- Watches an arriving service until it stands at the platform, then opens
--- its doors. A service that has not arrived in a minute is replaced in
--- place rather than left stuck short of the platform.
local function superviseArrival(service: Service)
	local built = lobby()
	if not built then
		return
	end
	local startedAt = os.clock()
	while service.phase == "arriving" do
		task.wait(0.1)
		local train = service.train
		if train.distance >= built.platformDistance - 0.05 and train.speed <= 0.01 then
			TrainService.setPilot(train, nil)
			train.serviceBrake = 1
			train.doorsOpen = true
			TrainService.applyDoors(train)
			service.phase = "waiting"
			setBoard("NOW BOARDING  -  DEPART FROM THE POST ON THE PLATFORM")
			log.info(string.format("%s standing at Platform 1", service.key))
			return
		end
		if os.clock() - startedAt > 60 then
			log.warn(string.format("%s did not reach the platform; replacing it", service.key))
			TrainService.despawn(service.key)
			local replacement = spawnService(service.trainId, service.liveryId, service.interiorId, true)
			if replacement then
				current = replacement
				setBoard("NOW BOARDING  -  DEPART FROM THE POST ON THE PLATFORM")
			end
			service.phase = "gone"
			return
		end
	end
end

--- Calls the next service after the turnaround, unless one is already on
--- its way.
local function callNext(delaySeconds: number)
	if calling then
		return
	end
	calling = true
	setBoard(string.format("NEXT SERVICE DUE IN %d SECONDS", math.ceil(delaySeconds)))
	task.delay(delaySeconds, function()
		calling = false
		local service = spawnService(TrainRegistry.StarterTrainId, "livery_depot", "interior_standard", false)
		if service then
			current = service
			setBoard("APPROACHING PLATFORM 1")
			task.spawn(superviseArrival, service)
		else
			-- Building failed outright; try again rather than leaving the yard
			-- without a train.
			callNext(10)
		end
	end)
end

--------------------------------------------------------------------------
-- The crew's side
--------------------------------------------------------------------------

--- Reserves the service at Platform 1 for a crew, waiting for one if it is
--- out on a run. The crew's chosen train and livery are honoured when the
--- waiting train is empty; with passengers already aboard, it is kept.
--- Returns nil if no train becomes available in time.
function DepartureService.reserve(
	crewId: string,
	trainId: string,
	liveryId: string?,
	interiorId: string?,
	onWaiting: (string) -> ()
): Service?
	local deadline = os.clock() + DepartureService.ReserveSeconds
	local told = false
	while os.clock() < deadline do
		local service = current
		if service and service.phase == "waiting" and not service.reservedBy then
			service.reservedBy = crewId
			-- Rebuild as the crew's own train if nobody is aboard to notice.
			local wantLivery = liveryId or TrainRegistry.getOrStarter(trainId).defaultLivery
			local wantInterior = interiorId or "interior_standard"
			if service.trainId ~= trainId or service.liveryId ~= wantLivery or service.interiorId ~= wantInterior then
				local occupied = false
				for _, player in Players:GetPlayers() do
					if DepartureService.isAboard(service, player) then
						occupied = true
						break
					end
				end
				if not occupied then
					TrainService.despawn(service.key)
					local rebuilt = spawnService(trainId, wantLivery, wantInterior, true)
					if rebuilt then
						rebuilt.reservedBy = crewId
						current = rebuilt
						service = rebuilt
					end
				end
			end
			return service
		end
		if not told then
			told = true
			onWaiting(if service and service.phase == "arriving" then "The next service is pulling in to Platform 1." else "The last service has just left. The next one is on its way.")
		end
		task.wait(0.5)
	end
	return nil
end

--- Waits for every member to walk aboard. Calls onStatus about twice a
--- second with who is still missing and how long is left. When the window
--- closes, stragglers are put aboard by the guard and told so. Returns the
--- players that needed help.
function DepartureService.board(
	service: Service,
	members: () -> { Player },
	onStatus: (missing: { Player }, remaining: number) -> ()
): { Player }
	service.phase = "boarding"
	setBoard("BOARDING  -  DOORS CLOSE WHEN THE CREW IS ABOARD")
	local deadline = os.clock() + DepartureService.BoardingSeconds
	local allAboardSince: number? = nil

	while true do
		local missing: { Player } = {}
		local crew = members()
		for _, player in crew do
			if not DepartureService.isAboard(service, player) then
				table.insert(missing, player)
			end
		end
		local remaining = math.max(0, deadline - os.clock())
		onStatus(missing, remaining)

		if #crew == 0 then
			return {}
		end
		if #missing == 0 then
			-- A short beat once everyone is in, so the last aboard is not
			-- shut in by the doors the instant they cross the threshold.
			allAboardSince = allAboardSince or os.clock()
			if os.clock() - (allAboardSince :: number) >= 2.5 then
				return {}
			end
		else
			allAboardSince = nil
		end
		if remaining <= 0 then
			-- Recovery: the guard holds the door and helps them on.
			local carriage = service.train.built.carriages[1]
			local anchor = if carriage then carriage:GetPivot() else service.train.built.root.CFrame
			for index, player in missing do
				local root = aliveRoot(player)
				local character = player.Character
				if root and character then
					character:PivotTo(anchor * CFrame.new(0, 1, (index - 1) * 2.5 - 4))
				end
				Net.fireClient("Notify", player, {
					kind = "info",
					title = "The guard held the doors",
					body = "Your crew could not leave without you, so you were helped aboard.",
					duration = 6,
				})
			end
			return missing
		end
		task.wait(0.5)
	end
end

--- Closes the doors and sends the train out. Anybody aboard who is not in
--- the departing crew is put back on the platform first.
function DepartureService.depart(service: Service, crewUserIds: { number })
	local built = lobby()
	service.phase = "departing"
	setBoard("DEPARTING  -  STAND CLEAR")
	for _, player in Players:GetPlayers() do
		if not table.find(crewUserIds, player.UserId) and DepartureService.isAboard(service, player) then
			local character = player.Character
			if character and built then
				character:PivotTo(built.platformCFrame * CFrame.new(math.random(-3, 3), 0, math.random(-8, 8)))
			end
			Net.fireClient("Notify", player, {
				kind = "info",
				title = "This service is reserved",
				body = "Another crew is departing. The next train will be at Platform 1 shortly.",
				duration = 7,
			})
		end
	end

	local train = service.train
	train.doorsOpen = false
	TrainService.applyDoors(train)
	task.wait(2.5)
	TrainService.setStopDistance(train, nil)
	TrainService.setPilot(train, DEPARTURE_SPEED, DEPARTURE_ACCELERATION)
	log.info(string.format("%s departing for crew %s", service.key, tostring(service.reservedBy)))
end

--- Yields until the service has travelled the given distance along the
--- departure road, or the timeout passes. Returns whether it got there.
function DepartureService.waitForDistance(service: Service, distance: number, timeout: number): boolean
	local deadline = os.clock() + timeout
	while os.clock() < deadline do
		if service.train.distance >= distance then
			return true
		end
		task.wait(0.05)
	end
	return false
end

--- Removes a service that has gone into the tunnel and calls the next.
function DepartureService.retire(service: Service)
	if service.phase == "gone" then
		return
	end
	service.phase = "gone"
	TrainService.despawn(service.key)
	if current == service then
		current = nil
	end
	callNext(DepartureService.TurnaroundSeconds)
end

--- Gives a reserved service back, for a crew that cancelled or failed to
--- start. It goes back to waiting at the platform.
function DepartureService.release(service: Service)
	if service.phase == "boarding" or service.phase == "waiting" then
		service.reservedBy = nil
		service.phase = "waiting"
		setBoard("NOW BOARDING  -  DEPART FROM THE POST ON THE PLATFORM")
	end
end

function DepartureService.lobbyGeometry(): (number, number)
	local built = lobby()
	if built then
		return built.platformDistance, built.tunnelDistance
	end
	return 0, 0
end

--------------------------------------------------------------------------

function DepartureService.start()
	-- The first service is already standing at the platform when the server
	-- opens, so the very first player to arrive sees a train waiting.
	local service = spawnService(TrainRegistry.StarterTrainId, "livery_depot", "interior_standard", true)
	if service then
		current = service
		setBoard("NOW BOARDING  -  DEPART FROM THE POST ON THE PLATFORM")
		log.info("yard service standing at Platform 1")
	else
		callNext(5)
	end
	log.info("started")
end

return DepartureService
