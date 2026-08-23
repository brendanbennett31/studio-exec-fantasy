-- Grants Brandon and Rafael the same profiles.is_admin flag you have --
-- this is the single global gate for the /universe page (migration 009):
-- it's page access AND full edit rights together (add/edit/delete any
-- film, plus the new manual lock/unlock override), there's no narrower
-- "view only" tier today. Matched by their CURRENT team_name on the live
-- league rather than a hardcoded user id, so this is self-verifying --
-- read the WHERE clause below before running: if "Continental Studios" and
-- "Sacko Studios" aren't actually Brandon and Rafael's teams anymore
-- (team names are player-editable), this would grant the wrong people.
update profiles set is_admin = true
where id in (
  select user_id from league_members
  where league_id = 'c388b799-6240-46c4-ba75-da8a0d2e8db5'
    and team_name in ('Continental Studios', 'Sacko Studios')
);

-- Verify: should show exactly 3 rows now (you + these two), each is_admin=true.
select p.id, p.display_name, p.is_admin, lm.team_name
from profiles p
join league_members lm on lm.user_id = p.id
where lm.league_id = 'c388b799-6240-46c4-ba75-da8a0d2e8db5'
order by lm.team_name;
