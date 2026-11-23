// ============================================================
//  BOX OFFICE -- everything that reads Box Office Mojo
// ============================================================
// Replaces the old Code.gs. The Google-Sheet-driven scrapers that lived there
// (updateMasterBoxOfficeSheet, updateOpeningWeekends, the "BY RELEASE DATE" tab,
// the `picks` table) only fed the original single-league page and are gone: every
// real league reads league_picks joined to universe_films, so box office is
// scraped ONCE per real film here and shared by every league.
//
//   scrapeUniverseBoxOffice  total + opening weekend + plateau/lock flag
//   scrapeDailyBoxOffice     day-by-day grosses (Trends charts)
//   snapshotWeeklyBOAndPOI   weekly team snapshots, every league (one RPC)
//
// Both scrapers are built to stay under Apps Script's 6-minute limit as the
// Universe grows: only films that can still change are fetched every run
// (new releases, anything still moving); settled films and films BOM has no
// box office for get a weekly sweep; stalest films go first; and a run stops
// starting new films after BO_TIME_BUDGET_MS and picks up the rest next time.
//
// Needs UniverseFilmsScraper.gs (ufGetAll, ufCallRpc, UF_SUPABASE_*).

var LOCK_THRESHOLD = 3;                 // days of no change before a film shows as locked
var BO_RECENT_DAYS = 30;                // released this recently = checked every run
var BO_RECHECK_DAYS = 7;                // settled / no-data films are re-checked this often
var BO_TIME_BUDGET_MS = 5 * 60 * 1000;  // stop starting new films after this (hard limit is 6 min)
var DAILY_BO_KEY = "universe";          // daily_bo.league_id for rows shared by every league

var BOM_HEADERS = {
  "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36",
  "Accept-Language": "en-US,en;q=0.9"
};

// ---- small helpers ---------------------------------------------------------
function boToday() { return Utilities.formatDate(new Date(), Session.getScriptTimeZone(), "yyyy-MM-dd"); }

function boDaysBetween(a, b) { // whole days from date string a to date string b
  var pa = a.split("-"), pb = b.split("-");
  return Math.round((Date.UTC(+pb[0], +pb[1] - 1, +pb[2]) - Date.UTC(+pa[0], +pa[1] - 1, +pa[2])) / 86400000);
}

function bomFetch(path) {
  var resp = UrlFetchApp.fetch("https://www.boxofficemojo.com" + path,
    { muteHttpExceptions: true, followRedirects: true, headers: BOM_HEADERS });
  return { code: resp.getResponseCode(), html: resp.getResponseCode() === 200 ? resp.getContentText() : "" };
}

// Domestic lifetime total from a Box Office Mojo title page. Anchors on the
// "Domestic (NN.N%)" summary heading and reads the first <span class="money">
// after it -- the one place on the page that's unambiguously the real total
// (the bare word "Domestic" first appears in a nav tab, nowhere near it).
// Falls back to an older heuristic only if that anchor isn't on the page.
function extractDomesticBO(html) {
  var domIdx = html.indexOf("Domestic (");
  if (domIdx !== -1) {
    var anchored = html.substring(domIdx, domIdx + 500).match(/class="money">\$([\d,]+)</);
    if (anchored) return parseInt(anchored[1].replace(/,/g, ""), 10);
  }
  var idx = html.indexOf("Domestic");
  if (idx === -1) return null;
  var budgetIdx = html.indexOf("Budget", idx);
  var win = budgetIdx === -1 ? html.substring(idx) : html.substring(idx, budgetIdx);
  var m = win.match(/\$[\d,]{5,}/);
  return m ? parseInt(m[0].replace(/[$,]/g, ""), 10) : null;
}

function extractOpeningWeekend(html) {
  var i = html.indexOf("Domestic Opening");
  if (i === -1) return 0;
  var m = html.substring(i, i + 600).match(/\$[\d,]+/);
  return m ? parseInt(m[0].replace(/[$,]/g, ""), 10) : 0;
}

// ---- which films to fetch this run -----------------------------------------
function boIsActive(f, today) { // can this film's number still change?
  return boDaysBetween(f.release_date, today) <= BO_RECENT_DAYS || ((f.bo || 0) > 0 && !f.locked);
}

function boShouldCheck(f, today) {
  if (!f.release_date || f.release_date > today) return false;
  if (boIsActive(f, today)) return true;
  if (!f.last_check_date) return true;                              // never looked at yet
  return boDaysBetween(f.last_check_date, today) >= BO_RECHECK_DAYS; // weekly sweep
}

// Active films first, then stalest (never-checked first) so nothing starves.
function boCompare(today) {
  return function(a, b) {
    var pa = boIsActive(a, today) ? 0 : 1, pb = boIsActive(b, today) ? 0 : 1;
    if (pa !== pb) return pa - pb;
    return (a.last_check_date || "").localeCompare(b.last_check_date || "");
  };
}

