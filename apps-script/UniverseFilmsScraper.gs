/**
 * UNIVERSE FILMS SCRAPER — Apps Script
 * Populates Supabase `universe_films` with every real theatrical release
 * (wide or specialty/awards) across the 2026 and 2027 Oscar-to-Oscar
 * windows, so the /universe admin page is a comprehensive "anything an
 * exec could draft" list without manual entry for every film.
 *
 * Data source: TMDb's /discover/movie endpoint, filtered by a curated
 * allowlist of ~40 major-studio and prestige/arthouse distributor IDs
 * (with_companies). This was chosen over two alternatives that don't work:
 *   - Popularity threshold alone: no cutoff cleanly separates real (but
 *     early/low-buzz) sequels like "Super Troopers 3" from random noise —
 *     both can sit in the same 3-8 popularity range months before release.
 *   - with_release_type (wide/limited): TMDb's release-type tagging is
 *     crowd-sourced and unreliable for obscure titles; adding it changed
 *     nothing (same noisy result set with or without it).
 * The company allowlist was validated against this league's own known real
 * film list (league.html's FALLBACK_FILMS) across 6 different months and
 * caught every real title while cutting result counts by ~95%+ (e.g. 1030
 * raw results for one month down to 8, with zero real misses).
 *
 * Short films are excluded using the Academy's 40-minute cutoff, but only
 * when runtime is *known* — discover's list response has no runtime field
 * at all, and unreleased films frequently have no runtime set yet (that's
 * exactly why a `with_runtime.gte=40` discover-level filter is unsafe: it
 * silently dropped "Jumanji: Open World", a real film, in testing). So
 * runtime is checked per-film via the detail endpoint, and only excludes
 * when it's a definite positive number under 40 -- unknown/0 is kept.
 *
 * Writes directly to Supabase via REST (no Google Sheet involved) with the
 * service_role key stored in Script Properties (see checkSetup() in Triggers.gs).
 *
 * Existing films aren't just skipped -- if TMDb's release_date differs from
 * what's stored (or imdb_id was never filled in), the row gets updated.
 * This is what makes an admin's manually-entered "estimated release date"
 * (for films TMDb doesn't have yet) a real workflow: once TMDb catches up
 * with a real date, this scraper corrects it automatically instead of the
 * estimate being stuck forever. (There's no reliable automated source for
 * *finding* undated announced films in the first place, though -- tested
 * this by browsing TMDb's entire history for the distributor allowlist
 * with no date filter at all, sorted by popularity: every single result,
 * even decades-old ones, already had a real date. By the time a film has
 * enough attention to be worth tracking, it typically already has one.)
 */

// ============================================================
//  CONFIG
// ============================================================
// Secrets live in Script Properties (Project Settings -> Script properties), never
// in the code, so this file can be shared/versioned safely and a key rotation is a
// one-place change. Run checkSetup() (Triggers.gs) to confirm both are set.
function ufSecret(name) { return PropertiesService.getScriptProperties().getProperty(name) || ""; }
var TMDB_API_KEY = ufSecret("TMDB_API_KEY");
var UF_SUPABASE_URL = "https://fymkwkbatklfynnhxrsf.supabase.co";
var UF_SUPABASE_KEY = ufSecret("SUPABASE_SERVICE_KEY");

// Oscar-to-Oscar windows, matching universe.html's SEASONS constant.
// Add a 2028 entry here (and to universe.html's SEASONS) once that
// ceremony's window boundaries are known.
var UF_SEASON_WINDOWS = [   // fallback only -- the seasons table is the source of truth
  { start: "2026-03-16", end: "2027-03-14" },
  { start: "2027-03-15", end: "2028-03-05" },
];

// Season windows from public.seasons (added on the Universe page -> Seasons & Oscars), so a new
// season needs no code change here. activeOnly skips seasons that ended over a month ago.
function ufSeasonWindows(activeOnly) {
  var rows = ufGetAll("seasons?select=season,window_start,window_end&order=season.asc");
  var list = (rows && rows.length)
    ? rows.map(function(r) { return { season: r.season, start: r.window_start, end: r.window_end }; })
    : UF_SEASON_WINDOWS;
  if (!activeOnly) return list;
  var cutoff = Utilities.formatDate(new Date(Date.now() - 31 * 86400000), "America/Los_Angeles", "yyyy-MM-dd");
  return list.filter(function(w) { return w.end >= cutoff; });
}

