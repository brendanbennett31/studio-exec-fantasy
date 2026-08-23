-- trg_notify_new_film() previously notified every account with the
-- preference on, globally, with league_id left null -- universe_films is
-- shared across leagues, so there was no per-league targeting at all. That
-- meant a player got "new film available" pings for films releasing in a
-- completely different season than the one they're actually playing (e.g.
-- a 2027-window film showing up as a notification while they're mid-2026
-- season). Rewritten to loop over every league whose season window
-- (league_season_window(), same helper nominate_film()/
-- submit_acquisition_bid() already use) actually contains the new film's
-- release_date, and only notify THAT league's members -- same per-league
-- shape as check_new_leaders(), notifications now get a real league_id
-- instead of null.
--
-- Films with no release_date yet (TBA) are skipped entirely -- there's no
-- way to know which league's season they'll eventually land in. If/when
-- scrapeUniverseFilms() later fills in a real date for one of these, no
-- notification fires retroactively for the leagues that just became
-- eligible -- a real, narrow gap, not fixed here since it wasn't part of
-- what was asked (the existing release-date-changed trigger only covers
-- films already drafted, not undrafted ones gaining a date for the first
-- time).
create or replace function public.trg_notify_new_film()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  r record;
begin
  if NEW.release_date is null then
    return NEW;
  end if;

  for r in
    select l.id as league_id, l.name as league_name
    from leagues l, league_season_window(l.season) w
    where NEW.release_date between w.window_start and w.window_end
  loop
    insert into notifications (user_id, league_id, type, title, body, link)
    select lm.user_id, r.league_id, 'new_film',
      'New film added: ' || NEW.title,
      'Releasing ' || to_char(NEW.release_date, 'FMMonth FMDD, YYYY') || '. Now available to draft or acquire in ' || r.league_name || '.',
      '/universe.html'
    from league_members lm
    left join notification_preferences np on np.user_id = lm.user_id
    where lm.league_id = r.league_id
      and coalesce(np.notify_new_film, true);
  end loop;
  return NEW;
end;
$$;
