-- Sacko punishment: a free-text field admins fill in describing what
-- happens to whoever finishes last (the "Sacko"). Shown in the Rules tab.
-- Run this once in the Supabase dashboard: SQL Editor -> New query -> paste -> Run.
-- Safe to run multiple times (IF NOT EXISTS).

alter table leagues
  add column if not exists sacko_punishment text;
