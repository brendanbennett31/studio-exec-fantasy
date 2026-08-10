-- Root cause of "the player names aren't showing for teammates": profiles
-- has always been SELECT-restricted to your own row only (id = auth.uid(),
-- confirmed untouched by migration 010's comment). league.html's
-- LEAGUE_MEMBERS query embeds profile:profiles(display_name,email) for
-- every member, but RLS silently returns null for every profile except
-- the signed-in viewer's own -- so PLAYER_NAMES could only ever resolve
-- for whichever team you personally play on, no matter what
-- profiles.display_name is set to for anyone else (migration 035 set the
-- right values, they just aren't reachable this way).
--
-- Same shape as public_member_names (migration 001), which already solves
-- this exact problem for anonymous public-view visitors by exposing only
-- display_name (never email) through a view. This is the authenticated
-- equivalent: scoped to leagues the CALLING user is also a member of,
-- rather than only leagues marked is_public, so it works for private
-- leagues like the real season league without exposing display names
-- league-wide to everyone on the app.
create or replace view league_member_names as
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
  where exists (
    select 1 from league_members me
    where me.league_id = m.league_id and me.user_id = auth.uid()
  );

grant select on league_member_names to authenticated;
