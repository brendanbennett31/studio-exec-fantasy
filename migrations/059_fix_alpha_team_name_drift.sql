-- One-off data repair for the ALPHA (experimental 2027) league only, same
-- class of bug as migration 033 for the 2026 league: this league was
-- duplicated from the 2026 league back when its league_picks.team_name still
-- held the old team codes (BRANDON / RAFA / KAI), while league_members.team_name
-- holds the real names (Brandon / Rafael / sampadiankai). Everything that
-- joins picks to members by team_name silently broke:
--   * Standings showed Rafa twice (11 picks under "RAFA", plus the $20M Star
--     Wars: Starfighter acquisition under "Rafael", which acquisitions write
--     using the member's real name);
--   * the acquisitions budget never charged that $20M, because
--     acq_remaining_budget matches picks to members by team_name;
--   * the weekly snapshots (Trends) carried a phantom all-zero "Rafael" team
--     next to the real "RAFA" history.
-- PATRICK is intentionally left alone: he has no account in this league yet
-- (picks entered by hand), exactly like Patrick in 2026. Once he joins, rename
-- his picks/snapshots to his team name the same way.
--
-- Scoped strictly to this league's id, guarded by name/season so it can't
-- touch any other league, and it refuses to run if the phantom "Rafael"
-- snapshot rows are anything but zero (so no real history is ever dropped).
-- Safe to re-run: once the RAFA rows are gone it only repeats no-op renames.
do $$
declare
  v_league constant uuid := 'dafbb0fd-7b29-41ac-8b15-dd002cdc6db7';
  v_nonzero int;
begin
  if not exists (select 1 from leagues where id = v_league and season = '2027' and name ilike '%alpha%') then
    raise exception 'League % is not the ALPHA 2027 league -- refusing to run', v_league;
  end if;

  -- Only while the old RAFA history still exists (i.e. this hasn't run yet):
  -- after the rename, "Rafael" rows are the real history and must be kept.
  if exists (select 1 from weekly_bo_snapshots where league_id::text = v_league::text and team = 'RAFA')
     or exists (select 1 from weekly_poi_snapshots where league_id::text = v_league::text and team = 'RAFA') then
    select (select count(*) from weekly_bo_snapshots  where league_id::text = v_league::text and team = 'Rafael' and bo  <> 0)
         + (select count(*) from weekly_poi_snapshots where league_id::text = v_league::text and team = 'Rafael' and poi <> 0)
    into v_nonzero;
    if v_nonzero > 0 then
      raise exception 'Phantom Rafael snapshot rows are not all zero (%) -- merge by hand instead', v_nonzero;
    end if;

    -- Phantom rows (they'd collide with the renamed RAFA history).
    delete from weekly_bo_snapshots  where league_id::text = v_league::text and team = 'Rafael';
    delete from weekly_poi_snapshots where league_id::text = v_league::text and team = 'Rafael';
  end if;

  update league_picks set team_name = 'Brandon'      where league_id::text = v_league::text and team_name = 'BRANDON';
  update league_picks set team_name = 'Rafael'       where league_id::text = v_league::text and team_name = 'RAFA';
  update league_picks set team_name = 'sampadiankai' where league_id::text = v_league::text and team_name = 'KAI';

  update weekly_bo_snapshots  set team = 'Brandon'      where league_id::text = v_league::text and team = 'BRANDON';
  update weekly_bo_snapshots  set team = 'Rafael'       where league_id::text = v_league::text and team = 'RAFA';
  update weekly_bo_snapshots  set team = 'sampadiankai' where league_id::text = v_league::text and team = 'KAI';
  update weekly_poi_snapshots set team = 'Brandon'      where league_id::text = v_league::text and team = 'BRANDON';
  update weekly_poi_snapshots set team = 'Rafael'       where league_id::text = v_league::text and team = 'RAFA';
  update weekly_poi_snapshots set team = 'sampadiankai' where league_id::text = v_league::text and team = 'KAI';
end $$;

-- Should now be BB, Brandon, PATRICK, Rafael, sampadiankai (and nothing else).
select 'picks' as kind, team_name, count(*)::text as n
from league_picks where league_id = 'dafbb0fd-7b29-41ac-8b15-dd002cdc6db7' group by team_name
union all
select 'snapshots', team, count(*)::text
from weekly_bo_snapshots where league_id = 'dafbb0fd-7b29-41ac-8b15-dd002cdc6db7' group by team
order by 1, 2;
