-- Lets a player delete their own notifications (individually, or all at
-- once via a bulk DELETE) directly through PostgREST, same self-scoped
-- pattern already used for its select/update policies -- no RPC needed
-- since "delete rows you own" doesn't need any extra business logic.
grant delete on notifications to authenticated;

drop policy if exists "notifications_own_delete" on notifications;
create policy "notifications_own_delete" on notifications
  for delete to authenticated using (user_id = auth.uid());
