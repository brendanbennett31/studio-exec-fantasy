-- Add the nine Gold Derby Oscar contenders that were missing from the Universe,
-- so the Awards tab can match them (they showed as "undrafted"/unmatched):
-- American Doctor, Artificial, By Any Means, Club Kid, Elsinore, Iron Boy,
-- Naza, Rose, Tangles. (Hoppers is a Mar 2026 release, before the 2026 season
-- window, so it stays out.)
--
-- imdb_id and release_date are TMDb's (release_date = TMDb's primary date, the
-- same one UniverseFilmsScraper.gs uses). Titles use Gold Derby's spelling so
-- the Awards tab matches them.
--
-- The new-film notification trigger is switched off for this insert: the
-- already-released films would be skipped anyway (migration 062), but Artificial
-- (Dec 25) and Tangles (Nov 27) are still upcoming and would send a "new film
-- available to draft or acquire" alert to every member of the 2026 league.
-- Everything runs in one transaction so the trigger can't be left disabled.
-- Safe to re-run: skips any film whose imdb_id or title is already present.
begin;

alter table universe_films disable trigger universe_films_notify_new_film;

insert into universe_films (title, imdb_id, release_date, notes)
select v.title, v.imdb_id, v.release_date::date, v.notes
from (values
  ('American Doctor', 'tt39149951', '2026-08-14', 'Documentary. Added as a Gold Derby Oscar contender.'),
  ('Artificial',      'tt37171180', '2026-12-25', 'Added as a Gold Derby Oscar contender.'),
  ('By Any Means',    'tt34379051', '2026-09-02', 'Added as a Gold Derby Oscar contender.'),
  ('Club Kid',        'tt38058097', '2026-11-04', 'Added as a Gold Derby Oscar contender.'),
  ('Elsinore',        'tt37363222', '2026-11-20', 'Added as a Gold Derby Oscar contender.'),
  ('Iron Boy',        'tt36639956', '2026-10-14', 'Animated. Added as a Gold Derby Oscar contender.'),
  ('Naza',            'tt44766123', '2026-09-25', 'Documentary. Added as a Gold Derby Oscar contender.'),
  ('Rose',            'tt25399154', '2026-04-17', 'Added as a Gold Derby Oscar contender.'),
  ('Tangles',         'tt22183852', '2026-11-27', 'Animated. Added as a Gold Derby Oscar contender.')
) as v(title, imdb_id, release_date, notes)
where not exists (select 1 from universe_films u where u.imdb_id = v.imdb_id)
  and not exists (select 1 from universe_films u where public.weekend_norm_title(u.title) = public.weekend_norm_title(v.title));

alter table universe_films enable trigger universe_films_notify_new_film;

commit;

-- Verify: nine rows.
select title, imdb_id, release_date from universe_films
where imdb_id in ('tt39149951','tt37171180','tt34379051','tt38058097','tt37363222','tt36639956','tt44766123','tt25399154','tt22183852')
order by release_date;