// Curated studio/distributor allowlist: major studios + prestige/arthouse
// distributors (the latter is what keeps foreign-language and festival
// films in scope -- A24/Neon/Focus/Searchlight/Sony Classics etc. are who
// actually releases those in the US). IDs are TMDb *production company*
// ids (discover's with_companies filters on those), verified via TMDb's
// /company/{id} endpoint.
//
// IMPORTANT: TMDb keeps several duplicate company records for the same
// studio and a film can be tagged under any one of them, so a studio often
// needs more than one id here (e.g. A24 = 293354 AND 41077; Screen Gems =
// 226208, 3287 AND 142334). The original list also had one id that doesn't
// exist (303935, meant to be New Line Cinema -- the real id is 12), which is
// why films like Mortal Kombat II were never picked up. Oct 2026 additions
// below came from "Other Mommy" (Blumhouse / Atomic Monster) being missing.
var UF_DISTRIBUTOR_IDS = [
  2, 420, 1, 3, 127928, 127929,           // Disney, Marvel, Lucasfilm, Pixar, 20th Century, Searchlight
  33, 521, 7, 6704,                        // Universal, DreamWorks Animation, DreamWorks Pictures, Illumination
  174, 12, 184898, 25120,                  // Warner Bros, New Line Cinema, DC Studios, Warner Animation Group
  4, 24955,                                // Paramount, Paramount Animation
  5, 34, 300397, 226208, 3287, 142334,     // Columbia, Sony Pictures, TriStar, Screen Gems (x3 records)
  2251, 302911, 58,                        // Sony Animation, Sony Classics (x2 records)
  1632, 21,                                // Lionsgate, MGM
  210099, 235254, 194232, 178464,          // Amazon MGM, Amazon Studios, Apple Studios, Netflix
  270158, 10146, 10163,                    // STX, Focus Features, Working Title
  293354, 41077, 90733, 307, 1030, 167986, 911, // A24 (x2 records), NEON, IFC Films, Magnolia, Bleecker Street, Roadside Attractions
  258623, 39134, 92394, 88606,             // Music Box Films, Kino Lorber, Well Go USA, Vertical
  9118, 18066, 149326,                     // Samuel Goldwyn Films, Utopia, Greenwich Entertainment
  3172, 76907, 923, 82819, 56              // Blumhouse, Atomic Monster, Legendary, Skydance Media, Amblin
];

var UF_MIN_RUNTIME = 40; // Academy's short-vs-feature cutoff, in minutes

// ============================================================
//  TITLE NORMALIZATION (mirrors universe.html's normTitle(), so a film
//  found by this scraper is recognized as the same film an admin already
//  added manually under a slightly different title). Treats any run of
//  non-alphanumeric characters (punctuation, hyphens, etc.) as a single
//  space rather than deleting it -- otherwise "Focker-In-Law" collapses to
//  "fockerinlaw" while "Focker in Law" stays "focker in law", and the same
//  real film ends up looking like two different titles.
// ============================================================
function ufNormTitle(t) {
  return (t || "").toString().toLowerCase()
    .replace(/^(the |a |an )/, "")
    .replace(/[^a-z0-9]+/g, " ")
    .trim();
}

// ============================================================
//  SUPABASE HELPERS
// ============================================================
// Every row of a PostgREST query, paging past its 1000-row response cap (a plain
// fetch silently truncates there). `path` is e.g. "universe_films?select=id,title".
// Returns null if any page fails, so callers can stop instead of acting on partial data.
function ufGetAll(path) {
  var rows = [], offset = 0, PAGE = 1000;
  while (true) {
    var resp = UrlFetchApp.fetch(UF_SUPABASE_URL + "/rest/v1/" + path + (path.indexOf("?") === -1 ? "?" : "&") + "limit=" + PAGE + "&offset=" + offset,
      { muteHttpExceptions: true, headers: { apikey: UF_SUPABASE_KEY, Authorization: "Bearer " + UF_SUPABASE_KEY } });
    if (resp.getResponseCode() !== 200) {
      Logger.log("Supabase read failed (" + path.split("?")[0] + "): HTTP " + resp.getResponseCode() + " " + resp.getContentText().slice(0, 150));
      return null;
    }
    var batch = JSON.parse(resp.getContentText());
    rows = rows.concat(batch);
    if (batch.length < PAGE) return rows;
    offset += PAGE;
  }
}

// Map of normalised title -> row, or null if it couldn't be loaded. Callers must
// stop on null: treating "couldn't load" as "no films yet" would re-add everything.
function ufFetchExistingFilms() {
  var rows = ufGetAll("universe_films?select=id,title,release_date,imdb_id");
  if (!rows) return null;
  var map = {};
  rows.forEach(function(r) { map[ufNormTitle(r.title)] = r; });
  return map;
}

