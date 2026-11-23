-- Season lifecycle + guardrails for opening SEF to many leagues.
-- Built and tested against a local replica of the live schema with a full simulated season
-- (draft -> 52 weeks -> Oscars -> finalize), plus attack tests. Re-runnable.
--
--  1. seasons            one row per Oscar season (eligibility window + Oscar date). Replaces the
--                         2026/2027 values hardcoded in league_season_window() and the pages.
--  2. oscar_results      real nominations + wins, entered ONCE per season for every league.
--  3. league_standings() authoritative scoring: box office + Oscar bonuses + unspent Acquisitions
--                         budget (same formula the league page uses).
--  4. league_results +   finalize_season() freezes every league's final standings, crowns the
--     finalize_season()  winner and notifies members. Weekly snapshots stop for finished leagues.
--  5. names / colors /   studio names 1-20 chars (letters, numbers, spaces, basic punctuation),
--     league size        unique per league; display names <= 24 chars; league names <= 40;
--                         team colors from a fixed 12-color palette; leagues hold 3-12 players and
--                         joining a full league is refused; a user can't create leagues as someone
--                         else or spam-create them.
--  6. refund fix          refunding a film won in a live draft failed (draft_items FK).
--  7. display-name fix    Settings only changed the login record, not profiles.display_name.
--  8. client_errors       browsers report JS errors here; Apps Script emails Brendan.

-- ── shared helpers ───────────────────────────────────────────────────────────
create or replace function public.is_site_admin(p_user_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select is_admin from public.profiles where id = p_user_id), false);
$$;
revoke all on function public.is_site_admin(uuid) from public, anon;
grant execute on function public.is_site_admin(uuid) to authenticated, service_role;

-- tabs/newlines -> spaces; strip control, invisible, direction-override and combining characters;
-- collapse runs of spaces. (Escapes are written as \uXXXX for the regex engine, so the SQL stays
-- plain ASCII and survives copy/paste.)
create or replace function public.sef_clean_text(p text)
returns text language sql immutable set search_path = public as $$
  select btrim(regexp_replace(
           regexp_replace(
             regexp_replace(coalesce(p, ''), '[\t\n\r\f\v\u0085\u00a0\u2000-\u200a\u2028\u2029\u3000]', ' ', 'g'),
             '[\u0000-\u001f\u007f-\u009f\u00ad\u0300-\u036f\u0483-\u0489\u1ab0-\u1aff\u1dc0-\u1dff\u200b-\u200f\u202a-\u202e\u2060-\u206f\u20d0-\u20ff\ufe00-\ufe0f\ufe20-\ufe2f\ufeff]',
             '', 'g'),
           ' {2,}', ' ', 'g'));
$$;
grant execute on function public.sef_clean_text(text) to anon, authenticated, service_role;

-- studio name rule: 1-20 chars; letters (any alphabet), digits, spaces and . , ' ’ & ! ? : -
create or replace function public.sef_team_name_ok(p text)
returns boolean language sql immutable set search_path = public as $$
  select p is not null and char_length(p) between 1 and 20
     and p ~ '^[[:alnum:]][[:alnum:] .,''’&!?:-]*$' and p = public.sef_clean_text(p);
$$;
grant execute on function public.sef_team_name_ok(text) to anon, authenticated, service_role;

-- best-effort valid name from arbitrary input (used for automatic defaults, never for renames)
create or replace function public.sef_sanitize_team_name(p text)
returns text language sql immutable set search_path = public as $$
  select case when char_length(x) >= 2 then x else 'Studio' end
  from (select btrim(left(btrim(regexp_replace(public.sef_clean_text(p), '[^[:alnum:] .,''’&!?:-]', '', 'g'), ' .,''’&!?:-'), 20)) as x) s;
$$;

