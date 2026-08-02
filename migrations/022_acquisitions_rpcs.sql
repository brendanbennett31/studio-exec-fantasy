-- Acquisitions feature, session 2 step 2: the bidding-engine RPCs. This is
-- the highest-stakes correctness surface of the whole feature -- hand-test
-- every one of these via direct `select fn(...)` calls in the SQL Editor
-- with crafted tie/over-cap/conflict scenarios before wiring up Apps Script
-- or league.html. See the verification queries at the bottom.
--
-- No base-table INSERT/UPDATE/DELETE grant to authenticated on any of the
-- four tables from migration 021 -- every write goes exclusively through
-- these RPCs (tighter than league_picks' admin-write-via-RLS model, closer
-- to the rename_my_team()/duplicate_league() precedent).

-- ── acq_remaining_budget(): shared derivation, not a stored wallet ─────────
-- "Remaining Acquisitions budget" is always computed fresh from source
-- tables, the same way this app already derives draft-budget-remaining
-- client-side -- there is no incrementing/decrementing counter anywhere to
-- drift. Used by both submit_acquisition_bid() and resolve_acquisitions_week()
-- so the exact same formula backs both the submission-time check and the
-- resolution-time defensive re-check.
create or replace function public.acq_remaining_budget(p_league_id uuid, p_user_id uuid)
returns numeric
language sql
security definer
stable
set search_path = public
as $$
  select
    coalesce((select acq_budget_default from leagues where id = p_league_id), 0)
    + coalesce((select acq_remainder_credit from league_members where league_id = p_league_id and user_id = p_user_id), 0)
    + coalesce((select sum(credit_amount) from refunds where league_id = p_league_id and user_id = p_user_id), 0)
    - coalesce((
        select sum(lp.bid)
        from league_picks lp
        join league_members lm on lm.league_id = p_league_id and lm.user_id = p_user_id
        where lp.league_id = p_league_id and lp.team_name = lm.team_name and lp.source = 'acquisition'
      ), 0);
$$;

revoke all on function public.acq_remaining_budget(uuid, uuid) from public, anon, authenticated;

-- ── ensure_acquisition_week(): self-computing, idempotent ──────────────────
-- Finds the Friday that starts the current weekly cycle (in
-- America/Los_Angeles, so DST transitions are handled correctly by Postgres
-- rather than fixed-offset arithmetic), and makes sure a row exists for it.
-- declare_deadline = the instant Wednesday starts (cutoff for "before
-- Tuesday midnight"); bid_deadline = the instant Thursday starts (cutoff
-- for "before Wednesday midnight"). week_start's unique constraint makes
-- repeated calls a no-op.
create or replace function public.ensure_acquisition_week()
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_now_la timestamp;
  v_dow int;
  v_week_start date;
  v_declare_deadline timestamptz;
  v_bid_deadline timestamptz;
  v_week_id uuid;
begin
  v_now_la := now() at time zone 'America/Los_Angeles';
  v_dow := extract(dow from v_now_la)::int; -- 0=Sunday .. 6=Saturday
  v_week_start := v_now_la::date - ((v_dow - 5 + 7) % 7); -- most recent Friday
  v_declare_deadline := ((v_week_start + 5)::timestamp) at time zone 'America/Los_Angeles'; -- Wed 00:00
  v_bid_deadline := ((v_week_start + 6)::timestamp) at time zone 'America/Los_Angeles'; -- Thu 00:00

  insert into acquisition_weeks (week_start, declare_deadline, bid_deadline)
  values (v_week_start, v_declare_deadline, v_bid_deadline)
  on conflict (week_start) do nothing
  returning id into v_week_id;

  if v_week_id is null then
    select id into v_week_id from acquisition_weeks where week_start = v_week_start;
  end if;

  return v_week_id;
end;
$$;

revoke all on function public.ensure_acquisition_week() from public, anon, authenticated;
grant execute on function public.ensure_acquisition_week() to service_role;

