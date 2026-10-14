const fs = require("fs");
const f = "server/Services/ShopService.luau";
let s = fs.readFileSync(f, "utf8");
function rep(a, b) { if (!s.includes(a)) throw new Error("missing " + a.slice(0, 60)); s = s.replace(a, b); }
rep(`	for _, def in Monetization.All do
		local owned = def.permanent and PurchaseService.ownsProduct(player, def.key)
		local price, liveName = PurchaseService.getPrice(def.key)
`, `	for _, def in Monetization.All do
		if def.offered == false then
			continue
		end
		local owned = def.permanent and PurchaseService.ownsProduct(player, def.key)
		local price, liveName, onSale = PurchaseService.getPrice(def.key)
`);
rep(`		elseif not price then
			purchasable = false
			reason = "Price unavailable. Try again in a moment."
		elseif owned then`, `		elseif owned then
			purchasable = false
			reason = "Owned"
		elseif not price then
			purchasable = false
			reason = "Price unavailable. Try again in a moment."
		elseif onSale == false then
			purchasable = false
			reason = "Not on sale right now."
		elseif owned then`);
rep(`Guard.enum(rawCommand, { "catalogue", "buy_credits", "prompt_robux" })`,
    `Guard.enum(rawCommand, { "catalogue", "buy_credits", "prompt_robux", "refresh_passes" })`);
rep(`		-- prompt_robux
`, `		if command == "refresh_passes" then
			-- The armory's "check again" after a failed ownership check.
			-- Rate limited: each check is several web calls.
			local last = lastPassRefresh[player.UserId]
			if last and os.clock() - last < 15 then
				return { ok = false, error = "WAIT" }
			end
			lastPassRefresh[player.UserId] = os.clock()
			task.spawn(PurchaseService.refreshPasses, player)
			return { ok = true }
		end

		-- prompt_robux
`);
rep(`function ShopService.start()`, `local lastPassRefresh: { [number]: number } = {}

function ShopService.start()`);
fs.writeFileSync(f, s);
console.log("ok");
