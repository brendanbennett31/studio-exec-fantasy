// Pre-compiles league.html's in-browser JSX at deploy time.
//
// league.html is written as one <script type="text/babel"> block that Babel
// compiled in every visitor's browser on every load (a ~395 KB download plus
// ~0.3 s of compiling on a fast laptop, much longer on phones). This does the
// same compile once at deploy and swaps the block for a plain, cacheable script.
// The source file is untouched, so local development keeps working as before.
//
// The Babel options mirror exactly what @babel/standalone 7.23.9 uses for a
// text/babel script tag (presets react + env, the same three plugins), so the
// deployed code behaves the same as the in-browser compile -- just without the
// inline source map and comments.
//
// Plain ES5-compatible JS with no require(): build/build.js runs it under Node
// at deploy, and the same file can be run anywhere a Babel object is available.
function buildLeague(html, Babel) {
  var open = '<script type="text/babel">';
  var a = html.indexOf(open);
  if (a < 0) throw new Error("league.html: no <script type=\"text/babel\"> block found");
  var b = html.indexOf("</script>", a);
  if (b < 0) throw new Error("league.html: the text/babel block is never closed");
  if (html.indexOf(open, b) >= 0) throw new Error("league.html: more than one text/babel block -- the build only handles one");
  var src = html.slice(a + open.length, b);

  var code = Babel.transform(src, {
    filename: "league.jsx",
    presets: ["react", "env"],
    plugins: ["transform-class-properties", "transform-object-rest-spread", "transform-flow-strip-types"],
    comments: false,
    compact: true
  }).code;

  // short content hash -> a new file name whenever the code changes, so the
  // script can be cached forever (vercel.json) without ever serving a stale one
  var h = 2166136261;
  for (var i = 0; i < code.length; i++) { h ^= code.charCodeAt(i); h = Math.imul(h, 16777619) >>> 0; }
  var file = "league.app." + ("0000000" + h.toString(16)).slice(-8) + ".js";

  var out = html.slice(0, a) + '<script defer src="/' + file + '"></script>' + html.slice(b + "</script>".length);

  var babelTag = /<script[^>]*src="[^"]*babel-standalone[^"]*"[^>]*><\/script>\s*\n?/;
  if (!babelTag.test(out)) throw new Error("league.html: couldn't find the babel-standalone script tag to remove");
  out = out.replace(babelTag, "");

  // React, ReactDOM and supabase-js stop blocking the page parse; defer keeps
  // them running in order, before the app script.
  out = out.replace(/<script src="(https:\/\/cdn[^"]+)"><\/script>/g, '<script defer src="$1"></script>');

  return { html: out, js: code, file: file, srcLength: src.length };
}

if (typeof module !== "undefined" && module.exports) module.exports = { buildLeague: buildLeague };
