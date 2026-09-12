--!strict
--[[
	CrewService
	-----------
	Crews: forming them, joining them, readying up and departing.

	The flow the brief asks for is Play, create or join, choose train and
	loadout, ready, depart. This service owns all of it except the loadout,
	which lives on the profile.

	FAILURE CASES HANDLED HERE, BECAUSE THEY ARE THE ONES THAT STRAND PLAYERS
	------------------------------------------------------------------------
	  - The leader leaves. The crew is handed to the longest-present member
	    after a short grace, not disbanded.
	  - A member leaves mid-countdown. The countdown continues if the crew is
	    still valid, and cancels with a reason if it is not.
	  - A member unreadies during the countdown. The countdown cancels and says
	    who cancelled it, so nobody is left guessing.
	  - A player joins a crew that departs while they are still loading. They
	    are placed with the crew rather than left in the lobby.
	  - Everybody leaves. The crew is disposed of and its expedition torn down.

	Departure itself is delegated: this service decides when a crew departs and
	who is in it, and ExpeditionService does the work.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.LastSignal

local GameConfig = require(Shared.Config.GameConfig)
local Guard = require(Shared.Core.Guard)
local Logger = require(Shared.Core.Logger)
local Net = require(Shared.Core.Net)
local Signal = require(Shared.Core.Signal)
local TrainRegistry = require(Shared.Registry.TrainRegistry)
local WeaponRegistry = require(Shared.Registry.WeaponRegistry)
local DataService = require(script.Parent.DataService)

local log = Logger.new("CrewService")

local CrewService = {}

export type MemberState = {
	userId: number,
	name: string,
	displayName: string,
	ready: boolean,
	joinedAt: number,
	role: string,
	level: number,
	patch: string,
	-- True while the player is between servers or still loading.
	connected: boolean,
}

export type Crew = {
	id: string,
	leaderUserId: number,
	private: boolean,
	name: string,
	trainId: string,
	difficulty: string,
	members: { [number]: MemberState },
	memberOrder: { number },
	createdAt: number,
	-- nil unless a countdown is running.
	countdownEndsAt: number?,
	countdownThread: thread?,
	-- "forming" | "departing" | "active" | "closed". Kept as a plain string so
	-- the solver does not narrow it across the async countdown thread.
	state: string,
	-- Set once the expedition exists.
	expeditionId: string?,
}

local crews: { [string]: Crew } = {}
local playerCrew: { [number]: string } = {}
local nextCrewNumber = 0

CrewService.CrewDeparted = Signal.new() :: Signal.Signal<Crew, { Player }>
CrewService.CrewClosed = Signal.new() :: Signal.Signal<Crew>
CrewService.CrewChanged = Signal.new() :: Signal.Signal<Crew>

--------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------

--- Reads the state field through a function so the type solver does not carry
--- a narrowed literal from an earlier guard into an async closure, where the
--- value has since been reassigned.
local function stateOf(crew: Crew): string
	return crew.state
end

local function memberCount(crew: Crew): number
	return #crew.memberOrder
end

local function playersOf(crew: Crew): { Player }
	local out: { Player } = {}
	for _, userId in crew.memberOrder do
		local player = Players:GetPlayerByUserId(userId)
		if player then
			table.insert(out, player)
		end
	end
	return out
end

local function describe(crew: Crew): { [string]: any }
	local members = {}
	for _, userId in crew.memberOrder do
		local member = crew.members[userId]
		if member then
			table.insert(members, {
				userId = member.userId,
				name = member.name,
				displayName = member.displayName,
				ready = member.ready,
				role = member.role,
				level = member.level,
				patch = member.patch,
				connected = member.connected,
				isLeader = member.userId == crew.leaderUserId,
			})
		end
	end
	local trainDef = TrainRegistry.getOrStarter(crew.trainId)
	return {
		id = crew.id,
		name = crew.name,
		leaderUserId = crew.leaderUserId,
		private = crew.private,
		trainId = crew.trainId,
		trainName = trainDef.name,
		difficulty = crew.difficulty,
		members = members,
		size = memberCount(crew),
		maxSize = GameConfig.MaxCrewSize,
		state = crew.state,
		countdownEndsAt = crew.countdownEndsAt,
	}
end

local function push(crew: Crew)
	local payload = describe(crew)
	for _, player in playersOf(crew) do
		Net.fireClient("CrewState", player, payload)
	end
	CrewService.CrewChanged:Fire(crew)
end

--- The list of open crews shown on the crew board.
local function browseList(): { { [string]: any } }
	local out = {}
	for _, crew in crews do
		if not crew.private and crew.state == "forming" and memberCount(crew) < GameConfig.MaxCrewSize then
			local trainDef = TrainRegistry.getOrStarter(crew.trainId)
			table.insert(out, {
				id = crew.id,
				name = crew.name,
				size = memberCount(crew),
				maxSize = GameConfig.MaxCrewSize,
				trainName = trainDef.name,
				difficulty = crew.difficulty,
				leaderName = (function()
					local leader = crew.members[crew.leaderUserId]
					return if leader then leader.displayName else "?"
				end)(),
			})
		end
	end
	table.sort(out, function(a, b)
		return a.size > b.size
	end)
	return out
end

--------------------------------------------------------------------------
-- Countdown
--------------------------------------------------------------------------

local function cancelCountdown(crew: Crew, reason: string)
	if crew.countdownThread then
		task.cancel(crew.countdownThread)
		crew.countdownThread = nil
	end
	if crew.countdownEndsAt then
		crew.countdownEndsAt = nil
		crew.state = "forming"
		for _, player in playersOf(crew) do
			Net.fireClient("Notify", player, {
				kind = "info",
				title = "Departure cancelled",
				body = reason,
				duration = 5,
			})
		end
		push(crew)
	end
end

local function everyoneReady(crew: Crew): boolean
	local connected = 0
	local ready = 0
	for _, userId in crew.memberOrder do
		local member = crew.members[userId]
		if member and member.connected then
			connected += 1
			if member.ready then
				ready += 1
			end
		end
	end
	if connected == 0 then
		return false
	end
	return ready >= math.ceil(connected * GameConfig.ReadyRequiredFraction)
end

--------------------------------------------------------------------------
-- Crew operations
--------------------------------------------------------------------------

local function memberFor(player: Player): MemberState
	local profile = DataService.getProfile(player)
	return {
		userId = player.UserId,
		name = player.Name,
		displayName = player.DisplayName,
		ready = false,
		joinedAt = os.clock(),
		role = if profile then profile.loadout.role else "crew",
		level = if profile then profile.level else 1,
		patch = if profile then profile.loadout.patch else "",
		connected = true,
	}
end

function CrewService.create(player: Player, private: boolean): (Crew?, string?)
	if playerCrew[player.UserId] then
		return nil, "ALREADY_IN_CREW"
	end
	local profile = DataService.getProfile(player)
	if not profile then
		return nil, "NOT_LOADED"
	end

	nextCrewNumber += 1
	local id = string.format("crew_%d_%d", nextCrewNumber, math.floor(os.clock() * 1000) % 100000)
	local crew: Crew = {
		id = id,
		leaderUserId = player.UserId,
		private = private,
		name = string.format("%s's crew", player.DisplayName),
		trainId = profile.loadout.train,
		difficulty = GameConfig.DefaultDifficulty,
		members = {},
		memberOrder = {},
		createdAt = os.clock(),
		state = "forming",
	}
	crew.members[player.UserId] = memberFor(player)
	table.insert(crew.memberOrder, player.UserId)
	crews[id] = crew
	playerCrew[player.UserId] = id

	log.info(string.format("%s created crew %s (%s)", player.Name, id, if private then "private" else "public"))
	push(crew)
	return crew, nil
end

function CrewService.join(player: Player, crewId: string): (Crew?, string?)
	if playerCrew[player.UserId] then
		return nil, "ALREADY_IN_CREW"
	end
	local crew = crews[crewId]
	if not crew then
		return nil, "NO_SUCH_CREW"
	end
	if crew.state ~= "forming" then
		return nil, "ALREADY_DEPARTED"
	end
	if memberCount(crew) >= GameConfig.MaxCrewSize then
		return nil, "CREW_FULL"
	end

	crew.members[player.UserId] = memberFor(player)
	table.insert(crew.memberOrder, player.UserId)
	playerCrew[player.UserId] = crewId

	-- A new member invalidates a running countdown: the arriving player has
	-- not readied, and departing without them would be exactly the stranding
	-- case this service exists to prevent.
	cancelCountdown(crew, string.format("%s joined the crew.", player.DisplayName))
	push(crew)
	return crew, nil
end

function CrewService.leave(player: Player): boolean
	local crewId = playerCrew[player.UserId]
	if not crewId then
		return false
	end
	local crew = crews[crewId]
	playerCrew[player.UserId] = nil
	if not crew then
		return false
	end

	crew.members[player.UserId] = nil
	local index = table.find(crew.memberOrder, player.UserId)
	if index then
		table.remove(crew.memberOrder, index)
	end

	if memberCount(crew) == 0 then
		CrewService.close(crew, "empty")
		return true
	end

	-- Leader transfer: the longest-present remaining member takes over.
	if crew.leaderUserId == player.UserId then
		local bestUserId: number? = nil
		local bestJoinedAt = math.huge
		for _, userId in crew.memberOrder do
			local member = crew.members[userId]
			if member and member.joinedAt < bestJoinedAt then
				bestJoinedAt = member.joinedAt
				bestUserId = userId
			end
		end
		if bestUserId then
			crew.leaderUserId = bestUserId
			local newLeader = crew.members[bestUserId]
			for _, remaining in playersOf(crew) do
				Net.fireClient("Notify", remaining, {
					kind = "info",
					title = "Crew leader changed",
					body = string.format("%s is now the crew leader.", if newLeader then newLeader.displayName else "A crew member"),
					duration = 5,
				})
			end
		end
	end

	if crew.state == "departing" and not everyoneReady(crew) then
		cancelCountdown(crew, "A crew member left.")
	end

	push(crew)
	return true
end

function CrewService.close(crew: Crew, reason: string)
	if crew.state == "closed" then
		return
	end
	if crew.countdownThread then
		task.cancel(crew.countdownThread)
		crew.countdownThread = nil
	end
	crew.state = "closed"
	for _, userId in crew.memberOrder do
		playerCrew[userId] = nil
	end
	crews[crew.id] = nil
	log.info(string.format("crew %s closed (%s)", crew.id, reason))
	CrewService.CrewClosed:Fire(crew)
end

function CrewService.setReady(player: Player, ready: boolean): boolean
	local crew = CrewService.crewOf(player)
	if not crew then
		return false
	end
	local member = crew.members[player.UserId]
	if not member then
		return false
	end
	member.ready = ready
	if not ready and crew.state == "departing" then
		cancelCountdown(crew, string.format("%s is not ready.", player.DisplayName))
	end
	push(crew)
	return true
end

function CrewService.setTrain(player: Player, trainId: string): (boolean, string?)
	local crew = CrewService.crewOf(player)
	if not crew then
		return false, "NO_CREW"
	end
	if crew.leaderUserId ~= player.UserId then
		return false, "NOT_LEADER"
	end
	local def = TrainRegistry.get(trainId)
	if not def then
		return false, "UNKNOWN_TRAIN"
	end
	-- The leader must own the train they pick for the crew.
	local profile = DataService.getProfile(player)
	if not profile or not profile.trains[trainId] then
		return false, "NOT_OWNED"
	end
	crew.trainId = trainId
	cancelCountdown(crew, "The train was changed.")
	push(crew)
	return true, nil
end

function CrewService.setDifficulty(player: Player, difficulty: string): (boolean, string?)
	local crew = CrewService.crewOf(player)
	if not crew then
		return false, "NO_CREW"
	end
	if crew.leaderUserId ~= player.UserId then
		return false, "NOT_LEADER"
	end
	local entry = GameConfig.getDifficulty(difficulty)
	if entry.id ~= difficulty then
		return false, "UNKNOWN_DIFFICULTY"
	end
	local profile = DataService.getProfile(player)
	if profile and profile.level < entry.unlockLevel then
		return false, "LEVEL_LOCKED"
	end
	crew.difficulty = difficulty
	cancelCountdown(crew, "The difficulty was changed.")
	push(crew)
	return true, nil
end

function CrewService.transferLeadership(player: Player, targetUserId: number): (boolean, string?)
	local crew = CrewService.crewOf(player)
	if not crew then
		return false, "NO_CREW"
	end
	if crew.leaderUserId ~= player.UserId then
		return false, "NOT_LEADER"
	end
	if not crew.members[targetUserId] then
		return false, "NOT_IN_CREW"
	end
	crew.leaderUserId = targetUserId
	push(crew)
	return true, nil
end

function CrewService.kick(player: Player, targetUserId: number): (boolean, string?)
	local crew = CrewService.crewOf(player)
	if not crew then
		return false, "NO_CREW"
	end
	if crew.leaderUserId ~= player.UserId then
		return false, "NOT_LEADER"
	end
	if targetUserId == player.UserId then
		return false, "CANNOT_KICK_SELF"
	end
	local target = Players:GetPlayerByUserId(targetUserId)
	if target then
		Net.fireClient("Notify", target, {
			kind = "warning",
			title = "Removed from crew",
			body = "The crew leader removed you.",
			duration = 6,
		})
		CrewService.leave(target)
	else
		crew.members[targetUserId] = nil
		local index = table.find(crew.memberOrder, targetUserId)
		if index then
			table.remove(crew.memberOrder, index)
		end
		playerCrew[targetUserId] = nil
		push(crew)
	end
	return true, nil
end

--------------------------------------------------------------------------
-- Departure
--------------------------------------------------------------------------

function CrewService.beginDeparture(player: Player): (boolean, string?)
	local crew = CrewService.crewOf(player)
	if not crew then
		return false, "NO_CREW"
	end
	if crew.leaderUserId ~= player.UserId then
		return false, "NOT_LEADER"
	end
	if crew.state ~= "forming" then
		return false, "BUSY"
	end
	if not everyoneReady(crew) then
		return false, "NOT_ALL_READY"
	end
	if memberCount(crew) < GameConfig.MinCrewSize then
		return false, "CREW_TOO_SMALL"
	end

	crew.state = "departing"
	crew.countdownEndsAt = os.time() + GameConfig.DepartureCountdownSeconds
	push(crew)

	crew.countdownThread = task.spawn(function()
		local remaining = GameConfig.DepartureCountdownSeconds
		while remaining > 0 do
			task.wait(1)
			remaining -= 1
			-- Re-validate every second rather than only at the end. A crew that
			-- becomes invalid mid-countdown should stop immediately.
			if stateOf(crew) ~= "departing" then
				return
			end
			if memberCount(crew) < GameConfig.MinCrewSize then
				cancelCountdown(crew, "The crew is too small to depart.")
				return
			end
			if not everyoneReady(crew) then
				cancelCountdown(crew, "A crew member is no longer ready.")
				return
			end
		end

		crew.countdownThread = nil
		crew.countdownEndsAt = nil
		crew.state = "active"

		local departing = playersOf(crew)
		if #departing == 0 then
			CrewService.close(crew, "nobody left to depart")
			return
		end
		log.info(string.format("crew %s departing with %d", crew.id, #departing))
		push(crew)
		CrewService.CrewDeparted:Fire(crew, departing)
	end)

	return true, nil
end

function CrewService.cancelDeparture(player: Player): (boolean, string?)
	local crew = CrewService.crewOf(player)
	if not crew then
		return false, "NO_CREW"
	end
	if crew.leaderUserId ~= player.UserId then
		return false, "NOT_LEADER"
	end
	cancelCountdown(crew, string.format("%s cancelled the departure.", player.DisplayName))
	return true, nil
end

--------------------------------------------------------------------------
-- Accessors
--------------------------------------------------------------------------

function CrewService.crewOf(player: Player): Crew?
	local crewId = playerCrew[player.UserId]
	return if crewId then crews[crewId] else nil
end

function CrewService.crewById(crewId: string): Crew?
	return crews[crewId]
end

function CrewService.playersOf(crew: Crew): { Player }
	return playersOf(crew)
end

function CrewService.push(crew: Crew)
	push(crew)
end

--- Solo convenience: creates a private crew of one and departs immediately.
--- Every part of the game supports one player, so this is a shortcut rather
--- than a separate mode.
function CrewService.soloDepart(player: Player): (boolean, string?)
	if CrewService.crewOf(player) then
		return false, "ALREADY_IN_CREW"
	end
	local crew, err = CrewService.create(player, true)
	if not crew then
		return false, err
	end
	crew.name = string.format("%s, solo", player.DisplayName)
	CrewService.setReady(player, true)
	return CrewService.beginDeparture(player)
end

--------------------------------------------------------------------------

function CrewService.start()
	Net.onServerInvoke("CrewCommand", function(player, rawCommand, rawA)
		local command = Guard.enum(rawCommand, {
			"create_public",
			"create_private",
			"join",
			"leave",
			"ready",
			"unready",
			"set_train",
			"set_difficulty",
			"set_role",
			"transfer_leader",
			"kick",
			"depart",
			"cancel_depart",
			"browse",
			"solo",
			"state",
		})
		if not command then
			return { ok = false, error = "BAD_COMMAND" }
		end

		if command == "browse" then
			return { ok = true, crews = browseList() }
		end

		if command == "state" then
			local crew = CrewService.crewOf(player)
			return { ok = true, crew = if crew then describe(crew) else nil, crews = browseList() }
		end

		if command == "create_public" or command == "create_private" then
			local crew, err = CrewService.create(player, command == "create_private")
			return { ok = crew ~= nil, error = err, crew = if crew then describe(crew) else nil }
		end

		if command == "join" then
			local crewId = Guard.string(rawA, 48)
			if not crewId then
				return { ok = false, error = "BAD_CREW" }
			end
			local crew, err = CrewService.join(player, crewId)
			return { ok = crew ~= nil, error = err, crew = if crew then describe(crew) else nil }
		end

		if command == "leave" then
			return { ok = CrewService.leave(player) }
		end

		if command == "ready" or command == "unready" then
			return { ok = CrewService.setReady(player, command == "ready") }
		end

		if command == "set_train" then
			local trainId = Guard.id(rawA)
			if not trainId then
				return { ok = false, error = "BAD_TRAIN" }
			end
			local ok, err = CrewService.setTrain(player, trainId)
			return { ok = ok, error = err }
		end

		if command == "set_difficulty" then
			local difficulty = Guard.id(rawA)
			if not difficulty then
				return { ok = false, error = "BAD_DIFFICULTY" }
			end
			local ok, err = CrewService.setDifficulty(player, difficulty)
			return { ok = ok, error = err }
		end

		if command == "set_role" then
			local role = Guard.enum(rawA, { "crew", "driver", "mechanic", "medic", "scout", "guard" })
			if not role then
				return { ok = false, error = "BAD_ROLE" }
			end
			DataService.update(player, function(p)
				p.loadout.role = role
			end)
			local crew = CrewService.crewOf(player)
			if crew then
				local member = crew.members[player.UserId]
				if member then
					member.role = role
				end
				push(crew)
			end
			return { ok = true }
		end

		if command == "transfer_leader" then
			local userId = Guard.integer(rawA, 1)
			if not userId then
				return { ok = false, error = "BAD_TARGET" }
			end
			local ok, err = CrewService.transferLeadership(player, userId)
			return { ok = ok, error = err }
		end

		if command == "kick" then
			local userId = Guard.integer(rawA, 1)
			if not userId then
				return { ok = false, error = "BAD_TARGET" }
			end
			local ok, err = CrewService.kick(player, userId)
			return { ok = ok, error = err }
		end

		if command == "depart" then
			local ok, err = CrewService.beginDeparture(player)
			return { ok = ok, error = err }
		end

		if command == "cancel_depart" then
			local ok, err = CrewService.cancelDeparture(player)
			return { ok = ok, error = err }
		end

		-- solo
		local ok, err = CrewService.soloDepart(player)
		return { ok = ok, error = err }
	end)

	Players.PlayerRemoving:Connect(function(player)
		local crew = CrewService.crewOf(player)
		if not crew then
			return
		end
		if stateOf(crew) == "active" then
			-- Mid-expedition disconnect: keep the slot open for a reconnect
			-- rather than removing them, so they can come back to their crew.
			local member = crew.members[player.UserId]
			if member then
				member.connected = false
			end
			push(crew)
			task.delay(GameConfig.ReconnectGraceSeconds, function()
				local stillCrew = crews[crew.id]
				if not stillCrew then
					return
				end
				local stillMember = stillCrew.members[player.UserId]
				if stillMember and not stillMember.connected then
					stillCrew.members[player.UserId] = nil
					local index = table.find(stillCrew.memberOrder, player.UserId)
					if index then
						table.remove(stillCrew.memberOrder, index)
					end
					playerCrew[player.UserId] = nil
					if memberCount(stillCrew) == 0 then
						CrewService.close(stillCrew, "all members disconnected")
					else
						push(stillCrew)
					end
				end
			end)
		else
			CrewService.leave(player)
		end
	end)

	-- Reconnection: a returning player rejoins the crew slot held for them.
	Players.PlayerAdded:Connect(function(player)
		for _, crew in crews do
			local member = crew.members[player.UserId]
			if member and not member.connected then
				member.connected = true
				member.name = player.Name
				member.displayName = player.DisplayName
				playerCrew[player.UserId] = crew.id
				log.info(string.format("%s reconnected to crew %s", player.Name, crew.id))
				push(crew)
				break
			end
		end
	end)

	log.info("started")
end

return CrewService
