-- Fixes 002/003's column REVOKE, which had no effect: `anon` already had a
-- table-wide SELECT grant on leagues (Supabase's default setup), and
-- column-level REVOKE doesn't override a pre-existing table-wide grant —
-- only a table-wide REVOKE followed by column-scoped re-grants does.
-- Confirmed via curl: invite_code/created_by were still coming back to anon
-- after the earlier migrations.

revoke select on public.leagues from anon;

grant select (
  id, name, season, budget, draft_status, created_at, num_players, min_bid,
  max_bid, oscar_nom_bonus, oscar_win_bonus, bp_bonus, festival_picks,
  draft_open_date, draft_close_date, season_end_date, description,
  is_public, share_token
) on public.leagues to anon;

-- Note: created_by and invite_code are intentionally omitted from this list.
-- authenticated is untouched -- members/creators still see everything via
-- leagues_select_public_or_own.
