// ============================================================================
// HEALTH -- immediate alert emails + end-of-season finalize.
//
// Every scheduled job runs through job(), which emails the admin the moment a job throws
// or logs a failure line. checkHealth() (every 10 minutes) emails when players' browsers
// report new errors (public.client_errors), when the box office or weekly snapshots stop
// updating, or when next season hasn't been added to the seasons table yet.
// finalizeSeasons() (daily) crowns every league once a season's Oscar results are marked
// final on the Universe page -> Seasons & Oscars.
//
// Alerts are rate-limited per kind (ALERT_COOLDOWN_HOURS) so one bad night is one email,
// not two hundred. Uses UF_ADMIN_EMAIL (UniverseFilmsScraper.gs); blank = the script owner.
// ============================================================================

var ALERT_COOLDOWN_HOURS = 6;
// Lines in a job's execution log that mean "something went wrong".
var FAILURE_LINE = /(FAILED|failed|HTTP [45]\d\d|Error:|exception|refusing|invariant)/;

function hAdminEmail() { return UF_ADMIN_EMAIL || Session.getEffectiveUser().getEmail(); }

// Email once per `key` per cooldown window. Returns true when sent.
function sefAlert(key, subject, lines) {
  var props = PropertiesService.getScriptProperties();
  var stamp = "ALERT_" + key.replace(/[^A-Za-z0-9_]/g, "_").slice(0, 80);
  var last = Number(props.getProperty(stamp) || 0);
  if (Date.now() - last < ALERT_COOLDOWN_HOURS * 3600 * 1000) {
    Logger.log("(alert '" + key + "' suppressed -- sent within the last " + ALERT_COOLDOWN_HOURS + "h)");
    return false;
  }
  props.setProperty(stamp, String(Date.now()));
  var body = (Array.isArray(lines) ? lines : [String(lines)]).join("\n");
  var html = '<div style="font-family:-apple-system,Helvetica,Arial,sans-serif;font-size:14px;color:#1d1d1f">'
    + '<div style="font-size:12px;letter-spacing:.12em;text-transform:uppercase;color:#b45309;font-weight:700">Studio Exec Fantasy alert</div>'
    + '<h2 style="font-size:18px;margin:6px 0 12px">' + ufEsc(subject) + '</h2>'
    + '<pre style="white-space:pre-wrap;background:#f5f5f7;border-radius:8px;padding:12px;font-size:12px">' + ufEsc(body.slice(0, 8000)) + '</pre>'
    + '<p style="font-size:12px;color:#6e6e73">Further "' + ufEsc(key) + '" alerts are paused for ' + ALERT_COOLDOWN_HOURS + ' hours. '
    + 'Open the Apps Script project &rarr; Executions for the full log.</p></div>';
  MailApp.sendEmail({ to: hAdminEmail(), subject: "[SEF] " + subject, body: body, htmlBody: html });
  return true;
}

// Runs one scheduled job and alerts on a crash or on failure lines in its log.
function job(name, fn) {
  var started = Date.now();
  try {
    fn();
  } catch (e) {
    Logger.log("CRASHED: " + e + "\n" + (e && e.stack || ""));
    sefAlert("job_" + name, name + " crashed", [String(e), "", (e && e.stack) || ""]);
    return;
  }
  // One flaky request (a single film's page timing out) isn't worth an email: alert on an explicit
  // FAILED (the job gave up), or on 3+ problem lines in one run.
  var bad = Logger.getLog().split("\n").filter(function(l) {
    return FAILURE_LINE.test(l) && !/suppressed|retrying/.test(l);
  });
  if (bad.some(function(l) { return /FAILED/.test(l); }) || bad.length >= 3) {
    sefAlert("job_" + name, name + " reported " + bad.length + " problem line(s)", bad.slice(0, 40));
  }
  Logger.log(name + " finished in " + Math.round((Date.now() - started) / 1000) + "s");
}

