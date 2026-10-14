const fs = require("fs");
const f = "shared/Registry/WeaponRegistry.luau";
let s = fs.readFileSync(f, "utf8");
const frag = fs.readFileSync("../../tools/devsync/frag_weapons.luau", "utf8");
const end = "\t\tstartingLoadout = true,\n\t\tunlockLevel = 2,\n\t\tcreditCost = 650,\n\t}),\n}";
if (!s.includes(end)) throw new Error("end marker");
s = s.replace(end, end.slice(0, -1) + frag + "}");
fs.writeFileSync(f, s);
