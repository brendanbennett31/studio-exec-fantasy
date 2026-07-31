-- Fixes the infinite-recursion error from 003_fix_leagues_rls_public_view_compat.sql.
-- league_members' existing "public_view_league_members" policy checks
-- leagues.is_public; the leagues policy from 003 checked league_members
-- membership directly — Postgres detected the resulting cycle and refused to
-- run any query against `leagues` at all (error 42P17).
--
-- Fix: replace the direct EXISTS-on-league_members check with a
-- SECURITY DEFINER helper. Its internal query bypasses RLS (it runs as the
-- table owner), so it no longer re-triggers league_members' policy, which is
-- what closed the loop back to leagues.

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

revoke all on function public.is_league_member(uuid, uuid) from public;
grant execute on function public.is_league_member(uuid, uuid) to anon, authenticated;

drop policy if exists "leagues_select_public_or_own" on public.leagues;

create policy "leagues_select_public_or_own" on public.leagues
  for select
  to anon, authenticated
  using (
    is_public = true
    or created_by = auth.uid()
    or public.is_league_member(id, auth.uid())
  );
