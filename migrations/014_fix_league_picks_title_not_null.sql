-- Fixes a gap in migration 012: league_picks.title (and release_date)
-- already existed as columns on the table before 012 ran, with a NOT NULL
-- constraint from whenever the table was originally created. 012 only ever
-- ran `add column if not exists`, which is a no-op for a column that
-- already exists -- it never touched the constraint on it. Confirmed via
-- the actual error hit trying to insert a real-film pick (title
-- intentionally null, since a real film's title comes from the
-- universe_films join instead):
--   ERROR: 23502: null value in column "title" of relation "league_picks"
--   violates not-null constraint
--
-- Both are meant to be nullable -- see the league_picks_resolvable_check
-- constraint from 012, which already encodes the real invariant (imdb_id
-- is not null or title is not null).

alter table league_picks
  alter column title drop not null,
  alter column release_date drop not null;
