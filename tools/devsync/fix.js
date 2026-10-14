const fs = require("fs");
const f = "../../tools/devsync/patch_prompt.js";
let s = fs.readFileSync(f, "utf8");
s = s.replace("rep(`\tMarketplaceService.PromptProductPurchaseFinished`, `\tMarketplaceService.PromptProductPurchaseFinished`);",
"rep(`\tDataService.ProfileLoaded:Connect(function(player)\n\t\ttask.spawn(function()\n\t\t\tPurchaseService.refreshPasses(player)`, `\tMarketplaceService.PromptProductPurchaseFinished:Connect(function(userId)\n\t\tpromptOpen[userId] = nil\n\tend)\n\tPlayers.PlayerRemoving:Connect(function(player)\n\t\tpromptOpen[player.UserId] = nil\n\tend)\n\n\tDataService.ProfileLoaded:Connect(function(player)\n\t\ttask.spawn(function()\n\t\t\tPurchaseService.refreshPasses(player)`);");
fs.writeFileSync(f, s);
