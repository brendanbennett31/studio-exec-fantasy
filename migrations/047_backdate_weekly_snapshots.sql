-- One-time port of the pre-migration-046 weekly history (written under the
-- legacy text id "sef-2026", keyed by the ORIGINAL hardcoded owner codes)
-- into the real league uuid, with those codes translated to whatever each
-- player's studio is named today. Purely additive: `do nothing` on
-- conflict means any week the new snapshot_weekly_bo_and_poi() RPC has
-- already written under the real uuid (i.e. today's) is left untouched --
-- this only fills in the gap of weeks that never existed under the uuid at
-- all.
--
-- Mapping verified two ways before writing this: (1) cross-checked against
-- migration 034's original rename mapping, and (2) independently confirmed
-- by comparing today's freshly-computed totals (same underlying
-- league_picks/universe_films data, just a few days further along) against
-- the historical BB/KAI/BRANDON/RAFA figures -- BB and KAI matched their
-- current-name counterparts exactly (same-day bo totals), BRANDON and RAFA
-- were within a few hundred dollars (expected: several days of real box
-- office movement between the old snapshot dates and today). RAFA maps to
-- "Sacko Studios", not migration 034's "Dwayne the Rock's Wig" -- team
-- names are player-editable (rename_my_team/the Settings tab), so that
-- player renamed again sometime after 034 ran. PATRICK is unchanged: no
-- real league_members row exists for him yet (see item 21 in the project
-- to-do memory), so league_picks/league_members still use the literal
-- "PATRICK" code today too.
insert into weekly_bo_snapshots (league_id, week_label, team, bo, snapshot_date)
select
  'c388b799-6240-46c4-ba75-da8a0d2e8db5'::uuid,
  week_label,
  case team
    when 'BRANDON' then 'Continental Studios'
    when 'KAI'     then 'Ginza Films'
    when 'RAFA'    then 'Sacko Studios'
    when 'BB'      then 'No Wot Studios'
    else team -- PATRICK, or anything unrecognized -- carried through as-is
  end,
  bo,
  snapshot_date
from weekly_bo_snapshots
where league_id = 'sef-2026'
on conflict (league_id, week_label, team) do nothing;

insert into weekly_poi_snapshots (league_id, week_label, team, poi, snapshot_date)
select
  'c388b799-6240-46c4-ba75-da8a0d2e8db5'::uuid,
  week_label,
  case team
    when 'BRANDON' then 'Continental Studios'
    when 'KAI'     then 'Ginza Films'
    when 'RAFA'    then 'Sacko Studios'
    when 'BB'      then 'No Wot Studios'
    else team
  end,
  poi,
  snapshot_date
from weekly_poi_snapshots
where league_id = 'sef-2026'
on conflict (league_id, week_label, team) do nothing;
