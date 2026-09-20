-- True calendar-week box office per team, computed straight from daily_bo
-- (real per-day Box Office Mojo data) instead of differencing weekly
-- snapshots. Snapshot deltas turned out to be unreliable for the "New
-- Weekly Box Office" chart: the old sheet-based system's rows were captured
-- at inconsistent points in their weeks (and stale for a stretch), so
-- Spider-Man's opening week landed in the wrong bars -- e.g. the chart
-- showed ~$618M for the week of Aug 3 when the real number was ~$395M.
--
-- Uses each team's CURRENT roster for every past week (a film traded via
-- Acquisitions shows under its current owner retroactively), and joins
-- daily_bo to universe_films by title (the only key daily_bo has -- see the
-- item 16 note about centralizing it by imdb_id). Films without daily rows
-- simply contribute nothing. distinct-on guards against double counting if
-- daily_bo ever holds the same film/day under more than one league_id.
--
-- Readable by members of the league, or by anyone if the league is public
-- (mirrors public-view mode) -- explicit grant to anon is intentional here:
-- it's a read-only aggregate over data anon can already read row by row.
create or replace function public.weekly_box_office_by_team(p_league_id uuid)
returns table(week_start date, team_name text, amount numeric)
language sql
security definer
stable
set search_path = public
as $$
  with daily as (
    select distinct on (film_title, bo_date) film_title, bo_date, daily_gross
    from daily_bo
    order by film_title, bo_date, id
  )
  select date_trunc('week', d.bo_date)::date as week_start,
         lp.team_name,
         sum(d.daily_gross)::numeric as amount
  from league_picks lp
  join universe_films uf on uf.imdb_id = lp.imdb_id
  join daily d on d.film_title = uf.title
  where lp.league_id = p_league_id
    and (
      public.is_league_member(p_league_id, auth.uid())
      or exists (select 1 from leagues l where l.id = p_league_id and l.is_public)
    )
  group by 1, 2
  order by 1, 2;
$$;

revoke all on function public.weekly_box_office_by_team(uuid) from public;
grant execute on function public.weekly_box_office_by_team(uuid) to anon, authenticated;
