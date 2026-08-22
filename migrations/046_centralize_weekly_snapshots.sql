-- Fixes the "Cumulative Box Office Race" and POI graphs in the Trends tab,
-- which have been silently broken for any league whose team names changed
-- since the snapshot pipeline was built:
--
-- weekly_bo_snapshots/weekly_poi_snapshots have only ever been written by
-- StudioExecFantasy.gs's snapshotWeeklyBoxOffice()/snapshotWeeklyPOI(),
-- which (a) read team totals off the legacy "BY RELEASE DATE"/"BY PURCHASE
-- PRICE" Google Sheet tabs, keyed against a HARDCODED
-- {BRANDON,KAI,RAFA,PATRICK,BB} owner map, and (b) always wrote under the
-- single hardcoded LEAGUE_ID="sef-2026" constant. Once migration 034
-- renamed the real team_name values to actual studio names (Continental
-- Studios, etc.), the sheet-derived rows kept using the old owner codes as
-- keys -- league.html's charts key by the CURRENT team_name
-- (Object.keys(EXEC_COLORS)), so every team's line reads as flat zero. And
-- since the sheet+hardcoded-league approach only ever wrote sef-2026 rows
-- in the first place, every other league's Trends tab has always been
-- completely empty (this is backlog item #16, "centralize daily_bo/
-- weekly_bo_snapshots/weekly_poi_snapshots", now done for these two).
--
-- Fix: compute both snapshots directly from league_picks/universe_films
-- (the same tables Standings and everything else already derive totals
-- from), for every league, using whatever team_name is current right now.
-- Self-healing on any future rename, and works for every league
-- automatically -- no more single-league hardcoding.
--
-- daily_bo (the per-film Daily Box Office chart, not team-keyed) is NOT
-- touched here -- it doesn't have the team-mismatch bug, only the
-- single-league-only gap, and centralizing it properly means moving it
-- from "one row per league per film per day" to "one row per film per day"
-- (matching how universe_films.bo was centralized) -- a bigger reshape,
-- left as the remaining piece of #16.
create or replace function public.snapshot_weekly_bo_and_poi()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_week_start date;
  v_week_label text;
begin
  -- Monday of the current week (ISO-ish, Sunday=0 handled explicitly),
  -- matching the Apps Script's existing getWeekStartMonday() convention so
  -- week labels line up with any pre-existing rows.
  v_week_start := current_date - ((extract(dow from current_date)::int + 6) % 7);
  v_week_label := to_char(v_week_start, 'FMMon FMDD');

  insert into weekly_bo_snapshots (league_id, week_label, team, bo, snapshot_date)
  select lp.league_id, v_week_label, lp.team_name, sum(coalesce(uf.bo, 0)), v_week_start
  from league_picks lp
  join universe_films uf on uf.imdb_id = lp.imdb_id
  group by lp.league_id, lp.team_name
  on conflict (league_id, week_label, team) do update
    set bo = excluded.bo, snapshot_date = excluded.snapshot_date;

  -- Same "100% = broke even" ratio as the client's own POI math
  -- (TrendsTab's data useMemo): released-film BO over (released + voided)
  -- purchase price, bid converted from millions to raw dollars to match bo.
  insert into weekly_poi_snapshots (league_id, week_label, team, poi, snapshot_date)
  select
    lp.league_id, v_week_label, lp.team_name,
    case when sum(lp.bid) filter (where uf.bo > 0 or lp.voided) > 0
      then sum(coalesce(uf.bo, 0)) filter (where uf.bo > 0)
           / (sum(lp.bid) filter (where uf.bo > 0 or lp.voided) * 1e6)
      else 0
    end,
    v_week_start
  from league_picks lp
  join universe_films uf on uf.imdb_id = lp.imdb_id
  group by lp.league_id, lp.team_name
  on conflict (league_id, week_label, team) do update
    set poi = excluded.poi, snapshot_date = excluded.snapshot_date;
end;
$$;

revoke all on function public.snapshot_weekly_bo_and_poi() from public;
revoke execute on function public.snapshot_weekly_bo_and_poi() from anon, authenticated;
grant execute on function public.snapshot_weekly_bo_and_poi() to service_role;

-- One-time backfill so existing leagues' charts have a correct current-week
-- point immediately, instead of waiting for tomorrow's cron run.
select public.snapshot_weekly_bo_and_poi();
