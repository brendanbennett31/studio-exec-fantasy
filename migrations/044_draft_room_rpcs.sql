-- Live Draft Room, session 1 step 2: the RPCs. Full design at
-- /Users/brendanbennett/.claude/plans/peaceful-beaming-feather.md
--
-- Every write to draft_sessions/draft_items/draft_bids goes exclusively
-- through these -- no base-table grants exist (migration 043). Every
-- multi-step function opens by locking the league's one draft_sessions
-- row (`for update`); since only one thing can ever be happening in a
-- given league's draft at once (one active item, one current turn), that
-- single lock serializes every draft RPC against each other for that
-- league only -- other leagues' drafts are untouched.
--
-- Every grant below is explicitly paired with `revoke execute ... from
-- anon` in the SAME statement block as `revoke all from public` -- this
-- project has been bitten three times (rename_my_team, then two of the
-- notification RPCs) by forgetting that Supabase grants its own default
-- EXECUTE to anon/authenticated on every new function independent of the
-- PUBLIC pseudo-role, so `revoke all from public` alone does NOT block anon.

-- ── draft_remaining_budget(): derived, not a stored wallet ──────────────────
-- Mirrors acq_remaining_budget() exactly, minus the Acquisitions-specific
-- credit sources: the league's main budget minus everything spent except
-- Acquisitions picks (a live_draft pick counts against the same pool a
-- manual-entry 'draft' pick does -- one pool, matching the app's existing
-- mental model). Internal helper only -- not directly callable by anyone,
-- same as acq_remaining_budget().
create or replace function public.draft_remaining_budget(p_league_id uuid, p_user_id uuid)
returns numeric
language sql
security definer
stable
set search_path = public
as $$
  select
    coalesce((select budget from leagues where id = p_league_id), 0)
    - coalesce((
        select sum(lp.bid)
        from league_picks lp
        join league_members lm on lm.league_id = p_league_id and lm.user_id = p_user_id
        where lp.league_id = p_league_id and lp.team_name = lm.team_name and lp.source <> 'acquisition'
      ), 0);
$$;

revoke all on function public.draft_remaining_budget(uuid, uuid) from public, anon, authenticated;

