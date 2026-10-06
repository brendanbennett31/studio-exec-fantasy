-- Weekend Top-3 Picks (playtest mechanic, requested by Brandon).
--
-- Each cycle, every exec in an opted-in league predicts the top 3 domestic
-- box office films for the coming weekend, in order. Window: opens Tuesday
-- 9:00 PM PT, locks Wednesday 9:00 PM PT. Picks stay visible (everyone's,
-- once locked) until the next window opens the following Tuesday 9 PM PT.
-- After the weekend's Box Office Mojo actuals land (Monday evening), anyone
-- who got all three right IN ORDER earns $1M toward their Acquisitions
-- budget. Multiple winners and zero winners are both fine.
--
-- Fully opt-in per league (leagues.weekend_picks_enabled, default false) and
-- every cycle row / pick is scoped by league_id, so nothing here can touch a
-- league that hasn't been switched on -- see migration 057 for the one-league
-- enable step. Same architecture as Acquisitions: no table is writable by a
-- client, every write goes through a SECURITY DEFINER RPC, the window is
-- self-computing (no cron needed to open/close it), and the credit is
-- DERIVED from winning picks rather than stored as a wallet.
--
-- Standing rule applied throughout: every function that isn't meant for
-- anon pairs `revoke all ... from public` with an explicit
-- `revoke execute ... from anon` in the SAME migration.

alter table leagues
  add column if not exists weekend_picks_enabled boolean not null default false,
  -- Last release date still eligible for the pick pool. Null = fall back to
  -- the league's own season window end. The playtest sets this to
  -- 2026-12-31 so the 2027 test league can pick from 2026's remaining slate.
  add column if not exists weekend_picks_pool_end date;

-- One row per league per weekend being predicted.
create table if not exists weekend_pick_weeks (
  id uuid primary key default gen_random_uuid(),
  league_id uuid not null references leagues(id) on delete cascade,
  weekend_friday date not null,           -- the Friday of the predicted weekend
  opens_at timestamptz not null,          -- Tue 9 PM PT
  closes_at timestamptz not null,         -- Wed 9 PM PT (admin playtest tools may pull this earlier)
  natural_closes_at timestamptz not null, -- the scheduled close, so tools can restore it
  resolve_after timestamptz not null,     -- Mon 5 PM PT after the weekend
  actual_top3 text[],                     -- imdb_ids, '' where BOM's film isn't in the Universe
  actual_top3_titles text[],              -- BOM's own titles, for display
  resolved_at timestamptz,
  resolved_by text,                       -- 'cron' | 'admin'
  created_at timestamptz not null default now(),
  unique (league_id, weekend_friday)
);

