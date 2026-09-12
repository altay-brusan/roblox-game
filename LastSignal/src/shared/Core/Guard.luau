--!strict
--[[
	Guard
	-----
	Payload validators for everything crossing the network boundary.

	Remote arguments arrive as arbitrary client data: the type annotations on a
	handler are compile-time only and enforce nothing at runtime. Every server
	handler in this project validates its arguments through Guard before the
	values reach any service.

	Validators return the coerced value on success and nil on failure, so the
	usual call shape is:

		local amount = Guard.integer(rawAmount, 1, 99)
		if not amount then return end
]]

local Guard = {}

--- Numbers only, rejecting NaN and infinity. Clients can send either.
function Guard.number(value: any, min: number?, max: number?): number?
	if type(value) ~= "number" then
		return nil
	end
	if value ~= value or value == math.huge or value == -math.huge then
		return nil
	end
	if min and value < min then
		return nil
	end
	if max and value > max then
		return nil
	end
	return value
end

function Guard.integer(value: any, min: number?, max: number?): number?
	local n = Guard.number(value, min, max)
	if not n or n % 1 ~= 0 then
		return nil
	end
	return n
end

--- Strings with a byte-length cap. The cap matters: an unbounded string from a
--- client can be megabytes and will be echoed into logs or other clients.
function Guard.string(value: any, maxLength: number?): string?
	if type(value) ~= "string" then
		return nil
	end
	if #value > (maxLength or 128) then
		return nil
	end
	return value
end

--- An identifier used as a registry key. Restricted character set so it can
--- never be used to reach outside a table or be injected into UI text.
function Guard.id(value: any): string?
	local str = Guard.string(value, 64)
	if not str or str == "" then
		return nil
	end
	if not string.match(str, "^[%w_%-%.]+$") then
		return nil
	end
	return str
end

function Guard.boolean(value: any): boolean?
	if type(value) ~= "boolean" then
		return nil
	end
	return value
end

--- Membership test against a fixed set of allowed literals.
function Guard.enum(value: any, allowed: { [string]: any } | { string }): string?
	local str = Guard.string(value, 64)
	if not str then
		return nil
	end
	-- Accept both array-of-strings and set-style tables.
	if (allowed :: any)[str] ~= nil then
		return str
	end
	for _, candidate in allowed :: { string } do
		if candidate == str then
			return str
		end
	end
	return nil
end

function Guard.vector3(value: any, maxMagnitude: number?): Vector3?
	if typeof(value) ~= "Vector3" then
		return nil
	end
	local v = value :: Vector3
	local x, y, z = v.X, v.Y, v.Z
	if x ~= x or y ~= y or z ~= z then
		return nil
	end
	if math.abs(x) == math.huge or math.abs(y) == math.huge or math.abs(z) == math.huge then
		return nil
	end
	if maxMagnitude and v.Magnitude > maxMagnitude then
		return nil
	end
	return v
end

--- A unit-ish direction. Clients frequently send slightly denormalised vectors,
--- so this normalises rather than rejecting, but rejects zero and garbage.
function Guard.direction(value: any): Vector3?
	local v = Guard.vector3(value, 1e6)
	if not v or v.Magnitude < 1e-4 then
		return nil
	end
	return v.Unit
end

--- An Instance of an expected class that is still parented to the world. The
--- parent check stops clients passing references to destroyed or client-only
--- objects that the server would otherwise happily act on.
function Guard.instance(value: any, className: string, ancestor: Instance?): Instance?
	if typeof(value) ~= "Instance" then
		return nil
	end
	local inst = value :: Instance
	if not inst:IsA(className) then
		return nil
	end
	if not inst.Parent then
		return nil
	end
	if ancestor and not inst:IsDescendantOf(ancestor) then
		return nil
	end
	return inst
end

--- A plain table with a bounded number of entries, rejecting anything with a
--- metatable. Used for structured commands such as shop or crew payloads.
function Guard.table(value: any, maxEntries: number?): { [any]: any }?
	if type(value) ~= "table" then
		return nil
	end
	if getmetatable(value :: any) ~= nil then
		return nil
	end
	local limit = maxEntries or 32
	local count = 0
	for _ in value do
		count += 1
		if count > limit then
			return nil
		end
	end
	return value
end

--- An array of validated elements. Fails whole if any element fails, which is
--- the safe default: partial acceptance hides malformed payloads.
function Guard.array(value: any, validator: (any) -> any?, maxLength: number?): { any }?
	local t = Guard.table(value, (maxLength or 32) + 1)
	if not t then
		return nil
	end
	local out = {}
	local expected = 0
	for key, element in t do
		if type(key) ~= "number" or key % 1 ~= 0 or key < 1 then
			return nil
		end
		expected += 1
		local checked = validator(element)
		if checked == nil then
			return nil
		end
		out[key] = checked
	end
	if #out ~= expected then
		return nil -- sparse array
	end
	if maxLength and #out > maxLength then
		return nil
	end
	return out
end

--- Distance check used by every proximity-gated interaction. Returns false when
--- either position is missing so a caller cannot accidentally allow the action.
function Guard.withinDistance(a: Vector3?, b: Vector3?, maxDistance: number): boolean
	if not a or not b then
		return false
	end
	return (a - b).Magnitude <= maxDistance
end

--- Convenience for server handlers: resolves a live, alive character root.
function Guard.aliveRoot(player: Player): BasePart?
	local character = player.Character
	if not character or not character.Parent then
		return nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return nil
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return nil
	end
	return root
end

return Guard
