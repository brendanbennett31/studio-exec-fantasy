-- One-off data repair for the live sef-2026 league: league_picks.team_name
-- still held the pre-multi-league team codes (BRANDON/RAFA/KAI) for three
-- players, while league_members.team_name (where a real rename or a saved
-- color actually lands) has their real current names (Brandon/Rafael/
-- sampadiankai). Every roster-building lookup in league.html joins on
-- team_name between these two tables (league_picks has no user_id column
-- to join on instead -- see migration 012's design notes), so the mismatch
-- silently broke both saved colors and real player names for these three,
-- falling back to auto-assigned colors and the raw old code as a name.
--
-- This is exactly what rename_my_team() already does automatically when a
-- player renames through the app -- applied once here for the drift that
-- predates that cascade. Also fixes the same join for Acquisitions'
-- budget RPCs (acq_remaining_budget, league_acquisitions_budgets) ahead of
-- whenever Acquisitions gets turned on for this league.
--
-- Patrick intentionally left untouched -- no real league_members row for
-- him exists yet (see migration notes from this session). Run the
-- equivalent update for PATRICK -> his real team name once he actually
-- creates an account and joins.
update league_picks set team_name = 'Brandon'
where league_id = 'c388b799-6240-46c4-ba75-da8a0d2e8db5' and team_name = 'BRANDON';

update league_picks set team_name = 'Rafael'
where league_id = 'c388b799-6240-46c4-ba75-da8a0d2e8db5' and team_name = 'RAFA';

update league_picks set team_name = 'sampadiankai'
where league_id = 'c388b799-6240-46c4-ba75-da8a0d2e8db5' and team_name = 'KAI';
