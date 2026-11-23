-- HOTFIX for 066. The league_members guard decided "is this the server?" with auth.uid() is null.
-- But server functions called BY a signed-in user (admin_end_draft -> leagues.draft_status =
-- 'locked' -> trg_convert_draft_remainder -> convert_draft_remainder) still carry that user's
-- auth.uid(), so ending a draft failed with "Budget credits are set by the server only".
--
-- Correct test: who is executing the UPDATE. A browser's direct PostgREST update runs as the
-- role 'authenticated' (or 'anon'); a SECURITY DEFINER function runs as its owner. So the guard
-- now restricts only direct API updates. The trigger function itself must NOT be security
-- definer, or current_user would always be its owner. Found by the full-season simulation.
create or replace function public.trg_league_members_guard()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if current_user not in ('authenticated', 'anon') then
    return new;  -- server-side: service role, or a SECURITY DEFINER function doing its own checks
  end if;
  if new.league_id is distinct from old.league_id or new.user_id is distinct from old.user_id then
    raise exception 'A membership cannot be moved to another league or user';
  end if;
  if new.role is distinct from old.role and not public.is_league_admin(old.league_id, auth.uid()) then
    raise exception 'Only a league admin can change roles';
  end if;
  if new.acq_remainder_credit is distinct from old.acq_remainder_credit
     or new.remainder_converted_at is distinct from old.remainder_converted_at then
    raise exception 'Budget credits are set by the server only';
  end if;
  return new;
end;
$$;
