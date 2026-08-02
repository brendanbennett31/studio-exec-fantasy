-- Acquisitions feature, step 1 of several: additive columns only, no
-- behavior change. Every column here is nullable or defaulted, so existing
-- rows/pages are completely unaffected until something deliberately reads or
-- writes them (which nothing does yet -- that's migrations 018+).
--
-- leagues.acquisitions_enabled defaults to false and is the opt-in gate for
-- this whole feature -- it stays false on the live in-progress season
-- forever. The plan is to build a "duplicate league" action (migration 018)
-- and only ever flip this on for the duplicate, not the original.

alter table leagues
  add column if not exists acquisitions_enabled boolean not null default false,
  add column if not exists acq_budget_default numeric not null default 50,
  add column if not exists acq_min_bid numeric not null default 20,
  add column if not exists acq_refund_rate numeric not null default 0.25;

alter table league_members
  add column if not exists acq_remainder_credit numeric not null default 0,
  add column if not exists remainder_converted_at timestamptz;

-- 'draft' vs 'acquisition' only matters for the future budget-derivation
-- query (migration 020) -- refund logic itself is uniform regardless of
-- source.
alter table league_picks
  add column if not exists source text not null default 'draft';

alter table league_picks drop constraint if exists league_picks_source_check;
alter table league_picks add constraint league_picks_source_check
  check (source in ('draft', 'acquisition'));

-- Null or past = eligible for acquisition; a future date = still
-- festival-protected. Distinct from the existing per-league
-- `festival_picks` boolean, which only controls whether blind placeholder
-- picks are allowed at all.
alter table universe_films
  add column if not exists festival_protected_until date;

-- Verify: existing rows are unaffected -- spot-check a few.
select id, name, acquisitions_enabled, acq_budget_default, acq_min_bid, acq_refund_rate
from leagues limit 5;

select id, league_id, team_name, acq_remainder_credit, remainder_converted_at
from league_members limit 5;

select id, league_id, team_name, source
from league_picks limit 5;
