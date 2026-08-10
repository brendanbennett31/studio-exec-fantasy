-- Release-day notification (backlog #11's third trigger). Notifies the
-- OWNING team's player specifically -- matches the Settings toggle's own
-- description, "A film on your slate releases today" -- not the whole
-- league, so this is a single set-based insert keyed off league_picks
-- joined to league_members (source of the notified user_id) and
-- universe_films (source of the release date).
--
-- Called once daily from Apps Script (service_role only, same pattern as
-- ensure_acquisition_week/resolve_acquisitions_week). Dedupes by checking
-- whether a release_day notification with this exact pick's link already
-- exists for that user -- a link is unique per (league, pick) and a pick
-- only ever releases once, so this is a safe permanent guard against
-- double-notifying even if the daily trigger somehow fires twice.
create or replace function public.notify_release_day_films()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into notifications (user_id, league_id, type, title, body, link)
  select lm.user_id, lp.league_id, 'release_day',
    uf.title || ' releases today!',
    'Your film in ' || l.name || ' hits theaters today.',
    '/league?id=' || lp.league_id || '&pick=' || lp.id
  from league_picks lp
  join universe_films uf on uf.imdb_id = lp.imdb_id
  join league_members lm on lm.league_id = lp.league_id and lm.team_name = lp.team_name
  join leagues l on l.id = lp.league_id
  left join notification_preferences np on np.user_id = lm.user_id
  where uf.release_date = current_date
    and not lp.voided
    and coalesce(np.notify_release_day, true)
    and not exists (
      select 1 from notifications n
      where n.type = 'release_day'
        and n.user_id = lm.user_id
        and n.link = '/league?id=' || lp.league_id || '&pick=' || lp.id
    );
end;
$$;

revoke all on function public.notify_release_day_films() from public;
grant execute on function public.notify_release_day_films() to service_role;