-- a default name not already used in the league (case-insensitive)
create or replace function public.sef_unique_team_name(p_league_id uuid, p_base text, p_user_id uuid)
returns text language plpgsql stable security definer set search_path = public as $$
declare v_base text := public.sef_sanitize_team_name(p_base); v_try text := v_base; i int := 2;
begin
  while exists (select 1 from league_members where league_id = p_league_id and user_id is distinct from p_user_id
                and lower(team_name) = lower(v_try)) loop
    v_try := btrim(left(v_base, 20 - char_length(' ' || i))) || ' ' || i;
    i := i + 1;
  end loop;
  return v_try;
end;
$$;
revoke all on function public.sef_unique_team_name(uuid, text, uuid) from public, anon, authenticated;

-- 8 team colors, validated for color-blind separation and contrast on the site's dark
-- backgrounds (same list as TEAM_COLOR_PALETTE in league.html). Leagues with 9-12 teams reuse
-- colors 1-4 with dashed chart lines, so no two teams ever look identical.
create or replace function public.sef_team_palette()
returns text[] language sql immutable as $$
  select array['#3987e5','#d95926','#199e70','#c98500','#d55181','#0ca30c','#9085e9','#e66767'];
$$;
grant execute on function public.sef_team_palette() to anon, authenticated, service_role;

-- ── 1. seasons ───────────────────────────────────────────────────────────────
create table if not exists public.seasons (
  season           text primary key,
  window_start     date not null,           -- first release date that counts (Monday after the previous Oscars)
  window_end       date not null,           -- last release date that counts (= Oscar Sunday)
  nominations_date date,                     -- Oscar nominations morning (display only)
  oscar_date       date not null,            -- ceremony
  results_final    boolean not null default false,  -- set when every winner is entered
  finalized_at     timestamptz,
  check (window_end > window_start)
);
insert into public.seasons (season, window_start, window_end, oscar_date) values
  ('2026', '2026-03-16', '2027-03-14', '2027-03-14'),
  ('2027', '2027-03-15', '2028-03-05', '2028-03-05')
on conflict (season) do nothing;
alter table public.seasons enable row level security;
drop policy if exists seasons_read on public.seasons;
create policy seasons_read on public.seasons for select to anon, authenticated using (true);
drop policy if exists seasons_site_admin on public.seasons;
create policy seasons_site_admin on public.seasons for all to authenticated
  using (public.is_site_admin(auth.uid())) with check (public.is_site_admin(auth.uid()));
grant select on public.seasons to anon, authenticated;
grant insert, update on public.seasons to authenticated;
grant all on public.seasons to service_role;

create or replace function public.league_season_window(p_season text)
returns table(window_start date, window_end date)
language sql stable set search_path = public as $$
  select s.window_start, s.window_end from public.seasons s where s.season = p_season;
$$;

-- ── 2. Oscar results ─────────────────────────────────────────────────────────
create table if not exists public.oscar_results (
  id          bigint generated always as identity primary key,
  season      text not null references public.seasons(season),
  category    text not null,
  imdb_id     text references public.universe_films(imdb_id) on update cascade,
  film_title  text not null,
  performer   text,
  is_winner   boolean not null default false,
  created_at  timestamptz not null default now(),
  unique nulls not distinct (season, category, film_title, performer)
);
create index if not exists oscar_results_season_imdb on public.oscar_results (season, imdb_id);
alter table public.oscar_results enable row level security;
drop policy if exists oscar_results_read on public.oscar_results;
create policy oscar_results_read on public.oscar_results for select to anon, authenticated using (true);
drop policy if exists oscar_results_site_admin on public.oscar_results;
create policy oscar_results_site_admin on public.oscar_results for all to authenticated
  using (public.is_site_admin(auth.uid())) with check (public.is_site_admin(auth.uid()));
grant select on public.oscar_results to anon, authenticated;
grant insert, update, delete on public.oscar_results to authenticated;
grant all on public.oscar_results to service_role;

-- one winner per category (Best Picture included)
create or replace function public.trg_oscar_one_winner()
returns trigger language plpgsql set search_path = public as $$
begin
  if new.is_winner and exists (select 1 from oscar_results where season = new.season and category = new.category
                               and is_winner and id is distinct from new.id) then
    raise exception '% already has a winner -- unmark it first', new.category;
  end if;
  new.film_title := public.sef_clean_text(new.film_title);
  new.performer := nullif(public.sef_clean_text(new.performer), '');
  if new.imdb_id is not null then
    select title into new.film_title from universe_films where imdb_id = new.imdb_id;
  end if;
  return new;
