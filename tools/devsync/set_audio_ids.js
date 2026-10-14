// Dev helper: node set_audio_ids.js <Audio.luau> <cue=id> [cue=id ...]
// Sets the first `id = N` inside each named cue({ ... }) definition.
const fs = require("fs");
const [file, ...pairs] = process.argv.slice(2);
let text = fs.readFileSync(file, "utf8");
for (const pair of pairs) {
	const [name, id] = pair.split("=");
	const re = new RegExp("(\\t" + name + " = cue\\(\\{[\\s\\S]*?id = )\\d+");
	if (!re.test(text)) throw new Error("no cue " + name);
	text = text.replace(re, "$1" + id);
}
fs.writeFileSync(file, text);
console.log("set " + pairs.length + " cue ids");