function ufInsertFilm(title, releaseDate, imdbId) {
  var url = UF_SUPABASE_URL + "/rest/v1/universe_films";
  var resp = UrlFetchApp.fetch(url, {
    method: "POST",
    muteHttpExceptions: true,
    headers: {
      "Content-Type": "application/json",
      "apikey": UF_SUPABASE_KEY,
      "Authorization": "Bearer " + UF_SUPABASE_KEY,
      "Prefer": "return=minimal"
    },
    payload: JSON.stringify({ title: title, release_date: releaseDate || null, imdb_id: imdbId || null })
  });
  var code = resp.getResponseCode();
  if (code >= 300) {
    Logger.log("Insert failed for \"" + title + "\": HTTP " + code + " " + resp.getContentText().slice(0, 200));
  }
  return code < 300;
}

// Used when a film already exists (e.g. an admin's manually-entered
// estimated release date) but TMDb now has a different/better date, or the
// imdb_id was never filled in. This is what makes the admin's "estimated
// release date" workflow real -- without it, a manual entry could never be
// corrected once TMDb catches up.
function ufUpdateFilm(id, releaseDate, imdbId) {
  var payload = {};
  if (releaseDate) payload.release_date = releaseDate;
  if (imdbId) payload.imdb_id = imdbId;
  if (Object.keys(payload).length === 0) return true;

  var url = UF_SUPABASE_URL + "/rest/v1/universe_films?id=eq." + id;
  var resp = UrlFetchApp.fetch(url, {
    method: "PATCH",
    muteHttpExceptions: true,
    headers: {
      "Content-Type": "application/json",
      "apikey": UF_SUPABASE_KEY,
      "Authorization": "Bearer " + UF_SUPABASE_KEY,
      "Prefer": "return=minimal"
    },
    payload: JSON.stringify(payload)
  });
  var code = resp.getResponseCode();
  if (code >= 300) {
    Logger.log("Update failed for id " + id + ": HTTP " + code + " " + resp.getContentText().slice(0, 200));
  }
  return code < 300;
}

// ============================================================
//  TMDB HELPERS
// ============================================================
function ufTmdbDiscoverPage(startDate, endDate, page) {
  var url = "https://api.themoviedb.org/3/discover/movie"
    + "?api_key=" + TMDB_API_KEY
    + "&region=US"
    + "&sort_by=popularity.desc"
    + "&primary_release_date.gte=" + startDate
    + "&primary_release_date.lte=" + endDate
    + "&with_companies=" + UF_DISTRIBUTOR_IDS.join("%7C")
    + "&page=" + page;
  var resp = UrlFetchApp.fetch(url, { muteHttpExceptions: true });
  if (resp.getResponseCode() !== 200) {
    Logger.log("TMDb discover failed (" + startDate + " to " + endDate + ", page " + page + "): HTTP " + resp.getResponseCode());
    return null;
  }
  return JSON.parse(resp.getContentText());
}

// Runtime + imdb_id aren't in discover's list response, only per-film detail.
function ufTmdbFilmDetails(tmdbId) {
  var url = "https://api.themoviedb.org/3/movie/" + tmdbId + "?api_key=" + TMDB_API_KEY + "&append_to_response=external_ids";
  var resp = UrlFetchApp.fetch(url, { muteHttpExceptions: true });
  if (resp.getResponseCode() !== 200) return null;
  return JSON.parse(resp.getContentText());
}

