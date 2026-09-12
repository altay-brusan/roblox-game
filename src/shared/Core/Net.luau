--!strict
--[[
	Net
	---
	The single networking boundary for LAST SIGNAL.

	Rules this module enforces, because they are the ones that get broken:

	1. Every remote is declared up front in RemoteManifest. A typo is a hard
	   error at boot rather than a silent no-op in production.
	2. The server creates the remote folder; the client only ever waits for it.
	   Clients cannot introduce new remotes.
	3. Every server-bound handler is wrapped with a token-bucket rate limit and
	   a pcall, so a malicious or buggy client cannot spam or crash a service.
	4. There are no server-to-client RemoteFunction invocations anywhere in the
	   project. A client that never returns would hang the server thread.

	Argument validation is the caller's responsibility and is expected on every
	server handler; see Guard for the shared validators.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local Logger = require(script.Parent.Logger)
local RateLimiter = require(script.Parent.RateLimiter)

local log = Logger.new("Net")
local IS_SERVER = RunService:IsServer()

-- Luau types pcall as returning only the success flag when the callee is
-- declared to return nothing, which loses the error message. This cast keeps
-- the (ok, err) pair the runtime actually provides.
local protectedCall = (pcall :: any) :: (fn: (...any) -> (), ...any) -> (boolean, string?)

local Net = {}

--[[
	Remote manifest.

	kind:  "event"    -> RemoteEvent, both directions
	       "function" -> RemoteFunction, client -> server only
	rate:  { capacity, refillPerSecond } applied per player to inbound traffic.
	       Omitted for server -> client only events.
]]
export type RemoteKind = "event" | "function"
export type RemoteSpec = { kind: RemoteKind, rate: { number }? }

local MANIFEST: { [string]: RemoteSpec } = {
	-- Session and profile ------------------------------------------------
	ProfileSnapshot = { kind = "event" }, -- server -> client, full profile push
	ProfileDelta = { kind = "event" }, -- server -> client, incremental update
	RequestProfile = { kind = "function", rate = { 4, 0.5 } },
	SetSetting = { kind = "event", rate = { 12, 3 } },

	-- Lobby, crew and expedition ------------------------------------------
	CrewState = { kind = "event" }, -- server -> client
	CrewCommand = { kind = "function", rate = { 10, 2 } },
	ExpeditionState = { kind = "event" }, -- server -> client
	ExpeditionCommand = { kind = "function", rate = { 10, 2 } },
	Cinematic = { kind = "event" }, -- server -> client
	CinematicSkip = { kind = "event", rate = { 4, 1 } },

	-- World interaction ----------------------------------------------------
	Interact = { kind = "event", rate = { 12, 4 } },
	InteractResult = { kind = "event" }, -- server -> client
	Inventory = { kind = "event" }, -- server -> client
	InventoryCommand = { kind = "function", rate = { 20, 6 } },
	Ping = { kind = "event", rate = { 6, 1 } },
	PingBroadcast = { kind = "event" }, -- server -> client

	-- Train ----------------------------------------------------------------
	TrainState = { kind = "event" }, -- server -> client
	TrainControl = { kind = "event", rate = { 24, 10 } },
	TrainCommand = { kind = "function", rate = { 8, 2 } },

	-- Combat ---------------------------------------------------------------
	WeaponFire = { kind = "event", rate = { 16, 8 } },
	WeaponReload = { kind = "event", rate = { 6, 2 } },
	WeaponEffect = { kind = "event" }, -- server -> client
	MeleeSwing = { kind = "event", rate = { 10, 3 } },

	-- Survival, downed state ------------------------------------------------
	VitalsState = { kind = "event" }, -- server -> client
	DownedState = { kind = "event" }, -- server -> client
	ReviveCommand = { kind = "function", rate = { 6, 1 } },
	SpectateCommand = { kind = "event", rate = { 10, 2 } },

	-- Horror direction -------------------------------------------------------
	HorrorCue = { kind = "event" }, -- server -> client
	RadioMessage = { kind = "event" }, -- server -> client

	-- Progression, quests, rewards -------------------------------------------
	QuestState = { kind = "event" }, -- server -> client
	RewardCommand = { kind = "function", rate = { 8, 1 } },
	RewardGranted = { kind = "event" }, -- server -> client
	LeaderboardData = { kind = "function", rate = { 3, 0.2 } },

	-- Shop and monetization ---------------------------------------------------
	ShopState = { kind = "event" }, -- server -> client
	ShopCommand = { kind = "function", rate = { 10, 1.5 } },
	PurchaseResult = { kind = "event" }, -- server -> client

	-- Live events --------------------------------------------------------------
	EventState = { kind = "event" }, -- server -> client
	EventCommand = { kind = "function", rate = { 8, 1 } },

	-- Presentation, notifications, admin ----------------------------------------
	Notify = { kind = "event" }, -- server -> client
	Subtitle = { kind = "event" }, -- server -> client
	AdminCommand = { kind = "function", rate = { 12, 2 } },
	AdminState = { kind = "event" }, -- server -> client
	Analytics = { kind = "event", rate = { 20, 4 } }, -- client funnel markers
}

Net.Manifest = MANIFEST

local REMOTE_FOLDER_NAME = "Remotes"

local remotes: { [string]: Instance } = {}
local limiters: { [string]: RateLimiter.RateLimiter } = {}
local folder: Folder? = nil

local function assertDeclared(name: string): RemoteSpec
	local spec = MANIFEST[name]
	if not spec then
		error(string.format("Net: remote '%s' is not declared in the manifest", name), 3)
	end
	return spec
end

--- Server-only. Creates every declared remote. Called once during boot.
function Net.initServer()
	assert(IS_SERVER, "Net.initServer may only run on the server")
	if folder then
		return
	end
	local root = ReplicatedStorage:FindFirstChild("LastSignal")
	assert(root, "Net.initServer: ReplicatedStorage.LastSignal is missing")

	local created = Instance.new("Folder")
	created.Name = REMOTE_FOLDER_NAME
	for name, spec in MANIFEST do
		local remote: Instance
		if spec.kind == "event" then
			remote = Instance.new("RemoteEvent")
		else
			remote = Instance.new("RemoteFunction")
		end
		remote.Name = name
		remote.Parent = created
		remotes[name] = remote
		if spec.rate then
			limiters[name] = RateLimiter.new(spec.rate[1], spec.rate[2])
		end
	end
	created.Parent = root
	folder = created

	Players.PlayerRemoving:Connect(function(player)
		for _, limiter in limiters do
			limiter:reset(player)
		end
	end)

	log.info(string.format("initialised %d remotes", (function()
		local n = 0
		for _ in MANIFEST do
			n += 1
		end
		return n
	end)()))
end

local function getRemote(name: string): Instance
	assertDeclared(name)
	local cached = remotes[name]
	if cached then
		return cached
	end
	assert(not IS_SERVER, "Net: server remote missing after init: " .. name)
	local root = ReplicatedStorage:WaitForChild("LastSignal", 30) :: Instance
	local remoteFolder = root:WaitForChild(REMOTE_FOLDER_NAME, 30) :: Instance
	local remote = remoteFolder:WaitForChild(name, 30)
	assert(remote, "Net: remote never replicated: " .. name)
	remotes[name] = remote :: Instance
	return remote :: Instance
end

Net.get = getRemote

-- Server API ---------------------------------------------------------------

export type HandlerOptions = {
	--- Skip the automatic rate limit. Only for server-authored internal calls.
	unlimited: boolean?,
}

--- Connects a server handler to a client-fired RemoteEvent.
--- The handler is rate limited per player and wrapped in pcall.
function Net.onServerEvent(name: string, handler: (Player, ...any) -> (), options: HandlerOptions?): RBXScriptConnection
	assert(IS_SERVER, "Net.onServerEvent is server only")
	local spec = assertDeclared(name)
	assert(spec.kind == "event", "Net.onServerEvent: " .. name .. " is not an event")
	local remote = getRemote(name) :: RemoteEvent
	local limiter = limiters[name]
	local skipLimit = options and options.unlimited

	return remote.OnServerEvent:Connect(function(player, ...)
		if limiter and not skipLimit and not limiter:check(player) then
			-- Dropping silently is intentional: telling a spammer that they are
			-- rate limited only helps them tune the spam.
			return
		end
		local ok, err = protectedCall(handler, player, ...)
		if not ok then
			log.error(string.format("handler '%s' for %s failed: %s", name, player.Name, tostring(err)))
		end
	end)
end

--- Connects a server handler to a client RemoteFunction invocation.
--- Returning nil is the convention for "rejected"; callers must handle it.
function Net.onServerInvoke(name: string, handler: (Player, ...any) -> ...any, options: HandlerOptions?)
	assert(IS_SERVER, "Net.onServerInvoke is server only")
	local spec = assertDeclared(name)
	assert(spec.kind == "function", "Net.onServerInvoke: " .. name .. " is not a function")
	local remote = getRemote(name) :: RemoteFunction
	local limiter = limiters[name]
	local skipLimit = options and options.unlimited

	remote.OnServerInvoke = function(player, ...)
		if limiter and not skipLimit and not limiter:check(player) then
			return { ok = false, error = "RATE_LIMITED" }
		end
		local results = table.pack(pcall(handler, player, ...))
		if not results[1] then
			log.error(string.format("invoke '%s' for %s failed: %s", name, player.Name, tostring(results[2])))
			return { ok = false, error = "INTERNAL" }
		end
		return table.unpack(results, 2, results.n)
	end
end

function Net.fireClient(name: string, player: Player, ...: any)
	assert(IS_SERVER, "Net.fireClient is server only")
	local remote = getRemote(name) :: RemoteEvent
	remote:FireClient(player, ...)
end

function Net.fireAllClients(name: string, ...: any)
	assert(IS_SERVER, "Net.fireAllClients is server only")
	local remote = getRemote(name) :: RemoteEvent
	remote:FireAllClients(...)
end

--- Fires to a specific set of players. Used for crew-scoped traffic so an
--- expedition never leaks state to players in the lobby.
function Net.fireClients(name: string, players: { Player }, ...: any)
	assert(IS_SERVER, "Net.fireClients is server only")
	local remote = getRemote(name) :: RemoteEvent
	for _, player in players do
		if player.Parent then
			remote:FireClient(player, ...)
		end
	end
end

-- Client API ---------------------------------------------------------------

function Net.fireServer(name: string, ...: any)
	assert(not IS_SERVER, "Net.fireServer is client only")
	local remote = getRemote(name) :: RemoteEvent
	remote:FireServer(...)
end

--- Client-to-server invoke. Wrapped in pcall because a server shutdown mid
--- call raises on the client, and no UI should break because of that.
function Net.invokeServer(name: string, ...: any): any
	assert(not IS_SERVER, "Net.invokeServer is client only")
	local remote = getRemote(name) :: RemoteFunction
	local ok, result = pcall(function(...)
		return remote:InvokeServer(...)
	end, ...)
	if not ok then
		log.warn(string.format("invoke '%s' failed: %s", name, tostring(result)))
		return { ok = false, error = "UNAVAILABLE" }
	end
	return result
end

function Net.onClientEvent(name: string, handler: (...any) -> ()): RBXScriptConnection
	assert(not IS_SERVER, "Net.onClientEvent is client only")
	local remote = getRemote(name) :: RemoteEvent
	return remote.OnClientEvent:Connect(function(...)
		local ok, err = protectedCall(handler, ...)
		if not ok then
			log.error(string.format("client handler '%s' failed: %s", name, tostring(err)))
		end
	end)
end

return Net
