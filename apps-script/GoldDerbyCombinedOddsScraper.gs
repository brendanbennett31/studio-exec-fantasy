// ============================================================
//  GOLD DERBY — Oscar nomination odds -> gold_derby_odds
// ============================================================
// Replaces the old Gold Derby scraper (which had drifted into garbage: people
// listed under the wrong category, film titles glued to names, duplicates, and
// only 8 of the 21 categories Gold Derby now predicts). Source of truth is the
// combined-odds page:
//   https://www.goldderby.com/odds/combined-odds/oscars-nominations-2027/
// Each category shows its top 5 contenders with Gold Derby's combined
// nomination odds. This reads that page, checks it looks right, and swaps the
// whole season in ONE database transaction through replace_gold_derby_odds()
// (migration 064) -- so a bad fetch can never leave the table half-written or
// empty: if the page doesn't parse, nothing is changed.
//
// Needs UniverseFilmsScraper.gs in the same project (uses its ufCallRpc()).
// Its daily trigger is defined in TRIGGER_PLAN (Triggers.gs).
//
// Row shape written (matches the table):
//   film_title      the film
//   performer_name  the person for Director/Actor/Actress/Supporting categories,
//                   the song title for Best Song, empty for film-only categories
//   nom_odds        combined nomination odds, percent
//   win_odds        0 (this page doesn't publish win odds)
//
// When Gold Derby's nominations page for the next season exists (or the page
// moves to the winners page after nominations are announced), change
// GD_SEASON and GD_URL below.

var GD_SEASON = "2027";   // Oscar CEREMONY year (league season 2026 -> "2027")
var GD_URL = "https://www.goldderby.com/odds/combined-odds/oscars-nominations-2027/";

// Optional: if Gold Derby ever blocks Google's servers, put a Scrape.do token
// here and the page is fetched through it instead. Blank = fetch directly.
var GD_SCRAPE_DO_TOKEN = "";

var GD_CATEGORIES = [
  "Best Picture", "Best Director", "Best Actress", "Best Actor",
  "Best Supporting Actress", "Best Supporting Actor",
  "Best Adapted Screenplay", "Best Original Screenplay", "Best Casting",
  "Best Cinematography", "Best Costume Design", "Best Film Editing",
  "Best Makeup and Hairstyling", "Best Production Design", "Best Score",
  "Best Song", "Best Sound", "Best Visual Effects", "Best Animated Feature",
  "Best Documentary Feature", "Best International Film"
];
var GD_PERSON_CATEGORIES = {
  "Best Director": true, "Best Actress": true, "Best Actor": true,
  "Best Supporting Actress": true, "Best Supporting Actor": true
};

function gdDecode(t) {
  return String(t || "")
    .replace(/&#x([0-9a-fA-F]+);/g, function(m, h) { return String.fromCharCode(parseInt(h, 16)); })
    .replace(/&#(\d+);/g, function(m, d) { return String.fromCharCode(parseInt(d, 10)); })
    .replace(/&amp;/g, "&").replace(/&quot;/g, '"').replace(/&apos;/g, "'")
    .replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&nbsp;/g, " ")
    .replace(/\s+/g, " ").trim();
}

// Pure function: page HTML in, rows out (so it can be tested without fetching).
function gdParseCombinedOdds(html) {
  var found = [];
  GD_CATEGORIES.forEach(function(cat) {
    var re = new RegExp("<h3[^>]*>\\s*" + cat.replace(/[.*+?^${}()|[\]\\]/g, "\\$&") + "\\s*</h3>");
    var m = re.exec(html);
    if (m) found.push({ cat: cat, pos: m.index });
  });
  found.sort(function(a, b) { return a.pos - b.pos; });

  var STOP = { "Experts Predicted Wins": 1, "Predicted Noms": 1, "Experts:": 1, "Editors:": 1, "Users:": 1, "Predicted Wins": 1, "Latest News": 1 };
  var rows = [];
  found.forEach(function(f, i) {
    var end = i + 1 < found.length ? found[i + 1].pos : f.pos + 400000;
    var seg = html.substring(f.pos, end);
    var items = seg.split('<div class="_predictionsContestantItem_').slice(1);
    items.forEach(function(item, idx) {
      var lines = [];
      var textRe = /<div class='_text_y7yck_1[^']*'[^>]*>([^<]*)<\/div>/g, tm;
      while ((tm = textRe.exec(item)) !== null) {
        var t = gdDecode(tm[1]);
        if (!t) continue;
        if (STOP[t]) break;
        lines.push(t);
      }
      if (lines.length && /^\d+\.$/.test(lines[0])) lines.shift(); // the "1." rank label
      var pct = /_progressText_[^>]*>([\d.]+)%/.exec(item);
      if (!lines.length || !pct) return;

      var film, performer = null;
      if (GD_PERSON_CATEGORIES[f.cat]) { performer = lines[0]; film = lines[1]; }
      else if (f.cat === "Best Song") { film = lines[0]; performer = lines[1] || null; }
      else { film = lines[0]; }
      if (!film) return;
      rows.push({ category: f.cat, film_title: film, performer_name: performer, nom_odds: parseFloat(pct[1]), win_odds: 0 });
    });
  });
  return rows;
}

