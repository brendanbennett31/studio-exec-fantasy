-- Follow-up to migration 033: that one fixed the league_picks/league_members
-- team_name mismatch by renaming league_picks to match league_members --
-- but league_members held each player's plain account-ish name (Brandon,
-- Rafael, sampadiankai), not their actual chosen studio name. Those live
-- in the old DEFAULT_STUDIOS constant (league.html) from the original
-- single-league era and were never carried over to league_members.color.
--
-- team_name is this app's one field for "studio name" (see rename_my_team
-- and the Settings "Studio Name" field) -- separate from the real player
-- name, which now comes from profiles.display_name via PLAYER_NAMES.
-- Updates both league_members and league_picks together to keep the join
-- that migration 033 just fixed intact.
update league_members set team_name = 'Continental Studios'
where league_id = 'c388b799-6240-46c4-ba75-da8a0d2e8db5' and team_name = 'Brandon';
update league_picks set team_name = 'Continental Studios'
where league_id = 'c388b799-6240-46c4-ba75-da8a0d2e8db5' and team_name = 'Brandon';

update league_members set team_name = 'Dwayne the Rock''s Wig'
where league_id = 'c388b799-6240-46c4-ba75-da8a0d2e8db5' and team_name = 'Rafael';
update league_picks set team_name = 'Dwayne the Rock''s Wig'
where league_id = 'c388b799-6240-46c4-ba75-da8a0d2e8db5' and team_name = 'Rafael';

update league_members set team_name = 'Ginza Films'
where league_id = 'c388b799-6240-46c4-ba75-da8a0d2e8db5' and team_name = 'sampadiankai';
update league_picks set team_name = 'Ginza Films'
where league_id = 'c388b799-6240-46c4-ba75-da8a0d2e8db5' and team_name = 'sampadiankai';

-- No Wot Studios (BB) already matches DEFAULT_STUDIOS.BB -- untouched.
-- Patrick still has no real league_members row -- once he joins, rename
-- him to 'Brock Heimer' (DEFAULT_STUDIOS.PATRICK) the same way.
