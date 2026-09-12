--!strict
--[[
	Admin
	-----
	Role configuration for LAST SIGNAL.

	Roles are resolved on the server from Player.UserId only. Display names are
	never used for anything but display: Roblox usernames can be changed, and a
	display name can be set to anything at all, so trusting either would let any
	player impersonate an administrator.

	FILLING IN THE USER IDS
	-----------------------
	The two accounts named in the brief are listed below with their IDs set to
	0, which grants nothing. To activate them, look up each account's numeric
	user ID and paste it in. The fastest way: open the profile in a browser and
	read the number in the URL, roblox.com/users/<NUMBER>/profile.

	The IDs are not filled in here because this project cannot verify which
	account a given username currently belongs to, and guessing would be worse
	than leaving the role switched off. A role with ID 0 is inert.
]]

local Admin = {}

export type Role = "owner" | "admin" | "moderator" | "tester" | "player"

export type RoleEntry = {
	userId: number,
	username: string, -- reference only, never used for authorisation
	role: Role,
	note: string?,
}

--------------------------------------------------------------------------
-- Role assignments
--------------------------------------------------------------------------

Admin.Roles = {
	{
		userId = 0, -- TODO(operator): RIPjafar1 numeric user ID
		username = "RIPjafar1",
		role = "owner" :: Role,
		note = "Owner and main developer. Full access including destructive resets.",
	},
	{
		userId = 0, -- TODO(operator): shayanbrusan1234 numeric user ID
		username = "shayanbrusan1234",
		role = "admin" :: Role,
		note = "Administrator. Everything except destructive resets and role changes.",
	},
} :: { RoleEntry }

--------------------------------------------------------------------------
-- Capability matrix
--------------------------------------------------------------------------

-- Each capability maps to the minimum role that holds it. Every admin command
-- declares one capability; AdminService checks it before running anything.
local RANK: { [string]: number } = {
	player = 0,
	tester = 10,
	moderator = 20,
	admin = 30,
	owner = 40,
}

Admin.Capabilities = {
	inspect_player = "moderator",
	announce = "moderator",
	kick = "moderator",
	teleport_self = "tester",
	teleport_player = "admin",
	grant_currency = "admin",
	grant_xp = "admin",
	grant_item = "admin",
	unlock_content = "admin",
	control_event = "admin",
	control_expedition = "admin",
	spawn_creature = "admin",
	set_difficulty = "admin",
	toggle_godmode = "admin",
	view_analytics = "admin",
	reset_player_data = "owner",
	reset_all_data = "owner",
	grant_role = "owner",
} :: { [string]: Role }

--------------------------------------------------------------------------
-- Resolution
--------------------------------------------------------------------------

local byUserId: { [number]: Role } = {}
for _, entry in Admin.Roles do
	if entry.userId and entry.userId > 0 then
		byUserId[entry.userId] = entry.role
	end
end

--- Server-side role lookup. The only correct way to ask "is this an admin".
function Admin.roleOf(userId: number): Role
	return byUserId[userId] or "player"
end

function Admin.rankOf(role: string): number
	return RANK[role] or 0
end

--- True when the given user ID may use the named capability.
function Admin.can(userId: number, capability: string): boolean
	local required = Admin.Capabilities[capability] :: Role?
	if not required then
		-- Unknown capability is denied. Failing closed matters here: a typo in a
		-- command definition must not silently grant access to everyone.
		return false
	end
	return Admin.rankOf(Admin.roleOf(userId)) >= Admin.rankOf(required)
end

--- Reports which configured roles are inert, so the operator sees it at boot.
function Admin.audit(): { active: number, inactive: { string } }
	local active = 0
	local inactive: { string } = {}
	for _, entry in Admin.Roles do
		if entry.userId > 0 then
			active += 1
		else
			table.insert(inactive, string.format("%s (%s)", entry.username, entry.role))
		end
	end
	return { active = active, inactive = inactive }
end

--------------------------------------------------------------------------
-- Command safety
--------------------------------------------------------------------------

-- Destructive commands require the operator to repeat the command with a
-- confirmation token within this window.
Admin.ConfirmWindowSeconds = 30

-- Commands that always require confirmation regardless of role.
Admin.ConfirmRequired = {
	reset_player_data = true,
	reset_all_data = true,
}

-- Maximum values an admin grant may issue in one command. Prevents a slip of
-- the keyboard from writing an absurd number into a live profile.
Admin.GrantLimits = {
	credits = 1000000,
	xp = 500000,
	itemQuantity = 999,
}

-- Public announcements are filtered through TextService before broadcast.
Admin.FilterAnnouncements = true

-- Admin actions are appended to a rolling in-memory log and mirrored to the
-- server output. Size is bounded so a long-running server cannot grow forever.
Admin.AuditLogSize = 250

return Admin
