-- Weekend Picks (migration 056) test script. Paste into the Supabase SQL editor
-- AFTER running migration 056. Self-contained and non-destructive: it runs against
-- the ALPHA 2027 league's real members inside one transaction, impersonates them
-- via request.jwt.claims, and always ends by raising an exception so EVERYTHING it
-- did (including switching the feature on) is rolled back. A passing run ends with
-- an error whose message starts "ALL PASSED" and lists every check; a failing run
-- ends with "FAIL: <what broke>". The 2026 league is never touched (and the script
-- asserts that).

create or replace function pg_temp.cycle_check(p_at text, p_opens text, p_friday date, p_resolve text)
returns void language plpgsql as $f$
declare
  c record;
  v_opens timestamptz := p_opens::timestamptz;
  v_closes timestamptz := ((v_opens at time zone 'America/Los_Angeles') + interval '1 day') at time zone 'America/Los_Angeles';
begin
  select * into c from public.weekend_picks_cycle(p_at::timestamptz);
  if c.opens_at <> v_opens or c.closes_at <> v_closes or c.weekend_friday <> p_friday or c.resolve_after <> p_resolve::timestamptz then
    raise exception 'FAIL: cycle math at % -> opens %, closes %, friday %, resolve_after %', p_at, c.opens_at, c.closes_at, c.weekend_friday, c.resolve_after;
  end if;
end $f$;

do $test$
declare
  ids uuid[]; L uuid; A uuid; B uuid; X uuid := gen_random_uuid();
  fs text[]; ft text[]; fr text; frt text; f27 text;
  st jsonb; n int; n_members int;
  bud0 numeric; bud1 numeric;
  ok boolean; err text;
  log text := '';
  wk record;
  r record;
