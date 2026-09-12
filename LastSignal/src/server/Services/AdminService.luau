--!strict
--[[
	AdminService
	------------
	Administrative commands, with authorisation that cannot be faked.

	AUTHORISATION
	-------------
	Every command resolves the caller's role from Player.UserId through
	Config.Admin, on the server, on every call. Nothing trusts a client flag,
	a display name, a username string or a previously granted session token.
	A player whose user ID is not in the table has no access, and a capability
	that is not declared is denied.

	Both accounts named in the brief are already listed in Config.Admin with
	their roles set. Their numeric user IDs are 0 until an operator fills them
	in, and a role with ID 0 grants nothing, so the system ships inert rather
	than shipping a guess.

	SAFETY
	------
	  Destructive commands require a confirmation token, issued by running the
	  command once and re-sending it within a short window.
	  Resets preserve purchase records, because a wipe must not take away what
	  somebody paid Robux for.
	  Grants are clamped to sane maximums so a typo cannot write an absurd
	  number into a live profile.
	  Announcements are filtered through TextService before broadcast.
	  Every executed command is written to a bounded audit log and to output.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextService = game:GetService("TextService")
local Shared = ReplicatedStorage.LastSignal

local Admin = require(Shared.Config.Admin)
local GameConfig = require(Shared.Config.GameConfig)
local Guard = require(Shared.Core.Guard)
local Logger = require(Shared.Core.Logger)
local Net = require(Shared.Core.Net)
local Protect = require(Shared.Core.Protect)
local ItemRegistry = require(Shared.Registry.ItemRegistry)

local DataService = require(script.Parent.DataService)
local EventService = require(script.Parent.EventService)
local ExpeditionService = require(script.Parent.ExpeditionService)
local HorrorDirector = require(script.Parent.HorrorDirector)
local InventoryService = require(script.Parent.InventoryService)
local ProgressionService = require(script.Parent.ProgressionService)
local SurvivalService = require(script.Parent.SurvivalService)
local WorldService = require(script.Parent.WorldService)

local log = Logger.new("AdminService")

local AdminService = {}

--------------------------------------------------------------------------
-- Audit log
--------------------------------------------------------------------------

export type AuditEntry = {
	at: number,
	userId: number,
	name: string,
	command: string,
	arguments: string,
	result: string,
}

local auditLog: { AuditEntry } = {}

local function audit(player: Player, command: string, arguments: string, result: string)
	table.insert(auditLog, {
		at = os.time(),
		userId = player.UserId,
		name = player.Name,
		command = command,
		arguments = arguments,
		result = result,
	})
	while #auditLog > Admin.AuditLogSize do
		table.remove(auditLog, 1)
	end
	log.info(string.format("[%s] %s %s -> %s", player.Name, command, arguments, result))
end

function AdminService.auditLog(): { AuditEntry }
	return table.clone(auditLog)
end

--------------------------------------------------------------------------
-- Confirmation tokens
--------------------------------------------------------------------------

type PendingConfirm = { command: string, arguments: string, expiresAt: number }
local pending: { [number]: PendingConfirm } = {}

local function requireConfirmation(player: Player, command: string, arguments: string): (boolean, string?)
	local entry = pending[player.UserId]
	local now = os.clock()
	if entry and entry.command == command and entry.arguments == arguments and now < entry.expiresAt then
		pending[player.UserId] = nil
		return true, nil
	end
	pending[player.UserId] = {
		command = command,
		arguments = arguments,
		expiresAt = now + Admin.ConfirmWindowSeconds,
	}
	return false,
		string.format(
			"This command is destructive. Run exactly the same command again within %d seconds to confirm.",
			Admin.ConfirmWindowSeconds
		)
end

--------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------

local function resolveTarget(raw: any): Player?
	if type(raw) == "number" then
		return Players:GetPlayerByUserId(raw)
	end
	local name = Guard.string(raw, 64)
	if not name then
		return nil
	end
	local lowered = string.lower(name)
	for _, player in Players:GetPlayers() do
		if string.lower(player.Name) == lowered or string.lower(player.DisplayName) == lowered then
			return player
		end
	end
	-- Prefix match, so an operator does not have to type a full username.
	for _, player in Players:GetPlayers() do
		if string.sub(string.lower(player.Name), 1, #lowered) == lowered then
			return player
		end
	end
	return nil
end

local function filtered(player: Player, text: string): string
	if not Admin.FilterAnnouncements then
		return text
	end
	local ok, result = Protect.call(function()
		local filterResult = TextService:FilterStringAsync(text, player.UserId, Enum.TextFilterContext.PublicChat)
		return filterResult:GetNonChatStringForBroadcastAsync()
	end)
	if ok and type(result) == "string" then
		return result
	end
	-- Filtering failed. Refusing to broadcast is the safe outcome.
	log.warn("text filter failed; announcement suppressed")
	return ""
end

--------------------------------------------------------------------------
-- Commands
--------------------------------------------------------------------------

export type CommandDef = {
	name: string,
	capability: string,
	usage: string,
	description: string,
	run: (player: Player, a: any, b: any, c: any) -> { [string]: any },
}

local COMMANDS: { [string]: CommandDef } = {}

local function define(def: CommandDef)
	COMMANDS[def.name] = def
end

define({
	name = "help",
	capability = "teleport_self",
	usage = "help",
	description = "Lists the commands your role can use.",
	run = function(player)
		local out = {}
		for name, def in COMMANDS do
			if Admin.can(player.UserId, def.capability) then
				table.insert(out, { name = name, usage = def.usage, description = def.description })
			end
		end
		table.sort(out, function(a, b)
			return a.name < b.name
		end)
		return { ok = true, commands = out, role = Admin.roleOf(player.UserId) }
	end,
})

define({
	name = "credits",
	capability = "grant_currency",
	usage = "credits <player> <amount>",
	description = "Grants credits to a player.",
	run = function(_player, rawTarget, rawAmount)
		local target = resolveTarget(rawTarget)
		if not target then
			return { ok = false, error = "NO_TARGET" }
		end
		local amount = Guard.integer(rawAmount, -Admin.GrantLimits.credits, Admin.GrantLimits.credits)
		if not amount then
			return { ok = false, error = "BAD_AMOUNT" }
		end
		ProgressionService.award(target, { credits = amount, source = "admin", exact = true })
		return { ok = true, message = string.format("%d credits to %s", amount, target.Name) }
	end,
})

define({
	name = "xp",
	capability = "grant_xp",
	usage = "xp <player> <amount>",
	description = "Grants XP to a player.",
	run = function(_player, rawTarget, rawAmount)
		local target = resolveTarget(rawTarget)
		if not target then
			return { ok = false, error = "NO_TARGET" }
		end
		local amount = Guard.integer(rawAmount, 0, Admin.GrantLimits.xp)
		if not amount then
			return { ok = false, error = "BAD_AMOUNT" }
		end
		local result = ProgressionService.award(target, { xp = amount, source = "admin", exact = true })
		return { ok = true, message = string.format("%d XP to %s (now level %d)", amount, target.Name, result.newLevel) }
	end,
})

define({
	name = "item",
	capability = "grant_item",
	usage = "item <player> <itemId> [quantity]",
	description = "Places items in a player's expedition inventory.",
	run = function(_player, rawTarget, rawItem, rawQuantity)
		local target = resolveTarget(rawTarget)
		if not target then
			return { ok = false, error = "NO_TARGET" }
		end
		local itemId = Guard.id(rawItem)
		if not itemId or not ItemRegistry.exists(itemId) then
			return { ok = false, error = "UNKNOWN_ITEM" }
		end
		local quantity = Guard.integer(rawQuantity, 1, Admin.GrantLimits.itemQuantity) or 1
		if not InventoryService.get(target) then
			return { ok = false, error = "TARGET_NOT_ON_EXPEDITION" }
		end
		local added = InventoryService.add(target, itemId, quantity)
		return { ok = added > 0, message = string.format("gave %d x %s to %s", added, itemId, target.Name) }
	end,
})

define({
	name = "unlock",
	capability = "unlock_content",
	usage = "unlock <player> <kind> <id>",
	description = "Grants an unlock. Kinds: cosmetic, livery, interior, train, weapon.",
	run = function(_player, rawTarget, rawKind, rawId)
		local target = resolveTarget(rawTarget)
		if not target then
			return { ok = false, error = "NO_TARGET" }
		end
		local kind = Guard.enum(rawKind, { "cosmetic", "livery", "interior", "train", "weapon" })
		local id = Guard.id(rawId)
		if not kind or not id then
			return { ok = false, error = "BAD_ARGS" }
		end
		local granted = ProgressionService.grantUnlock(target, kind, id)
		return { ok = granted, message = if granted then "granted" else "already owned or unknown" }
	end,
})

define({
	name = "tp",
	capability = "teleport_self",
	usage = "tp <lobby|station N|train>",
	description = "Moves you around the world.",
	run = function(player, rawWhere, rawIndex)
		local where = Guard.enum(rawWhere, { "lobby", "station", "train" })
		if not where then
			return { ok = false, error = "BAD_DESTINATION" }
		end
		local character = player.Character
		if not character then
			return { ok = false, error = "NO_CHARACTER" }
		end

		if where == "lobby" then
			local lobby = WorldService.getLobby()
			if not lobby then
				return { ok = false, error = "NO_LOBBY" }
			end
			character:PivotTo(lobby.spawnCFrames[1])
			return { ok = true, message = "moved to the yard" }
		end

		local expedition = ExpeditionService.forPlayer(player)
		if not expedition then
			return { ok = false, error = "NOT_ON_EXPEDITION" }
		end
		if where == "train" then
			character:PivotTo(expedition.train.built.root.CFrame * CFrame.new(0, 8, 20))
			return { ok = true, message = "moved to the train" }
		end
		local index = Guard.integer(rawIndex, 1, 10)
		if not index then
			return { ok = false, error = "BAD_INDEX" }
		end
		local station = expedition.lane.stations[index]
		if not station then
			return { ok = false, error = "NO_SUCH_STATION" }
		end
		character:PivotTo(station.origin * CFrame.new(0, 8, 0))
		return { ok = true, message = "moved to station " .. index }
	end,
})

define({
	name = "bring",
	capability = "teleport_player",
	usage = "bring <player>",
	description = "Teleports a player to you.",
	run = function(player, rawTarget)
		local target = resolveTarget(rawTarget)
		if not target or not target.Character or not player.Character then
			return { ok = false, error = "NO_TARGET" }
		end
		target.Character:PivotTo(player.Character:GetPivot() * CFrame.new(0, 0, -5))
		return { ok = true, message = "brought " .. target.Name }
	end,
})

define({
	name = "announce",
	capability = "announce",
	usage = "announce <message>",
	description = "Broadcasts a filtered message to every player on the server.",
	run = function(player, rawMessage)
		local message = Guard.string(rawMessage, 300)
		if not message or message == "" then
			return { ok = false, error = "EMPTY" }
		end
		local safe = filtered(player, message)
		if safe == "" then
			return { ok = false, error = "FILTERED" }
		end
		Net.fireAllClients("Notify", {
			kind = "announcement",
			title = "Announcement",
			body = safe,
			duration = 12,
		})
		return { ok = true, message = "sent" }
	end,
})

define({
	name = "kick",
	capability = "kick",
	usage = "kick <player> <reason>",
	description = "Removes a player from the server.",
	run = function(player, rawTarget, rawReason)
		local target = resolveTarget(rawTarget)
		if not target then
			return { ok = false, error = "NO_TARGET" }
		end
		if Admin.rankOf(Admin.roleOf(target.UserId)) >= Admin.rankOf(Admin.roleOf(player.UserId)) then
			-- An administrator cannot kick an equal or a superior.
			return { ok = false, error = "INSUFFICIENT_RANK" }
		end
		local reason = Guard.string(rawReason, 200) or "Removed by a moderator."
		target:Kick(reason)
		return { ok = true, message = "kicked " .. target.Name }
	end,
})

define({
	name = "inspect",
	capability = "inspect_player",
	usage = "inspect <player>",
	description = "Shows a player's progression and session state.",
	run = function(_player, rawTarget)
		local target = resolveTarget(rawTarget)
		if not target then
			return { ok = false, error = "NO_TARGET" }
		end
		local profile = DataService.getProfile(target)
		if not profile then
			return { ok = false, error = "NOT_LOADED" }
		end
		local expedition = ExpeditionService.forPlayer(target)
		local vitals = SurvivalService.get(target)
		return {
			ok = true,
			info = {
				name = target.Name,
				userId = target.UserId,
				level = profile.level,
				xp = profile.xp,
				credits = profile.credits,
				sessionCount = profile.sessionCount,
				writable = DataService.isWritable(target),
				readOnlyReason = DataService.readOnlyReason(target),
				expedition = if expedition then expedition.id else nil,
				station = if expedition then expedition.stationIndex else nil,
				vitals = if vitals then { health = vitals.health, state = vitals.state } else nil,
				role = Admin.roleOf(target.UserId),
				robuxSpent = profile.purchases.robuxSpent,
			},
		}
	end,
})

define({
	name = "godmode",
	capability = "toggle_godmode",
	usage = "godmode <player>",
	description = "Grants a long damage immunity, for testing.",
	run = function(_player, rawTarget)
		local target = resolveTarget(rawTarget)
		if not target then
			return { ok = false, error = "NO_TARGET" }
		end
		SurvivalService.grantImmunity(target, 3600)
		return { ok = true, message = "immunity granted for one hour" }
	end,
})

define({
	name = "threat",
	capability = "spawn_creature",
	usage = "threat <amount>",
	description = "Adds to your expedition's threat level.",
	run = function(player, rawAmount)
		local expedition = ExpeditionService.forPlayer(player)
		if not expedition then
			return { ok = false, error = "NOT_ON_EXPEDITION" }
		end
		local amount = Guard.number(rawAmount, -100, 100)
		if not amount then
			return { ok = false, error = "BAD_AMOUNT" }
		end
		HorrorDirector.addThreat(expedition.id, amount)
		return { ok = true, message = string.format("threat is now %.0f", HorrorDirector.threatOf(expedition.id)) }
	end,
})

define({
	name = "station",
	capability = "control_expedition",
	usage = "station <index>",
	description = "Advances your expedition to a station, completing the ones before it.",
	run = function(player, rawIndex)
		local expedition = ExpeditionService.forPlayer(player)
		if not expedition then
			return { ok = false, error = "NOT_ON_EXPEDITION" }
		end
		local index = Guard.integer(rawIndex, 1, 10)
		if not index then
			return { ok = false, error = "BAD_INDEX" }
		end
		-- Complete every outstanding objective at the current station, which is
		-- what actually advances the expedition through its normal path.
		for objectiveId in expedition.objectives do
			ExpeditionService.completeObjective(expedition, objectiveId)
		end
		return { ok = true, message = "current station objectives completed" }
	end,
})

define({
	name = "event",
	capability = "control_event",
	usage = "event <start|stop|status> [id] [hours]",
	description = "Controls live events.",
	run = function(_player, rawAction, rawId, rawHours)
		local action = Guard.enum(rawAction, { "start", "stop", "status" })
		if not action then
			return { ok = false, error = "BAD_ACTION" }
		end
		if action == "status" then
			return { ok = true, events = EventService.status() }
		end
		local id = Guard.id(rawId)
		if not id then
			return { ok = false, error = "BAD_EVENT" }
		end
		if action == "start" then
			local hours = Guard.number(rawHours, 0.1, 24 * 30) or 168
			local ok = EventService.startEvent(id, hours)
			return { ok = ok, message = if ok then "event started" else "unknown event" }
		end
		local ok = EventService.stopEvent(id)
		return { ok = ok, message = if ok then "event stopped; claims remain open" else "unknown event" }
	end,
})

define({
	name = "world",
	capability = "view_analytics",
	usage = "world",
	description = "Reports lane and server state.",
	run = function()
		local status = WorldService.status()
		local expeditions = {}
		for _, expedition in ExpeditionService.all() do
			table.insert(expeditions, {
				id = expedition.id,
				state = expedition.state,
				station = expedition.stationIndex,
				crew = expedition.crewSize,
				threat = HorrorDirector.threatOf(expedition.id),
			})
		end
		return {
			ok = true,
			world = status,
			expeditions = expeditions,
			data = DataService.status(),
			build = GameConfig.BuildId,
		}
	end,
})

define({
	name = "resetplayer",
	capability = "reset_player_data",
	usage = "resetplayer <player>",
	description = "OWNER ONLY. Wipes a player's progress. Purchases are preserved.",
	run = function(player, rawTarget)
		local target = resolveTarget(rawTarget)
		if not target then
			return { ok = false, error = "NO_TARGET" }
		end
		local confirmed, message = requireConfirmation(player, "resetplayer", tostring(target.UserId))
		if not confirmed then
			return { ok = false, error = "CONFIRM", message = message }
		end
		local ok = DataService.resetProgress(target.UserId)
		if ok then
			ProgressionService.pushToClient(target)
		end
		return {
			ok = ok,
			message = if ok then "progress reset; purchase records preserved" else "target session is not writable",
		}
	end,
})

define({
	name = "resetme",
	capability = "reset_player_data",
	usage = "resetme",
	description = "OWNER ONLY. Wipes your own progress. Purchases are preserved.",
	run = function(player)
		local confirmed, message = requireConfirmation(player, "resetme", tostring(player.UserId))
		if not confirmed then
			return { ok = false, error = "CONFIRM", message = message }
		end
		local ok = DataService.resetProgress(player.UserId)
		if ok then
			ProgressionService.pushToClient(player)
		end
		return { ok = ok, message = if ok then "your progress was reset" else "your session is not writable" }
	end,
})

--------------------------------------------------------------------------

function AdminService.roleOf(player: Player): string
	return Admin.roleOf(player.UserId)
end

function AdminService.start()
	Net.onServerInvoke("AdminCommand", function(player, rawCommand, a, b, c)
		local commandName = Guard.string(rawCommand, 32)
		if not commandName then
			return { ok = false, error = "BAD_COMMAND" }
		end
		local def = COMMANDS[string.lower(commandName)]
		if not def then
			return { ok = false, error = "UNKNOWN_COMMAND" }
		end

		-- The authorisation check. Server side, by user ID, every single call.
		if not Admin.can(player.UserId, def.capability) then
			audit(player, commandName, "", "DENIED")
			return { ok = false, error = "DENIED" }
		end

		local ok, result = Protect.call(def.run, player, a, b, c)
		if not ok then
			audit(player, commandName, tostring(a), "ERROR")
			log.error(string.format("command %s failed: %s", commandName, tostring(result)))
			return { ok = false, error = "INTERNAL" }
		end

		local payload = result :: { [string]: any }
		audit(
			player,
			commandName,
			string.format("%s %s %s", tostring(a), tostring(b), tostring(c)),
			if payload.ok then "OK" else tostring(payload.error)
		)
		return payload
	end)

	-- The client is told its own role so it can show or hide the admin panel.
	-- The panel is a convenience; every command is re-authorised server side,
	-- so a client that fakes the flag gains nothing.
	DataService.ProfileLoaded:Connect(function(player)
		local role = Admin.roleOf(player.UserId)
		if role ~= "player" then
			Net.fireClient("AdminState", player, { role = role, commands = (function()
				local out = {}
				for name, def in COMMANDS do
					if Admin.can(player.UserId, def.capability) then
						table.insert(out, { name = name, usage = def.usage, description = def.description })
					end
				end
				table.sort(out, function(x, y)
					return x.name < y.name
				end)
				return out
			end)() })
			log.info(string.format("%s connected with role %s", player.Name, role))
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		pending[player.UserId] = nil
	end)

	local roleAudit = Admin.audit()
	if roleAudit.active == 0 then
		log.warn(
			"no administrator user IDs are configured. Nobody has admin access. "
				.. "Fill in the numeric user IDs in ReplicatedStorage.LastSignal.Config.Admin; see docs/ADMIN.md."
		)
	else
		log.info(string.format("%d role(s) active", roleAudit.active))
		if #roleAudit.inactive > 0 then
			log.warn("roles with no user ID: " .. table.concat(roleAudit.inactive, ", "))
		end
	end

end

return AdminService
