const s = require("fs").readFileSync("shared/Config/Audio.luau", "utf8");
const re = /\t([a-z_0-9]+) = cue\(\{([\s\S]*?)\}\)/g; let m, out = [];
while ((m = re.exec(s))) { const id = /\bid = (\d+)/.exec(m[2]); if (!id || id[1] === "0") out.push(m[1]); }
console.log(out.length + ": " + out.join(" "));
const one = /\tgun_revolver = cue\(\{[\s\S]*?\}\)/.exec(s); console.log(one ? one[0] : "");
