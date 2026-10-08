-- Film add-request (migration 063) test script. Paste into the Supabase SQL editor
-- AFTER running 063. Non-destructive: runs against the ALPHA 2027 league's real
-- members inside one transaction (impersonating them via request.jwt.claims) and
-- always ends by raising an exception so everything it did is rolled back. A passing
-- run ends with an error whose message starts "ALL PASSED".
do $test$
declare
  ids uuid[]; L uuid; A uuid; B uuid; X uuid := gen_random_uuid();
  r jsonb; rid uuid; rid2 uuid; n int; log text := ''; ok boolean; err text;
  existing_title text; existing_imdb text;
begin
  reset role;
  select array_agg(id) into ids from leagues where season = '2027' and name ilike '%alpha%';
  if coalesce(array_length(ids,1),0) <> 1 then raise exception 'FAIL: expected exactly one ALPHA 2027 league'; end if;
  L := ids[1];
  select user_id into A from league_members where league_id = L and role = 'admin' order by user_id limit 1;
  select user_id into B from league_members where league_id = L and role <> 'admin' order by user_id limit 1;
  if A is null or B is null then raise exception 'FAIL: need an admin and a non-admin member'; end if;
  select title, imdb_id into existing_title, existing_imdb from universe_films where imdb_id is not null limit 1;
  select count(*) into n from film_add_requests; if n <> 0 then raise exception 'FAIL: expected no existing requests before the test (%)', n; end if;
  reset role; perform set_config('request.jwt.claims', json_build_object('sub', (B)::text, 'role', 'authenticated')::text, true); set local role authenticated;
  r := public.request_film_add(L, '  Brand New Test Film  ');
  if not (r->>'status' = 'requested') then raise exception 'FAIL: member can file a request'; end if; log := log || 'ok - member can file a request' || E'\n';
  rid := (r->>'id')::uuid;
  r := public.request_film_add(L, 'brand new TEST film!');
  if not (r->>'status' = 'already_requested' and (r->>'id')::uuid = rid) then raise exception 'FAIL: same film (case/punctuation) is not requested twice'; end if; log := log || 'ok - same film (case/punctuation) is not requested twice' || E'\n';
  r := public.request_film_add(L, upper(existing_title));
  if not (r->>'status' = 'exists') then raise exception 'FAIL: a film already in the Universe says so'; end if; log := log || 'ok - a film already in the Universe says so' || E'\n';
  ok := false; begin perform public.request_film_add(L, '  '); ok := true; exception when others then err := sqlerrm; end;
  if ok then raise exception 'FAIL (no error raised): blank title rejected'; end if;
  if err not ilike '%name first%' then raise exception 'FAIL (wrong error "%"): blank title rejected', err; end if;
  log := log || 'ok - blank title rejected' || E'\n';
  ok := false; begin perform public.request_film_add(L, repeat('x', 200)); ok := true; exception when others then err := sqlerrm; end;
  if ok then raise exception 'FAIL (no error raised): over-long title rejected'; end if;
  if err not ilike '%too long%' then raise exception 'FAIL (wrong error "%"): over-long title rejected', err; end if;
  log := log || 'ok - over-long title rejected' || E'\n';
  perform public.request_film_add(L, 'Film Two'); perform public.request_film_add(L, 'Film Three'); perform public.request_film_add(L, 'Film Four'); perform public.request_film_add(L, 'Film Five');
  ok := false; begin perform public.request_film_add(L, 'Film Six'); ok := true; exception when others then err := sqlerrm; end;
  if ok then raise exception 'FAIL (no error raised): a sixth pending request is refused'; end if;
  if err not ilike '%several films%' then raise exception 'FAIL (wrong error "%"): a sixth pending request is refused', err; end if;
  log := log || 'ok - a sixth pending request is refused' || E'\n';
  reset role; perform set_config('request.jwt.claims', json_build_object('sub', (X)::text, 'role', 'authenticated')::text, true); set local role authenticated;
  ok := false; begin perform public.request_film_add(L, 'Whatever Film'); ok := true; exception when others then err := sqlerrm; end;
  if ok then raise exception 'FAIL (no error raised): non-member cannot request'; end if;
  if err not ilike '%not a member%' then raise exception 'FAIL (wrong error "%"): non-member cannot request', err; end if;
  log := log || 'ok - non-member cannot request' || E'\n';
  reset role; set local role anon;
  ok := false; begin perform public.request_film_add(L, 'Whatever Film'); ok := true; exception when others then err := sqlerrm; end;
  if ok then raise exception 'FAIL (no error raised): anon cannot request'; end if;
  if err not ilike '%permission denied%' then raise exception 'FAIL (wrong error "%"): anon cannot request', err; end if;
  log := log || 'ok - anon cannot request' || E'\n';
  reset role; perform set_config('request.jwt.claims', json_build_object('sub', (B)::text, 'role', 'authenticated')::text, true); set local role authenticated;
  ok := false; begin perform 1 from public.film_add_requests limit 1; ok := true; exception when others then err := sqlerrm; end;
  if ok then raise exception 'FAIL (no error raised): members cannot read the table directly'; end if;
  if err not ilike '%permission denied%' then raise exception 'FAIL (wrong error "%"): members cannot read the table directly', err; end if;
  log := log || 'ok - members cannot read the table directly' || E'\n';
  ok := false; begin perform public.list_film_add_requests(L); ok := true; exception when others then err := sqlerrm; end;
  if ok then raise exception 'FAIL (no error raised): non-admin cannot list requests'; end if;
  if err not ilike '%admin%' then raise exception 'FAIL (wrong error "%"): non-admin cannot list requests', err; end if;
  log := log || 'ok - non-admin cannot list requests' || E'\n';
  ok := false; begin perform public.resolve_film_add_request(rid, 'reject'); ok := true; exception when others then err := sqlerrm; end;
  if ok then raise exception 'FAIL (no error raised): non-admin cannot resolve'; end if;
  if err not ilike '%admin%' then raise exception 'FAIL (wrong error "%"): non-admin cannot resolve', err; end if;
  log := log || 'ok - non-admin cannot resolve' || E'\n';
  reset role; perform set_config('request.jwt.claims', json_build_object('sub', (A)::text, 'role', 'authenticated')::text, true); set local role authenticated;
  r := public.list_film_add_requests(L);
  if not (jsonb_array_length(r) = 5) then raise exception 'FAIL: admin sees the pending requests (5)'; end if; log := log || 'ok - admin sees the pending requests (5)' || E'\n';
  ok := false; begin perform public.resolve_film_add_request(rid, 'add', existing_title, null, null); ok := true; exception when others then err := sqlerrm; end;
  if ok then raise exception 'FAIL (no error raised): add that duplicates an existing title is refused'; end if;
  if err not ilike '%already in the Universe%' then raise exception 'FAIL (wrong error "%"): add that duplicates an existing title is refused', err; end if;
  log := log || 'ok - add that duplicates an existing title is refused' || E'\n';
  ok := false; begin perform public.resolve_film_add_request(rid, 'link', null, null, 'tt0000000'); ok := true; exception when others then err := sqlerrm; end;
  if ok then raise exception 'FAIL (no error raised): link needs a real Universe film'; end if;
  if err not ilike '%already in the Universe%' then raise exception 'FAIL (wrong error "%"): link needs a real Universe film', err; end if;
  log := log || 'ok - link needs a real Universe film' || E'\n';
  r := public.resolve_film_add_request(rid, 'add', 'Brand New Test Film', date '2026-12-25', 'tt9999991');
  reset role;
  if not (r->>'status' = 'added' and exists (select 1 from universe_films where imdb_id = 'tt9999991' and release_date = date '2026-12-25' and title = 'Brand New Test Film')) then raise exception 'FAIL: approve adds the film to the Universe with the chosen date/imdb'; end if; log := log || 'ok - approve adds the film to the Universe with the chosen date/imdb' || E'\n';
  reset role; perform set_config('request.jwt.claims', json_build_object('sub', (A)::text, 'role', 'authenticated')::text, true); set local role authenticated;
  ok := false; begin perform public.resolve_film_add_request(rid, 'reject'); ok := true; exception when others then err := sqlerrm; end;
  if ok then raise exception 'FAIL (no error raised): a handled request cannot be handled twice'; end if;
  if err not ilike '%already handled%' then raise exception 'FAIL (wrong error "%"): a handled request cannot be handled twice', err; end if;
  log := log || 'ok - a handled request cannot be handled twice' || E'\n';
  reset role; select id into rid2 from film_add_requests where title = 'Film Two';
  reset role; perform set_config('request.jwt.claims', json_build_object('sub', (A)::text, 'role', 'authenticated')::text, true); set local role authenticated;
  r := public.resolve_film_add_request(rid2, 'link', null, null, existing_imdb);
  if not (r->>'status' = 'linked' and (select count(*) from universe_films where title = 'Film Two') = 0) then raise exception 'FAIL: link closes the request without inserting a film'; end if; log := log || 'ok - link closes the request without inserting a film' || E'\n';
  reset role; select id into rid2 from film_add_requests where title = 'Film Three';
  reset role; perform set_config('request.jwt.claims', json_build_object('sub', (A)::text, 'role', 'authenticated')::text, true); set local role authenticated;
  r := public.resolve_film_add_request(rid2, 'reject');
  if not (r->>'status' = 'rejected') then raise exception 'FAIL: reject closes the request'; end if; log := log || 'ok - reject closes the request' || E'\n';
  r := public.list_film_add_requests(L);
  if not (jsonb_array_length(r) = 2) then raise exception 'FAIL: only still-pending requests are listed (2 left)'; end if; log := log || 'ok - only still-pending requests are listed (2 left)' || E'\n';
  reset role;
  if not (not has_function_privilege('anon','public.request_film_add(uuid,text)','execute') and has_function_privilege('authenticated','public.request_film_add(uuid,text)','execute') and not has_function_privilege('anon','public.list_film_add_requests(uuid)','execute') and has_function_privilege('authenticated','public.list_film_add_requests(uuid)','execute') and not has_function_privilege('anon','public.resolve_film_add_request(uuid,text,text,date,text)','execute') and has_function_privilege('authenticated','public.resolve_film_add_request(uuid,text,text,date,text)','execute') and not has_table_privilege('authenticated','public.film_add_requests','select') and not has_table_privilege('anon','public.film_add_requests','select')) then raise exception 'FAIL: grants: anon none, authenticated only the three RPCs, no table access'; end if; log := log || 'ok - grants: anon none, authenticated only the three RPCs, no table access' || E'\n';

  raise exception E'ALL PASSED (everything rolled back)\n%', log;
end
$test$;
