// Studio Exec Fantasy -- browser error reporting (loaded first, as a plain script, on every page).
// Uncaught errors go to public.client_errors, which is insert-only; the database clamps field
// sizes and silently drops floods. Apps Script emails the site admin when new ones appear.
// Also catches a page that never renders (a JSX compile error or a crash before first paint).
(function () {
  var URL = "https://fymkwkbatklfynnhxrsf.supabase.co";
  var KEY = "sb_publishable_HOd_kJ4JcmD2srkGPyjEPA_2LIzKFxG";
  var sent = 0, seen = {};
  var IGNORE = /ResizeObserver loop|^Script error\.?$|extension:\/\/|Load failed|NetworkError|Failed to fetch|AbortError|The operation was aborted/i;

  function report(message, detail) {
    try {
      var m = String(message || "").slice(0, 500);
      if (!m || IGNORE.test(m) || IGNORE.test(String(detail || "")) || seen[m] || sent >= 5) return;
      seen[m] = 1; sent++;
      var token = null;
      try { token = (JSON.parse(localStorage.getItem("sef_session") || "null") || {}).access_token || null; } catch (e) {}
      var lid = new URLSearchParams(location.search).get("id");
      fetch(URL + "/rest/v1/client_errors", {
        method: "POST", keepalive: true,
        headers: { apikey: KEY, Authorization: "Bearer " + (token || KEY), "Content-Type": "application/json", Prefer: "return=minimal" },
        body: JSON.stringify({
          page: location.pathname, message: m, detail: String(detail || "").slice(0, 2000),
          league_id: /^[0-9a-f-]{36}$/i.test(lid || "") ? lid : null, user_agent: navigator.userAgent.slice(0, 200)
        })
      }).catch(function () {});
    } catch (e) {}
  }

  window.addEventListener("error", function (e) {
    report(e.message, (e.error && e.error.stack) || (e.filename + ":" + e.lineno));
  });
  window.addEventListener("unhandledrejection", function (e) {
    var r = e.reason;
    report("Unhandled: " + ((r && r.message) || r), r && r.stack);
  });
  window.sefReportError = report;

  // React pages render into #root. If the libraries loaded but #root is still empty after
  // 12s, the page is broken for this visitor (most often a JSX compile error after a deploy).
  window.addEventListener("load", function () {
    setTimeout(function () {
      var root = document.getElementById("root");
      if (root && !root.children.length && window.React && window.Babel) {
        report("Page did not render", "root still empty 12s after load on " + location.pathname);
      }
    }, 12000);
  });
})();
