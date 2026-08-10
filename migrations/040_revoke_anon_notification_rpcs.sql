-- notify_release_day_films() and check_new_leaders() (migrations 038/039)
-- were meant to be service_role-only, same as ensure_acquisition_week()/
-- resolve_acquisitions_week(), but only did `revoke all from public` +
-- `grant to service_role` -- missing the explicit `revoke ... from anon`
-- that rename_my_team() needed after the fact (migration 028) and
-- set_my_team_color() got right from the start (migration 032). Confirmed
-- both were callable with a bare anon key (HTTP 204) before this ran.
--
-- Not a severe hole content-wise (worst case is spammed/duplicate
-- notification runs, and release_day's own link-based dedupe already
-- limits the damage there), but neither should be triggerable by anyone
-- outside the daily Apps Script cron.
revoke execute on function public.notify_release_day_films() from anon, authenticated;
revoke execute on function public.check_new_leaders() from anon, authenticated;
