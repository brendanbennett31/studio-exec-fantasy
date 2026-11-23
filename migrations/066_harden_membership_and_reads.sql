-- Hardening before opening the app to many leagues.
--
-- Found in the audit (all verified from the policies in migrations 001/005/012 and, for
-- the read side, by querying the live API with the public anon key):
--
--   1. league_members INSERT only required user_id = auth.uid(). Any signed-in user could
--      add THEMSELVES to ANY league (the invite code was only checked in the browser) and
--      choose role = 'admin' -- an admin can rewrite picks and delete the league.
--   2. league_members UPDATE let a member edit every column of their own row, so they could
--      promote themselves to admin or give themselves acq_remainder_credit (free budget).
--   3. league_picks SELECT was `using (true)` for anon: every league's picks, bids and member
--      ids were readable by anyone with the public key. weekly_bo/poi_snapshots (every
--      team's standings, every league) were readable the same way.
--   4. The legacy `picks` table (the retired single-league page's data) was world-readable.
--
-- What this does:
--   * join_league(invite_code): the only way to join. Server-side invite check, role 'player'.
--   * members_insert: only the league CREATOR can insert a row directly, as the first admin
--     (that is how "Create League" works), and only while the league has no members.
--   * a trigger on league_members: nobody can move a row to another league/user, only an
--     admin can change a role, and only the server can change acq_remainder_credit.
--   * league_picks and the weekly snapshot tables are readable only by league members/admins
--     and by anyone for leagues marked public (so public view links keep working).
--   * `picks` is closed to the API.
--
-- The site is updated to call join_league (falling back to the old direct insert only if this
-- migration hasn't been run yet), so run this AFTER the site deploy; nothing breaks in between.
-- Re-runnable.

-- ── helpers ─────────────────────────────────────────────────────────────────
-- Needed because a policy that looked at league_members directly would only see the rows
-- RLS lets the caller see (nothing, for a league they aren't in).
create or replace function public.league_has_members(p_league_id uuid)
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select exists (select 1 from public.league_members where league_id = p_league_id);
$$;
revoke all on function public.league_has_members(uuid) from public;
revoke execute on function public.league_has_members(uuid) from anon;
grant execute on function public.league_has_members(uuid) to authenticated;

-- ── 1. join by invite code ──────────────────────────────────────────────────
create or replace function public.join_league(p_invite_code text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_league record;
  v_name text;
  v_rows integer;
begin
  if v_uid is null then
    raise exception 'Sign in to join a league';
  end if;
  select l.id, l.name into v_league
  from public.leagues l
  where lower(l.invite_code) = lower(btrim(coalesce(p_invite_code, '')))
  limit 1;
  if not found then
    raise exception 'That invite code is not valid';
  end if;

  select coalesce(nullif(btrim(p.display_name), ''), 'Player') into v_name
  from public.profiles p where p.id = v_uid;

  insert into public.league_members (league_id, user_id, role, team_name)
  values (v_league.id, v_uid, 'player', coalesce(v_name, 'Player'))
  on conflict do nothing;
  get diagnostics v_rows = row_count;

  return jsonb_build_object('league_id', v_league.id, 'name', v_league.name, 'joined', v_rows > 0);
end;
$$;
revoke all on function public.join_league(text) from public;
revoke execute on function public.join_league(text) from anon;
grant execute on function public.join_league(text) to authenticated;

-- ── 2. who may insert a membership row directly ─────────────────────────────
drop policy if exists "members_insert" on public.league_members;
create policy "members_insert" on public.league_members
  for insert to authenticated
  with check (
    user_id = auth.uid()
    and role = 'admin'
    and exists (select 1 from public.leagues l where l.id = league_members.league_id and l.created_by = auth.uid())
    and not public.league_has_members(league_members.league_id)
  );

-- ── 3. what a membership update may change ──────────────────────────────────
create or replace function public.trg_league_members_guard()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    return new;  -- server side (service role / definer functions): unrestricted
  end if;
  if new.league_id is distinct from old.league_id or new.user_id is distinct from old.user_id then
    raise exception 'A membership cannot be moved to another league or user';
  end if;
  if new.role is distinct from old.role and not public.is_league_admin(old.league_id, auth.uid()) then
    raise exception 'Only a league admin can change roles';
  end if;
  if new.acq_remainder_credit is distinct from old.acq_remainder_credit
     or new.remainder_converted_at is distinct from old.remainder_converted_at then
    raise exception 'Budget credits are set by the server only';
  end if;
  return new;
end;
$$;
drop trigger if exists league_members_guard on public.league_members;
create trigger league_members_guard
  before update on public.league_members
  for each row execute function public.trg_league_members_guard();

-- ── 4. who may read picks and weekly snapshots ──────────────────────────────
do $$
declare r record;
begin
  for r in select policyname, tablename from pg_policies
           where schemaname = 'public' and tablename in ('league_picks', 'weekly_bo_snapshots', 'weekly_poi_snapshots') loop
    execute format('drop policy %I on public.%I', r.policyname, r.tablename);
  end loop;
end $$;

alter table public.league_picks enable row level security;
create policy "league_picks_select" on public.league_picks
  for select to anon, authenticated
  using (
    public.is_league_member(league_id, auth.uid())
    or public.is_league_admin(league_id, auth.uid())
    or exists (select 1 from public.leagues l where l.id = league_picks.league_id and l.is_public = true)
  );
create policy "league_picks_write_admin" on public.league_picks
  for all to authenticated
  using (public.is_league_admin(league_id, auth.uid()))
  with check (public.is_league_admin(league_id, auth.uid()));

alter table public.weekly_bo_snapshots enable row level security;
create policy "weekly_bo_select" on public.weekly_bo_snapshots
  for select to anon, authenticated
  using (exists (
    select 1 from public.leagues l
    where l.id::text = weekly_bo_snapshots.league_id::text
      and (l.is_public = true or public.is_league_member(l.id, auth.uid()) or public.is_league_admin(l.id, auth.uid()))
  ));

alter table public.weekly_poi_snapshots enable row level security;
create policy "weekly_poi_select" on public.weekly_poi_snapshots
  for select to anon, authenticated
  using (exists (
    select 1 from public.leagues l
    where l.id::text = weekly_poi_snapshots.league_id::text
      and (l.is_public = true or public.is_league_member(l.id, auth.uid()) or public.is_league_admin(l.id, auth.uid()))
  ));

-- ── 5. retired table ────────────────────────────────────────────────────────
-- Data stays (nothing reads it any more); the API no longer serves it.
revoke all on public.picks from anon, authenticated;

-- Quick check, run as the SQL editor user: all three should show 0 rows for anon-style reads.
select 'picks closed to anon' as check_name, not has_table_privilege('anon', 'public.picks', 'select') as ok
union all
select 'league_picks policies', (select count(*) = 2 from pg_policies where tablename = 'league_picks')
union all
select 'members_insert tightened', (select with_check like '%league_has_members%' from pg_policies where tablename = 'league_members' and policyname = 'members_insert');
