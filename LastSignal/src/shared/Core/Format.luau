--!strict
--[[
	Format
	------
	Display formatting shared by every interface, so the same number never
	appears two different ways in two different panels.
]]

local Format = {}

local SUFFIXES = { "", "K", "M", "B" }

--- Compact number for HUD and shop chips: 1240 -> "1.2K".
function Format.compactNumber(value: number): string
	local n = math.floor(value + 0.5)
	local negative = n < 0
	n = math.abs(n)
	local tier = 1
	while n >= 1000 and tier < #SUFFIXES do
		n /= 1000
		tier += 1
	end
	local text: string
	if tier == 1 then
		text = tostring(math.floor(n))
	elseif n < 10 then
		text = string.format("%.1f", n)
	else
		text = string.format("%d", math.floor(n))
	end
	return (if negative then "-" else "") .. text .. SUFFIXES[tier]
end

--- Grouped number for detail panels: 1240 -> "1,240".
function Format.groupedNumber(value: number): string
	local n = math.floor(math.abs(value) + 0.5)
	local text = tostring(n)
	local grouped = ""
	local count = 0
	for index = #text, 1, -1 do
		grouped = string.sub(text, index, index) .. grouped
		count += 1
		if count % 3 == 0 and index > 1 then
			grouped = "," .. grouped
		end
	end
	return (if value < 0 then "-" else "") .. grouped
end

--- Clock for timers: 95 -> "1:35". Negative input clamps to zero so an expired
--- timer never renders as a negative duration.
function Format.clock(seconds: number): string
	local total = math.max(0, math.floor(seconds))
	local minutes = math.floor(total / 60)
	local remainder = total % 60
	if minutes >= 60 then
		local hours = math.floor(minutes / 60)
		return string.format("%d:%02d:%02d", hours, minutes % 60, remainder)
	end
	return string.format("%d:%02d", minutes, remainder)
end

--- Coarse duration for "resets in" labels: 7500 -> "2h 5m".
function Format.duration(seconds: number): string
	local total = math.max(0, math.floor(seconds))
	if total < 60 then
		return string.format("%ds", total)
	end
	local minutes = math.floor(total / 60)
	if minutes < 60 then
		return string.format("%dm", minutes)
	end
	local hours = math.floor(minutes / 60)
	if hours < 24 then
		local rest = minutes % 60
		return if rest > 0 then string.format("%dh %dm", hours, rest) else string.format("%dh", hours)
	end
	local days = math.floor(hours / 24)
	local restHours = hours % 24
	return if restHours > 0 then string.format("%dd %dh", days, restHours) else string.format("%dd", days)
end

--- In-world clock used by the story. The expedition starts at 02:17.
function Format.storyClock(minutesSinceStart: number): string
	local base = 2 * 60 + 17
	local total = (base + math.floor(minutesSinceStart)) % (24 * 60)
	return string.format("%02d:%02d", math.floor(total / 60), total % 60)
end

--- Speed shown on the cab gauge. The project uses studs/second internally and
--- presents km/h, using the common Roblox convention of 1 stud = 0.28 metres.
function Format.speedKph(studsPerSecond: number): string
	local metresPerSecond = studsPerSecond * 0.28
	return string.format("%d", math.floor(metresPerSecond * 3.6 + 0.5))
end

function Format.percent(fraction: number): string
	return string.format("%d%%", math.clamp(math.floor(fraction * 100 + 0.5), 0, 100))
end

--- Robux price label. Zero means "not configured" everywhere in this project,
--- and must never render as a free or purchasable item.
function Format.price(robux: number?): string
	if not robux or robux <= 0 then
		return "Unavailable"
	end
	return Format.groupedNumber(robux) .. " R$"
end

--- Title-cases an identifier for fallback display: "fuel_can" -> "Fuel Can".
function Format.titleFromId(id: string): string
	local spaced = string.gsub(id, "[_%-]", " ")
	-- Luau types the gsub replacement callback as single-capture; this cast
	-- keeps the two-capture form that the runtime supports.
	local capitalise = (function(first: string, rest: string): string
		return string.upper(first) .. string.lower(rest)
	end :: any) :: (string) -> string
	local titled = string.gsub(spaced, "(%a)([%w]*)", capitalise)
	return titled
end

return Format