function gdFetchPage() {
  var url = GD_URL;
  var opts = {
    muteHttpExceptions: true, followRedirects: true,
    headers: { "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36", "Accept-Language": "en-US,en;q=0.9" }
  };
  var resp = UrlFetchApp.fetch(url, opts);
  var html = resp.getResponseCode() === 200 ? resp.getContentText() : "";
  if ((!html || html.indexOf("prediction-odds-ticker") === -1) && GD_SCRAPE_DO_TOKEN) {
    Logger.log("Direct fetch looked blocked (HTTP " + resp.getResponseCode() + "); retrying through Scrape.do");
    resp = UrlFetchApp.fetch("https://api.scrape.do/?token=" + GD_SCRAPE_DO_TOKEN + "&url=" + encodeURIComponent(url), { muteHttpExceptions: true });
    html = resp.getResponseCode() === 200 ? resp.getContentText() : "";
  }
  return html;
}

function scrapeGoldDerbyCombinedOdds() {
  Logger.log("=== GOLD DERBY COMBINED ODDS (" + GD_SEASON + ") ===");
  var html = gdFetchPage();
  if (!html) { Logger.log("FAILED: couldn't fetch " + GD_URL + " -- nothing changed."); return; }

  var rows = gdParseCombinedOdds(html);
  var cats = {};
  rows.forEach(function(r) { cats[r.category] = (cats[r.category] || 0) + 1; });
  var catCount = Object.keys(cats).length;
  Logger.log("Parsed " + rows.length + " rows across " + catCount + " categories");

  // Sanity gate: a layout change or a blocked page must never wipe good data.
  if (catCount < 15 || rows.length < 75 || !cats["Best Picture"]) {
    Logger.log("FAILED: the page didn't parse like the Gold Derby combined-odds page (expected ~21 categories x 5). Nothing changed. Categories seen: " + JSON.stringify(cats));
    return;
  }
  var missing = GD_CATEGORIES.filter(function(c) { return !cats[c]; });
  if (missing.length) Logger.log("NOTE: no data for: " + missing.join(", "));

  var result = ufCallRpc("replace_gold_derby_odds", { p_season: GD_SEASON, p_rows: rows });
  if (result.code < 300) Logger.log("OK -- " + result.body + " rows written for season " + GD_SEASON);
  else { Logger.log("FAILED: HTTP " + result.code + " " + result.body.slice(0, 300) + " -- nothing changed."); return; }

  // Contenders Gold Derby lists that aren't in the Universe yet: add the
  // obvious ones, email the unclear ones for approval. Never fails the scrape.
  try { gdSyncMissingFilms(rows, false); }
  catch (e) { Logger.log("Missing-film sync failed (odds were still written): " + e.message); }
}

// ============================================================
//  MISSING FILMS -- auto-add the obvious, email the unclear
// ============================================================
// After each odds update, any film Gold Derby lists that isn't in the Universe
// is looked up on TMDb:
//   * exactly ONE film with that exact title releasing inside the season window,
//     with an IMDb id and feature length  -> added automatically (and listed in
//     the email so you know);
//   * anything else (several same-name films, no exact match, missing IMDb id)
//     -> emailed to you with an "Add this one" button per candidate and a
//     "Skip" button. Nothing is added until you click.
//   * the film exists on TMDb but only outside the season window (e.g. Hoppers,
//     a March release) -> left alone, no email.
// Titles are stored the way Gold Derby spells them so the Awards tab matches.
//
// ONE-TIME SETUP for the email buttons (they open an Apps Script web app):
//   Deploy -> New deployment -> gear icon -> Web app ->
//   "Execute as: Me", "Who has access: Anyone" -> Deploy (approve permissions).
//   The links are signed and expire after 30 days, so only emails this script
//   sent can add a film, and only the film named in that link. If you skip this,
//   emails still go out but without buttons (add films in the Universe page).
// If your project already has a doGet() function, merge this one into it.

var GD_LINK_TTL_DAYS = 30;     // email links stop working after this
var GD_REMIND_DAYS = 7;        // re-email an unanswered film after this long

// The season window whose ceremony is GD_SEASON (2027 -> Mar 2026 - Mar 2027).
function gdWindow() {
  var y = parseInt(GD_SEASON, 10);
  for (var i = 0; i < UF_SEASON_WINDOWS.length; i++) {
    if (parseInt(UF_SEASON_WINDOWS[i].end.slice(0, 4), 10) === y) return UF_SEASON_WINDOWS[i];
  }
  return null;
}

function gdStateGet() {
  try { return JSON.parse(PropertiesService.getScriptProperties().getProperty("GD_FILM_STATE") || "{}"); }
  catch (e) { return {}; }
}
function gdStateSet(s) { PropertiesService.getScriptProperties().setProperty("GD_FILM_STATE", JSON.stringify(s)); }

// film key -> { title, notes: ["Best Actor: Matt Damon", ...] }
function gdFilmContext(rows) {
  var ctx = {};
  rows.forEach(function(r) {
    var key = ufNormTitle(r.film_title);
    if (!ctx[key]) ctx[key] = { title: r.film_title, notes: [] };
    var who = "";
    if (r.performer_name) who = r.category === "Best Song" ? ": “" + r.performer_name + "”" : ": " + r.performer_name;
    ctx[key].notes.push(r.category.replace(/^Best /, "") + who);
  });
  return ctx;
}

