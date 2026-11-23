# Apps Script (scheduled jobs)

Source of truth for the Google Apps Script project "STUDIO EXE FANTASY". Paste files into the
project by name; the project has no build step. **No secrets live in these files.**

| File | What it does |
|---|---|
| `UniverseFilmsScraper.gs` | Config + shared helpers (`ufGetAll`, `ufCallRpc`...), TMDb film discovery, acquisition windows, weekend-picks resolution, film-request emails, notifications |
| `BoxOffice.gs` | Box Office Mojo: totals + opening weekend, day-by-day grosses, weekly snapshots |
| `GoldDerbyCombinedOddsScraper.gs` | Awards odds, auto-adding missing contender films, email approval buttons (web app `doGet`) |
| `Triggers.gs` | `TRIGGER_PLAN` (the only place schedules are defined), `syncTriggers`, `listTriggers`, `checkSetup` |
| `Health.gs` | `job()` wrapper that emails the admin when a scheduled job crashes or fails; `checkHealth` (browser errors, stalled jobs, next-season setup); `finalizeSeasons` (crowns every league once a season's Oscar results are final) |

## Script properties (Project Settings -> Script properties)

| Name | Value |
|---|---|
| `SUPABASE_SERVICE_KEY` | Supabase service-role key (rotating the key = change this one value) |
| `TMDB_API_KEY` | TMDb API key |

Run `checkSetup()` after pasting or changing anything: it tests both keys and the time zone.

## Triggers

Edit `TRIGGER_PLAN` in `Triggers.gs`, then run `syncTriggers()`. It deletes every trigger you own and
recreates exactly the plan, so duplicates can't accumulate. Every plan entry points at a `run...`
wrapper in `Health.gs`, which emails the admin the moment that job crashes or reports failures
(at most once per job per 6 hours). Triggers owned by "Other user" can only be deleted by that
person. `listTriggers()` shows what exists vs. the plan. Menu -> "Send a test alert email" checks mail.

## Alerts you can get (all from Health.gs)

| Email | Meaning / what to do |
|---|---|
| `<job> crashed` / `<job> reported N problem line(s)` | Open Executions for that job. Usually Box Office Mojo / TMDb / Gold Derby changed or was down. |
| `N new error report(s) from players' browsers` | A page threw an error for players (grouped by message). A brand-new kind of error always emails. |
| `Box office hasn't updated in N days` / `Weekly standings snapshots stopped` | A scheduled job isn't running -- check its trigger. |
| `Add the next season (YYYY)` | No season after today exists, so nobody can create a league. Universe page -> Seasons & Oscars -> Add the next season. |
| `YYYY Oscars were N days ago -- results aren't marked final` | Enter the winners and tick "Oscar results are final" so every league can finish. |
| `YYYY season finalized: N league(s) crowned` | Good news: every league of that season is final and its Wrapped page is live. |

## Once a year (the only manual steps)

1. **Add the next season** (any time after its Oscar date is announced): Universe page -> Seasons &
   Oscars -> Add the next season. Everything (league creation, eligibility windows, film discovery)
   reads the `seasons` table; no code changes.
2. **Nominations morning**: enter each category's nominees on the same page (pick films from the
   Universe list; a nominee that isn't in the Universe scores nothing and is flagged in red).
3. **Oscar night**: pick each category's winner, then tick "Oscar results are final". The daily
   `finalizeSeasons` job (6am) freezes every league of that season, crowns the winners, notifies
   players and unlocks each league's Wrapped page. "Finalize leagues now" does it immediately.
4. Point `GD_SEASON` / `GD_URL` in the Gold Derby file at the next ceremony.

## Limits that shape the design

Apps Script runs a job for at most 6 minutes. The box-office jobs only fetch films that can still
change, sweep settled films weekly, go stalest-first, and stop starting new films after 5 minutes.
