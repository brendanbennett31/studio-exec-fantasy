-- La Bola Negra won the 2026 Toronto Film Festival People's Choice Award
-- (Deadline, 2026-09-20). No Wot Studios had drafted the blind Festival
-- Futures placeholder "TIFF - People's Choice Award" (league_picks id 69,
-- $19M) -- this adds the film to the Universe and resolves that placeholder
-- into it, same as ManageTab's "Resolve" action would.
--
-- release_date is the US limited theatrical date (Oct 16, 2026, LA/NYC per
-- TMDb; it also streams on Netflix Dec 2). imdb tt35511966.
--
-- The new-film notification trigger is switched off just for this insert:
-- it would tell every member of the 2026 league "new film available to
-- draft or acquire" about a film that's already on a slate. Inside one
-- transaction, so it can't be left disabled if anything fails.
begin;

alter table universe_films disable trigger universe_films_notify_new_film;

insert into universe_films (title, imdb_id, release_date, notes)
values ('La Bola Negra', 'tt35511966', '2026-10-16',
        'TIFF 2026 People''s Choice winner. US limited release Oct 16 (Netflix Dec 2).')
on conflict (imdb_id) do nothing;

alter table universe_films enable trigger universe_films_notify_new_film;

update league_picks
set imdb_id = 'tt35511966', title = null, release_date = null
where id = 69 and imdb_id is null;

commit;

-- Verify: one row, imdb_id set, on No Wot Studios
select lp.id, lp.team_name, lp.bid, lp.imdb_id, uf.title, uf.release_date
from league_picks lp join universe_films uf on uf.imdb_id = lp.imdb_id
where lp.id = 69;