// ============================================================
//  MAIN
// ============================================================
function scrapeUniverseFilms() {
  Logger.log("=== UNIVERSE FILMS SCRAPE START ===");
  var existingFilms = ufFetchExistingFilms();
  if (!existingFilms) { Logger.log("FAILED to load the existing film list -- nothing changed."); return; }
  Logger.log("Existing films in Supabase: " + Object.keys(existingFilms).length);
  var seenThisRun = {}; // two different films can share a title; the first one wins so dates don't flip-flop

  var added = [], updated = [], skippedShorts = [], failed = [];
  var candidateCount = 0;

  ufSeasonWindows(true).forEach(function(season) {
    Logger.log("--- Season window " + season.start + " to " + season.end + " ---");
    var page = 1, totalPages = 1;
    do {
      var data = ufTmdbDiscoverPage(season.start, season.end, page);
      if (!data) break;
      totalPages = data.total_pages || 1;

      data.results.forEach(function(r) {
        candidateCount++;
        var normalized = ufNormTitle(r.title);
        if (seenThisRun[normalized]) return;
        seenThisRun[normalized] = true;
        var existing = existingFilms[normalized];

        if (existing && !existing.id) return; // added earlier in this same run
        if (existing) {
          // Already on the list -- this is what makes a manually-entered
          // estimated release date (or a missing imdb_id) get corrected
          // once TMDb has better data, instead of being stuck forever.
          var needsDateUpdate = r.release_date && r.release_date !== existing.release_date;
          var needsImdbBackfill = !existing.imdb_id;
          if (!needsDateUpdate && !needsImdbBackfill) return; // already up to date, nothing to do

          var imdbId = existing.imdb_id;
          if (needsImdbBackfill) {
            var lookup = ufTmdbFilmDetails(r.id);
            if (lookup) imdbId = (lookup.external_ids && lookup.external_ids.imdb_id) || null;
            Utilities.sleep(250);
          }
          var newDate = needsDateUpdate ? r.release_date : existing.release_date;
          if (newDate === existing.release_date && imdbId === existing.imdb_id) return; // nothing actually changed

          var updateOk = ufUpdateFilm(existing.id, newDate, imdbId);
          if (updateOk) {
            updated.push(r.title + ": " + (existing.release_date || "no date") + " -> " + (newDate || "no date"));
            existing.release_date = newDate;
            existing.imdb_id = imdbId;
          } else {
            failed.push(r.title + " (update)");
          }
          return;
        }

        // Genuinely new film
        var details = ufTmdbFilmDetails(r.id);
        if (!details) { failed.push(r.title); return; }

        var runtime = details.runtime;
        if (typeof runtime === "number" && runtime > 0 && runtime < UF_MIN_RUNTIME) {
          skippedShorts.push(r.title + " (" + runtime + " min)");
          return;
        }

        var newImdbId = (details.external_ids && details.external_ids.imdb_id) || null;
        var ok = ufInsertFilm(r.title, r.release_date || null, newImdbId);
        if (ok) {
          added.push(r.title + (r.release_date ? " (" + r.release_date + ")" : ""));
          existingFilms[normalized] = { id: null, title: r.title, release_date: r.release_date || null, imdb_id: newImdbId };
        } else {
          failed.push(r.title);
        }
        Utilities.sleep(250); // be polite to TMDb between per-film detail calls
      });

      page++;
    } while (page <= totalPages);
  });

  Logger.log("=== UNIVERSE FILMS SCRAPE COMPLETE ===");
  Logger.log("Candidates seen: " + candidateCount);
  Logger.log("Added (" + added.length + "):\n" + (added.join("\n") || "  none"));
  Logger.log("Updated (" + updated.length + "):\n" + (updated.join("\n") || "  none"));
  Logger.log("Skipped as shorts (" + skippedShorts.length + "):\n" + (skippedShorts.join("\n") || "  none"));
  Logger.log("Failed (" + failed.length + "):\n" + (failed.join("\n") || "  none"));
}

// ============================================================
//  ACQUISITIONS — weekly window creation + resolution
// ============================================================
// Calls the SECURITY DEFINER RPCs from migrations 021/022 using the same
// service_role key/pattern as everything else in this file. All the real
// business logic (deadline math in America/Los_Angeles, tie-breaking,
// budget checks) lives in Postgres -- this is just "wake up on a schedule
// and call one RPC," the same shape as scrapeUniverseBoxOffice. Apps
// Script triggers fire within an approximate window (not the exact
// minute), which is fine here: ensure_acquisition_week() and
// resolve_acquisitions_week() both re-check the real deadline against
// now() themselves, so timing drift on this side can only delay things by
// a few minutes, never cause incorrect behavior.
function ufCallRpc(fnName, args) {
  var url = UF_SUPABASE_URL + "/rest/v1/rpc/" + fnName;
  var resp = UrlFetchApp.fetch(url, {
    method: "POST",
    muteHttpExceptions: true,
    headers: {
      "Content-Type": "application/json",
      "apikey": UF_SUPABASE_KEY,
      "Authorization": "Bearer " + UF_SUPABASE_KEY
    },
    payload: JSON.stringify(args || {})
  });
  return { code: resp.getResponseCode(), body: resp.getContentText() };
}

function ensureAcquisitionWeek() {
  Logger.log("=== ENSURE ACQUISITION WEEK ===");
  var result = ufCallRpc("ensure_acquisition_week", {});
  if (result.code < 300) {
    Logger.log("OK -- week id: " + result.body);
  } else {
    Logger.log("FAILED: HTTP " + result.code + " " + result.body.slice(0, 300));
  }
}

