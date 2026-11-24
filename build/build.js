// Vercel build (vercel.json -> buildCommand): writes the deployable site to dist/.
//
// Only the site's own top-level files are published -- migrations/, tests/,
// apps-script/ and dotfiles stay in the repo and are no longer served publicly.
// league.html is published pre-compiled (see compile-league.js).
//
// Run locally with: npm install && npm run build
const fs = require("fs");
const path = require("path");
const Babel = require("@babel/standalone");
const { buildLeague } = require("./compile-league.js");

const root = path.join(__dirname, "..");
const out = path.join(root, "dist");
const PUBLISH = /\.(html|js|css|svg|png|jpe?g|webp|gif|ico|json|webmanifest|txt|xml)$/i;
const SKIP = new Set(["package.json", "package-lock.json", "vercel.json"]);

fs.rmSync(out, { recursive: true, force: true });
fs.mkdirSync(out);

const copied = [];
for (const name of fs.readdirSync(root)) {
  const full = path.join(root, name);
  if (name.startsWith(".") || SKIP.has(name) || !PUBLISH.test(name) || !fs.statSync(full).isFile()) continue;
  fs.copyFileSync(full, path.join(out, name));
  copied.push(name);
}
if (!copied.includes("league.html")) throw new Error("league.html is missing from the build");

const started = Date.now();
const league = buildLeague(fs.readFileSync(path.join(root, "league.html"), "utf8"), Babel);
fs.writeFileSync(path.join(out, "league.html"), league.html);
fs.writeFileSync(path.join(out, league.file), league.js);

console.log("Published " + copied.length + " files: " + copied.join(", "));
console.log("league.html: compiled " + Math.round(league.srcLength / 1024) + " KB of JSX into " + league.file +
  " (" + Math.round(league.js.length / 1024) + " KB) in " + (Date.now() - started) + " ms");
