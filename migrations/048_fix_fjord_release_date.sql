-- One-off data fix: universe_films had "Fjord" (tt35410859) release_date
-- 2026-08-19 (already released, so scrapeUniverseBoxOffice was trying and
-- failing to find real box office numbers for it -- the film hadn't
-- actually opened yet). Confirmed directly against Box Office Mojo's own
-- page for this imdb_id: real US theatrical date is October 9, 2026.
--
-- Why scrapeUniverseFilms() never auto-corrected this itself (it's
-- designed to -- see UniverseFilmsScraper.gs's file header comment): that
-- self-correction only fires for a film that reappears in the TMDb
-- discover() results our distributor allowlist (with_companies) actually
-- matches. Fjord's TMDb production_companies are all small European
-- production houses (Mobra Films, Why Not Productions, Film i Väst, etc.)
-- -- none of them are in the ~40-distributor allowlist, because TMDb's
-- production_companies field lists who *produced* the film, not who
-- picked it up for US theatrical distribution, and those are frequently
-- different for a foreign co-production. So Fjord can never be found by
-- our own discover query regardless of how stale its stored date gets --
-- this is a real (if narrow) gap in the auto-correction design, not a bug
-- in the matching logic itself. Worth a manual spot-fix like this one
-- whenever it comes up again for a similar foreign co-production; not
-- worth restructuring the whole discovery approach for what appears to be
-- a rare case (validated against 6 months of real data with zero other
-- misses when the allowlist was first built).
update universe_films
set release_date = '2026-10-09'
where imdb_id = 'tt35410859';
