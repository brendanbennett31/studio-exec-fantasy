-- Weekend Picks: free-text picks (playtest feedback from Kai/Brandon).
-- Players type a film title into three plain fill-in-the-blank boxes instead
-- of being limited to the Universe list (e.g. "Other Mommy" isn't in the
-- Universe, so it couldn't be picked). The Universe list stays as optional
-- autocomplete suggestions only.
--
-- Scoring is still automatic where it can be: a slot is correct when the
-- picked film matches the actual result by imdb id OR by normalised title
-- (lower-case, leading "the/a/an" and punctuation ignored). A typo simply
-- won't match; an admin can correct the result with admin_resolve_weekend_picks
-- (which now takes plain titles), or check by hand.
--
-- Same function signatures as 056/058 (so existing grants carry over) except
-- the two new internal helpers, which get the usual revokes.

alter table weekend_picks
  add column if not exists pick1_title text,
  add column if not exists pick2_title text,
  add column if not exists pick3_title text;

-- Backfill any picks already submitted with the old Universe-only flow.
update weekend_picks wp set
  pick1_title = (select title from universe_films where imdb_id = wp.pick1),
  pick2_title = (select title from universe_films where imdb_id = wp.pick2),
  pick3_title = (select title from universe_films where imdb_id = wp.pick3)
where pick1_title is null or pick2_title is null or pick3_title is null;

alter table weekend_picks
  alter column pick1 drop not null,
  alter column pick2 drop not null,
  alter column pick3 drop not null,
  alter column pick1_title set not null,
  alter column pick2_title set not null,
  alter column pick3_title set not null;

-- ── helpers (internal) ──────────────────────────────────────────────────────
create or replace function public.weekend_norm_title(p text)
returns text
language sql
immutable
set search_path = public
as $$
  select regexp_replace(
           regexp_replace(lower(coalesce(p, '')), '^(the|a|an)\s+', ''),
           '[^a-z0-9]+', '', 'g');
$$;
revoke all on function public.weekend_norm_title(text) from public, anon, authenticated;

create or replace function public.weekend_slot_match(p_pick_id text, p_pick_title text, p_act_id text, p_act_title text)
returns boolean
language sql
immutable
set search_path = public
as $$
  select (coalesce(p_act_id, '') <> '' and p_pick_id is not null and p_pick_id = p_act_id)
      or (public.weekend_norm_title(p_act_title) <> ''
          and public.weekend_norm_title(p_pick_title) = public.weekend_norm_title(p_act_title));
$$;
revoke all on function public.weekend_slot_match(text, text, text, text) from public, anon, authenticated;

-- ── scoring: all three slots, in order ──────────────────────────────────────
create or replace function public.weekend_apply_results(p_week_id uuid, p_top3 text[], p_titles text[], p_by text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update weekend_pick_weeks
  set actual_top3 = p_top3, actual_top3_titles = p_titles, resolved_at = now(), resolved_by = p_by
  where id = p_week_id;

  update weekend_picks
  set is_winner = (public.weekend_slot_match(pick1, pick1_title, p_top3[1], p_titles[1])
               and public.weekend_slot_match(pick2, pick2_title, p_top3[2], p_titles[2])
               and public.weekend_slot_match(pick3, pick3_title, p_top3[3], p_titles[3]))
  where week_id = p_week_id;
end;
$$;
revoke all on function public.weekend_apply_results(uuid, text[], text[], text) from public, anon, authenticated;

-- ── submit: three free-text titles ──────────────────────────────────────────
create or replace function public.submit_weekend_picks(p_league_id uuid, p_pick1 text, p_pick2 text, p_pick3 text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_week public.weekend_pick_weeks;
  v_in text[] := array[p_pick1, p_pick2, p_pick3];
  v_titles text[] := array[null, null, null]::text[];
  v_ids text[] := array[null, null, null]::text[];
  v_keys text[] := '{}';
  v_key text;
  v_id text;
  v_t text;
  i int;
begin
  if not public.is_league_member(p_league_id, auth.uid()) then
    raise exception 'Not a member of this league';
  end if;
  if not coalesce((select weekend_picks_enabled from leagues where id = p_league_id), false) then
    raise exception 'Weekend Picks is not enabled for this league';
  end if;

  v_week := public.ensure_weekend_picks_week(p_league_id);
  -- Lock the row so a submit can't interleave with an admin closing the window.
  select * into v_week from weekend_pick_weeks where id = v_week.id for update;
  if now() >= v_week.closes_at then
    raise exception 'The submission window for this weekend is closed';
  end if;

  for i in 1..3 loop
    v_t := btrim(coalesce(v_in[i], ''));
    if v_t = '' then
      raise exception 'Pick a film for all three spots';
    end if;
    if length(v_t) > 120 then
      raise exception 'That film title is too long';
    end if;
    v_key := public.weekend_norm_title(v_t);
    if v_key = '' then
      raise exception 'Pick a film for all three spots';
    end if;
    if v_key = any(v_keys) then
      raise exception 'Each spot needs a different film';
    end if;
    v_keys := v_keys || v_key;

    -- If it matches a Universe film, remember the id and use its proper title.
    v_id := null;
    select uf.imdb_id, uf.title into v_id, v_t
    from universe_films uf
    where uf.imdb_id is not null and public.weekend_norm_title(uf.title) = v_key
    order by uf.release_date desc nulls last
    limit 1;
    if not found then
      v_t := btrim(v_in[i]);
    end if;
    v_ids[i] := v_id;
    v_titles[i] := v_t;
  end loop;

  insert into weekend_picks (week_id, league_id, user_id, pick1, pick2, pick3, pick1_title, pick2_title, pick3_title)
  values (v_week.id, p_league_id, auth.uid(), v_ids[1], v_ids[2], v_ids[3], v_titles[1], v_titles[2], v_titles[3])
  on conflict (week_id, user_id) do update
    set pick1 = excluded.pick1, pick2 = excluded.pick2, pick3 = excluded.pick3,
        pick1_title = excluded.pick1_title, pick2_title = excluded.pick2_title, pick3_title = excluded.pick3_title,
        updated_at = now();
end;
$$;
revoke all on function public.submit_weekend_picks(uuid, text, text, text) from public;
revoke execute on function public.submit_weekend_picks(uuid, text, text, text) from anon;
grant execute on function public.submit_weekend_picks(uuid, text, text, text) to authenticated;

-- ── state: titles come from what the player typed; per-slot hits when resolved
create or replace function public.weekend_picks_state(p_league_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_week public.weekend_pick_weeks;
  v_phase text;
  v_mine jsonb;
  v_picks jsonb := '[]'::jsonb;
  v_missing jsonb := '[]'::jsonb;
  v_actual jsonb;
  v_wins jsonb;
  v_my_wins int;
begin
  if not public.is_league_member(p_league_id, auth.uid()) then
    raise exception 'Not a member of this league';
  end if;
  if not coalesce((select weekend_picks_enabled from leagues where id = p_league_id), false) then
    return jsonb_build_object('enabled', false);
  end if;

  v_week := public.ensure_weekend_picks_week(p_league_id);
  v_phase := case when now() < v_week.closes_at then 'open'
                  when v_week.resolved_at is null then 'locked'
                  else 'resolved' end;

  select jsonb_build_object(
    'submitted_at', p.updated_at,
    'picks', jsonb_build_array(
      jsonb_build_object('imdb_id', p.pick1, 'title', p.pick1_title),
      jsonb_build_object('imdb_id', p.pick2, 'title', p.pick2_title),
      jsonb_build_object('imdb_id', p.pick3, 'title', p.pick3_title)))
  into v_mine
  from weekend_picks p where p.week_id = v_week.id and p.user_id = auth.uid();

  if v_phase <> 'open' then
    select coalesce(jsonb_agg(jsonb_build_object(
      'team_name', lm.team_name,
      'is_winner', p.is_winner,
      'picks', jsonb_build_array(
        jsonb_build_object('imdb_id', p.pick1, 'title', p.pick1_title),
        jsonb_build_object('imdb_id', p.pick2, 'title', p.pick2_title),
        jsonb_build_object('imdb_id', p.pick3, 'title', p.pick3_title)),
      'hits', case when v_phase = 'resolved' then jsonb_build_array(
        public.weekend_slot_match(p.pick1, p.pick1_title, v_week.actual_top3[1], v_week.actual_top3_titles[1]),
        public.weekend_slot_match(p.pick2, p.pick2_title, v_week.actual_top3[2], v_week.actual_top3_titles[2]),
        public.weekend_slot_match(p.pick3, p.pick3_title, v_week.actual_top3[3], v_week.actual_top3_titles[3])) end
    ) order by lm.team_name), '[]'::jsonb)
    into v_picks
    from weekend_picks p
    join league_members lm on lm.league_id = p.league_id and lm.user_id = p.user_id
    where p.week_id = v_week.id;

    select coalesce(jsonb_agg(lm.team_name order by lm.team_name), '[]'::jsonb)
    into v_missing
    from league_members lm
    where lm.league_id = p_league_id
      and not exists (select 1 from weekend_picks p where p.week_id = v_week.id and p.user_id = lm.user_id);
  end if;

  if v_phase = 'resolved' then
    select jsonb_agg(jsonb_build_object('imdb_id', nullif(a.id, ''), 'title', t.title) order by a.ord)
    into v_actual
    from unnest(v_week.actual_top3) with ordinality as a(id, ord)
    join unnest(v_week.actual_top3_titles) with ordinality as t(title, ord) on t.ord = a.ord;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('team_name', lm.team_name, 'wins', coalesce(w.n, 0)) order by lm.team_name), '[]'::jsonb)
  into v_wins
  from league_members lm
  left join (
    select user_id, count(*) as n from weekend_picks where league_id = p_league_id and is_winner is true group by user_id
  ) w on w.user_id = lm.user_id
  where lm.league_id = p_league_id;

  select count(*) into v_my_wins from weekend_picks where league_id = p_league_id and user_id = auth.uid() and is_winner is true;

  return jsonb_build_object(
    'enabled', true,
    'week', jsonb_build_object(
      'id', v_week.id,
      'weekend_friday', v_week.weekend_friday,
      'opens_at', v_week.opens_at,
      'closes_at', v_week.closes_at,
      'natural_closes_at', v_week.natural_closes_at,
      'resolve_after', v_week.resolve_after,
      'phase', v_phase,
      'resolved_at', v_week.resolved_at,
      'actual', v_actual),
    'mine', v_mine,
    'picks', v_picks,
    'missing', v_missing,
    'my_wins', v_my_wins,
    'wins_by_team', v_wins);
end;
$$;
revoke all on function public.weekend_picks_state(uuid) from public;
revoke execute on function public.weekend_picks_state(uuid) from anon;
grant execute on function public.weekend_picks_state(uuid) to authenticated;

-- ── admin: declare the result by typing three titles ────────────────────────
-- Same signature as before; the p_top3 entries are now plain titles (matched
-- to the Universe by normalised title when possible, otherwise stored as typed).
create or replace function public.admin_resolve_weekend_picks(p_league_id uuid, p_top3 text[])
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_week weekend_pick_weeks%rowtype;
  v_ids text[] := array['', '', '']::text[];
  v_titles text[] := array['', '', '']::text[];
  v_in text;
  v_id text;
  v_t text;
  i int;
begin
  if not public.is_league_admin(p_league_id, auth.uid()) then
    raise exception 'Only a league admin can do this';
  end if;
  if not coalesce((select weekend_picks_enabled from leagues where id = p_league_id), false) then
    raise exception 'Weekend Picks is not enabled for this league';
  end if;
  if array_length(p_top3, 1) is distinct from 3 then
    raise exception 'Give exactly three films';
  end if;

  for i in 1..3 loop
    v_in := btrim(coalesce(p_top3[i], ''));
    if public.weekend_norm_title(v_in) = '' then
      raise exception 'Give exactly three films';
    end if;
    v_id := '';
    select uf.imdb_id, uf.title into v_id, v_t
    from universe_films uf
    where uf.imdb_id is not null and public.weekend_norm_title(uf.title) = public.weekend_norm_title(v_in)
    order by uf.release_date desc nulls last
    limit 1;
    if not found then
      v_id := '';
      v_t := v_in;
    end if;
    v_ids[i] := coalesce(v_id, '');
    v_titles[i] := v_t;
  end loop;

  select * into v_week from weekend_pick_weeks
  where league_id = p_league_id and closes_at <= now()
  order by weekend_friday desc limit 1 for update;
  if not found then
    raise exception 'No locked weekend to resolve yet -- close the window first';
  end if;

  perform public.weekend_apply_results(v_week.id, v_ids, v_titles, 'admin');
end;
$$;
revoke all on function public.admin_resolve_weekend_picks(uuid, text[]) from public;
revoke execute on function public.admin_resolve_weekend_picks(uuid, text[]) from anon;
grant execute on function public.admin_resolve_weekend_picks(uuid, text[]) to authenticated;
