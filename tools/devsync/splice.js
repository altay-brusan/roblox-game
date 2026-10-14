// Dev helper: node splice.js <file> <startMarker> <endMarker> <fragmentFile>
// Replaces text from the first occurrence of startMarker (inclusive) up to the
// next occurrence of endMarker (exclusive) with the fragment's contents.
// Markers are literal strings; "\n" and "\t" in them are unescaped.
const fs = require("fs");
const [file, startRaw, endRaw, fragmentFile] = process.argv.slice(2);
const unescape = (s) => s.replace(/\\n/g, "\n").replace(/\\t/g, "\t");
const start = unescape(startRaw);
const end = unescape(endRaw);
let text = fs.readFileSync(file, "utf8");
const a = text.indexOf(start);
if (a < 0) throw new Error("start marker not found: " + start);
const b = text.indexOf(end, a + start.length);
if (b < 0) throw new Error("end marker not found: " + end);
text = text.slice(0, a) + fs.readFileSync(fragmentFile, "utf8") + text.slice(b);
fs.writeFileSync(file, text);
console.log(`spliced ${file}: replaced ${b - a} chars`);
