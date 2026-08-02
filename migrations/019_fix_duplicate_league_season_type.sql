-- Fixes a bug in 018_duplicate_league_and_remainder.sql's duplicate_league():
-- it computed `v_src.season + 1`, assuming `leagues.season` is numeric. It's
-- actually stored as `text` (dashboard.html's create-league form reads it
-- straight off a number input's .value without ever parsing it), so
-- Postgres rejected the arithmetic outright:
--   ERROR: operator does not exist: text + integer
--
-- create or replace is idempotent -- this just re-defines the function with
-- the season handled as text throughout. Safe to run even though 018 already
-- ran.

create or replace function public.duplicate_league(
  p_source_league_id uuid,
  p_new_name text,
  p_new_season int default null
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_src leagues%rowtype;
  v_new_id uuid;
  v_new_season text;
begin
  if not public.is_league_admin(p_source_league_id, auth.uid()) then
    raise exception 'Only an admin of the source league can duplicate it';
  end if;

  select * into v_src from leagues where id = p_source_league_id;
  if not found then
    raise exception 'Source league not found';
  end if;

  -- leagues.season is text, not numeric -- cast both sides before combining.
  v_new_season := coalesce(p_new_season::text, (v_src.season::int + 1)::text);

  insert into leagues (
    name, season, budget, num_players, min_bid, max_bid,
    oscar_nom_bonus, oscar_win_bonus, bp_bonus, festival_picks,
    is_public, share_token, created_by, draft_status,
    acquisitions_enabled, acq_budget_default, acq_min_bid, acq_refund_rate
  ) values (
    coalesce(nullif(trim(p_new_name), ''), v_src.name),
    v_new_season,
    v_src.budget, v_src.num_players, v_src.min_bid, v_src.max_bid,
    v_src.oscar_nom_bonus, v_src.oscar_win_bonus, v_src.bp_bonus, v_src.festival_picks,
    false, substring(replace(gen_random_uuid()::text, '-', '') for 18), v_src.created_by, v_src.draft_status,
    false, v_src.acq_budget_default, v_src.acq_min_bid, v_src.acq_refund_rate
  )
  returning id into v_new_id;

  insert into league_members (league_id, user_id, team_name, role, color)
  select v_new_id, user_id, team_name, role, color
  from league_members
  where league_id = p_source_league_id;

  insert into league_picks (league_id, imdb_id, team_name, bid, voided, title, release_date, source)
  select v_new_id, imdb_id, team_name, bid, voided, title, release_date, 'draft'
  from league_picks
  where league_id = p_source_league_id;

  if v_src.draft_status = 'locked' then
    perform public.convert_draft_remainder(v_new_id);
  end if;

  return v_new_id;
end;
$$;

revoke all on function public.duplicate_league(uuid, text, int) from public;
grant execute on function public.duplicate_league(uuid, text, int) to authenticated;