begin
  reset role;
  -- ── setup ──
  select array_agg(id) into ids from leagues where season = '2027' and name ilike '%alpha%';
  if coalesce(array_length(ids,1),0) <> 1 then raise exception 'FAIL: expected exactly one ALPHA 2027 league, found %', coalesce(array_length(ids,1),0); end if;
  L := ids[1];
  if L = 'c388b799-6240-46c4-ba75-da8a0d2e8db5' then raise exception 'FAIL: refusing to run against the 2026 league'; end if;
  update leagues set weekend_picks_enabled = true, weekend_picks_pool_end = date '2026-12-31' where id = L;
  select user_id into A from league_members where league_id = L and role = 'admin' order by user_id limit 1;
  select user_id into B from league_members where league_id = L and role <> 'admin' order by user_id limit 1;
  if A is null or B is null then raise exception 'FAIL: need at least one admin and one non-admin member in the ALPHA league to run this test'; end if;
  select count(*) into n_members from league_members where league_id = L;
  select array_agg(imdb_id order by release_date, imdb_id) into fs from (
    select imdb_id, release_date from universe_films
    where imdb_id is not null and release_date > (now() at time zone 'America/Los_Angeles')::date and release_date <= date '2026-12-31'
    order by release_date, imdb_id limit 6) x;
  if coalesce(array_length(fs,1),0) < 6 then raise exception 'FAIL: need 6 unreleased 2026 films in universe_films'; end if;
  select array_agg((select title from universe_films where imdb_id = x.id) order by x.ord) into ft from unnest(fs) with ordinality as x(id, ord);
  select imdb_id into fr from universe_films where imdb_id is not null and release_date < current_date - 30 limit 1;
  select title into frt from universe_films where imdb_id = fr;
  select imdb_id into f27 from universe_films where imdb_id is not null and release_date >= date '2027-01-01' limit 1;
  select count(*) into n from weekend_pick_weeks where league_id <> L;
  if n <> 0 then raise exception 'FAIL: unexpected weekend_pick_weeks rows outside the ALPHA league before the test (%)', n; end if;

  -- The real cycle may be mid-lock when you run this; force this cycle's window open so the test works at any time of the week.
  perform public.ensure_weekend_picks_week(L);
  update weekend_pick_weeks set closes_at = now() + interval '1 hour', natural_closes_at = now() + interval '1 hour', resolve_after = now() + interval '1 day', resolved_at = null where league_id = L;

  -- ── cycle math ──
  perform pg_temp.cycle_check('2026-10-06 20:59 America/Los_Angeles', '2026-09-29 21:00 America/Los_Angeles', date '2026-10-02', '2026-10-05 17:00 America/Los_Angeles');
  perform pg_temp.cycle_check('2026-10-06 21:00 America/Los_Angeles', '2026-10-06 21:00 America/Los_Angeles', date '2026-10-09', '2026-10-12 17:00 America/Los_Angeles');
  perform pg_temp.cycle_check('2026-10-07 21:01 America/Los_Angeles', '2026-10-06 21:00 America/Los_Angeles', date '2026-10-09', '2026-10-12 17:00 America/Los_Angeles');
  perform pg_temp.cycle_check('2026-10-12 18:00 America/Los_Angeles', '2026-10-06 21:00 America/Los_Angeles', date '2026-10-09', '2026-10-12 17:00 America/Los_Angeles');
  perform pg_temp.cycle_check('2026-10-13 20:59 America/Los_Angeles', '2026-10-06 21:00 America/Los_Angeles', date '2026-10-09', '2026-10-12 17:00 America/Los_Angeles');
  perform pg_temp.cycle_check('2026-10-13 21:00 America/Los_Angeles', '2026-10-13 21:00 America/Los_Angeles', date '2026-10-16', '2026-10-19 17:00 America/Los_Angeles');
  -- DST ends Sun 2026-11-01: Monday 17:00 must still be 17:00 local (PST)
  perform pg_temp.cycle_check('2026-10-27 22:00 America/Los_Angeles', '2026-10-27 21:00 America/Los_Angeles', date '2026-10-30', '2026-11-02 17:00 America/Los_Angeles');
  select * into r from public.weekend_picks_cycle('2026-10-06 21:00 America/Los_Angeles'::timestamptz);
  if r.closes_at <> '2026-10-07 21:00 America/Los_Angeles'::timestamptz then raise exception 'FAIL: closes_at should be Wed 9pm PT, got %', r.closes_at; end if;
  log := log || E'ok - cycle math (Tue 9pm open, Wed 9pm close, Friday, Monday 5pm, DST)\n';

  -- ── member A: fresh state + pool ──
  reset role; perform set_config('request.jwt.claims', json_build_object('sub', (A)::text, 'role', 'authenticated')::text, true); set local role authenticated;
  select public.weekend_picks_state(L) into st;
  if not ((st->>'enabled')::boolean and st->'week'->>'phase' = 'open' and jsonb_typeof(st->'mine') = 'null') then raise exception 'FAIL: state: enabled, phase open, no submission yet'; end if; log := log || 'ok - state: enabled, phase open, no submission yet' || E'\n';
  select count(*) into n from public.weekend_pick_pool(L);
  if not (n > 0) then raise exception 'FAIL: pool is non-empty'; end if; log := log || 'ok - pool is non-empty' || E'\n';
  if not (exists (select 1 from public.weekend_pick_pool(L) p where p.imdb_id = fr) and exists (select 1 from public.weekend_pick_pool(L) p where p.imdb_id = fs[1]) and not exists (select 1 from public.weekend_pick_pool(L) p where p.release_date > date '2026-12-31' or p.imdb_id = f27)) then raise exception 'FAIL: pool has upcoming and released films, no 2027'; end if; log := log || 'ok - pool has upcoming and already-released films but no 2027' || E'\n';
  -- submit + edit
  perform public.submit_weekend_picks(L, ft[1], ft[2], ft[3]);
  select public.weekend_picks_state(L) into st;
  if not (st->'mine'->'picks'->0->>'imdb_id' = fs[1] and st->'mine'->'picks'->1->>'imdb_id' = fs[2] and st->'mine'->'picks'->2->>'imdb_id' = fs[3]) then raise exception 'FAIL: submitted picks come back in order'; end if; log := log || 'ok - submitted picks come back in order' || E'\n';
  perform public.submit_weekend_picks(L, ft[3], ft[1], ft[2]);
  select public.weekend_picks_state(L) into st;
  if not (st->'mine'->'picks'->0->>'imdb_id' = fs[3] and st->'mine'->'picks'->2->>'imdb_id' = fs[2]) then raise exception 'FAIL: editing replaces the picks (new order)'; end if; log := log || 'ok - editing replaces the picks (new order)' || E'\n';
  -- rejections
  ok := false; begin perform public.submit_weekend_picks(L, ft[1], ft[1], ft[2]); ok := true; exception when others then err := sqlerrm; end;
  if ok then raise exception 'FAIL (no error raised): duplicate film rejected'; end if;
  if err not ilike '%different film%' then raise exception 'FAIL (wrong error "%"): duplicate film rejected', err; end if;
  log := log || 'ok - duplicate film rejected' || E'\n';
  ok := false; begin perform public.submit_weekend_picks(L, ft[1], '', ft[2]); ok := true; exception when others then err := sqlerrm; end;
  if ok then raise exception 'FAIL (no error raised): blank slot rejected'; end if;
  if err not ilike '%all three%' then raise exception 'FAIL (wrong error "%"): blank slot rejected', err; end if;
  log := log || 'ok - blank slot rejected' || E'\n';
  ok := false; begin perform public.submit_weekend_picks(L, ft[1], null, ft[2]); ok := true; exception when others then err := sqlerrm; end;
  if ok then raise exception 'FAIL (no error raised): null slot rejected'; end if;
  if err not ilike '%all three%' then raise exception 'FAIL (wrong error "%"): null slot rejected', err; end if;
  log := log || 'ok - null slot rejected' || E'\n';
  perform public.submit_weekend_picks(L, frt, ft[1], ft[2]);
  select public.weekend_picks_state(L) into st;
  if not (st->'mine'->'picks'->0->>'imdb_id' = fr) then raise exception 'FAIL: an already-released holdover can be picked'; end if; log := log || 'ok - an already-released holdover can be picked' || E'\n';
  -- free text: a title that is not in the Universe at all is fine
  perform public.submit_weekend_picks(L, 'Other Mommy', ft[1], ft[2]);
  select public.weekend_picks_state(L) into st;
  if not (st->'mine'->'picks'->0->>'title' = 'Other Mommy' and jsonb_typeof(st->'mine'->'picks'->0->'imdb_id') = 'null') then raise exception 'FAIL: free-text title outside the Universe is accepted as typed'; end if; log := log || 'ok - free-text title outside the Universe is accepted as typed' || E'\n';
  ok := false; begin perform public.submit_weekend_picks(L, 'the OTHER mommy!', ' other MOMMY ', ft[2]); ok := true; exception when others then err := sqlerrm; end;
  if ok or err not ilike '%different film%' then raise exception 'FAIL: case/punctuation variants count as the same film (%)', err; end if; log := log || 'ok - case/punctuation variants count as the same film' || E'\n';
  ok := false; begin perform public.submit_weekend_picks(L, ft[1], repeat('x', 200), ft[2]); ok := true; exception when others then err := sqlerrm; end;
  if ok or err not ilike '%too long%' then raise exception 'FAIL: over-long title rejected (%)', err; end if; log := log || 'ok - over-long title rejected' || E'\n';
  perform public.submit_weekend_picks(L, ft[3], ft[1], ft[2]);
  reset role; perform set_config('request.jwt.claims', json_build_object('sub', (X)::text, 'role', 'authenticated')::text, true); set local role authenticated;
  ok := false; begin perform public.submit_weekend_picks(L, ft[1], ft[2], ft[3]); ok := true; exception when others then err := sqlerrm; end;
  if ok then raise exception 'FAIL (no error raised): non-member cannot submit'; end if;
  if err not ilike '%not a member%' then raise exception 'FAIL (wrong error "%"): non-member cannot submit', err; end if;
  log := log || 'ok - non-member cannot submit' || E'\n';
  ok := false; begin perform public.weekend_picks_state(L); ok := true; exception when others then err := sqlerrm; end;
  if ok then raise exception 'FAIL (no error raised): non-member cannot read state'; end if;
  if err not ilike '%not a member%' then raise exception 'FAIL (wrong error "%"): non-member cannot read state', err; end if;
  log := log || 'ok - non-member cannot read state' || E'\n';
  reset role; set local role anon;
  ok := false; begin perform public.submit_weekend_picks(L, ft[1], ft[2], ft[3]); ok := true; exception when others then err := sqlerrm; end;
  if ok then raise exception 'FAIL (no error raised): anon cannot call submit'; end if;
  if err not ilike '%permission denied%' then raise exception 'FAIL (wrong error "%"): anon cannot call submit', err; end if;
  log := log || 'ok - anon cannot call submit' || E'\n';
  ok := false; begin perform public.weekend_picks_state(L); ok := true; exception when others then err := sqlerrm; end;
  if ok then raise exception 'FAIL (no error raised): anon cannot call state'; end if;
  if err not ilike '%permission denied%' then raise exception 'FAIL (wrong error "%"): anon cannot call state', err; end if;
  log := log || 'ok - anon cannot call state' || E'\n';
  -- sealed until close; no direct table access
  reset role; perform set_config('request.jwt.claims', json_build_object('sub', (B)::text, 'role', 'authenticated')::text, true); set local role authenticated;
  select public.weekend_picks_state(L) into st;
  if not (jsonb_array_length(st->'picks') = 0 and jsonb_typeof(st->'mine') = 'null' and jsonb_array_length(st->'missing') = 0) then raise exception 'FAIL: B sees nothing of A picks while open'; end if; log := log || 'ok - B sees nothing of A picks while open' || E'\n';
  ok := false; begin perform 1 from public.weekend_picks limit 1; ok := true; exception when others then err := sqlerrm; end;
  if ok then raise exception 'FAIL (no error raised): authenticated cannot read weekend_picks directly'; end if;
  if err not ilike '%permission denied%' then raise exception 'FAIL (wrong error "%"): authenticated cannot read weekend_picks directly', err; end if;
  log := log || 'ok - authenticated cannot read weekend_picks directly' || E'\n';
  ok := false; begin perform 1 from public.weekend_pick_weeks limit 1; ok := true; exception when others then err := sqlerrm; end;
  if ok then raise exception 'FAIL (no error raised): authenticated cannot read weekend_pick_weeks directly'; end if;
  if err not ilike '%permission denied%' then raise exception 'FAIL (wrong error "%"): authenticated cannot read weekend_pick_weeks directly', err; end if;
  log := log || 'ok - authenticated cannot read weekend_pick_weeks directly' || E'\n';
  ok := false; begin insert into public.weekend_picks (week_id, league_id, user_id, pick1, pick2, pick3) values (gen_random_uuid(), L, B, fs[1], fs[2], fs[3]); ok := true; exception when others then err := sqlerrm; end;
  if ok then raise exception 'FAIL (no error raised): authenticated cannot write weekend_picks directly'; end if;
  if err not ilike '%permission denied%' then raise exception 'FAIL (wrong error "%"): authenticated cannot write weekend_picks directly', err; end if;
  log := log || 'ok - authenticated cannot write weekend_picks directly' || E'\n';
  perform public.submit_weekend_picks(L, ft[3], ft[1], ft[4]);
  ok := false; begin perform public.admin_close_weekend_window(L); ok := true; exception when others then err := sqlerrm; end;
  if ok then raise exception 'FAIL (no error raised): non-admin cannot close the window'; end if;
  if err not ilike '%admin%' then raise exception 'FAIL (wrong error "%"): non-admin cannot close the window', err; end if;
  log := log || 'ok - non-admin cannot close the window' || E'\n';
  ok := false; begin perform public.admin_resolve_weekend_picks(L, array[ft[1],ft[2],ft[3]]); ok := true; exception when others then err := sqlerrm; end;
  if ok then raise exception 'FAIL (no error raised): non-admin cannot resolve'; end if;
  if err not ilike '%admin%' then raise exception 'FAIL (wrong error "%"): non-admin cannot resolve', err; end if;
  log := log || 'ok - non-admin cannot resolve' || E'\n';
  ok := false; begin perform public.admin_reset_weekend_week(L); ok := true; exception when others then err := sqlerrm; end;
  if ok then raise exception 'FAIL (no error raised): non-admin cannot reset'; end if;
  if err not ilike '%admin%' then raise exception 'FAIL (wrong error "%"): non-admin cannot reset', err; end if;
  log := log || 'ok - non-admin cannot reset' || E'\n';
  reset role; perform set_config('request.jwt.claims', json_build_object('sub', (A)::text, 'role', 'authenticated')::text, true); set local role authenticated;
  ok := false; begin perform public.admin_resolve_weekend_picks(L, array[ft[1],ft[2],ft[3]]); ok := true; exception when others then err := sqlerrm; end;
  if ok then raise exception 'FAIL (no error raised): admin cannot resolve before the window has locked'; end if;
  if err not ilike '%no locked weekend%' then raise exception 'FAIL (wrong error "%"): admin cannot resolve before the window has locked', err; end if;
  log := log || 'ok - admin cannot resolve before the window has locked' || E'\n';
  perform public.admin_close_weekend_window(L);
  select public.weekend_picks_state(L) into st;
  if not (st->'week'->>'phase' = 'locked' and jsonb_array_length(st->'picks') = 2) then raise exception 'FAIL: after close: phase locked, both submissions visible'; end if; log := log || 'ok - after close: phase locked, both submissions visible' || E'\n';
  if not (jsonb_array_length(st->'missing') = n_members - 2) then raise exception 'FAIL: after close: missing = everyone who has not submitted'; end if; log := log || 'ok - after close: missing = everyone who has not submitted' || E'\n';
  ok := false; begin perform public.submit_weekend_picks(L, ft[1], ft[2], ft[3]); ok := true; exception when others then err := sqlerrm; end;
  if ok then raise exception 'FAIL (no error raised): submit after close rejected (admin)'; end if;
  if err not ilike '%closed%' then raise exception 'FAIL (wrong error "%"): submit after close rejected (admin)', err; end if;
  log := log || 'ok - submit after close rejected (admin)' || E'\n';
  reset role; perform set_config('request.jwt.claims', json_build_object('sub', (B)::text, 'role', 'authenticated')::text, true); set local role authenticated;
  ok := false; begin perform public.submit_weekend_picks(L, ft[1], ft[2], ft[3]); ok := true; exception when others then err := sqlerrm; end;
  if ok then raise exception 'FAIL (no error raised): submit after close rejected (member)'; end if;
  if err not ilike '%closed%' then raise exception 'FAIL (wrong error "%"): submit after close rejected (member)', err; end if;
  log := log || 'ok - submit after close rejected (member)' || E'\n';
  select public.weekend_picks_state(L) into st;
  if not (exists (select 1 from jsonb_array_elements(st->'picks') e where e->'picks'->0->>'imdb_id' = fs[3] and e->'picks'->2->>'imdb_id' = fs[2])) then raise exception 'FAIL: B can see the locked picks of A'; end if; log := log || 'ok - B can see the locked picks of A' || E'\n';
  -- cron resolver: service_role only, respects timing, validates input
  reset role; perform set_config('request.jwt.claims', json_build_object('sub', (B)::text, 'role', 'authenticated')::text, true); set local role authenticated;
  ok := false; begin perform public.resolve_weekend_picks_week(gen_random_uuid(), array['a','b','c'], array['a','b','c']); ok := true; exception when others then err := sqlerrm; end;
  if ok then raise exception 'FAIL (no error raised): authenticated cannot call the cron resolver'; end if;
  if err not ilike '%permission denied%' then raise exception 'FAIL (wrong error "%"): authenticated cannot call the cron resolver', err; end if;
  log := log || 'ok - authenticated cannot call the cron resolver' || E'\n';
  reset role; set local role anon;
  ok := false; begin perform public.resolve_weekend_picks_week(gen_random_uuid(), array['a','b','c'], array['a','b','c']); ok := true; exception when others then err := sqlerrm; end;
  if ok then raise exception 'FAIL (no error raised): anon cannot call the cron resolver'; end if;
  if err not ilike '%permission denied%' then raise exception 'FAIL (wrong error "%"): anon cannot call the cron resolver', err; end if;
  log := log || 'ok - anon cannot call the cron resolver' || E'\n';
  reset role; select id, league_id into wk from weekend_pick_weeks where league_id = L order by weekend_friday desc limit 1;
  select public.acq_remaining_budget(L, A) into bud0;
  set local role service_role;
  ok := false; begin perform public.resolve_weekend_picks_week(wk.id, array[fs[3],fs[1],fs[2]], array['t1','t2','t3']); ok := true; exception when others then err := sqlerrm; end;
  if ok then raise exception 'FAIL (no error raised): resolver refuses before Monday 5pm PT'; end if;
  if err not ilike '%too early%' then raise exception 'FAIL (wrong error "%"): resolver refuses before Monday 5pm PT', err; end if;
  log := log || 'ok - resolver refuses before Monday 5pm PT' || E'\n';
  reset role; update weekend_pick_weeks set resolve_after = now() - interval '1 hour' where id = wk.id; set local role service_role;
  ok := false; begin perform public.resolve_weekend_picks_week(wk.id, array[fs[3],fs[1]], array['t1','t2']); ok := true; exception when others then err := sqlerrm; end;
  if ok then raise exception 'FAIL (no error raised): resolver rejects a non-3 result'; end if;
  if err not ilike '%exactly three%' then raise exception 'FAIL (wrong error "%"): resolver rejects a non-3 result', err; end if;
  log := log || 'ok - resolver rejects a non-3 result' || E'\n';
  ok := false; begin perform public.resolve_weekend_picks_week(gen_random_uuid(), array[fs[3],fs[1],fs[2]], array['t1','t2','t3']); ok := true; exception when others then err := sqlerrm; end;
  if ok then raise exception 'FAIL (no error raised): resolver rejects an unknown week'; end if;
  if err not ilike '%unknown week%' then raise exception 'FAIL (wrong error "%"): resolver rejects an unknown week', err; end if;
  log := log || 'ok - resolver rejects an unknown week' || E'\n';
  -- A predicted (3,1,2); B predicted (3,1,4). Actual (3,1,2): A wins, B (2/3 right) gets nothing.
  perform public.resolve_weekend_picks_week(wk.id, array[fs[3],fs[1],fs[2]], array['t1','t2','t3']);
  reset role;
  if not ((select is_winner from weekend_picks where week_id = wk.id and user_id = A) is true and (select is_winner from weekend_picks where week_id = wk.id and user_id = B) is false) then raise exception 'FAIL: exact order wins; two-of-three does not'; end if; log := log || 'ok - exact order wins; two-of-three does not' || E'\n';
  select public.acq_remaining_budget(L, A) into bud1;
  if not (bud1 - bud0 = 1 and public.weekend_pick_credits(L, A) = 1 and public.weekend_pick_credits(L, B) = 0) then raise exception 'FAIL: winning pick raises the Acquisitions budget by exactly 1M'; end if; log := log || 'ok - winning pick raises the Acquisitions budget by exactly 1M' || E'\n';
  reset role; perform set_config('request.jwt.claims', json_build_object('sub', (B)::text, 'role', 'authenticated')::text, true); set local role authenticated;
  select public.weekend_picks_state(L) into st;
  if not (st->'week'->>'phase' = 'resolved' and jsonb_array_length(st->'week'->'actual') = 3 and exists (select 1 from jsonb_array_elements(st->'picks') e where (e->>'is_winner')::boolean)) then raise exception 'FAIL: state: resolved, actual top 3 present, winner flagged'; end if; log := log || 'ok - state: resolved, actual top 3 present, winner flagged' || E'\n';
  reset role; set local role service_role;
  perform public.resolve_weekend_picks_week(wk.id, array[fs[3],fs[1],fs[4]], array['x','y','z']);
  reset role;
  if not ((select is_winner from weekend_picks where week_id = wk.id and user_id = A) is true and public.weekend_pick_credits(L, A) = 1) then raise exception 'FAIL: resolver is idempotent (a second call cannot re-score)'; end if; log := log || 'ok - resolver is idempotent (a second call cannot re-score)' || E'\n';
  -- both budget derivations agree (acq_remaining_budget is internal-only, so check as postgres; claims still say A)
  reset role;
  if not (not exists (select 1 from public.league_acquisitions_budgets(L) b join league_members lm on lm.league_id = L and lm.team_name = b.team_name where b.remaining <> public.acq_remaining_budget(L, lm.user_id))) then raise exception 'FAIL: league_acquisitions_budgets.remaining == acq_remaining_budget for every member (incl. the new credit)'; end if; log := log || 'ok - league_acquisitions_budgets.remaining == acq_remaining_budget for every member (incl. the new credit)' || E'\n';
  -- admin override / correction
  reset role; perform set_config('request.jwt.claims', json_build_object('sub', (A)::text, 'role', 'authenticated')::text, true); set local role authenticated;
  ok := false; begin perform public.admin_resolve_weekend_picks(L, array[ft[1],ft[2]]); ok := true; exception when others then err := sqlerrm; end;
  if ok then raise exception 'FAIL (no error raised): admin resolve rejects wrong-size result'; end if;
  if err not ilike '%three%' then raise exception 'FAIL (wrong error "%"): admin resolve rejects wrong-size result', err; end if;
  log := log || 'ok - admin resolve rejects wrong-size result' || E'\n';
  perform public.admin_resolve_weekend_picks(L, array[ft[3],ft[1],ft[4]]);
  reset role;
  if not ((select is_winner from weekend_picks where week_id = wk.id and user_id = B) is true and (select is_winner from weekend_picks where week_id = wk.id and user_id = A) is false and public.weekend_pick_credits(L, A) = 0 and public.weekend_pick_credits(L, B) = 1 and (select resolved_by from weekend_pick_weeks where id = wk.id) = 'admin') then raise exception 'FAIL: admin correction re-scores: B now wins, A no longer does, credits follow'; end if; log := log || 'ok - admin correction re-scores: B now wins, A no longer does, credits follow' || E'\n';
  -- multiple winners / zero winners
  update weekend_picks set pick1 = fs[1], pick2 = fs[2], pick3 = fs[3], pick1_title = ft[1], pick2_title = ft[2], pick3_title = ft[3] where week_id = wk.id;
  perform public.weekend_apply_results(wk.id, array[fs[1],fs[2],fs[3]], array['a','b','c'], 'admin');
  if not ((select count(*) from weekend_picks where week_id = wk.id and is_winner) = 2) then raise exception 'FAIL: multiple winners are all credited'; end if; log := log || 'ok - multiple winners are all credited' || E'\n';
  perform public.weekend_apply_results(wk.id, array[fs[5],fs[6],fs[4]], array['a','b','c'], 'admin');
  if not ((select count(*) from weekend_picks where week_id = wk.id and is_winner) = 0 and public.weekend_pick_credits(L, A) = 0) then raise exception 'FAIL: zero winners is fine'; end if; log := log || 'ok - zero winners is fine' || E'\n';
  -- typed title outside the Universe scores by normalised title ("Other Mommy" case)
  update weekend_picks set pick1 = null, pick1_title = 'Other Mommy' where week_id = wk.id and user_id = A;
  perform public.weekend_apply_results(wk.id, array['', fs[2], fs[3]], array['other mommy', 'x', 'y'], 'cron');
  if not ((select is_winner from weekend_picks where week_id = wk.id and user_id = A) is true) then raise exception 'FAIL: a typed non-Universe title wins by title match'; end if; log := log || 'ok - a typed non-Universe title wins by title match' || E'\n';
  update weekend_picks set pick1 = fs[1], pick1_title = ft[1] where week_id = wk.id and user_id = A;
  perform public.weekend_apply_results(wk.id, array['', fs[2], fs[3]], array['?','b','c'], 'admin');
  if not ((select count(*) from weekend_picks where week_id = wk.id and is_winner) = 0) then raise exception 'FAIL: an unknown top-3 film (empty slot) never matches'; end if; log := log || 'ok - an unknown top-3 film (empty slot) never matches' || E'\n';
  ok := false; begin update weekend_picks set pick2 = pick1 where week_id = wk.id; ok := true; exception when others then err := sqlerrm; end;
  if ok then raise exception 'FAIL (no error raised): DB rejects duplicate films within one pick set'; end if;
  if err not ilike '%check constraint%' then raise exception 'FAIL (wrong error "%"): DB rejects duplicate films within one pick set', err; end if;
  log := log || 'ok - DB rejects duplicate films within one pick set' || E'\n';
  -- reset
  reset role; perform set_config('request.jwt.claims', json_build_object('sub', (B)::text, 'role', 'authenticated')::text, true); set local role authenticated;
  ok := false; begin perform public.admin_reset_weekend_week(L); ok := true; exception when others then err := sqlerrm; end;
  if ok then raise exception 'FAIL (no error raised): non-admin cannot reset (again)'; end if;
  if err not ilike '%admin%' then raise exception 'FAIL (wrong error "%"): non-admin cannot reset (again)', err; end if;
  log := log || 'ok - non-admin cannot reset (again)' || E'\n';
  reset role; perform set_config('request.jwt.claims', json_build_object('sub', (A)::text, 'role', 'authenticated')::text, true); set local role authenticated;
  perform public.admin_reset_weekend_week(L);
  select public.weekend_picks_state(L) into st;
  reset role;
  if not (st->'week'->>'phase' = 'open' and jsonb_typeof(st->'mine') = 'null' and (select count(*) from weekend_picks where week_id = wk.id) = 0 and (select resolved_at is null and closes_at = natural_closes_at from weekend_pick_weeks where id = wk.id)) then raise exception 'FAIL: reset: picks gone, result cleared, window reopened'; end if; log := log || 'ok - reset: picks gone, result cleared, window reopened' || E'\n';
  reset role; perform set_config('request.jwt.claims', json_build_object('sub', (B)::text, 'role', 'authenticated')::text, true); set local role authenticated;
  perform public.submit_weekend_picks(L, ft[1], ft[2], ft[3]);
  reset role;
  if not ((select count(*) from weekend_picks where week_id = wk.id) = 1) then raise exception 'FAIL: members can submit again after a reset'; end if; log := log || 'ok - members can submit again after a reset' || E'\n';
  -- 2026 league isolation
  reset role; perform set_config('request.jwt.claims', json_build_object('sub', (A)::text, 'role', 'authenticated')::text, true); set local role authenticated;
  ok := false; begin perform public.submit_weekend_picks('c388b799-6240-46c4-ba75-da8a0d2e8db5', fs[1], fs[2], fs[3]); ok := true; exception when others then err := sqlerrm; end;
  if ok then raise exception 'FAIL (no error raised): calling Weekend Picks on the 2026 league does nothing'; end if;
  if err not ilike '%' then raise exception 'FAIL (wrong error "%"): calling Weekend Picks on the 2026 league does nothing', err; end if;
  log := log || 'ok - calling Weekend Picks on the 2026 league does nothing' || E'\n';
  reset role;
  if not ((select count(*) from weekend_pick_weeks where league_id <> L) = 0 and (select count(*) from weekend_picks where league_id <> L) = 0 and (select count(*) from leagues where weekend_picks_enabled and id <> L) = 0 and not (select weekend_picks_enabled from leagues where id = 'c388b799-6240-46c4-ba75-da8a0d2e8db5')) then raise exception 'FAIL: no rows for any other league; no other league enabled'; end if; log := log || 'ok - no rows for any other league; no other league enabled' || E'\n';
  -- privilege matrix
  if not (not has_function_privilege('anon','public.weekend_pick_pool(uuid)','execute') and not has_function_privilege('anon','public.weekend_picks_state(uuid)','execute') and not has_function_privilege('anon','public.submit_weekend_picks(uuid,text,text,text)','execute') and not has_function_privilege('anon','public.admin_close_weekend_window(uuid)','execute') and not has_function_privilege('anon','public.admin_resolve_weekend_picks(uuid,text[])','execute') and not has_function_privilege('anon','public.admin_reset_weekend_week(uuid)','execute') and not has_function_privilege('anon','public.league_acquisitions_budgets(uuid)','execute') and not has_function_privilege('anon','public.resolve_weekend_picks_week(uuid,text[],text[])','execute') and not has_function_privilege('anon','public.weekend_apply_results(uuid,text[],text[],text)','execute') and not has_function_privilege('anon','public.ensure_weekend_picks_week(uuid)','execute') and not has_function_privilege('anon','public.weekend_picks_cycle(timestamptz)','execute') and not has_function_privilege('anon','public.weekend_pool_end(uuid)','execute') and not has_function_privilege('anon','public.weekend_pick_credits(uuid,uuid)','execute') and not has_function_privilege('anon','public.acq_remaining_budget(uuid,uuid)','execute') and has_function_privilege('authenticated','public.weekend_pick_pool(uuid)','execute') and has_function_privilege('authenticated','public.weekend_picks_state(uuid)','execute') and has_function_privilege('authenticated','public.submit_weekend_picks(uuid,text,text,text)','execute') and has_function_privilege('authenticated','public.admin_close_weekend_window(uuid)','execute') and has_function_privilege('authenticated','public.admin_resolve_weekend_picks(uuid,text[])','execute') and has_function_privilege('authenticated','public.admin_reset_weekend_week(uuid)','execute') and has_function_privilege('authenticated','public.league_acquisitions_budgets(uuid)','execute') and not has_function_privilege('authenticated','public.resolve_weekend_picks_week(uuid,text[],text[])','execute') and not has_function_privilege('authenticated','public.weekend_apply_results(uuid,text[],text[],text)','execute') and not has_function_privilege('authenticated','public.ensure_weekend_picks_week(uuid)','execute') and not has_function_privilege('authenticated','public.weekend_picks_cycle(timestamptz)','execute') and not has_function_privilege('authenticated','public.weekend_pool_end(uuid)','execute') and not has_function_privilege('authenticated','public.weekend_pick_credits(uuid,uuid)','execute') and not has_function_privilege('authenticated','public.acq_remaining_budget(uuid,uuid)','execute') and has_function_privilege('service_role','public.resolve_weekend_picks_week(uuid,text[],text[])','execute') and not has_table_privilege('anon','public.weekend_picks','select') and not has_table_privilege('authenticated','public.weekend_picks','select') and not has_table_privilege('authenticated','public.weekend_pick_weeks','select')) then raise exception 'FAIL: grants: anon gets nothing; authenticated only the client RPCs; service_role runs the resolver'; end if; log := log || 'ok - grants: anon gets nothing; authenticated only the client RPCs; service_role runs the resolver' || E'\n';

  raise exception E'ALL PASSED (everything rolled back)\n%', log;
end
$test$;
