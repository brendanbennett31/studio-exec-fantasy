-- 007 added leagues.sacko_punishment, but 006 locked anon's SELECT on
-- leagues down to an explicit column list (a table-wide REVOKE + column-
-- scoped re-GRANT) that predates this column, so anon can't read it yet.
-- Confirmed via curl: selecting sacko_punishment alongside any other column
-- returns 401 "permission denied for table leagues" for the anon key, even
-- though the column exists and authenticated users can read/write it fine.
--
-- Without this, the public view-only league link (?view=...) breaks
-- entirely for any league with a sacko_punishment set — loadLeagueContext()
-- fetches `leagues` first, so a permission error there throws before
-- standings/members even load.

grant select (sacko_punishment) on public.leagues to anon;