function gdTmdbSearch(title) {
  var url = "https://api.themoviedb.org/3/search/movie?api_key=" + TMDB_API_KEY
    + "&include_adult=false&query=" + encodeURIComponent(title);
  var resp = UrlFetchApp.fetch(url, { muteHttpExceptions: true });
  if (resp.getResponseCode() !== 200) { Logger.log("TMDb search failed for \"" + title + "\": HTTP " + resp.getResponseCode()); return null; }
  return JSON.parse(resp.getContentText()).results || [];
}

function gdDetails(tmdbId) {
  var d = ufTmdbFilmDetails(tmdbId);
  Utilities.sleep(250);
  if (!d) return null;
  return { imdb_id: d.external_ids ? (d.external_ids.imdb_id || null) : null, runtime: d.runtime || null };
}

function gdCand(r, d) {
  d = d || {};
  return {
    tmdb_id: r.id, title: r.title, release_date: r.release_date || null,
    imdb_id: d.imdb_id || null, runtime: d.runtime || null,
    popularity: Math.round(r.popularity || 0), overview: (r.overview || "").slice(0, 200)
  };
}

// Pure: decide what to do with one Gold Derby film. detailsFn(tmdbId) ->
// {imdb_id, runtime} so it can be tested without network.
//   auto     one clear in-window match
//   review   needs a human (several matches / no exact match / no IMDb id)
//   outside  exact match exists but only outside the season window
function gdClassify(gdTitle, results, win, detailsFn) {
  var key = ufNormTitle(gdTitle);
  var exact = results.filter(function(r) { return ufNormTitle(r.title) === key || ufNormTitle(r.original_title) === key; });
  var inWin = exact.filter(function(r) { return r.release_date && r.release_date >= win.start && r.release_date <= win.end; });
  if (!inWin.length) {
    if (exact.length) return { status: "outside", candidates: exact.map(function(r) { return gdCand(r); }) };
    return { status: "review", candidates: results.slice(0, 5).map(function(r) { return gdCand(r); }) };
  }
  var cands = inWin.map(function(r) { return gdCand(r, detailsFn(r.id)); });
  var c = cands[0];
  if (cands.length === 1 && c.imdb_id && (!c.runtime || c.runtime >= UF_MIN_RUNTIME)) return { status: "auto", candidates: cands };
  return { status: "review", candidates: cands };
}

// ---- signed links ----------------------------------------------------------
function gdSecret() {
  var props = PropertiesService.getScriptProperties();
  var s = props.getProperty("GD_LINK_SECRET");
  if (!s) { s = Utilities.getUuid() + Utilities.getUuid(); props.setProperty("GD_LINK_SECRET", s); }
  return s;
}
function gdSign(action, title, tmdbId, exp) {
  var bytes = Utilities.computeHmacSha256Signature([action, title, tmdbId, exp].join("|"), gdSecret());
  return bytes.map(function(b) { return ("0" + (b & 0xff).toString(16)).slice(-2); }).join("");
}
function gdLink(base, action, title, tmdbId, expMs, edit) {
  var id = tmdbId || "0";
  return base + "?a=" + action + "&t=" + encodeURIComponent(title) + "&id=" + encodeURIComponent(id) + "&x=" + expMs
    + "&s=" + gdSign(action, title, String(id), String(expMs)) + (edit ? "&e=1" : "");
}
function gdVerify(action, title, tmdbId, exp, sig) {
  if (!action || !title || !sig || !exp) return "That link is incomplete.";
  if (gdSign(action, title, String(tmdbId), String(exp)) !== sig) return "That link isn't valid.";
  if (Number(exp) < new Date().getTime()) return "That link has expired. A newer email with fresh links will be sent if the film is still missing.";
  return null;
}

// ---- email -----------------------------------------------------------------
var GD_ONE_CLICK = true;   // true: email buttons act immediately. false: they open a confirm page first.

var GD_C = { GOLD: "#d4a843", INK: "#14141f", MUTED: "#6b6b7b", LINE: "#e6e6ee", GREEN: "#1a7f4b", RED: "#b4322b" };
var GD_F = "font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif;";