// ── trigger entry points (TRIGGER_PLAN in Triggers.gs points at these) ─────────
function runScrapeUniverseFilms()        { job("scrapeUniverseFilms", scrapeUniverseFilms); }
function runScrapeUniverseBoxOffice()    { job("scrapeUniverseBoxOffice", scrapeUniverseBoxOffice); }
function runScrapeDailyBoxOffice()       { job("scrapeDailyBoxOffice", scrapeDailyBoxOffice); }
function runSnapshotWeeklyBOAndPOI()     { job("snapshotWeeklyBOAndPOI", snapshotWeeklyBOAndPOI); }
function runEnsureAcquisitionWeek()      { job("ensureAcquisitionWeek", ensureAcquisitionWeek); }
function runResolveDueAcquisitionWeeks() { job("resolveDueAcquisitionWeeks", resolveDueAcquisitionWeeks); }
function runNotifyReleaseDayFilms()      { job("notifyReleaseDayFilms", notifyReleaseDayFilms); }
function runCheckNewLeaders()            { job("checkNewLeaders", checkNewLeaders); }
function runResolveWeekendPicks()        { job("resolveWeekendPicks", resolveWeekendPicks); }
function runScrapeGoldDerbyCombinedOdds() { job("scrapeGoldDerbyCombinedOdds", scrapeGoldDerbyCombinedOdds); }
function runProcessFilmRequests()        { job("processFilmRequests", processFilmRequests); }
function runFinalizeSeasons()            { job("finalizeSeasons", finalizeSeasons); }
function runCheckHealth()                { job("checkHealth", checkHealth); }

// ── end of season ────────────────────────────────────────────────────────────
// For every season whose Oscar results are marked final but which isn't finalized yet,
// freeze every league (finalize_season waits on its own until Oscar Sunday has passed).
function finalizeSeasons() {
  var seasons = ufGetAll("seasons?results_final=eq.true&finalized_at=is.null&select=season");
  if (!seasons) { Logger.log("FAILED to read seasons"); return; }
  if (!seasons.length) { Logger.log("No season waiting to be finalized."); return; }
  seasons.forEach(function(s) {
    var r = ufCallRpc("finalize_season", { p_season: s.season });
    if (r.code >= 300) { Logger.log("finalize_season(" + s.season + ") FAILED: HTTP " + r.code + " " + r.body.slice(0, 300)); return; }
    var out = JSON.parse(r.body);
    Logger.log("Season " + s.season + ": " + out.status + (out.reason ? " (" + out.reason + ")" : ""));
    if (out.status === "finalized") {
      var lines = (out.leagues || []).map(function(l) { return "  " + l.league + " -- winner: " + (l.winner || "?"); });
      MailApp.sendEmail({ to: hAdminEmail(), subject: "[SEF] " + s.season + " season finalized: " + (out.leagues || []).length + " league(s) crowned",
        body: "Every " + s.season + " league is final and its Wrapped page is live.\n\n" + lines.join("\n") });
    }
  });
}

