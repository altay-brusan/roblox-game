--!strict
--[[
	Signal
	------
	Lightweight event implementation used across LAST SIGNAL.

	Why not BindableEvent: BindableEvents serialise their arguments, which breaks
	table identity and drops metatables. Every internal event in this project
	passes real Lua values, so a pure-Lua signal is both faster and safer.

	Handlers run on pooled coroutines (matching RBXScriptSignal semantics) so a
	single throwing listener can never prevent the others from running.
]]

export type Connection = {
	Connected: boolean,
	Disconnect: (self: Connection) -> (),
}

export type Signal<T...> = {
	Connect: (self: Signal<T...>, fn: (T...) -> ()) -> Connection,
	Once: (self: Signal<T...>, fn: (T...) -> ()) -> Connection,
	Wait: (self: Signal<T...>) -> T...,
	Fire: (self: Signal<T...>, T...) -> (),
	DisconnectAll: (self: Signal<T...>) -> (),
	Destroy: (self: Signal<T...>) -> (),
}

local Connection = {}
Connection.__index = Connection

local Signal = {}
Signal.__index = Signal

-- Pool of parked coroutines. Reusing them avoids one coroutine allocation per
-- fire, which matters for high-frequency signals such as the world tick.
local freeThread: thread? = nil

local function runHandler(fn, ...)
	local thread = freeThread
	freeThread = nil
	fn(...)
	freeThread = thread
end

local function threadLoop()
	while true do
		runHandler(coroutine.yield())
	end
end

local function spawnHandler(fn, ...)
	if not freeThread then
		local created = coroutine.create(threadLoop)
		freeThread = created
		task.spawn(created)
	end
	task.spawn(freeThread :: thread, fn, ...)
end

function Connection.new(signal: any, fn: any): any
	return setmetatable({
		Connected = true,
		_signal = signal,
		_fn = fn,
		_next = nil,
	}, Connection)
end

function Connection.Disconnect(self: any)
	if not self.Connected then
		return
	end
	self.Connected = false

	local signal = self._signal
	if signal then
		if signal._head == self then
			signal._head = self._next
		else
			local prev = signal._head
			while prev and prev._next ~= self do
				prev = prev._next
			end
			if prev then
				prev._next = self._next
			end
		end
	end
	self._signal = nil
	self._fn = nil
end

function Signal.Connect(self: any, fn)
	assert(type(fn) == "function", "Signal:Connect expects a function")
	local connection = Connection.new(self, fn)
	connection._next = self._head
	self._head = connection
	return connection
end

function Signal.Once(self: any, fn)
	assert(type(fn) == "function", "Signal:Once expects a function")
	local connection
	connection = self:Connect(function(...)
		if connection.Connected then
			connection:Disconnect()
		end
		fn(...)
	end)
	return connection
end

function Signal.Wait(self: any)
	local waiting = coroutine.running()
	local connection
	connection = self:Connect(function(...)
		connection:Disconnect()
		task.spawn(waiting, ...)
	end)
	return coroutine.yield()
end

function Signal.Fire(self: any, ...)
	local node = self._head
	while node do
		-- Cache the next node first: a handler may disconnect itself.
		local nextNode = node._next
		if node.Connected then
			spawnHandler(node._fn, ...)
		end
		node = nextNode
	end
end

function Signal.DisconnectAll(self: any)
	local node = self._head
	while node do
		local nextNode = node._next
		node.Connected = false
		node._signal = nil
		node._fn = nil
		node = nextNode
	end
	self._head = nil
end

function Signal.Destroy(self: any)
	self:DisconnectAll()
end

local function newSignal<T...>(): Signal<T...>
	return (setmetatable({ _head = nil }, Signal) :: any) :: Signal<T...>
end

return {
	new = newSignal,
}
