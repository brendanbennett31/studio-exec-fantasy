-- Live Draft Room, session 1 step 1: schema. Full design at
-- /Users/brendanbennett/.claude/plans/peaceful-beaming-feather.md -- a
-- fantasy-football-style live auction, entirely separate from Acquisitions
-- (the weekly waiver-wire market): admin sets/randomizes turn order,
-- players take turns nominating a film from the Universe, everyone can bid
-- on whatever's currently nominated (NOT sealed, unlike Acquisitions --
-- watching competing bids live is the point), a countdown timer (with
-- soft-close anti-snipe) decides the winner.

-- null = not yet chosen; set exactly once via choose_draft_mode() (session
-- 1 step 2). A league reaching draft_mode is not null, draft_status still
-- 'open', and zero league_picks rows is what the mode-picker screen (a
-- later session's UI work) triggers on.
alter table leagues add column if not exists draft_mode text check (draft_mode in ('manual','live'));

-- One row per league: the singleton draft state. turn_order stores user_id
-- (not team_name) -- rename_my_team() can change team_name mid-draft,
-- user_id is the stable identity, joined against league_members at
-- resolution time exactly like resolve_acquisitions_week() already does.
create table draft_sessions (
  id uuid primary key default gen_random_uuid(),
  league_id uuid not null references leagues(id) on delete cascade,
  status text not null default 'setup' check (status in ('setup','active','completed')),
  turn_order uuid[] not null default '{}',
  current_turn_idx int not null default 0,
  timer_seconds int not null default 60 check (timer_seconds between 10 and 3600),
  soft_close_seconds int not null default 10 check (soft_close_seconds between 1 and timer_seconds),
  nomination_timeout_seconds int not null default 30 check (nomination_timeout_seconds between 10 and 600),
  -- Set whenever it becomes someone's turn to nominate; cleared while an
  -- item is actively being bid on (no nomination-timer during bidding).
  nomination_ends_at timestamptz,
  created_by uuid not null references auth.users(id),
  started_at timestamptz,
  completed_at timestamptz,
  updated_at timestamptz not null default now(),
  unique(league_id)
);

-- One row per nomination.
create table draft_items (
  id uuid primary key default gen_random_uuid(),
  league_id uuid not null references leagues(id) on delete cascade,
  imdb_id text not null references universe_films(imdb_id),
  nominated_by uuid not null references auth.users(id),
  status text not null default 'active' check (status in ('active','sold','unsold','cancelled')),
  current_high_bid numeric,
  current_high_bidder uuid references auth.users(id),
  ends_at timestamptz not null,
  league_pick_id bigint references league_picks(id),
  started_at timestamptz not null default now(),
  resolved_at timestamptz
);
-- Structural guarantee, not just an app-level check: at most one film can
-- be under auction at once per league -- this alone makes "nominate while
-- something else is mid-bid" impossible, no race window to even close.
create unique index draft_items_one_active_per_league on draft_items(league_id) where status = 'active';
create index draft_items_league_status_idx on draft_items(league_id, status);

-- Append-only bid log -- deliberately NOT sealed like acquisition_bids.
-- Everyone sees every bid live; that's the whole point of an open auction.
create table draft_bids (
  id uuid primary key default gen_random_uuid(),
  draft_item_id uuid not null references draft_items(id) on delete cascade,
  league_id uuid not null references leagues(id) on delete cascade,
  user_id uuid not null references auth.users(id),
  amount numeric not null check (amount > 0),
  submitted_at timestamptz not null default now()
);
create index draft_bids_item_idx on draft_bids(draft_item_id, submitted_at desc);

-- league_picks gets a third source value. 'live_draft' picks count against
-- the same main budget pool as 'draft' (only 'acquisition' is excluded) --
-- one pool, matching the existing mental model everywhere else in the app.
alter table league_picks drop constraint if exists league_picks_source_check;
alter table league_picks add constraint league_picks_source_check
  check (source in ('draft','acquisition','live_draft'));

-- RLS: read-only for league members. No insert/update/delete grants at
-- all on any of the three new tables -- every write goes exclusively
-- through the RPCs in migration 044 (tighter than league_picks' admin-
-- write-via-RLS model, matching the acquisition_* precedent).
alter table draft_sessions enable row level security;
alter table draft_items enable row level security;
alter table draft_bids enable row level security;

grant select on draft_sessions to authenticated;
drop policy if exists "draft_sessions_select" on draft_sessions;
create policy "draft_sessions_select" on draft_sessions
  for select to authenticated using (public.is_league_member(league_id, auth.uid()));

grant select on draft_items to authenticated;
drop policy if exists "draft_items_select" on draft_items;
create policy "draft_items_select" on draft_items
  for select to authenticated using (public.is_league_member(league_id, auth.uid()));

grant select on draft_bids to authenticated;
drop policy if exists "draft_bids_select" on draft_bids;
create policy "draft_bids_select" on draft_bids
  for select to authenticated using (public.is_league_member(league_id, auth.uid()));
