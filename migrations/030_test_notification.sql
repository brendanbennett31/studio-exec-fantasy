-- One-off test notification, not a schema change -- inserts a single row
-- for every member of the live sef-2026 league so everyone's bell (and the
-- new dashboard badge) can be verified end-to-end. Safe to run more than
-- once; each run just adds another test row, no unique constraint to
-- violate. Delete afterward with the cleanup query at the bottom once
-- everyone's confirmed it shows up.
insert into notifications (user_id, league_id, type, title, body, link)
select user_id, league_id, 'new_film',
  'Notifications test',
  'This is a test notification to confirm the bell icon (and dashboard badge) are working. Safe to delete.',
  '/league?id=' || league_id
from league_members
where league_id = 'c388b799-6240-46c4-ba75-da8a0d2e8db5';

-- Cleanup: now that the bell has its own "Clear all" button, this row can
-- just be deleted from the UI instead of run as a query -- kept here only
-- as a fallback.
-- delete from notifications where title = 'Notifications test';