-- ── choose_draft_mode(): shown once, before anything's been drafted ────────
create or replace function public.choose_draft_mode(p_league_id uuid, p_mode text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_league_admin(p_league_id, auth.uid()) then
    raise exception 'Only a league admin can choose the draft mode';
  end if;
  if p_mode not in ('manual','live') then
    raise exception 'Invalid draft mode';
  end if;
  if exists (select 1 from leagues where id = p_league_id and draft_mode is not null) then
    raise exception 'Draft mode has already been chosen for this league';
  end if;
  if exists (select 1 from league_picks where league_id = p_league_id) then
    raise exception 'Draft mode can only be chosen before any picks exist';
  end if;

  update leagues set draft_mode = p_mode where id = p_league_id;
end;
$$;

revoke all on function public.choose_draft_mode(uuid, text) from public;
revoke execute on function public.choose_draft_mode(uuid, text) from anon;
grant execute on function public.choose_draft_mode(uuid, text) to authenticated;

-- ── configure_draft(): callable repeatedly pre-start ────────────────────────
-- The setup screen just re-POSTs the whole config on every edit (turn
-- order drag-reorder, "Randomize", timer tweaks) -- upsert keyed on the
-- table's own unique(league_id), guarded to only apply while still
-- 'setup' so a stray call after the draft has started can't silently
-- reset the running session.
create or replace function public.configure_draft(
  p_league_id uuid,
  p_turn_order uuid[],
  p_timer_seconds int default 60,
  p_soft_close_seconds int default 10,
  p_nomination_timeout_seconds int default 30
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_session_id uuid;
  v_roster uuid[];
begin
  if not public.is_league_admin(p_league_id, auth.uid()) then
    raise exception 'Only a league admin can configure the draft';
  end if;
  if not exists (select 1 from leagues where id = p_league_id and draft_mode = 'live') then
    raise exception 'This league is not set to live draft mode';
  end if;

  select array_agg(user_id order by user_id) into v_roster from league_members where league_id = p_league_id;
  if (select array_agg(x order by x) from unnest(p_turn_order) x) is distinct from v_roster then
    raise exception 'Turn order must include every current league member exactly once';
  end if;

  if p_timer_seconds not between 10 and 3600 then
    raise exception 'Timer must be between 10 and 3600 seconds';
  end if;
  if p_soft_close_seconds not between 1 and p_timer_seconds then
    raise exception 'Soft-close window must be between 1 second and the timer length';
  end if;
  if p_nomination_timeout_seconds not between 10 and 600 then
    raise exception 'Nomination timeout must be between 10 and 600 seconds';
  end if;

  insert into draft_sessions (league_id, turn_order, timer_seconds, soft_close_seconds, nomination_timeout_seconds, created_by)
  values (p_league_id, p_turn_order, p_timer_seconds, p_soft_close_seconds, p_nomination_timeout_seconds, auth.uid())
  on conflict (league_id) do update set
    turn_order = excluded.turn_order,
    timer_seconds = excluded.timer_seconds,
    soft_close_seconds = excluded.soft_close_seconds,
    nomination_timeout_seconds = excluded.nomination_timeout_seconds,
    updated_at = now()
  where draft_sessions.status = 'setup'
  returning id into v_session_id;

  if v_session_id is null then
    raise exception 'Draft has already started or finished -- cannot reconfigure';
  end if;

  return v_session_id;
end;
$$;

revoke all on function public.configure_draft(uuid, uuid[], int, int, int) from public;
revoke execute on function public.configure_draft(uuid, uuid[], int, int, int) from anon;
grant execute on function public.configure_draft(uuid, uuid[], int, int, int) to authenticated;

-- ── start_draft() ────────────────────────────────────────────────────────────
create or replace function public.start_draft(p_league_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_session draft_sessions%rowtype;
begin
  if not public.is_league_admin(p_league_id, auth.uid()) then
    raise exception 'Only a league admin can start the draft';
  end if;

  select * into v_session from draft_sessions where league_id = p_league_id for update;
  if not found then
    raise exception 'Draft has not been configured yet';
  end if;
  if v_session.status <> 'setup' then
    raise exception 'Draft has already been started';
  end if;
  if array_length(v_session.turn_order, 1) is null or array_length(v_session.turn_order, 1) < 2 then
    raise exception 'Need at least 2 players in the turn order to start';
  end if;

  update draft_sessions
  set status = 'active',
      started_at = now(),
      current_turn_idx = 0,
      nomination_ends_at = now() + (nomination_timeout_seconds || ' seconds')::interval,
      updated_at = now()
  where league_id = p_league_id;
end;
$$;

revoke all on function public.start_draft(uuid) from public;
revoke execute on function public.start_draft(uuid) from anon;
grant execute on function public.start_draft(uuid) to authenticated;

-- ── nominate_film() ──────────────────────────────────────────────────────────
-- The one place this flow enforces season eligibility server-side (unlike
-- manual-entry Add Picks, which only warns client-side with an admin-only
-- Override -- this flow is player-facing, so the real check lives here).
-- Also blocks already-released and festival-protected films, same checks
-- submit_acquisition_bid() already makes.
create or replace function public.nominate_film(p_league_id uuid, p_imdb_id text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_session draft_sessions%rowtype;
  v_league leagues%rowtype;
  v_film universe_films%rowtype;
  v_window record;
  v_current_user uuid;
  v_item_id uuid;
begin
  select * into v_session from draft_sessions where league_id = p_league_id for update;
  if not found or v_session.status <> 'active' then
    raise exception 'Draft is not currently active';
  end if;

  v_current_user := v_session.turn_order[v_session.current_turn_idx + 1]; -- 1-indexed array, 0-indexed counter
  if auth.uid() <> v_current_user then
    raise exception 'It is not your turn to nominate';
  end if;

  select * into v_league from leagues where id = p_league_id;

  select * into v_film from universe_films where imdb_id = p_imdb_id;
  if not found then
    raise exception 'Film not found';
  end if;
  if exists (select 1 from league_picks where league_id = p_league_id and imdb_id = p_imdb_id) then
    raise exception 'This film is already on this league''s slate';
  end if;
  if v_film.release_date is not null and v_film.release_date <= current_date then
    raise exception 'This film has already released';
  end if;
  if v_film.festival_protected_until is not null and v_film.festival_protected_until > current_date then
    raise exception 'This film is still festival-protected';
  end if;

  select * into v_window from public.league_season_window(v_league.season);
  if v_window.window_start is not null and v_film.release_date is not null
     and (v_film.release_date < v_window.window_start or v_film.release_date > v_window.window_end) then
    raise exception 'This film releases outside this league''s season window';
  end if;

  insert into draft_items (league_id, imdb_id, nominated_by, ends_at)
  values (p_league_id, p_imdb_id, auth.uid(), now() + (v_session.timer_seconds || ' seconds')::interval)
  returning id into v_item_id;

  -- No nomination-timer while an item is actively being bid on.
  update draft_sessions set nomination_ends_at = null, updated_at = now() where league_id = p_league_id;

  return v_item_id;
end;
$$;

revoke all on function public.nominate_film(uuid, text) from public;
revoke execute on function public.nominate_film(uuid, text) from anon;
grant execute on function public.nominate_film(uuid, text) to authenticated;

-- ── place_draft_bid() ────────────────────────────────────────────────────────
-- Self-bidding by the nominator is allowed (standard auction-draft
-- convention). No pending-bid-total sum needed the way submit_acquisition_bid
-- needs one -- only one item can ever be live per league at once (the
-- unique partial index in migration 043), so there's nothing else to sum
-- a given user's other pending bids against.
create or replace function public.place_draft_bid(p_league_id uuid, p_draft_item_id uuid, p_amount numeric)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_session draft_sessions%rowtype;
  v_item draft_items%rowtype;
  v_league leagues%rowtype;
  v_remaining numeric;
begin
  if not public.is_league_member(p_league_id, auth.uid()) then
    raise exception 'Not a member of this league';
  end if;

  select * into v_session from draft_sessions where league_id = p_league_id for update;
  if not found or v_session.status <> 'active' then
    raise exception 'Draft is not currently active';
  end if;

  select * into v_item from draft_items where id = p_draft_item_id and league_id = p_league_id;
  if not found or v_item.status <> 'active' then
    raise exception 'This item is not currently up for auction';
  end if;
  if now() >= v_item.ends_at then
    raise exception 'Bidding has closed for this item';
  end if;

  select * into v_league from leagues where id = p_league_id;

  if v_item.current_high_bid is null then
    if p_amount < v_league.min_bid then
      raise exception 'Bid must be at least %', v_league.min_bid;
    end if;
  else
    if p_amount <= v_item.current_high_bid then
      raise exception 'Bid must be higher than the current bid of %', v_item.current_high_bid;
    end if;
  end if;
  if v_league.max_bid is not null and p_amount > v_league.max_bid then
    raise exception 'Bid cannot exceed %', v_league.max_bid;
  end if;

  v_remaining := public.draft_remaining_budget(p_league_id, auth.uid());
  if p_amount > v_remaining then
    raise exception 'This bid would exceed your remaining budget (% available)', v_remaining;
  end if;

  insert into draft_bids (draft_item_id, league_id, user_id, amount)
  values (p_draft_item_id, p_league_id, auth.uid(), p_amount);

  -- Soft-close anti-snipe: a bid inside the last soft_close_seconds resets
  -- the clock to soft_close_seconds remaining, propagated to every
  -- watching client purely by this UPDATE landing via Realtime -- no
  -- separate "timer reset" message type needed.
  update draft_items
  set current_high_bid = p_amount,
      current_high_bidder = auth.uid(),
      ends_at = case
        when ends_at - now() < (v_session.soft_close_seconds || ' seconds')::interval
        then now() + (v_session.soft_close_seconds || ' seconds')::interval
        else ends_at
      end
  where id = p_draft_item_id;
end;
$$;

revoke all on function public.place_draft_bid(uuid, uuid, numeric) from public;
revoke execute on function public.place_draft_bid(uuid, uuid, numeric) from anon;
grant execute on function public.place_draft_bid(uuid, uuid, numeric) to authenticated;

-- ── resolve_draft_item() ─────────────────────────────────────────────────────
-- Callable by ANY league member, not admin-gated -- whichever connected
-- client's local countdown hits zero first calls this immediately (see
-- the plan doc's Realtime section). now() < ends_at just means a fast
-- client's clock jumped the gun; it raises harmlessly and the client
-- retries next tick. Idempotent: if the item isn't 'active' anymore
-- (already resolved by a racing caller), this is a silent no-op.
create or replace function public.resolve_draft_item(p_league_id uuid, p_draft_item_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_session draft_sessions%rowtype;
  v_item draft_items%rowtype;
  v_team_name text;
  v_final_remaining numeric;
  v_pick_id bigint;
  v_next_idx int;
begin
  if not public.is_league_member(p_league_id, auth.uid()) then
    raise exception 'Not a member of this league';
  end if;

  select * into v_session from draft_sessions where league_id = p_league_id for update;
  if not found or v_session.status <> 'active' then
    return;
  end if;

  select * into v_item from draft_items where id = p_draft_item_id and league_id = p_league_id for update;
  if not found or v_item.status <> 'active' then
    return;
  end if;
  if now() < v_item.ends_at then
    raise exception 'This item''s timer has not expired yet';
  end if;

  if v_item.current_high_bidder is not null then
    select team_name into v_team_name from league_members
    where league_id = p_league_id and user_id = v_item.current_high_bidder;

    -- Defensive re-check, mirrors resolve_acquisitions_week()'s invariant assert.
    v_final_remaining := public.draft_remaining_budget(p_league_id, v_item.current_high_bidder);
    if v_final_remaining < v_item.current_high_bid then
      raise exception 'Budget invariant violated for user % in league % (remaining % < bid %) -- refusing to resolve this item',
        v_item.current_high_bidder, p_league_id, v_final_remaining, v_item.current_high_bid;
    end if;

    insert into league_picks (league_id, imdb_id, team_name, bid, source)
    values (p_league_id, v_item.imdb_id, v_team_name, v_item.current_high_bid, 'live_draft')
    returning id into v_pick_id;

    update draft_items set status = 'sold', resolved_at = now(), league_pick_id = v_pick_id where id = p_draft_item_id;
  else
    -- No bids -- the film goes back in the pool, nominable again in a
    -- later turn. Deliberately NOT auto-awarded to the nominator at
    -- min_bid, which would let a player risk-free "gift" themselves
    -- obscure titles and undermine the open-auction premise.
    update draft_items set status = 'unsold', resolved_at = now() where id = p_draft_item_id;
  end if;

  v_next_idx := (v_session.current_turn_idx + 1) % array_length(v_session.turn_order, 1);
  update draft_sessions
  set current_turn_idx = v_next_idx,
      nomination_ends_at = now() + (nomination_timeout_seconds || ' seconds')::interval,
      updated_at = now()
  where league_id = p_league_id;
end;
$$;

revoke all on function public.resolve_draft_item(uuid, uuid) from public;
revoke execute on function public.resolve_draft_item(uuid, uuid) from anon;
grant execute on function public.resolve_draft_item(uuid, uuid) to authenticated;

-- ── pass_turn() ──────────────────────────────────────────────────────────────
-- Three legal callers: the current-turn player themselves (voluntary
-- pass), a league admin (manual skip, anytime), or ANY league member once
-- the nomination timeout has genuinely expired (auto-pass-on-timeout,
-- same "any client can trigger it" pattern as resolve_draft_item).
create or replace function public.pass_turn(p_league_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_session draft_sessions%rowtype;
  v_current_user uuid;
  v_next_idx int;
begin
  if not public.is_league_member(p_league_id, auth.uid()) then
    raise exception 'Not a member of this league';
  end if;

  select * into v_session from draft_sessions where league_id = p_league_id for update;
  if not found or v_session.status <> 'active' then
    raise exception 'Draft is not currently active';
  end if;
  if exists (select 1 from draft_items where league_id = p_league_id and status = 'active') then
    raise exception 'Cannot pass while a film is being auctioned';
  end if;

  v_current_user := v_session.turn_order[v_session.current_turn_idx + 1];

  if auth.uid() <> v_current_user
     and not public.is_league_admin(p_league_id, auth.uid())
     and not (v_session.nomination_ends_at is not null and now() >= v_session.nomination_ends_at)
  then
    raise exception 'Only the current player, a league admin, or an expired nomination timeout can pass this turn';
  end if;

  v_next_idx := (v_session.current_turn_idx + 1) % array_length(v_session.turn_order, 1);
  update draft_sessions
  set current_turn_idx = v_next_idx,
      nomination_ends_at = now() + (nomination_timeout_seconds || ' seconds')::interval,
      updated_at = now()
  where league_id = p_league_id;
end;
$$;

revoke all on function public.pass_turn(uuid) from public;
revoke execute on function public.pass_turn(uuid) from anon;
grant execute on function public.pass_turn(uuid) to authenticated;

-- ── admin_cancel_draft_item(): mis-nomination correction ────────────────────
-- Not in the original ask, but cheap and clearly needed. Turn does NOT
-- advance -- the nominator can immediately re-nominate, or the admin can
-- pass_turn() them.
create or replace function public.admin_cancel_draft_item(p_league_id uuid, p_draft_item_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_league_admin(p_league_id, auth.uid()) then
    raise exception 'Only a league admin can cancel a nomination';
  end if;

  update draft_items
  set status = 'cancelled', resolved_at = now()
  where id = p_draft_item_id and league_id = p_league_id and status = 'active';

  if not found then
    raise exception 'Item not found or not currently active';
  end if;
end;
$$;

revoke all on function public.admin_cancel_draft_item(uuid, uuid) from public;
revoke execute on function public.admin_cancel_draft_item(uuid, uuid) from anon;
grant execute on function public.admin_cancel_draft_item(uuid, uuid) to authenticated;

-- ── admin_end_draft() ────────────────────────────────────────────────────────
-- Reuses leagues.draft_status (the existing field ManageTab's Draft
-- Control card already toggles for manual-entry leagues) rather than
-- introducing a second "is the draft done" concept -- the rest of the app
-- then treats a finished live draft identically to a manually-locked one.
create or replace function public.admin_end_draft(p_league_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_league_admin(p_league_id, auth.uid()) then
    raise exception 'Only a league admin can end the draft';
  end if;
  if exists (select 1 from draft_items where league_id = p_league_id and status = 'active') then
    raise exception 'Resolve or cancel the current item before ending the draft';
  end if;

  update draft_sessions set status = 'completed', completed_at = now(), updated_at = now() where league_id = p_league_id;
  update leagues set draft_status = 'locked' where id = p_league_id;
end;
$$;

revoke all on function public.admin_end_draft(uuid) from public;
revoke execute on function public.admin_end_draft(uuid) from anon;
grant execute on function public.admin_end_draft(uuid) to authenticated;

-- ── league_draft_budgets(): read-only, per-team breakdown ──────────────────
-- Same shape/openness as league_acquisitions_budgets() (migration 024) --
-- open to any league member, for the Draft Room's budget strip.
create or replace function public.league_draft_budgets(p_league_id uuid)
returns table(team_name text, user_id uuid, budget numeric, spent numeric, remaining numeric)
language sql
security definer
stable
set search_path = public
as $$
  select
    lm.team_name,
    lm.user_id,
    coalesce(l.budget, 0) as budget,
    coalesce((
      select sum(lp.bid) from league_picks lp
      where lp.league_id = p_league_id and lp.team_name = lm.team_name and lp.source <> 'acquisition'
    ), 0) as spent,
    coalesce(l.budget, 0) - coalesce((
      select sum(lp.bid) from league_picks lp
      where lp.league_id = p_league_id and lp.team_name = lm.team_name and lp.source <> 'acquisition'
    ), 0) as remaining
  from league_members lm
  join leagues l on l.id = p_league_id
  where lm.league_id = p_league_id
    and public.is_league_member(p_league_id, auth.uid());
$$;

revoke all on function public.league_draft_budgets(uuid) from public;
revoke execute on function public.league_draft_budgets(uuid) from anon;
grant execute on function public.league_draft_budgets(uuid) to authenticated;

-- ── Verification (run by hand in the SQL Editor after applying) ────────────
-- 1. Pick (or create) a league with draft_mode still null and zero
--    league_picks. As that league's admin: select choose_draft_mode(<id>, 'live');
-- 2. select configure_draft(<id>, array[<user_id_1>,<user_id_2>,...]::uuid[], 30, 10, 15);
--    -- confirm it fails if the array doesn't exactly match current league_members.
-- 3. select start_draft(<id>); then select * from draft_sessions where league_id=<id>;
--    -- confirm status='active', current_turn_idx=0, nomination_ends_at set.
-- 4. As turn_order[1] (use set_config('request.jwt.claim.sub', ...) to
--    simulate, same technique used for Acquisitions testing):
--    select nominate_film(<id>, '<a real imdb_id in this league's season window>');
--    -- confirm rejected if attempted as a different user (out-of-turn),
--    -- confirm rejected for a film outside the season window.
-- 5. As two different simulated users, place_draft_bid() with increasing
--    amounts; place one bid inside the soft_close_seconds window and
--    confirm draft_items.ends_at moved forward.
-- 6. Manually backdate a draft_items.ends_at into the past (or wait it
--    out), then call resolve_draft_item() from two overlapping sessions
--    to confirm only one actually inserts into league_picks and the other
--    no-ops cleanly.
-- 7. Confirm an over-budget bid is rejected before insertion, and that an
--    unsold item (nobody bid) does NOT create a league_picks row and
--    leaves the film nominable again.
