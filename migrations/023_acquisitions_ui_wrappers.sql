-- Acquisitions feature, UI session: two small wrapper RPCs the backend
-- sessions didn't need but the UI does.
--
-- resolve_acquisitions_week()/ensure_acquisition_week() are deliberately
-- service_role-only (migration 022) so no player can trigger early
-- resolution via a crafted REST call. But the plan's admin UI wants a
-- manual "Resolve Now" button for troubleshooting (e.g. if the Apps Script
-- sweep fails one week) -- admin_resolve_acquisitions_week() preserves the
-- security property (still nobody but a league admin can call it) while
-- giving a legitimate manual override. Note: resolving affects the whole
-- shared week, not just the calling admin's league, since acquisition_weeks
-- isn't per-league -- resolve_acquisitions_week() already only acts on
-- leagues that actually have bids that week, so this is safe, just worth
-- knowing (surfaced in the UI's button tooltip).
create or replace function public.admin_resolve_acquisitions_week(p_league_id uuid, p_week_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_league_admin(p_league_id, auth.uid()) then
    raise exception 'Only a league admin can do this';
  end if;
  perform public.resolve_acquisitions_week(p_week_id);
end;
$$;

revoke all on function public.admin_resolve_acquisitions_week(uuid, uuid) from public;
grant execute on function public.admin_resolve_acquisitions_week(uuid, uuid) to authenticated;

-- acq_remaining_budget() is an internal-only helper (migration 022,
-- revoked from everyone) so the submission-time check and the UI's
-- displayed number can never drift apart -- this just lets the calling
-- user read their own value through the same single source of truth,
-- rather than the UI re-deriving the formula itself in JS.
create or replace function public.my_acq_remaining_budget(p_league_id uuid)
returns numeric
language sql
security definer
stable
set search_path = public
as $$
  select public.acq_remaining_budget(p_league_id, auth.uid());
$$;

revoke all on function public.my_acq_remaining_budget(uuid) from public;
grant execute on function public.my_acq_remaining_budget(uuid) to authenticated;
