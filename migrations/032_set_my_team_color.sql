-- Enforces one color per team within a league. Mirrors rename_my_team()'s
-- shape exactly (migration 016): an app-level existence check inside a
-- narrowly-scoped SECURITY DEFINER RPC ("caller can only change their own
-- row"), rather than a raw client PATCH + a DB unique constraint -- keeps
-- the error a clean, predictable message instead of a raw Postgres
-- unique-violation the client would have to special-case.
--
-- Explicitly revokes execute from anon in the same statement (not just
-- `revoke all from public`) -- Supabase grants its own default EXECUTE to
-- anon on every public-schema function independent of the PUBLIC
-- pseudo-role, which is exactly the gap migration 028 had to close after
-- the fact for rename_my_team(). Closing it here from the start instead.
create or replace function public.set_my_team_color(p_league_id uuid, p_color text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (
    select 1 from league_members
    where league_id = p_league_id and user_id = auth.uid()
  ) then
    raise exception 'Not a member of this league';
  end if;

  if exists (
    select 1 from league_members
    where league_id = p_league_id and user_id <> auth.uid() and color = p_color
  ) then
    raise exception 'That color is already taken in this league';
  end if;

  update league_members
  set color = p_color
  where league_id = p_league_id and user_id = auth.uid();
end;
$$;

revoke all on function public.set_my_team_color(uuid, text) from public;
revoke execute on function public.set_my_team_color(uuid, text) from anon;
grant execute on function public.set_my_team_color(uuid, text) to authenticated;