create table if not exists weekend_picks (
  id uuid primary key default gen_random_uuid(),
  week_id uuid not null references weekend_pick_weeks(id) on delete cascade,
  league_id uuid not null references leagues(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  pick1 text not null references universe_films(imdb_id),
  pick2 text not null references universe_films(imdb_id),
  pick3 text not null references universe_films(imdb_id),
  is_winner boolean,                      -- null until the week resolves
  submitted_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (week_id, user_id),
  check (pick1 <> pick2 and pick1 <> pick3 and pick2 <> pick3)
);
create index if not exists weekend_picks_league_user_idx on weekend_picks(league_id, user_id);

-- No direct client access at all: RLS on with zero policies, plus explicit
-- revokes (Supabase's default privileges would otherwise hand anon/
-- authenticated table grants). Everything goes through the RPCs below.
alter table weekend_pick_weeks enable row level security;
alter table weekend_picks enable row level security;
revoke all on weekend_pick_weeks from anon, authenticated;
revoke all on weekend_picks from anon, authenticated;

-- ── Cycle math (pure; internal) ─────────────────────────────────────────────
-- The cycle containing p_at: most recent Tuesday 9 PM PT at or before it.
create or replace function public.weekend_picks_cycle(p_at timestamptz default now())
returns table(opens_at timestamptz, closes_at timestamptz, weekend_friday date, resolve_after timestamptz)
language sql
stable
set search_path = public
as $$
  with x as (
    select (p_at at time zone 'America/Los_Angeles') as t
  ), y as (
    select t, (t::date - ((extract(dow from t)::int - 2 + 7) % 7)) as d from x
  ), z as (
    select case when t < (d + time '21:00') then d - 7 else d end as open_date from y
  )
  select ((open_date + time '21:00') at time zone 'America/Los_Angeles'),
         ((open_date + 1 + time '21:00') at time zone 'America/Los_Angeles'),
         (open_date + 3),
         ((open_date + 6 + time '17:00') at time zone 'America/Los_Angeles')
  from z;
$$;
revoke all on function public.weekend_picks_cycle(timestamptz) from public, anon, authenticated;

create or replace function public.ensure_weekend_picks_week(p_league_id uuid)
returns public.weekend_pick_weeks
language plpgsql
security definer
set search_path = public
as $$
declare
  c record;
  v public.weekend_pick_weeks;
begin
  select * into c from public.weekend_picks_cycle(now());
  insert into weekend_pick_weeks (league_id, weekend_friday, opens_at, closes_at, natural_closes_at, resolve_after)
  values (p_league_id, c.weekend_friday, c.opens_at, c.closes_at, c.closes_at, c.resolve_after)
  on conflict (league_id, weekend_friday) do nothing;
  select * into v from weekend_pick_weeks where league_id = p_league_id and weekend_friday = c.weekend_friday;
  return v;
end;
$$;
revoke all on function public.ensure_weekend_picks_week(uuid) from public, anon, authenticated;

-- Last release date still eligible for a league's pool.
create or replace function public.weekend_pool_end(p_league_id uuid)
returns date
language sql
security definer
stable
set search_path = public
as $$
  select coalesce(l.weekend_picks_pool_end, (select window_end from public.league_season_window(l.season)))
  from leagues l where l.id = p_league_id;
$$;
revoke all on function public.weekend_pool_end(uuid) from public, anon, authenticated;

-- $1M per winning week, in the same $M units as every other budget column.
create or replace function public.weekend_pick_credits(p_league_id uuid, p_user_id uuid)
returns numeric
language sql
security definer
stable
set search_path = public
as $$
  select count(*)::numeric * 1
  from weekend_picks where league_id = p_league_id and user_id = p_user_id and is_winner is true;
$$;
revoke all on function public.weekend_pick_credits(uuid, uuid) from public, anon, authenticated;

-- Shared by the cron resolver and the admin playtest override.
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

  -- All three, in order. An empty/unknown slot never matches anything.
  update weekend_picks
  set is_winner = (coalesce(p_top3[1], '') <> '' and pick1 = p_top3[1]
               and coalesce(p_top3[2], '') <> '' and pick2 = p_top3[2]
               and coalesce(p_top3[3], '') <> '' and pick3 = p_top3[3])
  where week_id = p_week_id;
end;
$$;
revoke all on function public.weekend_apply_results(uuid, text[], text[], text) from public, anon, authenticated;

-- ── Fold the weekend credit into the Acquisitions budget derivation ─────────
-- Same signature, so existing grants/callers are untouched. For any league
-- with no weekend wins the new term is 0.
create or replace function public.acq_remaining_budget(p_league_id uuid, p_user_id uuid)
returns numeric
language sql
security definer
stable
set search_path = public
as $$
  select
    coalesce((select acq_budget_default from leagues where id = p_league_id), 0)
    + coalesce((select acq_remainder_credit from league_members where league_id = p_league_id and user_id = p_user_id), 0)
    + coalesce((select sum(credit_amount) from refunds where league_id = p_league_id and user_id = p_user_id), 0)
    + public.weekend_pick_credits(p_league_id, p_user_id)
    - coalesce((
        select sum(lp.bid)
        from league_picks lp
        join league_members lm on lm.league_id = p_league_id and lm.user_id = p_user_id
        where lp.league_id = p_league_id and lp.team_name = lm.team_name and lp.source = 'acquisition'
      ), 0);
$$;
revoke all on function public.acq_remaining_budget(uuid, uuid) from public, anon, authenticated;

-- Extra column (weekend_pick_credits) changes the return type, so it has to
-- be dropped and recreated. Existing clients read columns by name, so the
-- added column is backward compatible.
drop function if exists public.league_acquisitions_budgets(uuid);
create function public.league_acquisitions_budgets(p_league_id uuid)
returns table(
  team_name text,
  budget_default numeric,
  remainder_credit numeric,
  refund_credits numeric,
  spent numeric,
  remaining numeric,
  weekend_pick_credits numeric
)
language plpgsql
security definer
stable
set search_path = public
as $$
begin
  if not public.is_league_member(p_league_id, auth.uid()) then
    raise exception 'Not a member of this league';
  end if;

  return query
  select
    lm.team_name,
    l.acq_budget_default,
    lm.acq_remainder_credit,
    coalesce(rf.total, 0),
    coalesce(sp.total, 0),
    l.acq_budget_default + lm.acq_remainder_credit + coalesce(rf.total, 0) + coalesce(wk.total, 0) - coalesce(sp.total, 0),
    coalesce(wk.total, 0)
  from league_members lm
  join leagues l on l.id = p_league_id
  left join (
    select user_id, sum(credit_amount) as total from refunds where league_id = p_league_id group by user_id
  ) rf on rf.user_id = lm.user_id
  left join (
    select lp.team_name as tn, sum(lp.bid) as total from league_picks lp where lp.league_id = p_league_id and lp.source = 'acquisition' group by lp.team_name
  ) sp on sp.tn = lm.team_name
  left join (
    select user_id, count(*)::numeric as total from weekend_picks where league_id = p_league_id and is_winner is true group by user_id
  ) wk on wk.user_id = lm.user_id
  where lm.league_id = p_league_id;
end;
$$;
revoke all on function public.league_acquisitions_budgets(uuid) from public;
revoke execute on function public.league_acquisitions_budgets(uuid) from anon;
grant execute on function public.league_acquisitions_budgets(uuid) to authenticated;

-- ── Client-facing RPCs ──────────────────────────────────────────────────────

-- Films a player can put in the three boxes: any film in the Universe
-- released (or releasing) no later than the pool end. Already-released films
-- are included on purpose -- holdovers routinely stay in the weekend top 3 for
-- weeks, so excluding them could make a win impossible.
create or replace function public.weekend_pick_pool(p_league_id uuid)
returns table(imdb_id text, title text, release_date date)
language plpgsql
security definer
stable
set search_path = public
as $$
declare
  v_end date;
begin
  if not public.is_league_member(p_league_id, auth.uid()) then
    raise exception 'Not a member of this league';
  end if;
  if not coalesce((select weekend_picks_enabled from leagues where id = p_league_id), false) then
    raise exception 'Weekend Picks is not enabled for this league';
  end if;
  v_end := public.weekend_pool_end(p_league_id);
  return query
    select uf.imdb_id, uf.title, uf.release_date
    from universe_films uf
    where uf.imdb_id is not null and uf.release_date <= v_end
    order by uf.release_date, uf.title;
end;
$$;
revoke all on function public.weekend_pick_pool(uuid) from public;
revoke execute on function public.weekend_pick_pool(uuid) from anon;
grant execute on function public.weekend_pick_pool(uuid) to authenticated;

-- Everything the tab renders, in one call. Other execs' picks are only
-- included once the window has locked.
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
      jsonb_build_object('imdb_id', p.pick1, 'title', (select title from universe_films where imdb_id = p.pick1)),
      jsonb_build_object('imdb_id', p.pick2, 'title', (select title from universe_films where imdb_id = p.pick2)),
      jsonb_build_object('imdb_id', p.pick3, 'title', (select title from universe_films where imdb_id = p.pick3))))
  into v_mine
  from weekend_picks p where p.week_id = v_week.id and p.user_id = auth.uid();

  if v_phase <> 'open' then
    select coalesce(jsonb_agg(jsonb_build_object(
      'team_name', lm.team_name,
      'is_winner', p.is_winner,
      'picks', jsonb_build_array(
        jsonb_build_object('imdb_id', p.pick1, 'title', (select title from universe_films where imdb_id = p.pick1)),
        jsonb_build_object('imdb_id', p.pick2, 'title', (select title from universe_films where imdb_id = p.pick2)),
        jsonb_build_object('imdb_id', p.pick3, 'title', (select title from universe_films where imdb_id = p.pick3)))
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

-- Submit or edit this cycle's three picks (editing allowed until the lock).
create or replace function public.submit_weekend_picks(p_league_id uuid, p_pick1 text, p_pick2 text, p_pick3 text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_week public.weekend_pick_weeks;
  v_end date;
  v_id text;
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

  if coalesce(p_pick1, '') = '' or coalesce(p_pick2, '') = '' or coalesce(p_pick3, '') = '' then
    raise exception 'Pick a film for all three spots';
  end if;
  if p_pick1 = p_pick2 or p_pick1 = p_pick3 or p_pick2 = p_pick3 then
    raise exception 'Each spot needs a different film';
  end if;

  v_end := public.weekend_pool_end(p_league_id);
  foreach v_id in array array[p_pick1, p_pick2, p_pick3] loop
    if not exists (
      select 1 from universe_films uf
      where uf.imdb_id = v_id and uf.release_date <= v_end
    ) then
      raise exception 'One of those films is not eligible (it has to be a film in this league''s pool)';
    end if;
  end loop;

  insert into weekend_picks (week_id, league_id, user_id, pick1, pick2, pick3)
  values (v_week.id, p_league_id, auth.uid(), p_pick1, p_pick2, p_pick3)
  on conflict (week_id, user_id) do update
    set pick1 = excluded.pick1, pick2 = excluded.pick2, pick3 = excluded.pick3, updated_at = now();
end;
$$;
revoke all on function public.submit_weekend_picks(uuid, text, text, text) from public;
revoke execute on function public.submit_weekend_picks(uuid, text, text, text) from anon;
grant execute on function public.submit_weekend_picks(uuid, text, text, text) to authenticated;

-- ── Cron resolver (service_role only) ───────────────────────────────────────
-- Called by Apps Script (resolveWeekendPicks) once Box Office Mojo's weekend
-- chart shows the top 3 as actuals. Idempotent: an already-resolved week is a
-- silent no-op, and it refuses to run before Monday 5 PM PT.
create or replace function public.resolve_weekend_picks_week(p_week_id uuid, p_top3 text[], p_top3_titles text[])
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_week weekend_pick_weeks%rowtype;
begin
  select * into v_week from weekend_pick_weeks where id = p_week_id for update;
  if not found then
    raise exception 'Unknown week';
  end if;
  if v_week.resolved_at is not null then
    return;
  end if;
  if now() < v_week.resolve_after then
    raise exception 'Too early to resolve this weekend';
  end if;
  if array_length(p_top3, 1) is distinct from 3 or array_length(p_top3_titles, 1) is distinct from 3 then
    raise exception 'Expected exactly three results';
  end if;
  perform public.weekend_apply_results(p_week_id, p_top3, p_top3_titles, 'cron');
end;
$$;
revoke all on function public.resolve_weekend_picks_week(uuid, text[], text[]) from public;
revoke execute on function public.resolve_weekend_picks_week(uuid, text[], text[]) from anon, authenticated;
grant execute on function public.resolve_weekend_picks_week(uuid, text[], text[]) to service_role;

-- ── Admin playtest tools ────────────────────────────────────────────────────
-- Only callable by an admin of a league that has Weekend Picks switched on,
-- and every one is scoped to that single league's own rows.

-- Lock the window right now (to test the reveal without waiting for Wed 9 PM).
create or replace function public.admin_close_weekend_window(p_league_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_week public.weekend_pick_weeks;
begin
  if not public.is_league_admin(p_league_id, auth.uid()) then
    raise exception 'Only a league admin can do this';
  end if;
  if not coalesce((select weekend_picks_enabled from leagues where id = p_league_id), false) then
    raise exception 'Weekend Picks is not enabled for this league';
  end if;
  v_week := public.ensure_weekend_picks_week(p_league_id);
  update weekend_pick_weeks set closes_at = least(closes_at, now()) where id = v_week.id;
end;
$$;
revoke all on function public.admin_close_weekend_window(uuid) from public;
revoke execute on function public.admin_close_weekend_window(uuid) from anon;
grant execute on function public.admin_close_weekend_window(uuid) to authenticated;

-- Declare the weekend's top 3 by hand (for testing before BOM's actuals, or to
-- correct a result). Applies to the most recent locked week; re-runnable.
create or replace function public.admin_resolve_weekend_picks(p_league_id uuid, p_top3 text[])
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_week weekend_pick_weeks%rowtype;
  v_titles text[];
  v_id text;
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
  foreach v_id in array p_top3 loop
    if not exists (select 1 from universe_films where imdb_id = v_id) then
      raise exception 'Unknown film: %', v_id;
    end if;
  end loop;

  select * into v_week from weekend_pick_weeks
  where league_id = p_league_id and closes_at <= now()
  order by weekend_friday desc limit 1 for update;
  if not found then
    raise exception 'No locked weekend to resolve yet -- close the window first';
  end if;

  select array_agg((select title from universe_films where imdb_id = x.id) order by x.ord)
  into v_titles from unnest(p_top3) with ordinality as x(id, ord);

  perform public.weekend_apply_results(v_week.id, p_top3, v_titles, 'admin');
end;
$$;
revoke all on function public.admin_resolve_weekend_picks(uuid, text[]) from public;
revoke execute on function public.admin_resolve_weekend_picks(uuid, text[]) from anon;
grant execute on function public.admin_resolve_weekend_picks(uuid, text[]) to authenticated;

-- Wipe this cycle's picks and result and restore the natural Wed 9 PM close.
create or replace function public.admin_reset_weekend_week(p_league_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_week public.weekend_pick_weeks;
begin
  if not public.is_league_admin(p_league_id, auth.uid()) then
    raise exception 'Only a league admin can do this';
  end if;
  if not coalesce((select weekend_picks_enabled from leagues where id = p_league_id), false) then
    raise exception 'Weekend Picks is not enabled for this league';
  end if;
  v_week := public.ensure_weekend_picks_week(p_league_id);
  delete from weekend_picks where week_id = v_week.id;
  update weekend_pick_weeks
  set closes_at = natural_closes_at, actual_top3 = null, actual_top3_titles = null, resolved_at = null, resolved_by = null
  where id = v_week.id;
end;
$$;
revoke all on function public.admin_reset_weekend_week(uuid) from public;
revoke execute on function public.admin_reset_weekend_week(uuid) from anon;
grant execute on function public.admin_reset_weekend_week(uuid) to authenticated;
