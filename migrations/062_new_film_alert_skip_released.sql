-- "New film added ... Now available to draft or acquire" is only useful for a
-- film that hasn't released yet. When the Universe scraper's company list was
-- fixed (Oct 2026) it started backfilling ~20 films that had already come out,
-- which would have sent members a pile of pointless alerts. So: skip the alert
-- when the film's release date is before today (Pacific). Films releasing today
-- or later, and the existing rules (needs a release date; only leagues whose
-- season window contains it; honours notify_new_film), are unchanged -- this is
-- migration 050's function with one extra early return.
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

  -- Already released: nothing left to draft or acquire-before-release.
  if NEW.release_date < (now() at time zone 'America/Los_Angeles')::date then
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
