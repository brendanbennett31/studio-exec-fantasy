// ============================================================
//  TRIGGERS + SETUP -- the ONE place schedules are defined
// ============================================================
// Edit TRIGGER_PLAN, then run syncTriggers(). It deletes every trigger owned by
// whoever runs it and recreates exactly this list, so re-running is always safe and
// duplicates can't build up. (Apps Script can't see or delete triggers owned by
// another collaborator -- those show as "Other user" in the Triggers panel and
// have to be deleted by that person, or by removing their access to the project.)
//
// Times are in the project's time zone (Project Settings -> Time zone; Pacific).

var TRIGGER_PLAN = [
  // Every job runs through Health.gs's job() wrapper (the run* names), which emails the admin
  // the moment a job crashes or reports failures.
  { fn: "runScrapeUniverseFilms",         hours: [8]  },   // new/changed films from TMDb
  { fn: "runScrapeUniverseBoxOffice",     hours: [9, 18] },// totals + opening weekend (morning actuals, evening catch-up)
  { fn: "runScrapeDailyBoxOffice",        hours: [10] },   // day-by-day grosses for the Trends charts
  { fn: "runSnapshotWeeklyBOAndPOI",      hours: [11] },   // weekly team snapshots, every active league
  { fn: "runEnsureAcquisitionWeek",       hours: [8]  },   // open this week's acquisition window
  { fn: "runResolveDueAcquisitionWeeks",  hours: [1]  },   // resolve bids after the Wednesday deadline
  { fn: "runNotifyReleaseDayFilms",       hours: [8]  },   // "your film opens today" notifications
  { fn: "runCheckNewLeaders",             hours: [19] },   // "new leader" notifications (after the evening box office run)
  { fn: "runResolveWeekendPicks",         hours: [7, 19, 22] }, // Weekend Picks results (no-op unless a weekend is due)
  { fn: "runScrapeGoldDerbyCombinedOdds", hours: [18] },   // Awards odds + missing-film check
  { fn: "runFinalizeSeasons",             hours: [6]  },   // crown every league once a season's Oscar results are final
  { fn: "runProcessFilmRequests",         everyMinutes: 10 }, // player "add a film" requests -> email
  { fn: "runCheckHealth",                 everyMinutes: 10 }  // browser errors, stalled jobs, next-season setup -> email
];

function syncTriggers() {
  var removed = [];
  ScriptApp.getProjectTriggers().forEach(function(t) {
    removed.push(t.getHandlerFunction());
    ScriptApp.deleteTrigger(t);
  });
  Logger.log("Removed " + removed.length + " existing trigger(s): " + removed.join(", "));

  var created = 0;
  TRIGGER_PLAN.forEach(function(p) {
    if (p.everyMinutes) {
      ScriptApp.newTrigger(p.fn).timeBased().everyMinutes(p.everyMinutes).create();
      created++;
    } else {
      p.hours.forEach(function(h) { ScriptApp.newTrigger(p.fn).timeBased().everyDays(1).atHour(h).create(); created++; });
    }
  });
  Logger.log("Created " + created + " trigger(s) for " + TRIGGER_PLAN.length + " jobs.");
  Logger.log("If the Triggers panel still lists entries owned by \"Other user\", delete those there (or ask that person to).");
}

function listTriggers() {
  var ts = ScriptApp.getProjectTriggers();
  var counts = {};
  ts.forEach(function(t) { counts[t.getHandlerFunction()] = (counts[t.getHandlerFunction()] || 0) + 1; });
  Logger.log(ts.length + " trigger(s) owned by you:");
  Object.keys(counts).sort().forEach(function(k) { Logger.log("  " + k + " x" + counts[k]); });
  var planned = {};
  TRIGGER_PLAN.forEach(function(p) { planned[p.fn] = p.everyMinutes ? 1 : p.hours.length; });
  Object.keys(planned).forEach(function(k) { if ((counts[k] || 0) !== planned[k]) Logger.log("  MISMATCH: " + k + " has " + (counts[k] || 0) + ", plan says " + planned[k]); });
  Object.keys(counts).forEach(function(k) { if (!(k in planned)) Logger.log("  NOT IN PLAN: " + k + " (run syncTriggers to remove it)"); });
}

// Run this after pasting the code / changing keys: confirms every secret is set and works.
function checkSetup() {
  var ok = true;
  function check(label, pass, detail) { Logger.log((pass ? "OK    " : "FIX   ") + label + (detail ? " -- " + detail : "")); if (!pass) ok = false; }

  check("Script property SUPABASE_SERVICE_KEY", !!UF_SUPABASE_KEY, UF_SUPABASE_KEY ? "" : "add it in Project Settings -> Script properties");
  check("Script property TMDB_API_KEY", !!TMDB_API_KEY, TMDB_API_KEY ? "" : "add it in Project Settings -> Script properties");
  if (UF_SUPABASE_KEY) {
    var r = UrlFetchApp.fetch(UF_SUPABASE_URL + "/rest/v1/universe_films?select=id&limit=1",
      { muteHttpExceptions: true, headers: { apikey: UF_SUPABASE_KEY, Authorization: "Bearer " + UF_SUPABASE_KEY } });
    check("Supabase accepts the service key", r.getResponseCode() === 200, "HTTP " + r.getResponseCode());
  }
  if (TMDB_API_KEY) {
    var t = UrlFetchApp.fetch("https://api.themoviedb.org/3/configuration?api_key=" + TMDB_API_KEY, { muteHttpExceptions: true });
    check("TMDb accepts the API key", t.getResponseCode() === 200, "HTTP " + t.getResponseCode());
  }
  check("Time zone is America/Los_Angeles", Session.getScriptTimeZone() === "America/Los_Angeles", Session.getScriptTimeZone());
  var url = "";
  try { url = ScriptApp.getService().getUrl() || ""; } catch (e) { url = ""; }
  check("Web app deployed (email approval buttons)", !!url, url ? "" : "Deploy -> New deployment -> Web app");
  Logger.log(ok ? "ALL GOOD" : "Fix the FIX lines above, then run checkSetup again.");
}

function onOpen() {
  try {
    SpreadsheetApp.getUi().createMenu("Studio Exec")
      .addItem("Check setup", "checkSetup")
      .addItem("List triggers", "listTriggers")
      .addItem("Rebuild all triggers", "syncTriggers")
      .addItem("Send a test alert email", "sendTestAlert")
      .addItem("Finalize finished seasons now", "finalizeSeasons")
      .addSeparator()
      .addItem("Update universe films now", "scrapeUniverseFilms")
      .addItem("Update box office now", "scrapeUniverseBoxOffice")
      .addItem("Update daily box office now", "scrapeDailyBoxOffice")
      .addItem("Update Gold Derby odds now", "scrapeGoldDerbyCombinedOdds")
      .addToUi();
  } catch (e) { /* standalone project: no spreadsheet UI, nothing to add */ }
}