function boPatchFilm(id, payload) {
  var r = UrlFetchApp.fetch(UF_SUPABASE_URL + "/rest/v1/universe_films?id=eq." + id, {
    method: "PATCH", muteHttpExceptions: true,
    headers: { "Content-Type": "application/json", apikey: UF_SUPABASE_KEY, Authorization: "Bearer " + UF_SUPABASE_KEY, Prefer: "return=minimal" },
    payload: JSON.stringify(payload)
  });
  return r.getResponseCode();
}

// ---- total + opening weekend -------------------------------------------------
function scrapeUniverseBoxOffice() {
  var started = Date.now(), today = boToday();
  Logger.log("=== UNIVERSE BOX OFFICE (" + today + ") ===");
  var films = ufGetAll("universe_films?imdb_id=not.is.null&release_date=lte." + today
    + "&select=id,title,imdb_id,release_date,bo,opening_weekend,no_change_days,locked,last_check_date");
  if (!films) { Logger.log("FAILED to load universe_films -- nothing changed."); return; }

  var due = films.filter(function(f) { return boShouldCheck(f, today); }).sort(boCompare(today));
  Logger.log("Released films with an IMDb id: " + films.length + " -- due this run: " + due.length);

  var updated = [], noData = [], failed = [], deferred = 0;
  for (var i = 0; i < due.length; i++) {
    if (Date.now() - started > BO_TIME_BUDGET_MS) { deferred = due.length - i; break; }
    var f = due[i];
    try {
      var page = bomFetch("/title/" + f.imdb_id + "/");
      if (page.code === 429) { Logger.log("Box Office Mojo is rate-limiting us (429) -- stopping early, will resume next run."); deferred = due.length - i; break; }
      if (page.code !== 200) { failed.push(f.title + " (HTTP " + page.code + ")"); continue; }

      var newBO = extractDomesticBO(page.html);
      if (newBO === null) {
        // BOM has the page but no domestic gross (streaming, tiny limited release...).
        // Stamp the check so it drops to the weekly sweep instead of being retried every run.
        boPatchFilm(f.id, { last_check_date: today });
        noData.push(f.title);
        continue;
      }

      var opening = f.opening_weekend || extractOpeningWeekend(page.html);
      var relMatch = page.html.match(/\/release\/(rl\d+)\//);
      var prevBO = typeof f.bo === "number" ? f.bo : 0;
      var unchanged = (newBO === prevBO && newBO > 0);
      // The plateau counter advances at most once per calendar day even though
      // this runs twice a day, otherwise films would lock twice as fast.
      var noChangeDays = !unchanged ? 0 : (f.last_check_date === today ? (f.no_change_days || 0) : (f.no_change_days || 0) + 1);
      var locked = noChangeDays >= LOCK_THRESHOLD;

      var code = boPatchFilm(f.id, {
        bo: newBO, opening_weekend: opening, no_change_days: noChangeDays, locked: locked,
        last_check_date: today, bom_release_id: relMatch ? relMatch[1] : null
      });
      if (code < 300) {
        var wasLocked = (f.no_change_days || 0) >= LOCK_THRESHOLD;
        updated.push(f.title + ": $" + newBO.toLocaleString() + (locked && !wasLocked ? " (now locked)" : (!locked && wasLocked ? " (unlocked -- real change)" : "")));
      } else {
        failed.push(f.title + " (save failed, HTTP " + code + ")");
      }
    } catch (e) {
      failed.push(f.title + " (" + e.message + ")");
    }
    Utilities.sleep(1000);
  }

  Logger.log("Updated (" + updated.length + "):\n" + (updated.join("\n") || "  none"));
  Logger.log("No domestic box office on BOM (" + noData.length + "): " + (noData.join(", ") || "none"));
  Logger.log("Failed (" + failed.length + "):\n" + (failed.join("\n") || "  none"));
  if (deferred) Logger.log("Out of time: " + deferred + " film(s) deferred to the next run (stalest are always first).");
  Logger.log("Took " + Math.round((Date.now() - started) / 1000) + "s");
}

// ---- day-by-day ---------------------------------------------------------------
// BOM's release page lists one row per day, oldest first, with the month but no
// year. The year starts at the film's release year and rolls forward whenever the
// month goes backwards (Dec -> Jan), so a December 2027 release correctly runs into
// January 2028 (the old code only handled 2026 -> 2027).
function parseReleasePageTable(html, startYear) {
  var results = [];
  var tableStart = html.indexOf("<table");
  if (tableStart === -1) return results;
  var tableEnd = html.indexOf("</table>", tableStart);
  if (tableEnd === -1) return results;
  var tableHtml = html.substring(tableStart, tableEnd + 8);

  var MONTHS = { Jan: 1, Feb: 2, Mar: 3, Apr: 4, May: 5, Jun: 6, Jul: 7, Aug: 8, Sep: 9, Oct: 10, Nov: 11, Dec: 12 };
  var year = parseInt(startYear, 10), prevMonth = 0, rowNum = 0;
  var trPattern = /<tr[^>]*>([\s\S]*?)<\/tr>/gi, trMatch;
  while ((trMatch = trPattern.exec(tableHtml)) !== null) {
    rowNum++;
    if (rowNum === 1) continue; // header
    var cells = [], tdPattern = /<td[^>]*>([\s\S]*?)<\/td>/gi, tdMatch;
    while ((tdMatch = tdPattern.exec(trMatch[1])) !== null) {
      cells.push(tdMatch[1].replace(/<[^>]+>/g, "").replace(/&nbsp;/g, " ").replace(/&amp;/g, "&").replace(/&lt;/g, "<").replace(/&gt;/g, ">").trim());
    }
    if (cells.length < 9) continue;

    var dateParts = cells[0].split(" ");
    if (dateParts.length < 2) continue;
    var month = MONTHS[dateParts[0]], dayNum = parseInt(dateParts[1], 10);
    if (!month || isNaN(dayNum)) continue;
    if (prevMonth && month < prevMonth) year++;
    prevMonth = month;

    var daily = parseInt(cells[3].replace(/[$,]/g, ""), 10) || 0;
    if (daily <= 0) continue;
    results.push({
      date: year + "-" + String(month).padStart(2, "0") + "-" + String(dayNum).padStart(2, "0"),
      daily: daily,
      cumulative: parseInt(cells[8].replace(/[$,]/g, ""), 10) || 0
    });
  }
  return results;
}

function insertDailyBORows(filmTitle, rows) {
  if (!rows.length) return true;
  var payload = rows.map(function(r) { return { league_id: DAILY_BO_KEY, film_title: filmTitle, bo_date: r.date, daily_gross: r.daily }; });
  // on_conflict names the real unique key (league_id, film_title, bo_date); without it
  // one duplicate row fails the whole batch and silently drops every new day with it.
  var resp = UrlFetchApp.fetch(UF_SUPABASE_URL + "/rest/v1/daily_bo?on_conflict=league_id,film_title,bo_date", {
    method: "POST", muteHttpExceptions: true,
    headers: { "Content-Type": "application/json", apikey: UF_SUPABASE_KEY, Authorization: "Bearer " + UF_SUPABASE_KEY, Prefer: "resolution=ignore-duplicates" },
    payload: JSON.stringify(payload)
  });
  if (resp.getResponseCode() >= 300) {
    Logger.log("daily_bo insert failed for " + filmTitle + ": HTTP " + resp.getResponseCode() + " " + resp.getContentText().slice(0, 200));
    return false;
  }
  return true;
}

// Stable 0-6 "weekday slot" for a title, so settled films get their weekly sweep
// spread across the week without storing any state.
function boWeekSlot(title) {
  var h = 0;
  for (var i = 0; i < title.length; i++) h = (h + title.charCodeAt(i)) % 7;
  return h;
}

function scrapeDailyBoxOffice() {
  var started = Date.now(), today = boToday();
  Logger.log("=== DAILY BOX OFFICE (" + today + ") ===");
  var films = ufGetAll("universe_films?bom_release_id=not.is.null&release_date=lte." + today
    + "&select=title,bom_release_id,release_date,bo,locked");
  if (!films) { Logger.log("FAILED to load universe_films -- nothing changed."); return; }

  var slot = new Date().getDay();
  var due = films.filter(function(f) {
    return boIsActive(f, today) || boWeekSlot(f.title) === slot;
  }).sort(function(a, b) { return b.release_date.localeCompare(a.release_date); }); // newest first
  Logger.log("Films with a BOM release id: " + films.length + " -- due this run: " + due.length);

  var ok = [], failed = [], deferred = 0, sent = 0;
  for (var i = 0; i < due.length; i++) {
    if (Date.now() - started > BO_TIME_BUDGET_MS) { deferred = due.length - i; break; }
    var f = due[i];
    try {
      var page = bomFetch("/release/" + f.bom_release_id + "/");
      if (page.code === 429) { Logger.log("Box Office Mojo is rate-limiting us (429) -- stopping early."); deferred = due.length - i; break; }
      var rows = page.code === 200 ? parseReleasePageTable(page.html, f.release_date.slice(0, 4)) : [];
      if (!rows.length) { failed.push(f.title + " (no daily table)"); }
      else if (insertDailyBORows(f.title, rows)) { ok.push(f.title); sent += rows.length; }
      else failed.push(f.title + " (insert failed)");
    } catch (e) {
      failed.push(f.title + " (" + e.message + ")");
    }
    Utilities.sleep(1000);
  }
  Logger.log("Checked (" + ok.length + "): " + ok.join(" | "));
  Logger.log("Problems (" + failed.length + "): " + (failed.join(", ") || "none"));
  Logger.log("Rows sent (existing ones are ignored by the database): " + sent);
  if (deferred) Logger.log("Out of time: " + deferred + " film(s) deferred to the next run.");
}

// ---- weekly snapshots (every league, one RPC -- migration 046) -------------------
function snapshotWeeklyBOAndPOI() {
  var result = ufCallRpc("snapshot_weekly_bo_and_poi", {});
  Logger.log(result.code < 300 ? "snapshotWeeklyBOAndPOI: OK -- refreshed for every league"
    : "snapshotWeeklyBOAndPOI FAILED: HTTP " + result.code + " " + result.body.slice(0, 300));
}
