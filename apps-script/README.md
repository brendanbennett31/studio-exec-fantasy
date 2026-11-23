# Apps Script (scheduled jobs)

Source of truth for the Google Apps Script project "STUDIO EXE FANTASY". Paste files into the
project by name; the project has no build step. **No secrets live in these files.**

| File | What it does |
|---|---|
| `UniverseFilmsScraper.gs` | Config + shared helpers (`ufGetAll`, `ufCallRpc`...), TMDb film discovery, acquisition windows, weekend-picks resolution, film-request emails, notifications |
| `BoxOffice.gs` | Box Office Mojo: totals + opening weekend, day-by-day grosses, weekly snapshots |
| `GoldDerbyCombinedOddsScraper.gs` | Awards odds, auto-adding missing contender films, email approval buttons (web app `doGet`) |
| `Triggers.gs` | `TRIGGER_PLAN` (the only place schedules are defined), `syncTriggers`, `listTriggers`, `checkSetup` |

## Script properties (Project Settings -> Script properties)

| Name | Value |
|---|---|
| `SUPABASE_SERVICE_KEY` | Supabase service-role key (rotating the key = change this one value) |
| `TMDB_API_KEY` | TMDb API key |

Run `checkSetup()` after pasting or changing anything: it tests both keys and the time zone.

## Triggers

Edit `TRIGGER_PLAN` in `Triggers.gs`, then run `syncTriggers()`. It deletes every trigger you own and
recreates exactly the plan, so duplicates can't accumulate. Triggers owned by "Other user" can only be
deleted by that person. `listTriggers()` shows what exists vs. the plan.

## Adding a season / league

Nothing per league: every job covers every league. For a new season add its window to
`UF_SEASON_WINDOWS` (here), `seasonWindowFor()` in `league.html` and `dashboard.html`, and
`SEASONS` in `universe.html`, and update `GD_SEASON` / `GD_URL` in the Gold Derby file.

## Limits that shape the design

Apps Script runs a job for at most 6 minutes. The box-office jobs only fetch films that can still
change, sweep settled films weekly, go stalest-first, and stop starting new films after 5 minutes.