function gdEmSection(label, count) {
  return "<div style=\"margin:26px 0 10px;padding-bottom:6px;border-bottom:2px solid " + GD_C.GOLD + "\">"
    + "<span style=\"" + GD_F + "font-size:12px;font-weight:700;letter-spacing:1.4px;text-transform:uppercase;color:" + GD_C.INK + "\">" + label + "</span>"
    + "<span style=\"" + GD_F + "font-size:12px;color:" + GD_C.MUTED + ";margin-left:8px\">" + count + "</span></div>";
}
function gdEmChips(notes) {
  return notes.map(function(n) {
    return "<span style=\"display:inline-block;margin:0 5px 5px 0;padding:2px 9px;background:#f3f1ea;border:1px solid #e7e1cf;border-radius:11px;font-size:12px;color:#5b5436\">" + ufEsc(n) + "</span>";
  }).join("");
}
function gdEmCard(inner, accent) {
  return "<div style=\"margin:0 0 12px;padding:14px 16px;background:#ffffff;border:1px solid " + GD_C.LINE + ";border-left:4px solid " + accent + ";border-radius:8px\">" + inner + "</div>";
}
function gdEmButton(href, label, bg) {
  return "<a href=\"" + ufEsc(href) + "\" style=\"display:inline-block;margin:0 6px 6px 0;padding:8px 16px;background:" + bg + ";color:#ffffff;border-radius:6px;text-decoration:none;font-size:13px;font-weight:600\">" + label + "</a>";
}
function gdEmLink(href, label, color) {
  return "<a href=\"" + ufEsc(href) + "\" style=\"display:inline-block;margin:0 14px 4px 0;font-size:12px;color:" + (color || GD_C.MUTED) + "\">" + label + "</a>";
}
function gdEmTitle(t, date) {
  return "<div style=\"" + GD_F + "font-size:17px;font-weight:700;color:" + GD_C.INK + "\">" + ufEsc(t)
    + (date ? " <span style=\"font-weight:400;font-size:13px;color:" + GD_C.MUTED + "\">" + ufEsc(date) + "</span>" : "") + "</div>";
}
function gdEmShell(heading, intro, inner, footer) {
  return "<div style=\"background:#f4f4f8;padding:24px 12px\">"
    + "<div style=\"max-width:600px;margin:0 auto;" + GD_F + "color:" + GD_C.INK + "\">"
    + "<div style=\"background:#0d0d14;padding:20px 24px;border-radius:10px 10px 0 0\">"
    + "<div style=\"font-size:11px;letter-spacing:2px;text-transform:uppercase;color:" + GD_C.GOLD + "\">Studio Exec Fantasy</div>"
    + "<div style=\"font-size:21px;font-weight:700;color:#ffffff;margin-top:4px\">" + heading + "</div></div>"
    + "<div style=\"background:#fbfbfd;padding:6px 24px 22px;border:1px solid " + GD_C.LINE + ";border-top:0;border-radius:0 0 10px 10px\">"
    + "<p style=\"margin:16px 0 0;font-size:14px;line-height:1.5;color:#3d3d4d\">" + intro + "</p>"
    + inner
    + "<p style=\"margin:22px 0 0;font-size:11px;color:#9a9aaa\">" + footer + "</p>"
    + "</div></div></div>";
}
function gdCandBox(c, buttons) {
  var meta = [c.release_date || "no date", c.runtime ? c.runtime + " min" : null, c.imdb_id ? null : "no IMDb id yet"].filter(Boolean).join(" &middot; ");
  return "<div style=\"margin-top:8px;padding:10px 12px;background:#f7f7fb;border-radius:6px\">"
    + "<div style=\"font-size:14px;font-weight:600\">" + ufEsc(c.title) + " <span style=\"font-weight:400;font-size:12px;color:" + GD_C.MUTED + "\">" + meta + "</span></div>"
    + (c.overview ? "<div style=\"margin-top:3px;font-size:12px;line-height:1.45;color:" + GD_C.MUTED + "\">" + ufEsc(c.overview) + "</div>" : "")
    + (buttons ? "<div style=\"margin-top:9px\">" + buttons + "</div>" : "")
    + "</div>";
}

// Email about Gold Derby contenders (auto-added / need approval / name mismatches).
function gdBuildEmail(added, review, mismatches, baseUrl, expMs) {
  var h = "";
  if (added.length) {
    h += gdEmSection("Added automatically", added.length);
    added.forEach(function(a) {
      h += gdEmCard(gdEmTitle(a.title, a.cand && a.cand.release_date) + "<div style=\"margin-top:7px\">" + gdEmChips(a.notes) + "</div>", GD_C.GREEN);
    });
  }
  if (review.length) {
    h += gdEmSection("Needs your OK", review.length);
    if (!baseUrl) h += "<p style=\"margin:0 0 12px;padding:10px 12px;background:#fdf0ef;border-radius:6px;font-size:13px;color:#a33\">The approval buttons are off because the script isn't deployed as a web app yet (Deploy &rarr; New deployment &rarr; Web app). Until then, add these on the Universe page.</p>";
    review.forEach(function(rv) {
      var inner = gdEmTitle(rv.title) + "<div style=\"margin-top:7px\">" + gdEmChips(rv.notes) + "</div>";
      if (rv.cands.length) {
        inner += "<div style=\"margin-top:8px;font-size:11px;letter-spacing:1px;text-transform:uppercase;color:" + GD_C.MUTED + "\">Possible matches on TMDb</div>";
        rv.cands.forEach(function(c) {
          inner += gdCandBox(c, baseUrl
            ? gdEmButton(gdLink(baseUrl, "add", rv.title, c.tmdb_id, expMs), "Add this one", GD_C.GREEN)
              + gdEmLink(gdLink(baseUrl, "add", rv.title, c.tmdb_id, expMs, true), "Adjust title / date first")
            : "");
        });
      } else {
        inner += "<div style=\"margin-top:10px;font-size:13px;color:#a33\">No TMDb matches found &mdash; add it manually on the Universe page if it's real.</div>";
      }
      if (baseUrl) inner += "<div style=\"margin-top:12px\">" + gdEmLink(gdLink(baseUrl, "skip", rv.title, "0", expMs), "Skip &mdash; don't add this film") + "</div>";
      h += gdEmCard(inner, GD_C.GOLD);
    });
  }
  if (mismatches.length) {
    h += gdEmSection("Named differently in the Universe", mismatches.length);
    h += "<p style=\"margin:0 0 10px;font-size:13px;line-height:1.5;color:#3d3d4d\">The Awards tab matches on title, so these won't line up until the Universe title is changed to Gold Derby's spelling.</p>";
    mismatches.forEach(function(m) {
      h += gdEmCard("<div style=\"font-size:14px\"><span style=\"color:" + GD_C.MUTED + "\">Gold Derby</span> &nbsp;<b>" + ufEsc(m.title) + "</b></div>"
        + "<div style=\"margin-top:3px;font-size:14px\"><span style=\"color:" + GD_C.MUTED + "\">Universe</span> &nbsp;&nbsp;&nbsp;&nbsp;<b>" + ufEsc(m.existingTitle) + "</b></div>", "#e0a030");
    });
  }
  return gdEmShell("Gold Derby film update",
    "Gold Derby lists Oscar contenders that weren't in the Universe. Here's what the daily check found.",
    h, "Buttons expire after 30 days. A film nobody answers is re-sent after a week.");
}

