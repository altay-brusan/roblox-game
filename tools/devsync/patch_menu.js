const fs = require("fs");
const f = "client/Controllers/MenuController.luau";
let s = fs.readFileSync(f, "utf8");
function rep(a, b) { if (!s.includes(a)) throw new Error("missing " + a.slice(0, 60)); s = s.replace(a, b); }
rep("--------------------------------------------------------------------------\n-- Panel: quests\n", "--------------------------------------------------------------------------\n-- Panel: armory\n--------------------------------------------------------------------------\n\nbuilders.armory = function(frame: Frame)\n\tArmoryPanel.build(frame, function()\n\t\tif rebuild then\n\t\t\trebuild()\n\t\tend\n\tend)\nend\n\n--------------------------------------------------------------------------\n-- Panel: quests\n");
rep("local Widgets = require(script.Parent.Parent.UI.Widgets)", "local Widgets = require(script.Parent.Parent.UI.Widgets)\nlocal ArmoryPanel = require(script.Parent.Parent.UI.ArmoryPanel)");
fs.writeFileSync(f, s);
console.log("ok");
