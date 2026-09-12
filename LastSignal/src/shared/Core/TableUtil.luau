--!strict
--[[
	TableUtil
	---------
	Table helpers used by the data layer, registries and UI. Deliberately small:
	every function here is used by production code in this project.
]]

local TableUtil = {}

--- Deep copy. Cycles are preserved via a seen-map so copying a profile that
--- references shared sub-tables cannot loop forever.
function TableUtil.deepCopy(source: any, _seen: { [any]: any }?): any
	if type(source) ~= "table" then
		return source
	end
	local seen = _seen or {}
	if seen[source] then
		return seen[source]
	end
	local copy = {}
	seen[source] = copy
	for key, value in source do
		copy[TableUtil.deepCopy(key, seen)] = TableUtil.deepCopy(value, seen)
	end
	return copy
end

--- Fills in missing keys from `template` without touching values the player
--- already has. This is how new save fields reach existing players without a
--- migration step, and it never clobbers real progress.
function TableUtil.reconcile(target: { [any]: any }, template: { [any]: any }): { [any]: any }
	local result: { [any]: any } = {}
	for key, templateValue in template do
		local targetValue = target[key]
		if targetValue == nil then
			result[key] = TableUtil.deepCopy(templateValue)
		elseif type(templateValue) == "table" and type(targetValue) == "table" then
			-- Arrays are owned wholesale by the save file; only maps merge.
			if #templateValue > 0 then
				result[key] = targetValue
			else
				result[key] = TableUtil.reconcile(targetValue, templateValue)
			end
		else
			result[key] = targetValue
		end
	end
	-- Preserve keys the template no longer knows about, so a rolled-back build
	-- cannot destroy data written by a newer one.
	for key, value in target do
		if result[key] == nil then
			result[key] = value
		end
	end
	return result
end

function TableUtil.count(t: { [any]: any }): number
	local n = 0
	for _ in t do
		n += 1
	end
	return n
end

function TableUtil.keys(t: { [any]: any }): { any }
	local out = {}
	for key in t do
		table.insert(out, key)
	end
	return out
end

function TableUtil.values(t: { [any]: any }): { any }
	local out = {}
	for _, value in t do
		table.insert(out, value)
	end
	return out
end

function TableUtil.find(list: { any }, predicate: (any, number) -> boolean): (any?, number?)
	for index, value in list do
		if predicate(value, index) then
			return value, index
		end
	end
	return nil, nil
end

function TableUtil.filter(list: { any }, predicate: (any, number) -> boolean): { any }
	local out = {}
	for index, value in list do
		if predicate(value, index) then
			table.insert(out, value)
		end
	end
	return out
end

function TableUtil.map(list: { any }, transform: (any, number) -> any): { any }
	local out = table.create(#list)
	for index, value in list do
		out[index] = transform(value, index)
	end
	return out
end

function TableUtil.shuffle(list: { any }, rng: Random?): { any }
	local random = rng or Random.new()
	local out = table.clone(list)
	for i = #out, 2, -1 do
		local j = random:NextInteger(1, i)
		out[i], out[j] = out[j], out[i]
	end
	return out
end

--- Weighted pick. `weightOf` must return a non-negative number.
function TableUtil.weightedPick(list: { any }, weightOf: (any) -> number, rng: Random?): any?
	local total = 0
	for _, item in list do
		total += math.max(0, weightOf(item))
	end
	if total <= 0 then
		return nil
	end
	local roll = (rng or Random.new()):NextNumber() * total
	for _, item in list do
		roll -= math.max(0, weightOf(item))
		if roll <= 0 then
			return item
		end
	end
	return list[#list]
end

--- Recursively freezes a table. Registries are frozen at load so a bug in one
--- system cannot mutate shared definitions used by every other system.
function TableUtil.deepFreeze(t: any): any
	if type(t) ~= "table" then
		return t
	end
	for _, value in t do
		if type(value) == "table" and not table.isfrozen(value) then
			TableUtil.deepFreeze(value)
		end
	end
	if not table.isfrozen(t) then
		table.freeze(t)
	end
	return t
end

return TableUtil
