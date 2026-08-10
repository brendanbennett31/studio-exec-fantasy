-- Sets each real player's account-level display name to match the clean
-- short names already used in the legacy view (BB/Brandon/Rafa/Kai), which
-- is what the modern per-league Standings view is supposed to show as the
-- bold "player name" -- separate from their studio name (Continental
-- Studios etc, already fixed in migration 034).
--
-- profiles.display_name is what LEAGUE_MEMBERS' joined profile actually
-- reads (league.html:264) -- updating it here directly rather than via
-- the /auth/v1/user endpoint each person would normally use themselves in
-- Settings. If any of them later change their own display name through
-- the app, that will overwrite this.
update profiles set display_name = 'BB'      where id = '0525ad1a-54ac-4aff-b0a1-dfa58dd26335';
update profiles set display_name = 'Brandon' where id = '400947eb-960f-4145-a22d-cbf0b956f42c';
update profiles set display_name = 'Rafa'    where id = 'ef1c9331-2a68-4f3b-8848-a3f4c602c2e8';
update profiles set display_name = 'Kai'     where id = '36ced750-05b8-42f1-8b36-598f2c202cd9';

-- Patrick has no real account/profile yet -- once he signs up and joins,
-- set his display_name to 'Patrick' the same way.
