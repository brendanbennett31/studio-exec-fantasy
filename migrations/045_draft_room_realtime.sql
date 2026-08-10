-- Live Draft Room, session 2 step 1: turn on Postgres Changes for the three
-- draft tables. RLS still applies -- a client only receives change events
-- for rows it could already SELECT (is_league_member(league_id, auth.uid())),
-- same as any other read in this app. This does not touch how writes work;
-- the RPCs from migration 044 are still the only write path.
alter publication supabase_realtime add table draft_sessions, draft_items, draft_bids;
