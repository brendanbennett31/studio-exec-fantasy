-- Fixes: deleting a league silently does nothing. dashboard.html's delete
-- flow (executeLAM's 'delete' branch) issues DELETE requests for
-- league_picks, then league_members, then leagues itself -- but `leagues`
-- has never had a DELETE grant or RLS policy at any point in this
-- migration history (002-006 only ever added SELECT policies, 005 added
-- the leagues_update UPDATE policy). With RLS enabled and no DELETE policy,
-- Postgres/PostgREST silently matches zero rows -- the request "succeeds"
-- (dashboard.html's sbFetch sees ok:true) but the league row is never
-- actually removed, so it reappears on the dashboard after reload.
--
-- Same is_league_admin() helper already used for leagues_update (migration
-- 005) and league_picks_write_admin (migration 012) -- only a league's
-- admin or its creator can delete it.

grant delete on public.leagues to authenticated;

drop policy if exists "leagues_delete" on public.leagues;
create policy "leagues_delete" on public.leagues
  for delete
  to authenticated
  using (public.is_league_admin(id, auth.uid()));
