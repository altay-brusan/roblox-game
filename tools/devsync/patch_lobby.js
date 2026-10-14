const fs = require("fs");
let f = "server/World/LobbyBuilder.luau";
let s = fs.readFileSync(f, "utf8");
function rep(a, b) { if (!s.includes(a)) throw new Error("missing " + a.slice(0, 60)); s = s.replace(a, b); }
const frag = fs.readFileSync("../../tools/devsync/frag_armory_build.luau", "utf8");
rep("--------------------------------------------------------------------------\n-- Platform 1\n", frag + "--------------------------------------------------------------------------\n-- Platform 1\n");
rep("local BuildKit = require(script.Parent.BuildKit)", "local BuildKit = require(script.Parent.BuildKit)\nlocal ReplicatedStorage = game:GetService(\"ReplicatedStorage\")\nlocal WeaponModels = require(ReplicatedStorage.LastSignal.Registry.WeaponModels)\nlocal WeaponRegistry = require(ReplicatedStorage.LastSignal.Registry.WeaponRegistry)");
rep("\tlocal storesCounter = buildStoresHut(originCF * CFrame.new(74, 0, 60) * CFrame.Angles(0, math.rad(-90), 0), model, lights)",
    "\tlocal storesCounter = buildStoresHut(originCF * CFrame.new(74, 0, 60) * CFrame.Angles(0, math.rad(-90), 0), model, lights)\n\t-- Facing the same way as the stores hatch, just past the hut's corner.\n\tbuildArmory(originCF * CFrame.new(88, 0, 79) * CFrame.Angles(0, math.rad(-90), 0), model, lights)");
fs.writeFileSync(f, s);

f = "server/Services/InteractionService.luau";
s = fs.readFileSync(f, "utf8");
rep("\t\telseif target:HasTag(\"WorkshopBench\") then\n\t\t\tpanel = \"loadout\"", "\t\telseif target:HasTag(\"WorkshopBench\") then\n\t\t\tpanel = \"loadout\"\n\t\telseif target:HasTag(\"ArmoryRack\") then\n\t\t\tpanel = \"armory\"");
rep("\twire(\"WorkshopBench\", \"Open loadout\", \"Workshop bench\", true)", "\twire(\"WorkshopBench\", \"Open loadout\", \"Workshop bench\", true)\n\twire(\"ArmoryRack\", \"Open armory\", \"Armory\", true)");
fs.writeFileSync(f, s);

f = "client/Controllers/InteractionController.luau";
s = fs.readFileSync(f, "utf8");
rep("\tif instance:HasTag(\"WorkshopBench\") then", "\tif instance:HasTag(\"ArmoryRack\") then\n\t\treturn \"lobby\", \"Open the armory\", \"Premium weapons and the Conductor Collection\"\n\tend\n\tif instance:HasTag(\"WorkshopBench\") then");
fs.writeFileSync(f, s);

f = "client/Controllers/MenuController.luau";
s = fs.readFileSync(f, "utf8");
rep("\tshop = \"Stores\",\n", "\tshop = \"Stores\",\n\tarmory = \"Armory\",\n");
rep("\t\t{ id = \"shop\", label = \"Stores\", detail = \"Liveries, cosmetics and supplies.\" },", "\t\t{ id = \"shop\", label = \"Stores\", detail = \"Liveries, cosmetics and supplies.\" },\n\t\t{ id = \"armory\", label = \"Armory\", detail = \"Inspect and equip weapons, and the passes.\" },");
fs.writeFileSync(f, s);
console.log("ok");