// Fetches weeks whose bid_deadline has already passed and that haven't
// been resolved yet, then resolves each. Pre-filtering by bid_deadline
// client-side (rather than just fetching every unresolved week) avoids
// calling resolve_acquisitions_week() on a week that isn't due yet, which
// would just raise "Bidding window has not closed yet" -- harmless, but
// noisy in the execution log every time this runs.
function resolveDueAcquisitionWeeks() {
  Logger.log("=== RESOLVE DUE ACQUISITION WEEKS ===");
  var url = UF_SUPABASE_URL + "/rest/v1/acquisition_weeks"
    + "?resolved_at=is.null&bid_deadline=lt." + encodeURIComponent(new Date().toISOString())
    + "&select=id,week_start,bid_deadline";
  var resp = UrlFetchApp.fetch(url, {
    muteHttpExceptions: true,
    headers: { "apikey": UF_SUPABASE_KEY, "Authorization": "Bearer " + UF_SUPABASE_KEY }
  });
  if (resp.getResponseCode() !== 200) {
    Logger.log("Failed to fetch due acquisition_weeks: HTTP " + resp.getResponseCode());
    return;
  }
  var weeks = JSON.parse(resp.getContentText());
  Logger.log("Weeks due for resolution: " + weeks.length);

  var resolved = [], failed = [];
  weeks.forEach(function(w) {
    var result = ufCallRpc("resolve_acquisitions_week", { p_week_id: w.id });
    if (result.code < 300) {
      resolved.push(w.week_start + " (" + w.id + ")");
    } else {
      failed.push(w.week_start + " (" + w.id + "): HTTP " + result.code + " " + result.body.slice(0, 200));
    }
  });

  Logger.log("=== RESOLUTION COMPLETE ===");
  Logger.log("Resolved (" + resolved.length + "):\n" + (resolved.join("\n") || "  none"));
  Logger.log("Failed (" + failed.length + "):\n" + (failed.join("\n") || "  none"));
}

// ============================================================
//  WEEKEND PICKS — resolve the Top-3 weekend predictions
// ============================================================
// Players predict the weekend's top 3 domestic box office films, in order
// (see migration 056). This reads Box Office Mojo's weekend chart for each
// week that's past its resolve_after (Monday 5pm PT) and hasn't been
// resolved, maps the top 3 rows onto universe_films (BOM release id first,
// normalised title as fallback), and hands them to the service-role-only
// resolve_weekend_picks_week() RPC, which does the all-three-in-order
// scoring and enforces the real timing itself. Safe to run as often as you
// like: resolved weeks are never fetched, and the RPC no-ops on a week
// that's already resolved.
//
// BOM publishes Sunday numbers as ESTIMATES first and swaps in actuals
// around Monday evening, so a week is only resolved once all three top rows
// are non-estimated -- except as a fallback 24h past resolve_after, so a
// chart that never flips can't strand the week forever (an admin can still
// correct it later with admin_resolve_weekend_picks).
function ufIsoWeekLabel(dateStr) {
  // dateStr is a yyyy-mm-dd Friday; BOM's weekend pages are keyed by ISO week.
  var p = dateStr.split("-");
  var d = new Date(Date.UTC(+p[0], +p[1] - 1, +p[2]));
  var dayNum = d.getUTCDay() || 7;
  d.setUTCDate(d.getUTCDate() + 4 - dayNum); // Thursday of this ISO week
  var yearStart = new Date(Date.UTC(d.getUTCFullYear(), 0, 1));
  var week = Math.ceil(((d - yearStart) / 86400000 + 1) / 7);
  return d.getUTCFullYear() + "W" + (week < 10 ? "0" + week : week);
}

