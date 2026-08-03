-- Fixes refund_my_film(): its second parameter was declared uuid, but
-- league_picks.id is actually a plain integer/serial (unlike the newer
-- tables in this feature, which all use uuid pks) -- confirmed by the
-- exact error hit clicking Refund for real:
--   invalid input syntax for type uuid: "92"
--
-- create or replace can't just change a parameter's type in place --
-- Postgres treats a different parameter type list as a different function
-- overload, which would leave the broken uuid-typed version sitting
-- alongside this one and risk an ambiguous-overload error. Drop it first.
drop function if exists public.refund_my_film(uuid, uuid);

create or replace function public.refund_my_film(p_league_id uuid, p_league_pick_id bigint)
returns numeric
language plpgsql
security definer
set search_path = public
as $$
declare
  v_member league_members%rowtype;
  v_pick league_picks%rowtype;
  v_league leagues%rowtype;
  v_film universe_films%rowtype;
  v_week acquisition_weeks%rowtype;
  v_credit numeric;
begin
  select * into v_member from league_members
  where league_id = p_league_id and user_id = auth.uid()
  for update;
  if not found then
    raise exception 'Not a member of this league';
  end if;

  select * into v_league from leagues where id = p_league_id;
  if not found or not v_league.acquisitions_enabled then
    raise exception 'Acquisitions is not enabled for this league';
  end if;

  select * into v_pick from league_picks where id = p_league_pick_id and league_id = p_league_id;
  if not found then
    raise exception 'Pick not found in this league';
  end if;
  if v_pick.team_name <> v_member.team_name then
    raise exception 'You can only refund your own picks';
  end if;
  if v_pick.imdb_id is null then
    raise exception 'A blind Festival Futures pick cannot be refunded until it resolves to a real film';
  end if;

  select * into v_film from universe_films where imdb_id = v_pick.imdb_id;
  if found and v_film.release_date is not null and v_film.release_date < current_date + 14 then
    raise exception 'Films must be refunded at least 14 days before release';
  end if;

  select * into v_week from acquisition_weeks order by week_start desc limit 1;
  if found
     and extract(dow from (now() at time zone 'America/Los_Angeles')) = 3
     and exists (
       select 1 from acquisition_declarations
       where week_id = v_week.id and league_id = p_league_id and user_id = auth.uid()
     )
  then
    raise exception 'Cannot refund on Wednesday while declared for this week''s bidding';
  end if;

  v_credit := round(v_pick.bid * v_league.acq_refund_rate, 2);

  insert into refunds (league_id, user_id, team_name, imdb_id, film_title, original_bid, refund_rate_applied, credit_amount)
  values (p_league_id, auth.uid(), v_pick.team_name, v_pick.imdb_id, coalesce(v_film.title, v_pick.title), v_pick.bid, v_league.acq_refund_rate, v_credit);

  -- Deleted, not soft-marked: this is what makes the film immediately
  -- available for anyone (including a different team) to acquire again --
  -- refund history for display purposes comes from the refunds table
  -- above, not from a lingering league_picks row.
  delete from league_picks where id = p_league_pick_id;

  return v_credit;
end;
$$;

revoke all on function public.refund_my_film(uuid, bigint) from public;
grant execute on function public.refund_my_film(uuid, bigint) to authenticated;