// Email about films players asked to add (film_add_requests). Called by
// processFilmRequests() in UniverseFilmsScraper.gs.
function gdBuildRequestEmail(reqs, baseUrl, expMs, appLeagueUrl) {
  var h = "";
  if (!baseUrl) h += "<p style=\"margin:16px 0 0;padding:10px 12px;background:#fdf0ef;border-radius:6px;font-size:13px;color:#a33\">The approval buttons are off because the script isn't deployed as a web app yet. Use the app link below.</p>";
  h += gdEmSection("Requests to review", reqs.length);
  reqs.forEach(function(r) {
    var c = r.candidates || { tmdb: [], universe: [] };
    var inner = gdEmTitle(r.title)
      + "<div style=\"margin-top:3px;font-size:12px;color:" + GD_C.MUTED + "\">requested by " + ufEsc(r.requester_team || "a league member") + " &middot; " + ufEsc(String(r.created_at).slice(0, 16).replace("T", " ")) + " UTC</div>";

    if (c.universe && c.universe.length) {
      inner += "<div style=\"margin-top:10px;font-size:11px;letter-spacing:1px;text-transform:uppercase;color:" + GD_C.MUTED + "\">Possibly already in the film list</div>";
      c.universe.forEach(function(u) {
        inner += gdCandBox({ title: u.title, release_date: u.release_date, imdb_id: u.imdb_id },
          baseUrl ? gdEmButton(gdLink(baseUrl, "rlink", r.id, u.imdb_id, expMs), "It's this one", GD_C.GOLD) : "");
      });
    }
    if (c.tmdb && c.tmdb.length) {
      inner += "<div style=\"margin-top:10px;font-size:11px;letter-spacing:1px;text-transform:uppercase;color:" + GD_C.MUTED + "\">TMDb matches</div>";
      c.tmdb.forEach(function(t) {
        var btns = "";
        if (baseUrl) {
          if (t.in_universe_title && t.imdb_id) {
            btns = gdEmButton(gdLink(baseUrl, "rlink", r.id, t.imdb_id, expMs), "Already in list &mdash; link", GD_C.GOLD);
          } else {
            btns = gdEmButton(gdLink(baseUrl, "radd", r.id, t.tmdb_id, expMs), "Add this one", GD_C.GREEN)
              + gdEmLink(gdLink(baseUrl, "radd", r.id, t.tmdb_id, expMs, true), "Adjust title / date first");
          }
        }
        inner += gdCandBox(t, btns);
      });
    } else {
      inner += "<div style=\"margin-top:10px;font-size:13px;color:#a33\">No TMDb matches found &mdash; may be a typo, or too obscure.</div>";
    }
    if (baseUrl) {
      inner += "<div style=\"margin-top:12px;padding-top:10px;border-top:1px solid " + GD_C.LINE + "\">"
        + gdEmButton(gdLink(baseUrl, "rtyped", r.id, "0", expMs), "Add as typed", "#4a4a5e")
        + gdEmLink(gdLink(baseUrl, "rtyped", r.id, "0", expMs, true), "Adjust title / date first")
        + gdEmLink(gdLink(baseUrl, "rreject", r.id, "0", expMs), "Reject this request", GD_C.RED)
        + "</div>";
    }
    h += gdEmCard(inner, GD_C.GOLD);
  });
  return gdEmShell("Film add request" + (reqs.length === 1 ? "" : "s"),
    "Someone couldn't find a film in the Universe and asked to add it.",
    h, "Prefer the app? <a href=\"" + ufEsc(appLeagueUrl) + "\" style=\"color:#9a9aaa\">Open the league</a> &rarr; Weekend Picks &rarr; Film requests. Buttons expire after 30 days.");
}

