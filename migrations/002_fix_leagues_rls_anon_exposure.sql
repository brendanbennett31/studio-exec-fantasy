-- Fix: `leagues` table has no real RLS restriction for anon/authenticated SELECT,
-- so any unfiltered or irrelevant-filter query returns every row, including
-- invite_code and created_by. Verified via anon-key curl against
-- https://fymkwkbatklfynnhxrsf.supabase.co on 2026-07-30.
--
-- Run this whole file in the Supabase SQL editor (Database > SQL Editor).
-- It is idempotent — safe to re-run.

-- 1. Drop whatever SELECT policy(ies) currently exist on leagues, regardless of name.
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

-- 2. Members and the creator can read their own league in full (invite_code, created_by, everything).
--    This is what dashboard.html / league.html need when a real member is logged in.
create policy "leagues_select_member_or_creator" on public.leagues
  for select
  to authenticated
  using (
    created_by = auth.uid()
    or exists (
      select 1 from public.league_members lm
      where lm.league_id = leagues.id and lm.user_id = auth.uid()
    )
  );

-- Intentionally NO general anon (or non-member authenticated) SELECT policy on
-- the base table. Anon reads go through the view + RPC below instead, so
-- invite_code / created_by are never exposed to anon, and there is no
-- "list everything" path left.

-- 3. Safe, column-limited view for the public-view-link feature (is_public leagues only).
--    Mirrors the public_member_names pattern already used for league_members/profiles.
create or replace view public.public_leagues as
  select
    id, name, season, budget, draft_status, num_players, min_bid, max_bid,
    oscar_nom_bonus, oscar_win_bonus, bp_bonus, festival_picks,
    draft_open_date, draft_close_date, season_end_date, description,
    is_public, share_token, created_at
  from public.leagues
  where is_public = true;

grant select on public.public_leagues to anon, authenticated;

-- 4. RPC for join.html's invite-code lookup. SECURITY DEFINER so it can see the
--    base table internally, but it only ever returns the single matching row's
--    id/name — never invite_code or created_by, and there's no way to call it
--    without supplying an exact code (so it can't be used to enumerate leagues).
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
