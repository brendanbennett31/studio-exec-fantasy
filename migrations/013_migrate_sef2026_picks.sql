-- One-time data migration: moves the 63 existing `picks` rows for the
-- legacy sef-2026 league (real uuid c388b799-6240-46c4-ba75-da8a0d2e8db5)
-- into the new league_picks + universe_films model. Run 012 first.
--
-- 61 of the 63 rows have a matching universe_films row (by imdb_id or
-- fuzzy-normalized title); 2 are "Festival Futures" placeholders ("Palme
-- d'Or Winner", "TIFF - People's Choice Award") with no real film yet --
-- these were confirmed by name in a prior session, not re-derived here.
--
-- `picks` itself is left untouched afterward -- a frozen historical
-- archive. Nothing in the new code path reads it; only the separate,
-- deliberately-untouched IS_LEGACY fallback in league.html (the bare
-- /league.html with no ?id= at all) still reads picks directly.

-- Throwaway SQL port of universe.html's normTitle() (lowercase, strip a
-- leading "the/a/an", collapse any run of non-alphanumeric characters to a
-- single space) -- used only for this one-off backfill's title matching.
-- Dropped at the end of this migration; the JS version in universe.html
-- remains the single source of truth for this logic going forward.
create or replace function pg_temp_norm_title(t text) returns text as $$
  select trim(regexp_replace(regexp_replace(lower(coalesce(t,'')), '^(the |a |an )', ''), '[^a-z0-9]+', ' ', 'g'));
$$ language sql immutable;

-- ─────────────────────────────────────────────────────────────────────────
-- STEP 0 -- RUN THIS FIRST, BY ITSELF, AND CONFIRM THE OUTPUT BEFORE
-- CONTINUING. Expect 61 rows with a non-null matched_universe_film_id and
-- exactly 2 with null (the two Festival Futures placeholders). If the
-- count is off, stop -- some picks row's title doesn't match its
-- universe_films counterpart and needs a manual fix first.
-- ─────────────────────────────────────────────────────────────────────────
select p.title, p.imdb_id, uf.id as matched_universe_film_id
from picks p
left join universe_films uf
  on (p.imdb_id is not null and p.imdb_id = uf.imdb_id)
  or pg_temp_norm_title(p.title) = pg_temp_norm_title(uf.title)
where p.league_id = 'sef-2026'
order by matched_universe_film_id nulls first;

-- ─────────────────────────────────────────────────────────────────────────
-- Once STEP 0 looks right (61 matched + 2 null), run everything below.
-- ─────────────────────────────────────────────────────────────────────────

-- STEP 1 -- backfill universe_films' box-office columns from picks so
-- scraped history (BO total, opening weekend, plateau/lock state) isn't
-- lost for the already-tracked films. coalesce so nothing already-good in
-- universe_films gets clobbered by a stale/zero value from picks.
update universe_films uf
set bo              = coalesce(p.bo, uf.bo),
    opening_weekend  = coalesce(p.opening_weekend, uf.opening_weekend),
    no_change_days   = coalesce(p.no_change_days, uf.no_change_days),
    locked           = coalesce(p.locked, uf.locked),
    last_check_date  = coalesce(p.last_check_date, uf.last_check_date)
from picks p
where p.league_id = 'sef-2026'
  and (
    (p.imdb_id is not null and p.imdb_id = uf.imdb_id)
    or pg_temp_norm_title(p.title) = pg_temp_norm_title(uf.title)
  );

-- STEP 2 -- insert the 61 real-film league_picks rows.
insert into league_picks (league_id, imdb_id, team_name, bid, voided)
select 'c388b799-6240-46c4-ba75-da8a0d2e8db5'::uuid,
       uf.imdb_id, p.team, p.bid, coalesce(p.voided, false)
from picks p
join universe_films uf
  on (p.imdb_id is not null and p.imdb_id = uf.imdb_id)
  or pg_temp_norm_title(p.title) = pg_temp_norm_title(uf.title)
where p.league_id = 'sef-2026';

-- STEP 3 -- insert the 2 Festival Futures placeholders explicitly by name.
insert into league_picks (league_id, imdb_id, team_name, bid, voided, title, release_date)
select 'c388b799-6240-46c4-ba75-da8a0d2e8db5'::uuid,
       null, p.team, p.bid, coalesce(p.voided, false), p.title, p.release_date
from picks p
where p.league_id = 'sef-2026'
  and p.title in ('Palme d''Or Winner', 'TIFF - People''s Choice Award');

-- STEP 4 -- verify: both counts should read 63.
select
  (select count(*) from picks where league_id = 'sef-2026') as picks_count,
  (select count(*) from league_picks where league_id = 'c388b799-6240-46c4-ba75-da8a0d2e8db5') as league_picks_count;

drop function pg_temp_norm_title(text);
