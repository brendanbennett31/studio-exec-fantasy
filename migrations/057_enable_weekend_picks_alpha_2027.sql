-- Switch Weekend Picks on for the ALPHA / experimental 2027 league ONLY.
-- (Brandon's playtest: "Please do not touch anything from the 2026 league.")
--
-- Name-guarded: refuses to run unless exactly one 2027 league has "alpha" in
-- its name, and updates strictly by that league's id. The 2026 league is never
-- selected. Pool end is 2026-12-31 so the test league can pick from the
-- remaining 2026 slate (no 2027 films, per the request).
do $$
declare
  v_ids uuid[];
begin
  select array_agg(id) into v_ids from leagues where season = '2027' and name ilike '%alpha%';
  if coalesce(array_length(v_ids, 1), 0) <> 1 then
    raise exception 'Expected exactly one ALPHA 2027 league, found %', coalesce(array_length(v_ids, 1), 0);
  end if;
  if v_ids[1] = 'c388b799-6240-46c4-ba75-da8a0d2e8db5' then
    raise exception 'Refusing to touch the 2026 league';
  end if;
  update leagues
  set weekend_picks_enabled = true, weekend_picks_pool_end = date '2026-12-31'
  where id = v_ids[1];
end $$;

select id, name, season, weekend_picks_enabled, weekend_picks_pool_end, acquisitions_enabled
from leagues where weekend_picks_enabled;
