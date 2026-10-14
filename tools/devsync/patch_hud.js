const fs = require("fs");
const f = "client/Controllers/HUDController.luau";
let s = fs.readFileSync(f, "utf8");
function rep(a, b) { if (!s.includes(a)) throw new Error("missing " + a.slice(0, 60)); s = s.replace(a, b); }
rep("local function refreshWeapon()", "-- When the last weapon state arrived, for cooling the arc readout locally.\nlocal weaponStampedAt: number? = nil\n\nlocal function refreshWeapon()");
rep("\t\telseif key == \"weapon\" then\n\t\t\trefreshWeapon()", "\t\telseif key == \"weapon\" then\n\t\t\tweaponStampedAt = os.clock()\n\t\t\trefreshWeapon()");
// Keep the heat readout moving between server updates.
rep("local function refreshDowned()", "task.spawn(function()\n\twhile true do\n\t\ttask.wait(0.25)\n\t\tlocal weapon = StateController.get(\"weapon\")\n\t\tif weapon and type(weapon.heat) == \"number\" then\n\t\t\trefreshWeapon()\n\t\tend\n\tend\nend)\n\nlocal function refreshDowned()");
if (!s.includes("local WeaponRegistry = require(")) {
  rep("local Net = require(Shared.Core.Net)", "local Net = require(Shared.Core.Net)\nlocal WeaponRegistry = require(Shared.Registry.WeaponRegistry)");
}
fs.writeFileSync(f, s);
console.log("ok");
