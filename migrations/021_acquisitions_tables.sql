-- Acquisitions feature, session 2 step 1: the tables for the actual weekly
-- bidding engine (declare -> bid -> resolve). RLS enabled on all four but no
-- policies/grants yet -- inspectable via the SQL Editor (which runs as a
-- privileged role) but not readable or writable by any client until
-- migration 022 adds the RPCs (the only sanctioned way to write to them)
-- and read policies.

create table if not exists acquisition_weeks (
  id uuid primary key default gen_random_uuid(),
  week_start date unique not null,
  declare_deadline timestamptz not null,
  bid_deadline timestamptz not null,
  resolved_at timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists acquisition_declarations (
  id uuid primary key default gen_random_uuid(),
  week_id uuid not null references acquisition_weeks(id) on delete cascade,
  league_id uuid not null references leagues(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  declared_at timestamptz not null default now(),
  violated boolean not null default false,
  unique(week_id, league_id, user_id)
);

create table if not exists acquisition_bids (
  id uuid primary key default gen_random_uuid(),
  week_id uuid not null references acquisition_weeks(id) on delete cascade,
  league_id uuid not null references leagues(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  -- A film must already exist in the real catalog to be bid on -- a still-
  -- blind Festival Futures placeholder (imdb_id is null on its league_picks
  -- row) has no imdb_id to reference here, so it's correctly ineligible.
  imdb_id text not null references universe_films(imdb_id),
  amount numeric not null check (amount > 0),
  submitted_at timestamptz not null default now(),
  status text not null default 'pending' check (status in ('pending','won','lost','invalid')),
  resolved_at timestamptz,
  unique(week_id, league_id, user_id, imdb_id)
);

-- Deliberately NOT FK'd to universe_films -- league_picks.imdb_id has an
-- "on delete restrict" FK specifically to stop a *drafted* film from being
-- deleted out from under a league; a historical refund record shouldn't
-- re-impose that same restriction on a film nobody has anymore.
create table if not exists refunds (
  id uuid primary key default gen_random_uuid(),
  league_id uuid not null references leagues(id) on delete cascade,
  user_id uuid,
  team_name text,
  imdb_id text,
  film_title text,
  original_bid numeric,
  refund_rate_applied numeric,
  credit_amount numeric,
  refunded_at timestamptz not null default now()
);

alter table acquisition_weeks enable row level security;
alter table acquisition_declarations enable row level security;
alter table acquisition_bids enable row level security;
alter table refunds enable row level security;

-- Verify: tables exist, empty, RLS on -- no client-facing behavior change yet.
select 'acquisition_weeks' as t, count(*) from acquisition_weeks
union all select 'acquisition_declarations', count(*) from acquisition_declarations
union all select 'acquisition_bids', count(*) from acquisition_bids
union all select 'refunds', count(*) from refunds;
