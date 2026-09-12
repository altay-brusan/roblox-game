--!strict
--[[
	Logger
	------
	Prefixed, level-filtered logging. Every service creates its own scope so
	output reads "[LAST SIGNAL][DataService] ..." and can be filtered in the
	Studio output window or in live server logs.
]]

local RunService = game:GetService("RunService")

local Logger = {}

export type Level = "debug" | "info" | "warn" | "error"

local LEVEL_ORDER: { [string]: number } = {
	debug = 10,
	info = 20,
	warn = 30,
	error = 40,
}

-- Studio shows debug output; live servers stay at info so logs stay readable.
local minimumLevel: number = if RunService:IsStudio() then LEVEL_ORDER.debug else LEVEL_ORDER.info

function Logger.setMinimumLevel(level: Level)
	minimumLevel = LEVEL_ORDER[level] or LEVEL_ORDER.info
end

export type Scope = {
	debug: (...any) -> (),
	info: (...any) -> (),
	warn: (...any) -> (),
	error: (...any) -> (),
	scope: (string) -> Scope,
}

local function format(prefix: string, ...: any): string
	local count = select("#", ...)
	local parts = table.create(count)
	for index = 1, count do
		local value = select(index, ...)
		if type(value) == "table" then
			parts[index] = "<table>"
		else
			parts[index] = tostring(value)
		end
	end
	return prefix .. " " .. table.concat(parts, " ")
end

function Logger.new(name: string): Scope
	local prefix = string.format("[LAST SIGNAL][%s]", name)
	local scope: Scope = {
		debug = function(...)
			if minimumLevel <= LEVEL_ORDER.debug then
				print(format(prefix, ...))
			end
		end,
		info = function(...)
			if minimumLevel <= LEVEL_ORDER.info then
				print(format(prefix, ...))
			end
		end,
		warn = function(...)
			if minimumLevel <= LEVEL_ORDER.warn then
				warn(format(prefix, ...))
			end
		end,
		error = function(...)
			-- Never raises: logging must not be able to abort its caller.
			warn(format(prefix .. "[ERROR]", ...))
		end,
		scope = function(child: string): Scope
			return Logger.new(name .. "/" .. child)
		end,
	}
	return scope
end

return Logger
