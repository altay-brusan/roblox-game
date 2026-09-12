--!strict
--[[
	Maid
	----
	Deterministic cleanup container. Anything whose lifetime is shorter than the
	server or client session goes into a Maid, so teardown is a single call and
	nothing leaks across expeditions, respawns or menu open/close cycles.

	Accepts Instances, RBXScriptConnections, internal Signal connections,
	functions, threads, and tables exposing Destroy or Disconnect.
]]

-- Luau types pcall as returning only the success flag when the callee is
-- declared to return nothing, which loses the error message. This cast keeps
-- the (ok, err) pair that the runtime actually provides.
local protectedCall = (pcall :: any) :: (fn: (...any) -> (), ...any) -> (boolean, string?)

local Maid = {}
Maid.__index = Maid

export type Maid = typeof(setmetatable(
	{} :: { _tasks: { [any]: any }, _destroyed: boolean, _id: number },
	Maid
))

function Maid.new(): Maid
	return setmetatable({ _tasks = {}, _destroyed = false, _id = 0 }, Maid)
end

local function cleanupTask(item: any)
	local kind = typeof(item)
	if kind == "function" then
		item()
	elseif kind == "RBXScriptConnection" then
		item:Disconnect()
	elseif kind == "Instance" then
		item:Destroy()
	elseif kind == "thread" then
		-- Cancelling the running thread would abort our own teardown.
		if coroutine.running() ~= item and coroutine.status(item) ~= "dead" then
			pcall(task.cancel, item)
		end
	elseif kind == "table" then
		if type(item.Destroy) == "function" then
			item:Destroy()
		elseif type(item.Disconnect) == "function" then
			item:Disconnect()
		end
	end
end

--- Adds a task and returns it, so `local part = maid:Give(Instance.new("Part"))`
--- reads naturally at the call site.
function Maid.Give(self: Maid, item: any): any
	if self._destroyed then
		-- Late additions to a destroyed maid are cleaned immediately rather than
		-- leaking; this happens when async work lands after teardown.
		cleanupTask(item)
		return item
	end
	self._id += 1
	self._tasks[self._id] = item
	return item
end

--- Adds a task under a stable key. Re-using a key cleans the previous occupant,
--- which is how single-instance state such as an active beam is managed.
function Maid.GiveKeyed(self: Maid, key: any, item: any): any
	if self._destroyed then
		cleanupTask(item)
		return item
	end
	local existing = self._tasks[key]
	if existing ~= nil and existing ~= item then
		cleanupTask(existing)
	end
	self._tasks[key] = item
	return item
end

function Maid.Remove(self: Maid, key: any)
	local existing = self._tasks[key]
	if existing ~= nil then
		self._tasks[key] = nil
		cleanupTask(existing)
	end
end

--- Runs every task and empties the maid. The maid remains usable afterwards.
function Maid.Clean(self: Maid)
	local tasks = self._tasks
	self._tasks = {}
	for _, item in tasks do
		local ok, err = protectedCall(cleanupTask, item)
		if not ok then
			warn("[Maid] cleanup error: " .. tostring(err))
		end
	end
end

function Maid.Destroy(self: Maid)
	self:Clean()
	self._destroyed = true
end

return Maid
