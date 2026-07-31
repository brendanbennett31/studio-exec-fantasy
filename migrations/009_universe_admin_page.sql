-- Backs the new /universe admin page.
-- Run this once in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
--
-- universe_films currently exists (empty, never written to by the Apps
-- Script) with: title, release_date, imdb_id, bo, on_slate. Confirmed via
-- probing PostgREST's schema-cache errors with the anon key, since the
-- project's OpenAPI introspection endpoint is service_role-only. This adds
-- the three columns the admin UI needs (studio, eligible, notes) plus an
-- is_admin flag on profiles, and sets up RLS so:
--   - any signed-in user can view the list (read-only by default)
--   - only users with profiles.is_admin = true can add/edit/delete rows
--   - anon (no login) gets nothing, matching "auth-gated" requirement

alter table universe_films
  add column if not exists studio text,
  add column if not exists eligible boolean not null default true,
  add column if not exists notes text;

alter table profiles
  add column if not exists is_admin boolean not null default false;

-- Defensive: make sure authenticated actually has the base table grant.
-- (Learned the hard way on the leagues table that Supabase project grants
-- can be customized in ways RLS policies alone don't reveal.)
grant select, insert, update, delete on universe_films to authenticated;

drop policy if exists "universe_films_select_authenticated" on universe_films;
create policy "universe_films_select_authenticated" on universe_films
  for select
  to authenticated
  using (true);

drop policy if exists "universe_films_write_admin" on universe_films;
create policy "universe_films_write_admin" on universe_films
  for all
  to authenticated
  using (
    exists (select 1 from profiles p where p.id = auth.uid() and p.is_admin = true)
  )
  with check (
    exists (select 1 from profiles p where p.id = auth.uid() and p.is_admin = true)
  );
