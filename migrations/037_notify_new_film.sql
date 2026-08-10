-- New-film notification trigger (backlog #11's second of three remaining
-- triggers). Fires on any genuine INSERT into universe_films -- a DB-level
-- trigger rather than something scrapeUniverseFilms() calls explicitly, so
-- it fires correctly regardless of source (the daily TMDb scrape, or an
-- admin manually adding a film via universe.html) and can't be silently
-- skipped by an Apps Script error elsewhere in that run.
--
-- Notifies every account with the preference on, not scoped to a league --
-- universe_films is shared across all leagues, so "a new film exists" isn't
-- a per-league event the way declarations/acquisitions are. league_id is
-- left null on these notifications for that reason.
create or replace function public.trg_notify_new_film()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into notifications (user_id, league_id, type, title, body, link)
  select p.id, null, 'new_film',
    'New film added: ' || NEW.title,
    case when NEW.release_date is not null
      then 'Releasing ' || to_char(NEW.release_date, 'FMMonth FMDD, YYYY') || '. Now available to draft or acquire.'
      else 'Release date TBA. Now available to draft or acquire.'
    end,
    '/universe.html'
  from profiles p
  left join notification_preferences np on np.user_id = p.id
  where coalesce(np.notify_new_film, true);
  return NEW;
end;
$$;

drop trigger if exists universe_films_notify_new_film on universe_films;
create trigger universe_films_notify_new_film
  after insert on universe_films
  for each row
  execute function public.trg_notify_new_film();
