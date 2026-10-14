const fs = require("fs");
const f = "server/Services/PurchaseService.luau";
let s = fs.readFileSync(f, "utf8");
function rep(a, b) { if (!s.includes(a)) throw new Error("missing " + a.slice(0, 60)); s = s.replace(a, b); }

// Sale state alongside the price.
rep("type PriceEntry = { price: number, name: string, fetchedAt: number, ok: boolean }",
    "type PriceEntry = { price: number, name: string, fetchedAt: number, ok: boolean, onSale: boolean }");
rep("function PurchaseService.getPrice(productKey: string): (number?, string?)",
    "function PurchaseService.getPrice(productKey: string): (number?, string?, boolean?)");
rep("\t\treturn cached.price, cached.name\n", "\t\treturn cached.price, cached.name, cached.onSale\n");
rep(`	if ok and type(info) == "table" and type(info.PriceInRobux) == "number" then
		priceCache[key] = {
			price = info.PriceInRobux,
			name = info.Name or def.name,
			fetchedAt = os.clock(),
			ok = true,
		}
		return info.PriceInRobux, info.Name or def.name
	end`, `	if ok and type(info) == "table" and (type(info.PriceInRobux) == "number" or info.IsForSale == false) then
		-- A pass taken off sale reports IsForSale = false and may have no
		-- price at all. That is a state to show, not a failure.
		local onSale = info.IsForSale ~= false
		local price = if type(info.PriceInRobux) == "number" then info.PriceInRobux else 0
		priceCache[key] = {
			price = price,
			name = info.Name or def.name,
			fetchedAt = os.clock(),
			ok = true,
			onSale = onSale,
		}
		return price, info.Name or def.name, onSale
	end`);
rep("priceCache[key] = { price = 0, name = def.name, fetchedAt = os.clock(), ok = false }",
    "priceCache[key] = { price = 0, name = def.name, fetchedAt = os.clock(), ok = false, onSale = false }");

// Weapons granted by a pass.
rep(`	-- Liveries and interiors named by the product key.`, `	-- Weapons. A weapon pass grants the weapon itself; ammunition and the
	-- current run's loadout follow the normal rules.
	if type(grants.weapons) == "table" then
		for _, id in grants.weapons do
			if ProgressionService.grantUnlock(player, "weapon", id) then
				summary.weapons = summary.weapons or {}
				table.insert(summary.weapons, id)
			end
		end
	end

	-- Liveries and interiors named by the product key.`);
fs.writeFileSync(f, s);
console.log("ok");
