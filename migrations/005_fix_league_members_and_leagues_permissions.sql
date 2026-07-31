-- Fixes: league_members (SELECT/UPDATE/DELETE/INSERT) and leagues (UPDATE)
-- currently allow ANY authenticated user to read/modify/delete ANY row,
-- not just ones for leagues they belong to or administer.
--
-- The app already has an admin concept: the league creator gets inserted
-- into league_members with role='admin' when a league is created (see
-- dashboard.html), and league.html gates its "Manage" tab on
-- membership.role === 'admin'. These policies enforce that server-side.
--
-- Uses SECURITY DEFINER helper functions (not raw EXISTS subqueries) so
-- these don't recreate the leagues <-> league_members RLS recursion fixed
-- in 004_fix_leagues_select_recursion.sql.

create or replace function public.is_league_member(p_league_id uuid, p_user_id uuid)
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select exists (
    select 1 from public.league_members lm
    where lm.league_id = p_league_id and lm.user_id = p_user_id
  );
$$;

create or replace function public.is_league_admin(p_league_id uuid, p_user_id uuid)
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select exists (
    select 1 from public.league_members lm
    where lm.league_id = p_league_id and lm.user_id = p_user_id and lm.role = 'admin'
  )
  or exists (
    select 1 from public.leagues l
    where l.id = p_league_id and l.created_by = p_user_id
  );
$$;

revoke all on function public.is_league_member(uuid, uuid) from public;
revoke all on function public.is_league_admin(uuid, uuid) from public;
grant execute on function public.is_league_member(uuid, uuid) to anon, authenticated;
grant execute on function public.is_league_admin(uuid, uuid) to anon, authenticated;

-- league_members: only see the roster for leagues you belong to or administer
-- (public_view_league_members, the separate policy for public-league viewers,
-- is untouched — this is additive alongside it).
drop policy if exists "members_select" on public.league_members;
create policy "members_select" on public.league_members
  for select
  to authenticated
  using (
    public.is_league_member(league_id, auth.uid())
    or public.is_league_admin(league_id, auth.uid())
  );

-- league_members: you can only insert yourself, never another user_id.
drop policy if exists "members_insert" on public.league_members;
create policy "members_insert" on public.league_members
  for insert
  to authenticated
  with check (user_id = auth.uid());

-- league_members: update your own row (e.g. team name), or any row if you
-- administer that league.
drop policy if exists "members_update" on public.league_members;
create policy "members_update" on public.league_members
  for update
  to authenticated
  using (user_id = auth.uid() or public.is_league_admin(league_id, auth.uid()))
  with check (user_id = auth.uid() or public.is_league_admin(league_id, auth.uid()));

-- league_members: leave (delete your own row), or an admin removing any
-- member / cascading a full league delete.
drop policy if exists "members_delete" on public.league_members;
create policy "members_delete" on public.league_members
  for delete
  to authenticated
  using (user_id = auth.uid() or public.is_league_admin(league_id, auth.uid()));

-- leagues: only an admin/creator of a league can update its settings.
drop policy if exists "leagues_update" on public.leagues;
create policy "leagues_update" on public.leagues
  for update
  to authenticated
  using (public.is_league_admin(id, auth.uid()))
  with check (public.is_league_admin(id, auth.uid()));
