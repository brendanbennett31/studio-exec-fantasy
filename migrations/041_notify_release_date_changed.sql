-- Release-date-change notification (backlog #12). The actual date
-- correction already happens in scrapeUniverseFilms() (UniverseFilmsScraper.gs,
-- not this repo) whenever TMDb's release_date differs from what's stored --
-- this just adds the missing notification half. Since every league's slate
-- joins to universe_films by imdb_id, that correction already cascades to
-- every slate on its own; this trigger doesn't need to touch league_picks
-- at all, only notify the people it affects.
--
-- "All players" is scoped to whoever actually has this film drafted (in
-- any league, via league_picks), not every account in the app -- a date
-- shift for a film you have no stake in isn't useful noise, and new_film
-- (migration 037) already covers the "notify literally everyone" case for
-- films that aren't on anyone's slate yet.
--
-- Reuses the existing notify_release_day preference rather than adding a
-- 5th toggle -- both are "something changed about a release date for a
-- film on your slate." Settings copy updated to reflect that.
alter table notifications drop constraint if exists notifications_type_check;
alter table notifications add constraint notifications_type_check
  check (type in ('declaration','new_leader','new_film','release_day','release_date_changed'));

create or replace function public.trg_notify_release_date_changed()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if OLD.release_date is distinct from NEW.release_date then
    insert into notifications (user_id, league_id, type, title, body, link)
    select lm.user_id, lp.league_id, 'release_date_changed',
      NEW.title || '''s release date changed',
      case
        when OLD.release_date is null then NEW.title || ' now has a release date: ' || to_char(NEW.release_date, 'FMMonth FMDD, YYYY') || '.'
        when NEW.release_date is null then NEW.title || '''s release date is now TBA (was ' || to_char(OLD.release_date, 'FMMonth FMDD, YYYY') || ').'
        else NEW.title || ' moved from ' || to_char(OLD.release_date, 'FMMonth FMDD, YYYY') || ' to ' || to_char(NEW.release_date, 'FMMonth FMDD, YYYY') || '.'
      end,
      '/league?id=' || lp.league_id || '&pick=' || lp.id
    from league_picks lp
    join league_members lm on lm.league_id = lp.league_id and lm.team_name = lp.team_name
    left join notification_preferences np on np.user_id = lm.user_id
    where lp.imdb_id = NEW.imdb_id
      and not lp.voided
      and coalesce(np.notify_release_day, true);
  end if;
  return NEW;
end;
$$;

drop trigger if exists universe_films_notify_release_date_changed on universe_films;
create trigger universe_films_notify_release_date_changed
  after update on universe_films
  for each row
  execute function public.trg_notify_release_date_changed();
