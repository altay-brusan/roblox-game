--!strict
--[[
	Protect
	-------
	A typed pcall.

	Luau types pcall as returning only the success flag when the callee is
	declared to return nothing, which discards the error message. Every service
	in this project wants the (ok, err) pair, so the cast lives here once
	instead of being repeated in every file that needs it.

	Behaviour is exactly pcall's; this is a typing convenience, not a wrapper
	with its own semantics.
]]

local Protect = {}

Protect.call = (pcall :: any) :: (fn: (...any) -> ...any, ...any) -> (boolean, any)

--- Runs `fn` and logs a failure through `onError` instead of propagating it.
--- Used where a failure must never abort a loop, such as per-player ticks.
function Protect.tryOr(fn: (...any) -> ...any, onError: (string) -> (), ...: any): boolean
	local ok, err = Protect.call(fn, ...)
	if not ok then
		onError(tostring(err))
	end
	return ok
end

return Protect
