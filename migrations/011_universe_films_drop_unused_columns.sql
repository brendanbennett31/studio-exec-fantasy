-- Drops `eligible` and `studio` from universe_films, added in migration 009
-- but removed from the admin UI almost immediately: eligibility isn't a
-- useful distinction in practice (most/all films could be), and studio
-- isn't tracked. Both columns are unused (table had 0 rows when 009 ran,
-- and neither field was ever exposed for more than a day), so dropping is
-- safe -- no data loss.
--
-- release_date is intentionally NOT touched here: it's becoming a
-- scraper-owned field (Box Office Mojo as source of truth) rather than
-- admin-entered, but it's still needed to bucket films into the 2026/2027
-- Season tabs, so the column and its data stay.

alter table universe_films
  drop column if exists eligible,
  drop column if exists studio;
