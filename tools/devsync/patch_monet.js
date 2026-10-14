const fs = require("fs");
const f = "shared/Config/Monetization.luau";
let s = fs.readFileSync(f, "utf8");
function rep(a, b) { if (!s.includes(a)) throw new Error("missing " + a.slice(0, 50)); s = s.replace(a, b); }
rep("+25% credits and XP, a reserved cab seat cosmetic, the Signalman lantern skin, and a second daily quest slot.",
    "+25% credits and XP, the Signalman lamp and crew patch, and a second daily quest slot.");
rep("\t-- Sort weight inside its shop category.\n\torder: number,\n}",
    "\t-- Sort weight inside its shop category.\n\torder: number,\n\t-- False takes a product off sale: hidden in the shop and never prompted.\n\t-- Used for a product whose benefit is not finished in the game, because\n\t-- selling something that does not exist is not an option.\n\toffered: boolean?,\n}");
// Permanent cosmetic unlocks are Game Passes, not Developer Products.
for (const key of ["livery_ember", "livery_permafrost", "livery_nightpost", "lantern_kit", "tool_finishes", "crew_outfits"]) {
  const re = new RegExp('(key = "' + key + '",\n\t\tkind = )"developerproduct"');
  if (!re.test(s)) throw new Error("kind " + key);
  s = s.replace(re, '$1"gamepass"');
}
rep('name = "Crew Wardrobe",', 'name = "Crew Wardrobe",\n\t\t-- Outfits are not drawn on characters yet. Off sale until they are.\n\t\toffered = false,');
fs.writeFileSync(f, s);
console.log("ok");
