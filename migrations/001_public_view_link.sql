-- Public view-only league links.
-- Run this once in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
-- Safe to run multiple times (uses IF NOT EXISTS / OR REPLACE / DROP POLICY IF EXISTS).
--
-- What this does:
--   1. Adds `is_public` (default false) and `share_token` to `leagues`.
--   2. Adds a policy so `league_members` rows become readable by anyone
--      (no login) ONLY when the parent league has is_public = true.
--      This is purely additive -- it does not touch or remove whatever
--      policy already lets logged-in members read their own league's roster.
--   3. Adds a narrow view, `public_member_names`, that exposes ONLY
--      display_name (never email or other profile fields) for members of
--      public leagues. The app's public-view page reads from this view
--      instead of the `profiles` table directly, so email is never
--      reachable by an anonymous visitor even via a direct API call.
--
-- Does NOT touch: picks, weekly_bo_snapshots, weekly_poi_snapshots, daily_bo,
-- or the existing `leagues` SELECT policy. See the note at the bottom about
-- pre-existing gaps in those that are out of scope for this migration.

alter table leagues
  add column if not exists is_public boolean not null default false,
  add column if not exists share_token text unique;

drop policy if exists "public_view_league_members" on league_members;
create policy "public_view_league_members" on league_members
  for select
  using (
    exists (
      select 1 from leagues l
      where l.id = league_members.league_id
        and l.is_public = true
    )
  );

create or replace view public_member_names as
  select
    m.id as member_id,
    m.league_id,
    m.user_id,
    m.team_name,
    m.role,
    m.joined_at,
    p.display_name
  from league_members m
  join profiles p on p.id = m.user_id
  join leagues l on l.id = m.league_id
  where l.is_public = true;

grant select on public_member_names to anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────
-- PRE-EXISTING GAP (found while building this feature, not caused by it):
-- the current RLS policy on `leagues` appears to allow anon to SELECT the
-- entire table with no per-row restriction, including `invite_code` and
-- `created_by` for every league -- not just ones marked public. That means
-- someone hitting the REST API directly (not through the app UI) can already
-- list every league's invite code today, regardless of this migration.
-- Recommend reviewing that policy in Database -> Tables -> leagues -> RLS
-- Policies and restricting the columns/rows anon can select. Left untouched
-- here since the exact fix depends on the current policy's definition,
-- which isn't visible without dashboard access.
-- ─────────────────────────────────────────────────────────────────────────