// ---- the sync --------------------------------------------------------------
// dryRun = log what it WOULD do; add nothing, email nothing.
function gdSyncMissingFilms(rows, dryRun) {
  var win = gdWindow();
  if (!win) { Logger.log("Missing-film sync skipped: no season window for " + GD_SEASON); return; }
  var existing = ufFetchExistingFilms();
  if (!existing) { Logger.log("Missing-film sync skipped: couldn't load the Universe film list."); return; }
  var byImdb = {};
  Object.keys(existing).forEach(function(k) { if (existing[k].imdb_id) byImdb[existing[k].imdb_id] = existing[k]; });
  var ctx = gdFilmContext(rows);
  var state = gdStateGet();
  var now = new Date();
  var added = [], review = [], mismatches = [];

  Object.keys(ctx).forEach(function(key) {
    if (existing[key]) return;
    var st = state[key];
    if (st && st.status === "skipped") return;
    if (st && st.emailedAt && (now - new Date(st.emailedAt)) < GD_REMIND_DAYS * 86400000) return;

    var f = ctx[key];
    var results = gdTmdbSearch(f.title);
    if (results === null) return; // TMDb hiccup: try again next run
    var c = gdClassify(f.title, results, win, gdDetails);
    Logger.log("Missing from Universe: " + f.title + " -> " + c.status);

    // Already in the Universe under another title? Then it needs a rename, not an add.
    var dup = null;
    c.candidates.forEach(function(x) { if (x.imdb_id && byImdb[x.imdb_id]) dup = byImdb[x.imdb_id]; });
    if (dup) { mismatches.push({ key: key, title: f.title, existingTitle: dup.title }); return; }

    if (c.status === "outside") { state[key] = { status: "outside", checkedAt: now.toISOString() }; return; }

    if (c.status === "auto") {
      var cand = c.candidates[0];
      if (dryRun) { Logger.log("  would add " + f.title + " (" + cand.release_date + ", " + cand.imdb_id + ")"); return; }
      if (ufInsertFilm(f.title, cand.release_date, cand.imdb_id)) {
        added.push({ key: key, title: f.title, notes: f.notes, cand: cand });
        state[key] = { status: "added", addedAt: now.toISOString() };
        return;
      }
      // insert failed: fall through to a human
    }
    review.push({ key: key, title: f.title, notes: f.notes, cands: c.candidates });
  });

  if (dryRun) {
    review.forEach(function(r) { Logger.log("  would email for approval: " + r.title + " (" + r.cands.length + " candidate(s))"); });
    mismatches.forEach(function(m) { Logger.log("  would flag name mismatch: " + m.title + " vs Universe \"" + m.existingTitle + "\""); });
    return;
  }
  if (!added.length && !review.length && !mismatches.length) { gdStateSet(state); Logger.log("No missing films to report."); return; }

  var base = "";
  try { base = ScriptApp.getService().getUrl() || ""; } catch (e) { base = ""; }
  var expMs = now.getTime() + GD_LINK_TTL_DAYS * 86400000;
  var to = UF_ADMIN_EMAIL || Session.getEffectiveUser().getEmail();
  var subject = "Studio Exec Fantasy: Gold Derby films "
    + (review.length ? review.length + " need your OK" : added.length + " added");
  var sent = false;
  try {
    MailApp.sendEmail({ to: to, subject: subject, htmlBody: gdBuildEmail(added, review, mismatches, base, expMs) });
    sent = true;
  } catch (e) {
    Logger.log("Email failed (will retry next run): " + e.message);
    Logger.log("Auto-added this run: " + added.map(function(a) { return a.title; }).join(", "));
  }
  if (sent) {
    review.forEach(function(r) { state[r.key] = { status: "review", emailedAt: now.toISOString() }; });
    mismatches.forEach(function(m) { state[m.key] = { status: "mismatch", emailedAt: now.toISOString() }; });
  }
  gdStateSet(state);
  Logger.log("Sync done: " + added.length + " added, " + review.length + " for approval, " + mismatches.length + " name mismatch(es)" + (sent ? ", emailed " + to : ""));
}

// Dry run: shows what the sync would do right now. Adds nothing, emails nothing.
function gdPreviewMissingFilms() {
  var html = gdFetchPage();
  if (!html) { Logger.log("Couldn't fetch the page."); return; }
  gdSyncMissingFilms(gdParseCombinedOdds(html), true);
}

// ---- approval web app -------------------------------------------------------
// Actions (signed in the link):
//   add / skip                         Gold Derby contender (title in the link)
//   radd / rlink / rtyped / rreject    a player's film request (request id in the link)
var GD_REQ_ACTIONS = { radd: 1, rlink: 1, rtyped: 1, rreject: 1 };

function gdPage(body) {
  return HtmlService.createHtmlOutput(
    "<div style=\"font-family:-apple-system,Helvetica,Arial,sans-serif;max-width:560px;margin:40px auto;padding:0 16px;color:#14141f\">"
    + "<div style=\"font-size:11px;letter-spacing:2px;text-transform:uppercase;color:#b8902f;margin-bottom:8px\">Studio Exec Fantasy</div>"
    + body + "<p id=\"out\" style=\"font-weight:bold\"></p></div>"
  ).setTitle("Studio Exec Fantasy");
}

function doGet(e) {
  var p = (e && e.parameter) || {};
  var bad = gdVerify(p.a, p.t, p.id, p.x, p.s);
  if (bad) return gdPage("<p>" + ufEsc(bad) + "</p>");
  var editable = p.a === "add" || p.a === "radd" || p.a === "rtyped";
  if (p.e === "1" && editable) return gdPage(gdEditForm(p));
  if (GD_ONE_CLICK) {
    var msg = gdApprove(p.a, p.t, p.id, p.x, p.s);
    return gdPage("<h2 style=\"margin:0 0 8px\">" + ufEsc(msg) + "</h2><p style=\"color:#6b6b7b\">You can close this tab.</p>");
  }
  return gdPage(gdConfirmBody(p));
}

