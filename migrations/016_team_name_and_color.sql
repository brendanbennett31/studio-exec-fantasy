-- Lets a player rename their own studio/team and pick their own color
-- within a league.
--
-- Color: purely a new league_members.color column. A member updating their
-- own row is already permitted by migration 005's members_update policy, so
-- no new policy is needed for this part -- just the column.
--
-- Team name: league.html already had a "Studio Name" field (SettingsPanel's
-- "league" tab) that PATCHes league_members.team_name directly -- but that
-- never cascaded to that member's existing league_picks rows. Standings
-- bucket films by a plain string match on league_picks.team_name (it is not
-- a foreign key to league_members -- see migration 012's design notes), so
-- a rename would silently orphan that player's already-drafted films under
-- their old name. And a plain member can't fix this themselves by directly
-- patching league_picks: migration 012's league_picks_write_admin policy
-- only allows a league's admin to write to league_picks.
--
-- rename_my_team() is a narrowly-scoped SECURITY DEFINER RPC (same pattern
-- as is_league_member/is_league_admin from migration 005) that does both
-- updates in one transaction, gated to "the caller can only rename
-- themselves" rather than opening up general league_picks write access.

alter table league_members add column if not exists color text;

create or replace function public.rename_my_team(p_league_id uuid, p_new_name text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_old_name text;
  v_new_name text := trim(p_new_name);
begin
  if v_new_name = '' then
    raise exception 'Team name cannot be empty';
  end if;

  select team_name into v_old_name
  from league_members
  where league_id = p_league_id and user_id = auth.uid();

  if v_old_name is null then
    raise exception 'Not a member of this league';
  end if;

  if exists (
    select 1 from league_members
    where league_id = p_league_id and user_id <> auth.uid() and team_name = v_new_name
  ) then
    raise exception 'That team name is already taken in this league';
  end if;

  update league_members
  set team_name = v_new_name
  where league_id = p_league_id and user_id = auth.uid();

  if v_old_name <> v_new_name then
    update league_picks
    set team_name = v_new_name
    where league_id = p_league_id and team_name = v_old_name;
  end if;
end;
$$;

revoke all on function public.rename_my_team(uuid, text) from public;
grant execute on function public.rename_my_team(uuid, text) to authenticated;
