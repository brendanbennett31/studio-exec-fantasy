-- Centralizes box-office tracking on universe_films (one scrape per real
-- film, shared across every league that drafted it, instead of once per
-- league) and turns league_picks into a thin per-league join row against
-- universe_films, matched by imdb_id.
--
-- league_picks currently has 0 rows (confirmed: only two stray references
-- anywhere in the codebase -- a leftover DELETE in dashboard.html's
-- league-deletion flow, and a stale comment in league.html -- neither a
-- working feature), so this migration freely drops/re-adds its columns
-- rather than trying to preserve anything.
--
-- Pre-checked: universe_films has 167 non-null imdb_ids with zero
-- duplicates, so the unique constraint below is safe to add as-is.

-- ── league_picks: drop the columns that are really film-level facts ────────
-- bo/locked were only ever per-league because `picks` (the table this
-- replaces) was per-league. Keeping them here too would recreate the "same
-- film scraped N times, N disagreeing copies" problem this migration exists
-- to fix. status is dropped because it's fully derivable client-side from
-- release_date (league.html already does this as a fallback) -- storing it
-- would just be a second, driftable copy of the same fact.
alter table league_picks
  drop column if exists bo,
  drop column if exists locked,
  drop column if exists status;

alter table league_picks
  add column if not exists league_id uuid,
  add column if not exists imdb_id text,
  add column if not exists team_name text,
  add column if not exists bid numeric,
  add column if not exists voided boolean not null default false,
  add column if not exists title text,
  add column if not exists release_date date,
  add column if not exists user_id uuid;

-- title/release_date are only meaningful when imdb_id is null -- the
-- "Festival Futures" placeholder case (e.g. drafting the not-yet-announced
-- Palme d'Or winner). When imdb_id is set, universe_films is the source of
-- truth for both and these columns are ignored by the app.
alter table league_picks drop constraint if exists league_picks_resolvable_check;
alter table league_picks add constraint league_picks_resolvable_check
  check (imdb_id is not null or title is not null);

alter table league_picks
  alter column league_id set not null,
  alter column team_name set not null,
  alter column bid set not null;

-- A league can't draft the same real film twice. Partial (not full) unique
-- index: placeholder rows (imdb_id null) are exempt, since a league can
-- have multiple undecided Festival Futures picks at once.
create unique index if not exists league_picks_league_imdb_uidx
  on league_picks(league_id, imdb_id) where imdb_id is not null;

alter table league_picks drop constraint if exists league_picks_league_id_fkey;
alter table league_picks add constraint league_picks_league_id_fkey
  foreign key (league_id) references leagues(id) on delete cascade;

-- ── universe_films: shared box-office columns ──────────────────────────────
-- One row per real film. Mirrors exactly what used to live per-league-row
-- in `picks` (bo, opening_weekend, no_change_days, locked/plateau
-- tracking, last_check_date, bom_release_id).
alter table universe_films
  add column if not exists bo numeric not null default 0,
  add column if not exists opening_weekend numeric not null default 0,
  add column if not exists no_change_days integer not null default 0,
  add column if not exists locked boolean not null default false,
  add column if not exists last_check_date date,
  add column if not exists bom_release_id text;

-- Required for the FK below AND for PostgREST's embedded-resource join
-- syntax (league_picks?select=*,universe_films(*)) to work at all --
-- PostgREST only auto-detects embeds across a real foreign key. Plain
-- UNIQUE (not a partial index -- Postgres won't let a FK reference one) is
-- fine even with many NULLs, since a standard UNIQUE constraint never
-- compares NULL to NULL.
alter table universe_films drop constraint if exists universe_films_imdb_id_key;
alter table universe_films add constraint universe_films_imdb_id_key unique (imdb_id);

alter table league_picks drop constraint if exists league_picks_imdb_id_fkey;
alter table league_picks add constraint league_picks_imdb_id_fkey
  foreign key (imdb_id) references universe_films(imdb_id)
  -- restrict, not cascade/set null: deleting a universe_films row that a
  -- league already drafted should force deliberate handling (via
  -- universe.html's edit-in-place) rather than silently orphaning or
  -- erasing a league's pick history.
  on delete restrict
  on update cascade;

-- ── RLS ──────────────────────────────────────────────────────────────────
alter table league_picks enable row level security;

-- Match `picks`' existing (always-open, never restricted by any prior
-- migration) anon-select posture, so public-view leagues keep working
-- exactly the same way they do today.
grant select on league_picks to anon, authenticated;
grant insert, update, delete on league_picks to authenticated;

drop policy if exists "league_picks_select" on league_picks;
create policy "league_picks_select" on league_picks
  for select
  to anon, authenticated
  using (true);

-- Writes: only a league admin (or the league's creator) can add/edit/void
-- picks for that league -- reusing the is_league_admin() helper already
-- defined in migration 005, same pattern as leagues_update there.
drop policy if exists "league_picks_write_admin" on league_picks;
create policy "league_picks_write_admin" on league_picks
  for all
  to authenticated
  using (public.is_league_admin(league_id, auth.uid()))
  with check (public.is_league_admin(league_id, auth.uid()));