function gdAskLabel(p) {
  var req = GD_REQ_ACTIONS[p.a] ? gdFetchRequest(p.t) : null;
  var name = req ? req.title : p.t;
  if (p.a === "skip") return { h: "Skip " + name + "?", d: "It won't be added and you won't be emailed about it again.", b: "Skip it" };
  if (p.a === "rreject") return { h: "Reject the request for " + name + "?", d: "", b: "Reject" };
  if (p.a === "rlink") return { h: "Link the request for " + name + " to the film already in the Universe?", d: "", b: "Link it" };
  if (p.a === "rtyped") return { h: "Add " + name + " exactly as typed?", d: "No release date or IMDb id.", b: "Add to Universe" };
  var d = ufTmdbFilmDetails(p.id);
  var line = d ? d.title + (d.release_date ? " (" + d.release_date + ")" : "") + (d.runtime ? " · " + d.runtime + " min" : "") : "TMDb id " + p.id;
  return { h: "Add " + name + " to the Universe?", d: line, b: "Add to Universe" };
}

function gdConfirmBody(p) {
  var q = gdAskLabel(p);
  return "<h2>" + ufEsc(q.h) + "</h2>" + (q.d ? "<p>" + ufEsc(q.d) + "</p>" : "") + gdButton(q.b, p, false);
}

function gdEditForm(p) {
  var title = p.t, date = "";
  if (p.a === "radd") {
    var d = ufTmdbFilmDetails(p.id);
    var req = gdFetchRequest(p.t);
    title = d ? d.title : (req ? req.title : p.t);
    date = d && d.release_date ? d.release_date : "";
  } else if (p.a === "rtyped") {
    var rq = gdFetchRequest(p.t);
    title = rq ? rq.title : p.t;
  } else {
    var d2 = ufTmdbFilmDetails(p.id);
    date = d2 && d2.release_date ? d2.release_date : "";
  }
  var field = "display:block;width:100%;box-sizing:border-box;padding:9px 10px;margin:4px 0 14px;font-size:15px;border:1px solid #ccc;border-radius:6px";
  return "<h2 style=\"margin:0 0 14px\">Adjust before adding</h2>"
    + "<label style=\"font-size:12px;color:#6b6b7b\">Title</label><input id=\"ti\" style=\"" + field + "\" value=\"" + ufEsc(title) + "\">"
    + "<label style=\"font-size:12px;color:#6b6b7b\">Release date (optional)</label><input id=\"dt\" type=\"date\" style=\"" + field + "\" value=\"" + ufEsc(date) + "\">"
    + gdButton("Add to Universe", p, true);
}

function gdButton(label, p, hasForm) {
  var args = JSON.stringify([p.a, p.t, p.id, p.x, p.s]).replace(/</g, "\\u003c");
  var over = hasForm ? "{title:document.getElementById('ti').value,date:document.getElementById('dt').value}" : "null";
  return "<button id=\"go\" style=\"padding:10px 22px;font-size:15px;background:#1a7f4b;color:#fff;border:0;border-radius:6px;cursor:pointer\">" + ufEsc(label) + "</button>"
    + "<script>document.getElementById('go').onclick=function(){var b=this;b.disabled=true;b.textContent='Working...';"
    + "var a=" + args + ";a.push(" + over + ");"
    + "google.script.run.withSuccessHandler(function(m){b.style.display='none';document.getElementById('out').textContent=m;})"
    + ".withFailureHandler(function(err){b.disabled=false;b.textContent='" + ufEsc(label) + "';document.getElementById('out').textContent='Something went wrong: '+err.message;})"
    + ".gdApprove.apply(null,a);};</script>";
}

// Titles/dates typed on the adjust page: keep them sane.
function gdCleanOver(over) {
  var o = {};
  if (over && typeof over.title === "string") { var t = over.title.replace(/\s+/g, " ").trim(); if (t.length >= 1 && t.length <= 120) o.title = t; }
  if (over && typeof over.date === "string" && /^\d{4}-\d{2}-\d{2}$/.test(over.date)) o.date = over.date;
  return o;
}

function gdFetchRequest(id) {
  var resp = UrlFetchApp.fetch(UF_SUPABASE_URL + "/rest/v1/film_add_requests?id=eq." + encodeURIComponent(id) + "&select=*",
    { muteHttpExceptions: true, headers: { apikey: UF_SUPABASE_KEY, Authorization: "Bearer " + UF_SUPABASE_KEY } });
  if (resp.getResponseCode() !== 200) return null;
  var rows = JSON.parse(resp.getContentText());
  return rows.length ? rows[0] : null;
}

