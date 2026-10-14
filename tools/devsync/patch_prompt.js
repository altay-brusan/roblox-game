const fs = require("fs");
const f = "server/Services/PurchaseService.luau";
let s = fs.readFileSync(f, "utf8");
function rep(a, b) { if (!s.includes(a)) throw new Error("missing " + a.slice(0, 60)); s = s.replace(a, b); }
rep(`	if def.id <= 0 then
		return false, "NOT_CONFIGURED"
	end
	if blockedReason then`, `	if def.offered == false then
		return false, "NOT_OFFERED"
	end
	if def.id <= 0 then
		return false, "NOT_CONFIGURED"
	end
	-- One prompt at a time. A second press while the first prompt is open is
	-- ignored rather than queued, so a double click never opens two prompts.
	local openSince = promptOpen[player.UserId]
	if openSince and os.clock() - openSince < PROMPT_LOCK_SECONDS then
		return false, "PROMPT_OPEN"
	end
	if blockedReason then`);
rep(`	if not ok then
		log.warn(string.format("prompt failed for %s: %s", productKey, tostring(err)))
		return false, "PROMPT_FAILED"
	end
	return true, nil
end`, `	if not ok then
		log.warn(string.format("prompt failed for %s: %s", productKey, tostring(err)))
		return false, "PROMPT_FAILED"
	end
	promptOpen[player.UserId] = os.clock()
	return true, nil
end`);
rep(`--- Opens the Roblox purchase prompt.`, `-- Players with a purchase prompt open, and since when. Cleared when Roblox
-- reports the prompt closed; the time limit covers a close that never arrives.
local promptOpen: { [number]: number } = {}
local PROMPT_LOCK_SECONDS = 20

--- Opens the Roblox purchase prompt.`);
rep(`	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, gamePassId, wasPurchased)
		if wasPurchased then`, `	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, gamePassId, wasPurchased)
		promptOpen[player.UserId] = nil
		if not wasPurchased then
			-- Cancelled or failed. Nothing is granted; the client is told so
			-- the armory can return from its waiting state.
			Net.fireClient("PurchaseResult", player, { ok = false, cancelled = true, gamePassId = gamePassId })
			return
		end
		if wasPurchased then`);
rep(`	DataService.ProfileLoaded:Connect(function(player)
		task.spawn(function()
			PurchaseService.refreshPasses(player)`, `	MarketplaceService.PromptProductPurchaseFinished:Connect(function(userId)
		promptOpen[userId] = nil
	end)
	Players.PlayerRemoving:Connect(function(player)
		promptOpen[player.UserId] = nil
	end)

	DataService.ProfileLoaded:Connect(function(player)
		task.spawn(function()
			PurchaseService.refreshPasses(player)`);
fs.writeFileSync(f, s);
console.log("ok");