// ── health checks (every 10 minutes) ─────────────────────────────────────────
function checkHealth() {
  var props = PropertiesService.getScriptProperties();

  // 1. new browser errors since the last check
  var since = props.getProperty("HEALTH_ERRORS_SINCE") || new Date(Date.now() - 3600 * 1000).toISOString();
  var errs = ufGetAll("client_errors?created_at=gt." + encodeURIComponent(since) + "&select=created_at,page,message,league_id,user_agent&order=created_at.asc");
  if (errs === null) {
    Logger.log("FAILED to read client_errors");
  } else if (errs.length) {
    props.setProperty("HEALTH_ERRORS_SINCE", errs[errs.length - 1].created_at);
    var groups = {};
    errs.forEach(function(e) {
      var k = (e.page || "?") + " :: " + (e.message || "").slice(0, 160);
      var g = groups[k] || (groups[k] = { n: 0, leagues: {}, ua: e.user_agent });
      g.n++; if (e.league_id) g.leagues[e.league_id] = 1;
    });
    var keys = Object.keys(groups).sort(function(a, b) { return groups[b].n - groups[a].n; });
    var lines = keys.slice(0, 25).map(function(k) {
      var g = groups[k];
      return g.n + "x  " + k + "\n     leagues: " + (Object.keys(g.leagues).length || "none") + " · e.g. " + (g.ua || "").slice(0, 90);
    });
    // Different error messages get their own cooldown key, so a NEW problem always emails.
    sefAlert("client_" + Utilities.base64EncodeWebSafe(Utilities.computeDigest(Utilities.DigestAlgorithm.MD5, keys.slice(0, 5).join("|"))).slice(0, 12),
      errs.length + " new error report(s) from players' browsers", lines);
  } else {
    props.setProperty("HEALTH_ERRORS_SINCE", new Date().toISOString());
  }

  // The checks below only need to run about once an hour.
  var lastSlow = Number(props.getProperty("HEALTH_SLOW_LAST") || 0);
  if (Date.now() - lastSlow < 55 * 60 * 1000) return;
  props.setProperty("HEALTH_SLOW_LAST", String(Date.now()));
  var today = boToday();

  // 2. box office scraper still running? (it stamps last_check_date on every film it checks)
  var fresh = ufGetAll("universe_films?select=last_check_date&last_check_date=not.is.null&order=last_check_date.desc&limit=1");
  if (fresh && fresh.length && boDaysBetween(fresh[0].last_check_date, today) > 2) {
    sefAlert("stale_box_office", "Box office hasn't updated in " + boDaysBetween(fresh[0].last_check_date, today) + " days",
      ["Newest last_check_date in universe_films: " + fresh[0].last_check_date, "Check the scrapeUniverseBoxOffice executions and its trigger."]);
  }

  // 3. weekly snapshots still being written?
  var snap = ufGetAll("weekly_bo_snapshots?select=snapshot_date&order=snapshot_date.desc&limit=1");
  if (snap && snap.length && boDaysBetween(snap[0].snapshot_date, today) > 9) {
    sefAlert("stale_snapshots", "Weekly standings snapshots stopped (" + snap[0].snapshot_date + ")",
      ["The Trends charts and Wrapped race need snapshotWeeklyBOAndPOI to run daily.", "Check its trigger and recent executions."]);
  }

  // 4. is next season set up? Needed before anyone can create a league for it.
  var seasons = ufGetAll("seasons?select=season,window_start,oscar_date&order=season.asc");
  if (seasons && seasons.length) {
    var upcoming = seasons.filter(function(s) { return s.window_start > today; });
    var last = seasons[seasons.length - 1];
    if (!upcoming.length) {
      sefAlert("next_season_missing", "Add the next season (" + (Number(last.season) + 1) + ")",
        ["New leagues can only be created for a season that hasn't started yet, and the newest one (" + last.season + ") already has.",
         "Universe page -> Seasons & Oscars -> Add the next season: the year, the day after this season's Oscars, and next Oscar Sunday."]);
    }
  }

  // 5. Oscar Sunday passed but results never marked final -> leagues can't finish
  if (seasons) {
    seasons.forEach(function(s) {
      if (s.oscar_date && boDaysBetween(s.oscar_date, today) >= 2) {
        var row = ufGetAll("seasons?season=eq." + s.season + "&select=results_final,finalized_at");
        if (row && row.length && !row[0].finalized_at && !row[0].results_final) {
          sefAlert("results_not_final_" + s.season, s.season + " Oscars were " + boDaysBetween(s.oscar_date, today) + " days ago -- results aren't marked final",
            ["Every " + s.season + " league is waiting on this to crown a winner.", "Universe page -> Seasons & Oscars: enter the winners, then tick 'Oscar results are final'."]);
        }
      }
    });
  }
}

// Run by hand to check email works (bypasses the cooldown).
function sendTestAlert() {
  PropertiesService.getScriptProperties().deleteProperty("ALERT_test");
  sefAlert("test", "Test alert", ["If you can read this, SEF alert emails work."]);
}