// A player's film request, resolved the same three ways as in the app
// (add / link to an existing film / reject), straight through the service role.
function gdApproveRequest(action, reqId, id, over) {
  var r = gdFetchRequest(reqId);
  if (!r) return "Couldn't find that request.";
  if (r.status !== "pending") return "That request was already handled (" + r.status + ").";
  var now = new Date().toISOString();

  if (action === "rreject") {
    ufPatchFilmRequest(r.id, { status: "rejected", resolved_at: now });
    return "Rejected the request for “" + r.title + "”.";
  }

  var existing = ufFetchExistingFilms();
  if (!existing) return "Couldn't load the film list. Try the link again in a minute.";
  var byImdb = {};
  Object.keys(existing).forEach(function(k) { if (existing[k].imdb_id) byImdb[existing[k].imdb_id] = existing[k]; });

  if (action === "rlink") {
    if (!byImdb[id]) return "That film isn't in the Universe, so there's nothing to link to.";
    ufPatchFilmRequest(r.id, { status: "linked", resolved_at: now, resolution_imdb_id: id });
    return "Linked “" + r.title + "” to “" + byImdb[id].title + "” (already in the Universe).";
  }

  var title, date = null, imdb = null;
  if (action === "radd") {
    var d = ufTmdbFilmDetails(id);
    if (!d) return "Couldn't reach TMDb. Try the link again in a minute.";
    title = d.title; date = d.release_date || null;
    imdb = d.external_ids ? (d.external_ids.imdb_id || null) : null;
  } else { title = r.title; }
  if (over.title) title = over.title;
  if (over.date) date = over.date;

  if (imdb && byImdb[imdb]) {
    ufPatchFilmRequest(r.id, { status: "linked", resolved_at: now, resolution_imdb_id: imdb });
    return "“" + byImdb[imdb].title + "” was already in the Universe, so the request was linked to it.";
  }
  if (existing[ufNormTitle(title)]) return "A film called “" + title + "” is already in the Universe. Nothing was added — use “Adjust title / date first” if it's a different film.";
  if (!ufInsertFilm(title, date, imdb)) return "The database refused the add. Nothing was changed.";
  ufPatchFilmRequest(r.id, { status: "added", release_date: date, resolved_at: now, resolution_imdb_id: imdb });
  return "Added “" + title + "”" + (date ? " (" + date + ")" : "") + " to the Universe.";
}

// Called by the link (one-click) or the confirm/adjust page. Re-verifies the
// signed link before doing anything. `over` = optional {title, date} from the adjust page.
function gdApprove(action, title, tmdbId, exp, sig, over) {
  var bad = gdVerify(action, title, tmdbId, exp, sig);
  if (bad) return bad;
  over = gdCleanOver(over);
  if (GD_REQ_ACTIONS[action]) return gdApproveRequest(action, title, tmdbId, over);

  var key = ufNormTitle(title);
  var state = gdStateGet();
  if (action === "skip") {
    state[key] = { status: "skipped", at: new Date().toISOString() };
    gdStateSet(state);
    return "Skipped. You won't hear about " + title + " again.";
  }
  var existing = ufFetchExistingFilms();
  if (!existing) return "Couldn't load the film list. Try the link again in a minute.";
  if (existing[key]) return title + " is already in the Universe.";
  var d = ufTmdbFilmDetails(tmdbId);
  if (!d) return "Couldn't reach TMDb. Try the link again in a minute.";
  var imdb = d.external_ids ? (d.external_ids.imdb_id || null) : null;
  var addTitle = over.title || title, addDate = over.date || d.release_date || null;
  if (!ufInsertFilm(addTitle, addDate, imdb)) return "The database refused the add (is this film already in under another title?). Nothing was changed.";
  state[key] = { status: "added", addedAt: new Date().toISOString(), by: "email" };
  gdStateSet(state);
  return "Added " + addTitle + (addDate ? " (" + addDate + ")" : "") + " to the Universe.";
}

// Sends a sample approval email so you can check email delivery and the
// buttons end to end. Safe: the sample "Add this one" button points at a film
// that's already in the Universe, so clicking it adds nothing ("already in the
// Universe"); the Skip link only records a skip for a made-up title.
function gdSendTestEmail() {
  var base = "";
  try { base = ScriptApp.getService().getUrl() || ""; } catch (e) { base = ""; }
  var expMs = new Date().getTime() + GD_LINK_TTL_DAYS * 86400000;
  var to = UF_ADMIN_EMAIL || Session.getEffectiveUser().getEmail();
  var html = gdBuildEmail(
    [{ title: "Sample Auto-Added Film", notes: ["Best Picture"], cand: { release_date: "2026-12-25" } }],
    [{ title: "The Odyssey", notes: ["Best Picture", "Best Director: Christopher Nolan"],
       cands: [{ tmdb_id: 0, title: "The Odyssey (sample - already in the Universe)", release_date: "2026-07-17", runtime: 160, imdb_id: "tt0000000", overview: "Test email. Clicking Add does nothing because this film is already in the Universe." }] },
     { title: "Sample Skip Film Zzz", notes: ["Best Actor: Nobody"], cands: [] }],
    [], base, expMs);
  MailApp.sendEmail({ to: to, subject: "[TEST] Studio Exec Fantasy: Gold Derby films 2 need your OK", htmlBody: "<p><b>This is a test email.</b></p>" + html });
  // Sample player-request email. Its buttons point at a request that doesn't
  // exist, so clicking one just says "Couldn't find that request."
  var fake = "00000000-0000-0000-0000-000000000000";
  var reqHtml = gdBuildRequestEmail([{
    id: fake, title: "Sample Requested Film", requester_team: "Sample Studios", created_at: new Date().toISOString(),
    candidates: {
      universe: [{ title: "Sample Film Already In The List", release_date: "2026-08-01", imdb_id: "tt0000001" }],
      tmdb: [{ tmdb_id: 0, title: "Sample Requested Film", release_date: "2026-12-01", runtime: 110, imdb_id: "tt0000002", overview: "Test email. These buttons do nothing because the request doesn't exist." }]
    }
  }], base, expMs, UF_APP_URL + "/league.html");
  MailApp.sendEmail({ to: to, subject: "[TEST] Studio Exec Fantasy: 1 film add request to review", htmlBody: "<p><b>This is a test email.</b></p>" + reqHtml });
  Logger.log("Two test emails sent to " + to + (base ? " (buttons use " + base + ")" : " -- NO web app URL, so no buttons. Deploy as a web app first."));
}
