// Dev-only sync server for Last Signal.
// Serves LastSignal/src as a flat list of scripts mapped to their Rojo instance
// paths, so a Studio session can pull edits without rebuilding the place file.
//   node server.js [port]
// GET /manifest -> [{ path, className, hash }]
// GET /source?path=... -> raw source text
const http = require("http");
const fs = require("fs");
const path = require("path");
const crypto = require("crypto");

const SRC = path.resolve(__dirname, "../../LastSignal/src");
const PORT = Number(process.argv[2] || 34900);

// Mirrors LastSignal/default.project.json.
const ROOTS = [
	{ dir: "shared", mount: ["ReplicatedStorage", "LastSignal"], rootClass: "Folder" },
	{ dir: "server", mount: ["ServerScriptService", "LastSignalServer"], rootClass: "Script" },
	{ dir: "client", mount: ["StarterPlayer", "StarterPlayerScripts", "LastSignalClient"], rootClass: "LocalScript" },
];

function classify(file) {
	if (file.endsWith(".server.luau")) return ["Script", file.slice(0, -".server.luau".length)];
	if (file.endsWith(".client.luau")) return ["LocalScript", file.slice(0, -".client.luau".length)];
	if (file.endsWith(".luau")) return ["ModuleScript", file.slice(0, -".luau".length)];
	return null;
}

function collect() {
	const out = [];
	for (const root of ROOTS) {
		const walk = (dirAbs, segs) => {
			for (const name of fs.readdirSync(dirAbs).sort()) {
				const abs = path.join(dirAbs, name);
				if (fs.statSync(abs).isDirectory()) {
					walk(abs, segs.concat([name]));
					continue;
				}
				const c = classify(name);
				if (!c) continue;
				let [className, base] = c;
				let instPath = root.mount.concat(segs);
				if (base === "init") className = root.rootClass;
				else instPath = instPath.concat([base]);
				const source = fs.readFileSync(abs, "utf8");
				out.push({
					path: instPath.join("/"),
					className,
					file: path.relative(SRC, abs).replace(/\\/g, "/"),
					hash: crypto.createHash("sha1").update(source).digest("hex").slice(0, 12),
				});
			}
		};
		walk(path.join(SRC, root.dir), []);
	}
	out.push({
		path: "ReplicatedFirst/LoadingScreen",
		className: "LocalScript",
		file: "replicatedfirst/LoadingScreen.client.luau",
		hash: crypto
			.createHash("sha1")
			.update(fs.readFileSync(path.join(SRC, "replicatedfirst/LoadingScreen.client.luau"), "utf8"))
			.digest("hex")
			.slice(0, 12),
	});
	return out;
}

http
	.createServer((req, res) => {
		const url = new URL(req.url, "http://localhost");
		try {
			if (url.pathname === "/manifest") {
				res.writeHead(200, { "Content-Type": "application/json" });
				res.end(JSON.stringify(collect()));
			} else if (url.pathname === "/dev") {
				// Dev-only helpers kept beside this server (for example harness.luau).
				const name = path.basename(url.searchParams.get("name") || "");
				res.writeHead(200, { "Content-Type": "text/plain; charset=utf-8" });
				res.end(fs.readFileSync(path.join(__dirname, name), "utf8"));
			} else if (url.pathname === "/source") {
				const entry = collect().find((e) => e.path === url.searchParams.get("path"));
				if (!entry) throw new Error("unknown path");
				res.writeHead(200, { "Content-Type": "text/plain; charset=utf-8" });
				res.end(fs.readFileSync(path.join(SRC, entry.file), "utf8"));
			} else {
				res.writeHead(404);
				res.end();
			}
		} catch (err) {
			res.writeHead(500);
			res.end(String(err));
		}
	})
	.listen(PORT, "127.0.0.1", () => console.log("devsync on " + PORT));
