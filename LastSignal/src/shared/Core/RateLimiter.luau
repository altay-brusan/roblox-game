--!strict
--[[
	RateLimiter
	-----------
	Token-bucket limiter guarding every server-bound remote. One bucket exists
	per (owner, limiter) pair and is discarded when the player leaves.

	Bursts are allowed up to `capacity`; sustained rate is `refillPerSecond`.
	That shape suits gameplay input: a player may legitimately fire three shots
	in a moment, but not three hundred in a minute.
]]

local RateLimiter = {}
RateLimiter.__index = RateLimiter

type Bucket = { tokens: number, updated: number }

export type RateLimiter = typeof(setmetatable(
	{} :: {
		_capacity: number,
		_refill: number,
		_buckets: { [any]: Bucket },
	},
	RateLimiter
))

function RateLimiter.new(capacity: number, refillPerSecond: number): RateLimiter
	assert(capacity > 0, "capacity must be positive")
	assert(refillPerSecond > 0, "refillPerSecond must be positive")
	return setmetatable({
		_capacity = capacity,
		_refill = refillPerSecond,
		_buckets = {},
	}, RateLimiter)
end

--- Returns true when the caller may proceed, consuming one token.
function RateLimiter.check(self: RateLimiter, owner: any): boolean
	local now = os.clock()
	local bucket = self._buckets[owner]
	if not bucket then
		bucket = { tokens = self._capacity, updated = now }
		self._buckets[owner] = bucket
	else
		local elapsed = now - bucket.updated
		bucket.updated = now
		bucket.tokens = math.min(self._capacity, bucket.tokens + elapsed * self._refill)
	end
	local resolved = bucket :: Bucket
	if resolved.tokens >= 1 then
		resolved.tokens -= 1
		return true
	end
	return false
end

--- Whole tokens remaining. Used by admin tooling to inspect suspected abuse.
function RateLimiter.remaining(self: RateLimiter, owner: any): number
	local bucket = self._buckets[owner]
	if not bucket then
		return self._capacity
	end
	local elapsed = os.clock() - bucket.updated
	return math.floor(math.min(self._capacity, bucket.tokens + elapsed * self._refill))
end

function RateLimiter.reset(self: RateLimiter, owner: any)
	self._buckets[owner] = nil
end

function RateLimiter.clear(self: RateLimiter)
	table.clear(self._buckets)
end

return RateLimiter