end;
$$;
drop trigger if exists oscar_one_winner on public.oscar_results;
create trigger oscar_one_winner before insert or update on public.oscar_results
  for each row execute function public.trg_oscar_one_winner();

-- ── 3. authoritative standings ───────────────────────────────────────────────
alter table public.leagues add column if not exists finalized_at timestamptz;
-- anon reads leagues through column grants (migration 006); public view links need this one too
grant select (finalized_at) on public.leagues to anon;

create or replace function public.league_standings(p_league_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_league leagues%rowtype;
  v_out jsonb;
begin
  select * into v_league from leagues where id = p_league_id;
  if not found then raise exception 'League not found'; end if;
  -- (current_user can't be used here: inside a SECURITY DEFINER function it is always the owner)
  if not (coalesce(auth.role(), '') = 'service_role' or v_league.is_public or public.is_league_member(p_league_id, auth.uid())
          or public.is_league_admin(p_league_id, auth.uid()) or public.is_site_admin(auth.uid())) then
    raise exception 'Not a member of this league';
  end if;

  with osc as (
    select o.imdb_id,
           count(*)                                                        as noms,
           count(*) filter (where o.is_winner and o.category <> 'Best Picture') as wins,
           bool_or(o.is_winner and o.category = 'Best Picture')            as bp_win,
           jsonb_agg(jsonb_build_object('category', o.category, 'performer', o.performer, 'won', o.is_winner) order by o.is_winner desc, o.category) as detail
    from oscar_results o where o.season = v_league.season and o.imdb_id is not null group by o.imdb_id
  ), films as (
    select lp.team_name,
           jsonb_build_object(
             'pick_id', lp.id, 'imdb_id', lp.imdb_id, 'title', coalesce(uf.title, lp.title), 'bid', lp.bid,
             'source', lp.source, 'voided', lp.voided, 'release', coalesce(uf.release_date, lp.release_date),
             'bo', case when lp.voided then 0 else coalesce(uf.bo, 0) end,
             'noms', coalesce(o.noms, 0), 'wins', coalesce(o.wins, 0), 'bp_win', coalesce(o.bp_win, false),
             'oscar_m', case when lp.voided then 0 else
                coalesce(o.noms, 0) * v_league.oscar_nom_bonus + coalesce(o.wins, 0) * v_league.oscar_win_bonus
                + case when coalesce(o.bp_win, false) then v_league.bp_bonus else 0 end end,
             'oscar_detail', coalesce(o.detail, '[]'::jsonb)) as f,
           case when lp.voided then 0 else coalesce(uf.bo, 0) end as bo,
           case when lp.voided then 0 else
              coalesce(o.noms, 0) * v_league.oscar_nom_bonus + coalesce(o.wins, 0) * v_league.oscar_win_bonus
              + case when coalesce(o.bp_win, false) then v_league.bp_bonus else 0 end end as oscar_m,
           lp.bid
    from league_picks lp
    left join universe_films uf on uf.imdb_id = lp.imdb_id
    left join osc o on o.imdb_id = lp.imdb_id
    where lp.league_id = p_league_id
  ), teams as (
    select t.team_name, lm.user_id, p.display_name as player
    from (select team_name from league_members where league_id = p_league_id and team_name is not null
          union select team_name from league_picks where league_id = p_league_id) t
    left join league_members lm on lm.league_id = p_league_id and lm.team_name = t.team_name
    left join profiles p on p.id = lm.user_id
  ), agg as (
    select t.team_name, t.user_id, t.player,
           coalesce(sum(f.bo), 0) as bo, coalesce(sum(f.oscar_m), 0) as oscar_m, coalesce(sum(f.bid), 0) as spent,
           coalesce(jsonb_agg(f.f order by (f.f->>'bo')::numeric desc) filter (where f.f is not null), '[]'::jsonb) as films,
           case when v_league.acquisitions_enabled and t.user_id is not null
                then greatest(public.acq_remaining_budget(p_league_id, t.user_id), 0) else 0 end as remaining_m
    from teams t left join films f on f.team_name = t.team_name
    group by t.team_name, t.user_id, t.player
  ), ranked as (
    select a.*, a.bo + (a.oscar_m + a.remaining_m) * 1e6 as total,
           rank() over (order by a.bo + (a.oscar_m + a.remaining_m) * 1e6 desc, a.bo desc) as rnk
    from agg a
  )
  select jsonb_agg(jsonb_build_object(
           'rank', rnk, 'team', team_name, 'user_id', user_id, 'player', player,
           'bo', bo, 'oscar_m', oscar_m, 'remaining_m', remaining_m, 'total', total, 'spent', spent,
           'roi', case when spent > 0 then round(bo / (spent * 1e6), 4) else null end,
           'films', films) order by rnk, team_name)
  into v_out from ranked;
  return coalesce(v_out, '[]'::jsonb);
end;
$$;
revoke all on function public.league_standings(uuid) from public;
grant execute on function public.league_standings(uuid) to anon, authenticated, service_role;

-- ── 4. final results ─────────────────────────────────────────────────────────
create table if not exists public.league_results (
  league_id      uuid primary key references public.leagues(id) on delete cascade,
  season         text not null,
  finalized_at   timestamptz not null default now(),
  winner_team    text,
  winner_user_id uuid,
  standings      jsonb not null
);
alter table public.league_results enable row level security;
drop policy if exists league_results_read on public.league_results;
create policy league_results_read on public.league_results for select to anon, authenticated using (
  public.is_league_member(league_id, auth.uid()) or public.is_league_admin(league_id, auth.uid())
  or exists (select 1 from public.leagues l where l.id = league_results.league_id and l.is_public));
grant select on public.league_results to anon, authenticated;
grant all on public.league_results to service_role;

alter table public.notifications drop constraint if exists notifications_type_check;
alter table public.notifications add constraint notifications_type_check check (type = any (array[
  'declaration', 'new_leader', 'new_film', 'release_day', 'release_date_changed', 'season_final']));

-- Freeze one league (internal). Returns the winning team.
create or replace function public.finalize_league(p_league_id uuid)
returns text language plpgsql security definer set search_path = public as $$
declare v_league leagues%rowtype; v_st jsonb; v_win jsonb;
begin
  select * into v_league from leagues where id = p_league_id for update;
  if v_league.finalized_at is not null then return null; end if;
  v_st := public.league_standings(p_league_id);
  v_win := v_st -> 0;
  insert into league_results (league_id, season, winner_team, winner_user_id, standings)
  values (p_league_id, v_league.season, v_win->>'team', nullif(v_win->>'user_id', '')::uuid, v_st)
  on conflict (league_id) do update set standings = excluded.standings, winner_team = excluded.winner_team,
    winner_user_id = excluded.winner_user_id, finalized_at = now();
  update leagues set finalized_at = now() where id = p_league_id;
  insert into notifications (user_id, league_id, type, title, body, link)
  select lm.user_id, p_league_id, 'season_final',
         coalesce(v_win->>'team', 'Nobody') || ' wins ' || v_league.name || '!',
         'The season is over. See the final standings and your season Wrapped.',
         '/wrapped?id=' || p_league_id
  from league_members lm where lm.league_id = p_league_id;
  return v_win->>'team';
end;
$$;
revoke all on function public.finalize_league(uuid) from public, anon, authenticated;

-- Finalize every finished league of a season. Runs daily from Apps Script; a site admin can also
-- run it. Only acts once the season's Oscar results are marked final and Oscar Sunday has passed.
create or replace function public.finalize_season(p_season text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_season seasons%rowtype; r record; v_done jsonb := '[]'::jsonb;
begin
  if not (coalesce(auth.role(), '') = 'service_role' or public.is_site_admin(auth.uid())) then
    raise exception 'Only the site admin can finalize a season';
  end if;
  select * into v_season from seasons where season = p_season for update;
  if not found then raise exception 'Unknown season %', p_season; end if;
  if not v_season.results_final then
    return jsonb_build_object('status', 'waiting', 'reason', 'Oscar results are not marked final yet');
  end if;
  if current_date < v_season.oscar_date then
    return jsonb_build_object('status', 'waiting', 'reason', 'Oscar Sunday has not happened yet');
  end if;
  for r in select id, name from leagues
           where season = p_season and finalized_at is null
             and exists (select 1 from league_picks lp where lp.league_id = leagues.id)
  loop
    v_done := v_done || jsonb_build_object('league', r.name, 'winner', public.finalize_league(r.id));
  end loop;
  update seasons set finalized_at = coalesce(finalized_at, now()) where season = p_season;
  return jsonb_build_object('status', 'finalized', 'leagues', v_done);
end;
$$;
revoke all on function public.finalize_season(text) from public, anon;
grant execute on function public.finalize_season(text) to authenticated, service_role;

-- a finished league is frozen: no more acquisitions, weekend picks or refunds
create or replace function public.trg_block_finished_league()
returns trigger language plpgsql set search_path = public as $$
begin
  if exists (select 1 from leagues where id = new.league_id and finalized_at is not null) then
    raise exception 'This season is over -- the league is final';
  end if;
  return new;
end;
$$;
drop trigger if exists block_finished_league on public.acquisition_declarations;
create trigger block_finished_league before insert on public.acquisition_declarations for each row execute function public.trg_block_finished_league();
drop trigger if exists block_finished_league on public.acquisition_bids;
create trigger block_finished_league before insert on public.acquisition_bids for each row execute function public.trg_block_finished_league();
drop trigger if exists block_finished_league on public.weekend_picks;
create trigger block_finished_league before insert or update on public.weekend_picks for each row execute function public.trg_block_finished_league();
drop trigger if exists block_finished_league on public.refunds;
create trigger block_finished_league before insert on public.refunds for each row execute function public.trg_block_finished_league();
drop trigger if exists block_finished_league on public.league_picks;
create trigger block_finished_league before insert on public.league_picks for each row execute function public.trg_block_finished_league();

-- weekly snapshots + "new leader" alerts stop once a league is finished
create or replace function public.snapshot_weekly_bo_and_poi()
returns void language plpgsql security definer set search_path = public as $$
declare v_week_start date; v_week_label text;
begin
  v_week_start := current_date - ((extract(dow from current_date)::int + 6) % 7);
  v_week_label := to_char(v_week_start, 'FMMon FMDD');

  insert into weekly_bo_snapshots (league_id, week_label, team, bo, snapshot_date)
  select lp.league_id, v_week_label, lp.team_name, sum(case when lp.voided then 0 else coalesce(uf.bo, 0) end), v_week_start
  from league_picks lp
  join universe_films uf on uf.imdb_id = lp.imdb_id
  join leagues l on l.id = lp.league_id and l.finalized_at is null
  group by lp.league_id, lp.team_name
  on conflict (league_id, week_label, team) do update
    set bo = excluded.bo, snapshot_date = excluded.snapshot_date;

  insert into weekly_poi_snapshots (league_id, week_label, team, poi, snapshot_date)
  select lp.league_id, v_week_label, lp.team_name,
    case when sum(lp.bid) filter (where uf.bo > 0 or lp.voided) > 0
      then sum(coalesce(uf.bo, 0)) filter (where uf.bo > 0 and not lp.voided)
           / (sum(lp.bid) filter (where uf.bo > 0 or lp.voided) * 1e6)
      else 0 end,
    v_week_start
  from league_picks lp
  join universe_films uf on uf.imdb_id = lp.imdb_id
  join leagues l on l.id = lp.league_id and l.finalized_at is null
  group by lp.league_id, lp.team_name
  on conflict (league_id, week_label, team) do update
    set poi = excluded.poi, snapshot_date = excluded.snapshot_date;
end;
$$;

create or replace function public.check_new_leaders()
returns void language plpgsql security definer set search_path = public as $$
declare r record;
begin
  for r in
    select distinct on (lp.league_id) lp.league_id, lp.team_name, l.name as league_name, l.current_leader_team
    from league_picks lp
    join universe_films uf on uf.imdb_id = lp.imdb_id
    join leagues l on l.id = lp.league_id and l.finalized_at is null
    where not lp.voided
    group by lp.league_id, lp.team_name, l.name, l.current_leader_team
    order by lp.league_id, sum(coalesce(uf.bo, 0)) desc
  loop
    if r.current_leader_team is not null and r.current_leader_team <> r.team_name then
      insert into notifications (user_id, league_id, type, title, body, link)
      select lm.user_id, r.league_id, 'new_leader', r.team_name || ' takes the lead!',
             r.team_name || ' is now #1 in ' || r.league_name || ' by box office.', '/league?id=' || r.league_id
      from league_members lm left join notification_preferences np on np.user_id = lm.user_id
      where lm.league_id = r.league_id and coalesce(np.notify_new_leader, true);
    end if;
    update leagues set current_leader_team = r.team_name where id = r.league_id;
  end loop;
end;
$$;

-- ── 5a. leagues: who can create, name/size/season rules ──────────────────────
drop policy if exists leagues_insert on public.leagues;
create policy leagues_insert on public.leagues for insert to authenticated with check (created_by = auth.uid());

create or replace function public.trg_leagues_rules()
returns trigger language plpgsql set search_path = public as $$
declare v_members int;
begin
  if tg_op = 'INSERT' or new.name is distinct from old.name then
    new.name := public.sef_clean_text(new.name);
    if char_length(new.name) not between 1 and 40 then
      raise exception 'League names must be 1 to 40 characters';
    end if;
  end if;
  if tg_op = 'INSERT' or new.description is distinct from old.description then
    new.description := left(public.sef_clean_text(new.description), 280);
  end if;
  if tg_op = 'INSERT' or new.sacko_punishment is distinct from old.sacko_punishment then
    new.sacko_punishment := left(public.sef_clean_text(new.sacko_punishment), 280);
  end if;
  if tg_op = 'INSERT' or new.num_players is distinct from old.num_players then
    if new.num_players not between 3 and 12 then
      raise exception 'A league holds 3 to 12 players';
    end if;
    if tg_op = 'UPDATE' then
      select count(*) into v_members from league_members where league_id = new.id;
      if new.num_players < v_members then
        raise exception 'This league already has % players', v_members;
      end if;
    end if;
  end if;
  if tg_op = 'INSERT' or new.season is distinct from old.season then
    if not exists (select 1 from seasons where season = new.season) then
      raise exception 'Season % is not open yet', new.season;
    end if;
    if tg_op = 'UPDATE' and exists (select 1 from league_picks where league_id = new.id) then
      raise exception 'The season can''t change once films are drafted';
    end if;
  end if;
  if tg_op = 'INSERT' and current_user in ('authenticated', 'anon') then
    new.created_by := auth.uid();
    new.finalized_at := null;
    if (select count(*) from leagues where created_by = auth.uid() and created_at > now() - interval '1 day') >= 5 then
      raise exception 'You can create up to 5 leagues a day';
    end if;
  end if;
  if tg_op = 'UPDATE' and current_user in ('authenticated', 'anon') then
    if new.finalized_at is distinct from old.finalized_at then
      raise exception 'Seasons are finalized by the server';
    end if;
    if new.created_by is distinct from old.created_by then
      raise exception 'A league''s creator can''t change';
    end if;
  end if;
  return new;
end;
$$;
drop trigger if exists leagues_rules on public.leagues;
create trigger leagues_rules before insert or update on public.leagues
  for each row execute function public.trg_leagues_rules();

-- ── 5b. league_members: studio names, colors, join cap ───────────────────────
create or replace function public.trg_league_members_names()
returns trigger language plpgsql set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    -- defaults come from display names, so clean them instead of refusing the join/create
    if not public.sef_team_name_ok(new.team_name)
       or exists (select 1 from league_members where league_id = new.league_id and lower(team_name) = lower(new.team_name)) then
      new.team_name := public.sef_unique_team_name(new.league_id, new.team_name, new.user_id);
    end if;
    if new.color is not null and not (new.color = any(public.sef_team_palette())) then new.color := null; end if;
    return new;
  end if;
  if new.team_name is distinct from old.team_name then
    if current_user in ('authenticated', 'anon') then
      raise exception 'Use the rename option to change a studio name';
    end if;
    if not public.sef_team_name_ok(new.team_name) then
      raise exception 'Studio names are 1-20 letters, numbers, spaces or . , '' & ! ? : -';
    end if;
  end if;
  if new.color is distinct from old.color and new.color is not null and not (new.color = any(public.sef_team_palette())) then
    raise exception 'Pick one of the league colors';
  end if;
  return new;
end;
$$;
drop trigger if exists league_members_names on public.league_members;
create trigger league_members_names before insert or update on public.league_members
  for each row execute function public.trg_league_members_names();

create or replace function public.rename_my_team(p_league_id uuid, p_new_name text)
returns void language plpgsql security definer set search_path = public as $$
declare v_old text; v_new text := public.sef_clean_text(p_new_name);
begin
  if not public.sef_team_name_ok(v_new) then
    raise exception 'Studio names are 1-20 letters, numbers, spaces or . , '' & ! ? : -';
  end if;
  select team_name into v_old from league_members where league_id = p_league_id and user_id = auth.uid() for update;
  if v_old is null then raise exception 'Not a member of this league'; end if;
  if (select finalized_at from leagues where id = p_league_id) is not null then
    raise exception 'This season is over -- studio names are frozen';
  end if;
  if exists (select 1 from league_members where league_id = p_league_id and user_id <> auth.uid()
             and lower(team_name) = lower(v_new)) then
    raise exception 'That studio name is already taken in this league';
  end if;
  update league_members set team_name = v_new where league_id = p_league_id and user_id = auth.uid();
  if v_old <> v_new then
    update league_picks set team_name = v_new where league_id = p_league_id and team_name = v_old;
    update weekly_bo_snapshots set team = v_new where league_id = p_league_id::text and team = v_old;
    update weekly_poi_snapshots set team = v_new where league_id = p_league_id::text and team = v_old;
    update refunds set team_name = v_new where league_id = p_league_id and team_name = v_old;
    update leagues set current_leader_team = v_new where id = p_league_id and current_leader_team = v_old;
  end if;
end;
$$;

create or replace function public.set_my_team_color(p_league_id uuid, p_color text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from league_members where league_id = p_league_id and user_id = auth.uid()) then
    raise exception 'Not a member of this league';
  end if;
  if p_color is not null and not (lower(p_color) = any(public.sef_team_palette())) then
    raise exception 'Pick one of the league colors';
  end if;
  if exists (select 1 from league_members where league_id = p_league_id and user_id <> auth.uid() and lower(color) = lower(p_color)) then
    raise exception 'That color is already taken in this league';
  end if;
  update league_members set color = lower(p_color) where league_id = p_league_id and user_id = auth.uid();
end;
$$;

create or replace function public.join_league(p_invite_code text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_league record;
  v_name text;
  v_rows integer;
begin
  if v_uid is null then raise exception 'Sign in to join a league'; end if;
  select l.id, l.name, l.num_players, l.finalized_at into v_league
  from public.leagues l
  where lower(l.invite_code) = lower(btrim(coalesce(p_invite_code, '')))
  limit 1
  for update;
  if not found then raise exception 'That invite code is not valid'; end if;
  if exists (select 1 from league_members where league_id = v_league.id and user_id = v_uid) then
    return jsonb_build_object('league_id', v_league.id, 'name', v_league.name, 'joined', false);
  end if;
  if v_league.finalized_at is not null then raise exception 'This league''s season is over'; end if;
  if (select count(*) from league_members where league_id = v_league.id) >= least(coalesce(v_league.num_players, 12), 12) then
    raise exception 'This league is full';
  end if;
  select p.display_name into v_name from public.profiles p where p.id = v_uid;
  insert into public.league_members (league_id, user_id, role, team_name)
  values (v_league.id, v_uid, 'player', public.sef_unique_team_name(v_league.id, coalesce(v_name, 'Player'), v_uid))
  on conflict do nothing;
  get diagnostics v_rows = row_count;
  return jsonb_build_object('league_id', v_league.id, 'name', v_league.name, 'joined', v_rows > 0);
end;
$$;

-- resolved acquisition bids were readable by ANY signed-in user, for every league
drop policy if exists acq_bids_select on public.acquisition_bids;
create policy acq_bids_select on public.acquisition_bids for select to authenticated using (
  user_id = auth.uid() or public.is_league_admin(league_id, auth.uid())
  or (status <> 'pending' and public.is_league_member(league_id, auth.uid())));

-- ── 6. refunds of live-drafted films ─────────────────────────────────────────
alter table public.draft_items drop constraint if exists draft_items_league_pick_id_fkey;
alter table public.draft_items add constraint draft_items_league_pick_id_fkey
  foreign key (league_pick_id) references public.league_picks(id) on delete set null;

-- ── 7. display names ─────────────────────────────────────────────────────────
create or replace function public.sef_clean_display_name(p text, p_email text)
returns text language sql immutable set search_path = public as $$
  select coalesce(nullif(left(public.sef_clean_text(p), 24), ''), nullif(left(split_part(coalesce(p_email, ''), '@', 1), 24), ''), 'Player');
$$;

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, email, display_name)
  values (new.id, new.email, public.sef_clean_display_name(new.raw_user_meta_data->>'display_name', new.email));
  return new;
end;
$$;

create or replace function public.set_my_display_name(p_name text)
returns text language plpgsql security definer set search_path = public as $$
declare v text := left(public.sef_clean_text(p_name), 24);
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  if v = '' then raise exception 'Display name cannot be empty'; end if;
  update profiles set display_name = v where id = auth.uid();
  return v;
end;
$$;
revoke all on function public.set_my_display_name(text) from public, anon;
grant execute on function public.set_my_display_name(text) to authenticated;

-- ── 8. browser error reports ─────────────────────────────────────────────────
create table if not exists public.client_errors (
  id         bigint generated always as identity primary key,
  created_at timestamptz not null default now(),
  user_id    uuid,
  league_id  uuid,
  page       text,
  message    text,
  detail     text,
  user_agent text
);
create index if not exists client_errors_created on public.client_errors (created_at);
alter table public.client_errors enable row level security;
drop policy if exists client_errors_insert on public.client_errors;
create policy client_errors_insert on public.client_errors for insert to anon, authenticated with check (true);
grant insert (league_id, page, message, detail, user_agent) on public.client_errors to anon, authenticated;
grant all on public.client_errors to service_role;

create or replace function public.trg_client_errors_clamp()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  -- drop floods silently: at most 300 reports an hour site-wide, 30 per signed-in user
  if (select count(*) from client_errors where created_at > now() - interval '1 hour') >= 300 then return null; end if;
  if auth.uid() is not null and (select count(*) from client_errors where user_id = auth.uid()
                                 and created_at > now() - interval '1 hour') >= 30 then return null; end if;
  new.user_id := auth.uid();
  new.page := left(new.page, 200); new.message := left(new.message, 500);
  new.detail := left(new.detail, 2000); new.user_agent := left(new.user_agent, 200);
  return new;
end;
$$;
drop trigger if exists client_errors_clamp on public.client_errors;
create trigger client_errors_clamp before insert on public.client_errors
  for each row execute function public.trg_client_errors_clamp();

-- ── checks ───────────────────────────────────────────────────────────────────
select 'seasons' as item, count(*)::text as value from public.seasons
union all select 'league_season_window(2027)', (select window_start || ' to ' || window_end from public.league_season_window('2027'))
union all select 'refund FK on delete', (select confdeltype::text from pg_constraint where conname = 'draft_items_league_pick_id_fkey')
union all select 'leagues insert policy', (select with_check from pg_policies where tablename = 'leagues' and policyname = 'leagues_insert');
