-- Release-date audit (2026-09-20): cross-checked every universe_films row
-- that has an imdb_id (204 of 218) against TMDb's US theatrical dates and
-- Box Office Mojo's own "Release Date (Domestic)" field. Four real fixes,
-- each confirmed by BOTH sources:
--
--  * Shaun the Sheep: The Beast of Mossy Bottom -- stored 2026-10-31, real
--    US theatrical release is 2026-09-18.
--  * Once Upon A Time In Harlem, All of a Sudden, Godzilla x Kong:
--    Supernova -- all three were sitting on a slate with NO date at all;
--    real US dates are below.
--
-- Updating release_date fires the existing release-date-changed
-- notification to whoever has each film drafted, which is what we want.
update universe_films set release_date = '2026-09-18' where imdb_id = 'tt36841161'; -- Shaun the Sheep
update universe_films set release_date = '2026-10-16' where imdb_id = 'tt39163347' and release_date is null; -- Once Upon A Time In Harlem
update universe_films set release_date = '2026-11-25' where imdb_id = 'tt36834996' and release_date is null; -- All of a Sudden
update universe_films set release_date = '2027-03-26' where imdb_id = 'tt32561550' and release_date is null; -- Godzilla x Kong: Supernova

select title, release_date from universe_films
where imdb_id in ('tt36841161','tt39163347','tt36834996','tt32561550') order by title;