-- ── declare_for_acquisitions() ──────────────────────────────────────────────
create or replace function public.declare_for_acquisitions(p_league_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_week_id uuid;
  v_deadline timestamptz;
begin
  if not public.is_league_member(p_league_id, auth.uid()) then
    raise exception 'Not a member of this league';
  end if;
  if not exists (select 1 from leagues where id = p_league_id and acquisitions_enabled) then
    raise exception 'Acquisitions is not enabled for this league';
  end if;

  select id, declare_deadline into v_week_id, v_deadline
  from acquisition_weeks order by week_start desc limit 1;

  if v_week_id is null then
    v_week_id := public.ensure_acquisition_week();
    select declare_deadline into v_deadline from acquisition_weeks where id = v_week_id;
  end if;

  if now() >= v_deadline then
    raise exception 'Declaration window has closed for this week';
  end if;

  insert into acquisition_declarations (week_id, league_id, user_id)
  values (v_week_id, p_league_id, auth.uid())
  on conflict (week_id, league_id, user_id) do nothing;
end;
$$;

revoke all on function public.declare_for_acquisitions(uuid) from public;
grant execute on function public.declare_for_acquisitions(uuid) to authenticated;

-- ── submit_acquisition_bid() ─────────────────────────────────────────────────
create or replace function public.submit_acquisition_bid(p_league_id uuid, p_imdb_id text, p_amount numeric)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_member league_members%rowtype;
  v_week acquisition_weeks%rowtype;
  v_film universe_films%rowtype;
  v_league leagues%rowtype;
  v_pending_total numeric;
  v_remaining numeric;
  v_bid_id uuid;
begin
  -- Lock the caller's own league_members row so two concurrent submissions
  -- from the same user (e.g. two browser tabs) serialize instead of racing
  -- on the budget check below.
  select * into v_member from league_members
  where league_id = p_league_id and user_id = auth.uid()
  for update;
  if not found then
    raise exception 'Not a member of this league';
  end if;

  select * into v_league from leagues where id = p_league_id;
  if not found or not v_league.acquisitions_enabled then
    raise exception 'Acquisitions is not enabled for this league';
  end if;

  select * into v_week from acquisition_weeks order by week_start desc limit 1;
  if not found or now() < v_week.declare_deadline or now() >= v_week.bid_deadline then
    raise exception 'Bidding window is not currently open';
  end if;

  if not exists (
    select 1 from acquisition_declarations
    where week_id = v_week.id and league_id = p_league_id and user_id = auth.uid()
  ) then
    raise exception 'You must declare before you can bid this week';
  end if;

  if p_amount < v_league.acq_min_bid then
    raise exception 'Bid must be at least %', v_league.acq_min_bid;
  end if;

  select * into v_film from universe_films where imdb_id = p_imdb_id;
  if not found then
    raise exception 'Film not found';
  end if;
  if v_film.release_date is not null and v_film.release_date <= current_date then
    raise exception 'This film has already released';
  end if;
  if v_film.festival_protected_until is not null and v_film.festival_protected_until > current_date then
    raise exception 'This film is still festival-protected';
  end if;
  if exists (select 1 from league_picks where league_id = p_league_id and imdb_id = p_imdb_id) then
    raise exception 'This film is already on this league''s slate';
  end if;

  select coalesce(sum(amount), 0) into v_pending_total
  from acquisition_bids
  where week_id = v_week.id and league_id = p_league_id and user_id = auth.uid() and status = 'pending'
    and imdb_id <> p_imdb_id; -- exclude any existing bid on this same film, which this call replaces

  v_remaining := public.acq_remaining_budget(p_league_id, auth.uid());

  if v_pending_total + p_amount > v_remaining then
    raise exception 'This bid would exceed your remaining Acquisitions budget (% available, % already pending on other films)', v_remaining, v_pending_total;
  end if;

  insert into acquisition_bids (week_id, league_id, user_id, imdb_id, amount)
  values (v_week.id, p_league_id, auth.uid(), p_imdb_id, p_amount)
  on conflict (week_id, league_id, user_id, imdb_id)
    do update set amount = excluded.amount, submitted_at = now(), status = 'pending'
  returning id into v_bid_id;

  return v_bid_id;
end;
$$;

revoke all on function public.submit_acquisition_bid(uuid, text, numeric) from public;
grant execute on function public.submit_acquisition_bid(uuid, text, numeric) to authenticated;

-- ── withdraw_acquisition_bid() ───────────────────────────────────────────────
-- Not in the original rules but needed for the planned UI's "Withdraw"
-- button -- without it there'd be no way to back out of a pending bid
-- before the deadline.
create or replace function public.withdraw_acquisition_bid(p_bid_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from acquisition_bids
  where id = p_bid_id and user_id = auth.uid() and status = 'pending';
  if not found then
    raise exception 'Bid not found, not yours, or already resolved';
  end if;
end;
$$;

revoke all on function public.withdraw_acquisition_bid(uuid) from public;
grant execute on function public.withdraw_acquisition_bid(uuid) to authenticated;

-- ── refund_my_film() ─────────────────────────────────────────────────────────
create or replace function public.refund_my_film(p_league_id uuid, p_league_pick_id uuid)
returns numeric
language plpgsql
security definer
set search_path = public
as $$
declare
  v_member league_members%rowtype;
  v_pick league_picks%rowtype;
  v_league leagues%rowtype;
  v_film universe_films%rowtype;
  v_week acquisition_weeks%rowtype;
  v_credit numeric;
begin
  select * into v_member from league_members
  where league_id = p_league_id and user_id = auth.uid()
  for update;
  if not found then
    raise exception 'Not a member of this league';
  end if;

  select * into v_league from leagues where id = p_league_id;
  if not found or not v_league.acquisitions_enabled then
    raise exception 'Acquisitions is not enabled for this league';
  end if;

  select * into v_pick from league_picks where id = p_league_pick_id and league_id = p_league_id;
  if not found then
    raise exception 'Pick not found in this league';
  end if;
  if v_pick.team_name <> v_member.team_name then
    raise exception 'You can only refund your own picks';
  end if;
  -- A still-blind Festival Futures placeholder (imdb_id is null) hasn't
  -- resolved to a real film yet and can't be refunded -- see universe.html/
  -- ManageTab's "Resolve" action, which is what turns imdb_id from null to
  -- a real value once the placeholder lands.
  if v_pick.imdb_id is null then
    raise exception 'A blind Festival Futures pick cannot be refunded until it resolves to a real film';
  end if;

  select * into v_film from universe_films where imdb_id = v_pick.imdb_id;
  if found and v_film.release_date is not null and v_film.release_date < current_date + 14 then
    raise exception 'Films must be refunded at least 14 days before release';
  end if;

  -- Block refunds on Wednesday if declared for this week's bidding --
  -- prevents juicing your Acquisitions budget mid-window.
  select * into v_week from acquisition_weeks order by week_start desc limit 1;
  if found
     and extract(dow from (now() at time zone 'America/Los_Angeles')) = 3 -- Wednesday
     and exists (
       select 1 from acquisition_declarations
       where week_id = v_week.id and league_id = p_league_id and user_id = auth.uid()
     )
  then
    raise exception 'Cannot refund on Wednesday while declared for this week''s bidding';
  end if;

  v_credit := round(v_pick.bid * v_league.acq_refund_rate, 2);

  insert into refunds (league_id, user_id, team_name, imdb_id, film_title, original_bid, refund_rate_applied, credit_amount)
  values (p_league_id, auth.uid(), v_pick.team_name, v_pick.imdb_id, coalesce(v_film.title, v_pick.title), v_pick.bid, v_league.acq_refund_rate, v_credit);

  delete from league_picks where id = p_league_pick_id;

  return v_credit;
end;
$$;

revoke all on function public.refund_my_film(uuid, uuid) from public;
grant execute on function public.refund_my_film(uuid, uuid) to authenticated;

-- ── resolve_acquisitions_week() ──────────────────────────────────────────────
create or replace function public.resolve_acquisitions_week(p_week_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_week acquisition_weeks%rowtype;
  r record;
  v_final_remaining numeric;
begin
  select * into v_week from acquisition_weeks where id = p_week_id for update;
  if not found then
    raise exception 'Week not found';
  end if;
  if v_week.resolved_at is not null then
    return; -- already resolved -- idempotent no-op
  end if;
  if now() < v_week.bid_deadline then
    raise exception 'Bidding window has not closed yet';
  end if;

  -- Flag declared-but-never-bid violations (surfaced in the UI later, not
  -- auto-penalized, per the stated rules).
  update acquisition_declarations d
  set violated = true
  where d.week_id = p_week_id
    and not exists (
      select 1 from acquisition_bids b
      where b.week_id = d.week_id and b.league_id = d.league_id and b.user_id = d.user_id
    );

  -- Defensive re-check: a film's eligibility could have shifted since
  -- submission (drafted elsewhere, released, or (re-)festival-protected).
  update acquisition_bids b
  set status = 'invalid', resolved_at = now()
  where b.week_id = p_week_id
    and b.status = 'pending'
    and (
      exists (select 1 from league_picks lp where lp.league_id = b.league_id and lp.imdb_id = b.imdb_id)
      or exists (
        select 1 from universe_films f
        where f.imdb_id = b.imdb_id
          and (
            (f.release_date is not null and f.release_date <= current_date)
            or (f.festival_protected_until is not null and f.festival_protected_until > current_date)
          )
      )
    );

  -- Highest bid wins each (league, film); earliest submission breaks ties.
  for r in
    select b.*, row_number() over (
      partition by b.league_id, b.imdb_id
      order by b.amount desc, b.submitted_at asc
    ) as rnk
    from acquisition_bids b
    where b.week_id = p_week_id and b.status = 'pending'
    order by b.league_id, b.user_id, b.submitted_at
  loop
    if r.rnk = 1 then
      -- Defensive assert: should be unreachable given submission-time
      -- locking, but verify rather than silently trust, since this moves
      -- real slate-affecting data.
      v_final_remaining := public.acq_remaining_budget(r.league_id, r.user_id);
      if v_final_remaining < r.amount then
        raise exception 'Budget invariant violated for user % in league % (remaining % < bid %) -- refusing to resolve this week', r.user_id, r.league_id, v_final_remaining, r.amount;
      end if;

      insert into league_picks (league_id, imdb_id, team_name, bid, source)
      select r.league_id, r.imdb_id, lm.team_name, r.amount, 'acquisition'
      from league_members lm
      where lm.league_id = r.league_id and lm.user_id = r.user_id;

      update acquisition_bids set status = 'won', resolved_at = now() where id = r.id;
    else
      update acquisition_bids set status = 'lost', resolved_at = now() where id = r.id;
    end if;
  end loop;

  update acquisition_weeks set resolved_at = now() where id = p_week_id;
end;
$$;

revoke all on function public.resolve_acquisitions_week(uuid) from public, anon, authenticated;
grant execute on function public.resolve_acquisitions_week(uuid) to service_role;

-- ── RLS: reads only, all writes go through the RPCs above ──────────────────
grant select on acquisition_weeks to authenticated;
drop policy if exists "acq_weeks_select" on acquisition_weeks;
create policy "acq_weeks_select" on acquisition_weeks
  for select to authenticated using (true);

grant select on acquisition_declarations to authenticated;
drop policy if exists "acq_declarations_select" on acquisition_declarations;
create policy "acq_declarations_select" on acquisition_declarations
  for select to authenticated
  using (public.is_league_member(league_id, auth.uid()));

-- Sealed bidding: your own pending bids and anyone's *resolved* bids are
-- visible; other people's still-pending bids are not.
grant select on acquisition_bids to authenticated;
drop policy if exists "acq_bids_select" on acquisition_bids;
create policy "acq_bids_select" on acquisition_bids
  for select to authenticated
  using (user_id = auth.uid() or public.is_league_admin(league_id, auth.uid()) or status <> 'pending');

grant select on refunds to authenticated;
drop policy if exists "refunds_select" on refunds;
create policy "refunds_select" on refunds
  for select to authenticated
  using (public.is_league_member(league_id, auth.uid()));

-- ── Verification (run these by hand after applying, replace uuids/dates) ───
-- 1. select public.ensure_acquisition_week(); -- should insert or return this week's id
-- 2. select * from acquisition_weeks order by week_start desc limit 1;
-- 3. As a real logged-in user (via the app, not the SQL Editor's superuser
--    role): select declare_for_acquisitions('<a league id with acquisitions_enabled=true>');
-- 4. Hand-craft a tie: insert two acquisition_bids rows for the same
--    week_id/league_id/imdb_id with equal amount but different submitted_at,
--    then call resolve_acquisitions_week(<week_id>) and confirm the earlier
--    submitted_at wins.
-- 5. Hand-craft an over-cap bid (amount summing above a member's
--    acq_remaining_budget) via submit_acquisition_bid and confirm it's
--    rejected before insertion.
