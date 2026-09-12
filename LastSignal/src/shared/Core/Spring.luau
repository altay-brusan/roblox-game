--!strict
--[[
	Spring
	------
	Critically-damped-ish spring used for camera sway, weapon recoil recovery,
	HUD meter motion and the cab needle gauges.

	Framerate independent: step() integrates with the real delta time, so a
	120 fps client and a 30 fps phone settle at the same rate. This matters
	because the same spring drives recoil, which affects aim.
]]

local Spring = {}
Spring.__index = Spring

export type Spring = typeof(setmetatable(
	{} :: {
		position: number,
		velocity: number,
		target: number,
		stiffness: number,
		damping: number,
	},
	Spring
))

function Spring.new(initial: number, stiffness: number?, damping: number?): Spring
	return setmetatable({
		position = initial,
		velocity = 0,
		target = initial,
		stiffness = stiffness or 90,
		damping = damping or 16,
	}, Spring)
end

function Spring.setTarget(self: Spring, target: number)
	self.target = target
end

--- Adds an instantaneous velocity change, used for recoil kicks and impacts.
function Spring.impulse(self: Spring, amount: number)
	self.velocity += amount
end

function Spring.step(self: Spring, deltaTime: number): number
	-- Sub-stepping keeps a stiff spring stable when a frame hitches. Without
	-- this, a 200 ms stall makes recoil springs explode.
	local remaining = math.min(deltaTime, 0.25)
	local maxStep = 1 / 120
	while remaining > 0 do
		local step = math.min(remaining, maxStep)
		remaining -= step
		local displacement = self.position - self.target
		local acceleration = -self.stiffness * displacement - self.damping * self.velocity
		self.velocity += acceleration * step
		self.position += self.velocity * step
	end
	return self.position
end

function Spring.reset(self: Spring, value: number)
	self.position = value
	self.velocity = 0
	self.target = value
end

--- Three-axis spring for camera and weapon offsets.
local Vector3Spring = {}
Vector3Spring.__index = Vector3Spring

export type Vector3Spring = typeof(setmetatable(
	{} :: { x: Spring, y: Spring, z: Spring },
	Vector3Spring
))

function Spring.vector3(initial: Vector3, stiffness: number?, damping: number?): Vector3Spring
	return setmetatable({
		x = Spring.new(initial.X, stiffness, damping),
		y = Spring.new(initial.Y, stiffness, damping),
		z = Spring.new(initial.Z, stiffness, damping),
	}, Vector3Spring)
end

function Vector3Spring.setTarget(self: Vector3Spring, target: Vector3)
	self.x:setTarget(target.X)
	self.y:setTarget(target.Y)
	self.z:setTarget(target.Z)
end

function Vector3Spring.impulse(self: Vector3Spring, amount: Vector3)
	self.x:impulse(amount.X)
	self.y:impulse(amount.Y)
	self.z:impulse(amount.Z)
end

function Vector3Spring.step(self: Vector3Spring, deltaTime: number): Vector3
	return Vector3.new(self.x:step(deltaTime), self.y:step(deltaTime), self.z:step(deltaTime))
end

function Vector3Spring.reset(self: Vector3Spring, value: Vector3)
	self.x:reset(value.X)
	self.y:reset(value.Y)
	self.z:reset(value.Z)
end

--- Exponential smoothing helper for values that do not need spring overshoot,
--- such as fog density and audio gain. Also framerate independent.
function Spring.damp(current: number, target: number, smoothing: number, deltaTime: number): number
	local alpha = 1 - math.exp(-deltaTime / math.max(1e-4, smoothing))
	return current + (target - current) * alpha
end

return Spring