function ufDecodeHtml(t) {
  return String(t || "")
    .replace(/&amp;/g, "&").replace(/&#0?39;/g, "'").replace(/&apos;/g, "'")
    .replace(/&quot;/g, '"').replace(/&lt;/g, "<").replace(/&gt;/g, ">")
    .replace(/&#x27;/g, "'").replace(/&nbsp;/g, " ").trim();
}

// Returns the first three chart rows as
// [{rank, title, releaseId, estimated}] or null if the page doesn't look
// like a real weekend chart.
function ufParseBomWeekendTop3(html) {
  var tableStart = html.indexOf("<table");
  if (tableStart === -1) return null;
  var rows = html.substring(tableStart).match(/<tr[^>]*>[\s\S]*?<\/tr>/g) || [];
  var out = [];
  for (var i = 0; i < rows.length && out.length < 3; i++) {
    var cells = rows[i].match(/<td[^>]*>[\s\S]*?<\/td>/g);
    if (!cells || cells.length < 12) continue; // header row or malformed
    var strip = function(c) { return c.replace(/<svg[\s\S]*?<\/svg>/g, "").replace(/<[^>]+>/g, "").replace(/\s+/g, " ").trim(); };
    var rank = parseInt(strip(cells[0]), 10);
    var link = cells[2].match(/href="\/release\/(rl\d+)\/[^"]*"[^>]*>([^<]*)</);
    if (!link || isNaN(rank)) continue;
    out.push({
      rank: rank,
      title: ufDecodeHtml(link[2]),
      releaseId: link[1],
      estimated: strip(cells[cells.length - 1]).toLowerCase() === "true"
    });
  }
  if (out.length < 3) return null;
  for (var r = 0; r < 3; r++) if (out[r].rank !== r + 1) return null;
  return out;
}

function resolveWeekendPicks() {
  Logger.log("=== RESOLVE WEEKEND PICKS ===");
  var nowIso = new Date().toISOString();
  var resp = UrlFetchApp.fetch(UF_SUPABASE_URL + "/rest/v1/weekend_pick_weeks"
    + "?resolved_at=is.null&resolve_after=lt." + encodeURIComponent(nowIso)
    + "&select=id,league_id,weekend_friday,resolve_after",
    { muteHttpExceptions: true, headers: { apikey: UF_SUPABASE_KEY, Authorization: "Bearer " + UF_SUPABASE_KEY } });
  if (resp.getResponseCode() !== 200) {
    Logger.log("Failed to fetch due weekend_pick_weeks: HTTP " + resp.getResponseCode() + " " + resp.getContentText().slice(0, 200));
    return;
  }
  var weeks = JSON.parse(resp.getContentText());
  Logger.log("Weeks due for resolution: " + weeks.length);
  if (!weeks.length) return;

  // One universe lookup shared by every week (PostgREST caps a response at
  // 1000 rows, which is comfortably above the Universe's size).
  var universe = ufGetAll("universe_films?select=imdb_id,title,bom_release_id");
  if (!universe) return;
  var byRelease = {}, byTitle = {};
  universe.forEach(function(f) {
    if (f.bom_release_id) byRelease[f.bom_release_id] = f;
    byTitle[ufNormTitle(f.title)] = f;
  });

  var chartCache = {};
  var resolved = [], waiting = [], failed = [];
  weeks.forEach(function(w) {
    var label = ufIsoWeekLabel(w.weekend_friday);
    try {
      if (!(label in chartCache)) {
        var page = bomFetch("/weekend/" + label + "/");
        chartCache[label] = page.code === 200 ? ufParseBomWeekendTop3(page.html) : null;
        Utilities.sleep(1200);
      }
      var top3 = chartCache[label];
      if (!top3) { waiting.push(label + " (chart not available/parseable yet)"); return; }

      var fallbackAfter = new Date(w.resolve_after).getTime() + 24 * 3600 * 1000;
      var anyEstimate = top3.some(function(r) { return r.estimated; });
      if (anyEstimate && Date.now() < fallbackAfter) {
        waiting.push(label + " (top 3 still estimates: " + top3.map(function(r) { return r.title; }).join(" / ") + ")");
        return;
      }

      var ids = top3.map(function(r) {
        var f = byRelease[r.releaseId] || byTitle[ufNormTitle(r.title)];
        return f ? f.imdb_id : "";
      });
      var titles = top3.map(function(r) { return r.title; });
      var result = ufCallRpc("resolve_weekend_picks_week", { p_week_id: w.id, p_top3: ids, p_top3_titles: titles });
      if (result.code < 300) {
        resolved.push(label + " [" + w.league_id + "]: " + titles.join(" / ")
          + (ids.indexOf("") !== -1 ? " (NOTE: a top-3 film isn't in the Universe -- nobody can match it)" : "")
          + (anyEstimate ? " (resolved from estimates after the 24h fallback)" : ""));
      } else {
        failed.push(label + " [" + w.league_id + "]: HTTP " + result.code + " " + result.body.slice(0, 200));
      }
    } catch (e) {
      failed.push(label + ": " + e.message);
    }
  });

  Logger.log("=== WEEKEND PICKS RESOLUTION COMPLETE ===");
  Logger.log("Resolved (" + resolved.length + "):\n" + (resolved.join("\n") || "  none"));
  Logger.log("Waiting (" + waiting.length + "):\n" + (waiting.join("\n") || "  none"));
  Logger.log("Failed (" + failed.length + "):\n" + (failed.join("\n") || "  none"));
}

// ============================================================
//  FILM ADD REQUESTS — research + email the admin
// ============================================================
// A player who can't find a film in the Universe (Weekend Picks tab ->
// "Add film") files a row in film_add_requests (migration 063). This job
// researches each new request -- TMDb title search, plus any Universe films
// whose title looks similar (so a misspelling or a re-titled film doesn't get
// added twice) -- stores the candidates on the request, and emails the admin
// once per run with everything new. The admin then approves in the app
// (Weekend Picks tab -> Film requests): add a TMDb match, link to an existing
// Universe film, or reject. Nothing is inserted into universe_films here.
//
// Emails go out through MailApp from whoever owns this Apps Script project.
// Set UF_ADMIN_EMAIL to send somewhere else; blank = the script owner. The
// first run asks for permission to send email.
var UF_ADMIN_EMAIL = "";
var UF_APP_URL = "https://studioexecfantasy.com";

function ufEsc(t) {
  return String(t == null ? "" : t).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

// Token-overlap similarity (0..1) between two titles, on the same
// normalisation the rest of this file uses; a title that contains the other
// counts as a strong match.
function ufTitleSimilarity(a, b) {
  var na = ufNormTitle(a), nb = ufNormTitle(b);
  if (!na || !nb) return 0;
  if (na === nb) return 1;
  if (na.indexOf(nb) !== -1 || nb.indexOf(na) !== -1) return 0.85;
  var ta = na.split(" "), tb = nb.split(" ");
  var setB = {}; tb.forEach(function(t) { setB[t] = true; });
  var inter = 0; ta.forEach(function(t) { if (setB[t]) inter++; });
  var union = ta.length + tb.length - inter;
  return union ? inter / union : 0;
}

function ufResearchFilmRequest(title, universeRows) {
  var tmdb = [];
  var searchUrl = "https://api.themoviedb.org/3/search/movie?api_key=" + TMDB_API_KEY
    + "&include_adult=false&query=" + encodeURIComponent(title);
  var resp = UrlFetchApp.fetch(searchUrl, { muteHttpExceptions: true });
  if (resp.getResponseCode() === 200) {
    var results = (JSON.parse(resp.getContentText()).results || []).slice(0, 5);
    results.forEach(function(r) {
      var d = ufTmdbFilmDetails(r.id);
      Utilities.sleep(250);
      var imdb = d && d.external_ids ? (d.external_ids.imdb_id || null) : null;
      var inUni = null;
      if (imdb) universeRows.forEach(function(u) { if (u.imdb_id === imdb) inUni = u.title; });
      tmdb.push({
        tmdb_id: r.id,
        title: r.title,
        release_date: r.release_date || null,
        imdb_id: imdb,
        popularity: Math.round(r.popularity || 0),
        runtime: d ? d.runtime || null : null,
        overview: (r.overview || "").slice(0, 220),
        in_universe_title: inUni
      });
    });
  } else {
    Logger.log("TMDb search failed for \"" + title + "\": HTTP " + resp.getResponseCode());
  }

  var universe = universeRows
    .map(function(u) { return { imdb_id: u.imdb_id, title: u.title, release_date: u.release_date, score: ufTitleSimilarity(title, u.title) }; })
    .filter(function(u) { return u.imdb_id && u.score >= 0.5; })
    .sort(function(a, b) { return b.score - a.score; })
    .slice(0, 3);

  return { tmdb: tmdb, universe: universe };
}

function ufPatchFilmRequest(id, payload) {
  var resp = UrlFetchApp.fetch(UF_SUPABASE_URL + "/rest/v1/film_add_requests?id=eq." + id, {
    method: "PATCH", muteHttpExceptions: true,
    headers: { "Content-Type": "application/json", "apikey": UF_SUPABASE_KEY, "Authorization": "Bearer " + UF_SUPABASE_KEY, "Prefer": "return=minimal" },
    payload: JSON.stringify(payload)
  });
  return resp.getResponseCode() < 300;
}

function processFilmRequests() {
  Logger.log("=== PROCESS FILM ADD REQUESTS ===");
  var resp = UrlFetchApp.fetch(UF_SUPABASE_URL + "/rest/v1/film_add_requests?status=eq.pending&emailed_at=is.null&select=*&order=created_at",
    { muteHttpExceptions: true, headers: { apikey: UF_SUPABASE_KEY, Authorization: "Bearer " + UF_SUPABASE_KEY } });
  if (resp.getResponseCode() !== 200) {
    Logger.log("Failed to fetch film_add_requests: HTTP " + resp.getResponseCode() + " " + resp.getContentText().slice(0, 200));
    return;
  }
  var reqs = JSON.parse(resp.getContentText());
  Logger.log("New requests: " + reqs.length);
  if (!reqs.length) return;

  var universeRows = ufGetAll("universe_films?select=title,imdb_id,release_date") || [];

  reqs.forEach(function(r) {
    if (!r.candidates) {
      r.candidates = ufResearchFilmRequest(r.title, universeRows);
      ufPatchFilmRequest(r.id, { candidates: r.candidates, researched_at: new Date().toISOString() });
    }
  });

  var blocks = reqs.map(function(r) {
    var c = r.candidates || { tmdb: [], universe: [] };
    var html = "<div style=\"margin:0 0 22px\"><div style=\"font-size:16px\"><b>" + ufEsc(r.title) + "</b></div>"
      + "<div style=\"color:#666;font-size:12px\">requested by " + ufEsc(r.requester_team || "a league member") + " &middot; " + ufEsc(String(r.created_at).slice(0, 16).replace("T", " ")) + " UTC</div>";
    if (c.universe && c.universe.length) {
      html += "<div style=\"margin-top:8px\"><b>Possibly already in the Universe:</b><ul style=\"margin:4px 0\">"
        + c.universe.map(function(u) { return "<li>" + ufEsc(u.title) + (u.release_date ? " (" + ufEsc(u.release_date) + ")" : "") + "</li>"; }).join("") + "</ul></div>";
    }
    if (c.tmdb && c.tmdb.length) {
      html += "<div style=\"margin-top:8px\"><b>TMDb matches:</b><ul style=\"margin:4px 0\">"
        + c.tmdb.map(function(t) {
          return "<li>" + ufEsc(t.title) + (t.release_date ? " (" + ufEsc(t.release_date) + ")" : " (no date)")
            + (t.runtime ? " &middot; " + t.runtime + " min" : "")
            + (t.in_universe_title ? " &middot; <i>already in the Universe</i>" : "")
            + (t.overview ? "<br><span style=\"color:#666;font-size:12px\">" + ufEsc(t.overview) + "</span>" : "") + "</li>";
        }).join("") + "</ul></div>";
    } else {
      html += "<div style=\"margin-top:8px;color:#a33\">No TMDb matches found &mdash; may be a typo, or too obscure.</div>";
    }
    return html + "</div>";
  });

  var to = UF_ADMIN_EMAIL || Session.getEffectiveUser().getEmail();
  var leagueId = reqs[0].league_id;
  var appLeagueUrl = UF_APP_URL + "/league.html?id=" + leagueId;
  var htmlBody;
  if (typeof gdBuildRequestEmail === "function") {
    // Styled email with one-click approve buttons (GoldDerbyCombinedOddsScraper.gs).
    var webAppUrl = "";
    try { webAppUrl = ScriptApp.getService().getUrl() || ""; } catch (e) { webAppUrl = ""; }
    htmlBody = gdBuildRequestEmail(reqs, webAppUrl, new Date().getTime() + 30 * 86400000, appLeagueUrl);
  } else {
    htmlBody = "<div style=\"font-family:Arial,sans-serif;font-size:14px\">"
      + "<p>Someone couldn't find a film in the Universe and asked to add it. Review and approve in the app: "
      + "<a href=\"" + appLeagueUrl + "\">open the league</a> &rarr; Weekend Picks &rarr; Film requests.</p>"
      + blocks.join("") + "</div>";
  }
  try {
    MailApp.sendEmail({
      to: to,
      subject: "Studio Exec Fantasy: " + reqs.length + " film add request" + (reqs.length === 1 ? "" : "s") + " to review",
      htmlBody: htmlBody
    });
  } catch (e) {
    Logger.log("Email failed (will retry next run): " + e.message);
    return;
  }
  reqs.forEach(function(r) { ufPatchFilmRequest(r.id, { emailed_at: new Date().toISOString() }); });
  Logger.log("Emailed " + reqs.length + " request(s) to " + to);
}

// ============================================================
//  NOTIFICATIONS — release day + new leaderboard leader
// ============================================================
// Same "wake up and call one RPC" shape as the Acquisitions functions
// above; new_film notifications don't need anything here since that one's
// a DB trigger on universe_films itself, firing automatically whenever
// scrapeUniverseFilms() (or a manual admin add) inserts a row.
function notifyReleaseDayFilms() {
  Logger.log("=== NOTIFY RELEASE DAY FILMS ===");
  var result = ufCallRpc("notify_release_day_films", {});
  if (result.code < 300) {
    Logger.log("OK");
  } else {
    Logger.log("FAILED: HTTP " + result.code + " " + result.body.slice(0, 300));
  }
}

// Best run after the day's box office numbers are in (see
// TRIGGER_PLAN in Triggers.gs), so the ranking it checks reflects fresh data.
// See migration 039 for the important caveat: this ranks by total box
// office only, not the full grandTotal (BO + remaining budget) formula
// league.html displays -- a deliberate simplification, not a bug.
function checkNewLeaders() {
  Logger.log("=== CHECK NEW LEADERS ===");
  var result = ufCallRpc("check_new_leaders", {});
  if (result.code < 300) {
    Logger.log("OK");
  } else {
    Logger.log("FAILED: HTTP " + result.code + " " + result.body.slice(0, 300));
  }
}
