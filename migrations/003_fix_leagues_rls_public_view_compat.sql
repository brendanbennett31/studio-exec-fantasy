-- Corrects 002_fix_leagues_rls_anon_exposure.sql, which was written against a
-- stale copy of league.html that didn't yet have the shipped public-view-link
-- feature (main@353b16b "Add view-only public league share links").
--
-- That feature's verifyPublicView() and loadLeagueContext() query the base
-- `leagues` table directly as anon, relying on RLS to restrict rows to
-- is_public = true. 002's "no anon access at all" policy breaks that entirely.
--
-- This migration:
--   1. Replaces the leagues SELECT policy with one that allows anon +
--      authenticated to read rows where is_public = true, in addition to a
--      user's own leagues (creator or member).
--   2. Column-revokes invite_code/created_by from anon specifically, so a
--      public league's row is still readable, but those two columns are not
--      (matches the frontend's own "RLS is the security boundary" comment).
--   3. Drops the public_leagues view from 002 — the shipped frontend never
--      uses it, it queries `leagues` directly.
--   4. Leaves the get_league_by_invite_code RPC from 002 in place — it's
--      still correct and still needed for join.html.
--
-- Run this whole file in the Supabase SQL editor. Idempotent — safe to re-run.

-- 1. Drop whatever SELECT policy(ies) currently exist on leagues (i.e. the one from 002).
do $$
declare
  pol record;
begin
  for pol in
    select policyname from pg_policies
    where schemaname = 'public' and tablename = 'leagues' and cmd = 'SELECT'
  loop
    execute format('drop policy %I on public.leagues', pol.policyname);
  end loop;
end $$;

-- 2. Single policy: a row is visible if it's public, or you created it, or you're a member.
--    auth.uid() is null for anon, so the last two conditions naturally evaluate to
--    false/no-match for anon requests without needing a separate role check.
create policy "leagues_select_public_or_own" on public.leagues
  for select
  to anon, authenticated
  using (
    is_public = true
    or created_by = auth.uid()
    or exists (
      select 1 from public.league_members lm
      where lm.league_id = leagues.id and lm.user_id = auth.uid()
    )
  );

-- 3. Column-level lockdown: anon can read a public league's row, but never its
--    invite_code or created_by, even via `select=*` or an explicit column list.
--    (authenticated members/creators are untouched by this and keep full access,
--    since dashboard.html/league.html show them their own invite_code.)
revoke select (invite_code, created_by) on public.leagues from anon;

-- 4. Drop the view from 002 -- unused by the shipped frontend, kept things simple.
drop view if exists public.public_leagues;

-- 5. (unchanged from 002, restated here for completeness/idempotency)
create or replace function public.get_league_by_invite_code(p_invite_code text)
returns table(id uuid, name text)
language sql
security definer
set search_path = public
stable
as $$
  select l.id, l.name
  from public.leagues l
  where l.invite_code = p_invite_code
  limit 1;
$$;

revoke all on function public.get_league_by_invite_code(text) from public;
grant execute on function public.get_league_by_invite_code(text) to anon, authenticated;
