-- Weekend Picks: let already-released films into the pick pool.
-- Holdovers often stay in the weekend top 3 for weeks, so an unreleased-only
-- pool could make a win impossible. Pool is now every Universe film released
-- (or releasing) on or before the league's pool end (2026-12-31 for the ALPHA
-- 2027 playtest, so still no 2027 films). Replaces two functions from 056; safe
-- to run whether or not 056 has been updated, and in either order with 057.

create or replace function public.weekend_pick_pool(p_league_id uuid)
returns table(imdb_id text, title text, release_date date)
language plpgsql
security definer
stable
set search_path = public
as $$
declare
  v_end date;
begin
  if not public.is_league_member(p_league_id, auth.uid()) then
    raise exception 'Not a member of this league';
  end if;
  if not coalesce((select weekend_picks_enabled from leagues where id = p_league_id), false) then
    raise exception 'Weekend Picks is not enabled for this league';
  end if;
  v_end := public.weekend_pool_end(p_league_id);
  return query
    select uf.imdb_id, uf.title, uf.release_date
    from universe_films uf
    where uf.imdb_id is not null and uf.release_date <= v_end
    order by uf.release_date, uf.title;
end;
$$;
revoke all on function public.weekend_pick_pool(uuid) from public;
revoke execute on function public.weekend_pick_pool(uuid) from anon;
grant execute on function public.weekend_pick_pool(uuid) to authenticated;

create or replace function public.submit_weekend_picks(p_league_id uuid, p_pick1 text, p_pick2 text, p_pick3 text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_week public.weekend_pick_weeks;
  v_end date;
  v_id text;
begin
  if not public.is_league_member(p_league_id, auth.uid()) then
    raise exception 'Not a member of this league';
  end if;
  if not coalesce((select weekend_picks_enabled from leagues where id = p_league_id), false) then
    raise exception 'Weekend Picks is not enabled for this league';
  end if;

  v_week := public.ensure_weekend_picks_week(p_league_id);
  -- Lock the row so a submit can't interleave with an admin closing the window.
  select * into v_week from weekend_pick_weeks where id = v_week.id for update;
  if now() >= v_week.closes_at then
    raise exception 'The submission window for this weekend is closed';
  end if;

  if coalesce(p_pick1, '') = '' or coalesce(p_pick2, '') = '' or coalesce(p_pick3, '') = '' then
    raise exception 'Pick a film for all three spots';
  end if;
  if p_pick1 = p_pick2 or p_pick1 = p_pick3 or p_pick2 = p_pick3 then
    raise exception 'Each spot needs a different film';
  end if;

  v_end := public.weekend_pool_end(p_league_id);
  foreach v_id in array array[p_pick1, p_pick2, p_pick3] loop
    if not exists (
      select 1 from universe_films uf
      where uf.imdb_id = v_id and uf.release_date <= v_end
    ) then
      raise exception 'One of those films is not eligible (it has to be a film in this league''s pool)';
    end if;
  end loop;

  insert into weekend_picks (week_id, league_id, user_id, pick1, pick2, pick3)
  values (v_week.id, p_league_id, auth.uid(), p_pick1, p_pick2, p_pick3)
  on conflict (week_id, user_id) do update
    set pick1 = excluded.pick1, pick2 = excluded.pick2, pick3 = excluded.pick3, updated_at = now();
end;
$$;
revoke all on function public.submit_weekend_picks(uuid, text, text, text) from public;
revoke execute on function public.submit_weekend_picks(uuid, text, text, text) from anon;
grant execute on function public.submit_weekend_picks(uuid, text, text, text) to authenticated;
