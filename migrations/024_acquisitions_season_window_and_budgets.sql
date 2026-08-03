-- Acquisitions feature, testing-feedback round 1: two fixes found during
-- the first real logged-in test.
--
-- 1. Acquisitions bids were only checked against "not already drafted /
--    not yet released / not festival-protected" -- nothing stopped a
--    league from acquiring a film that belongs to a DIFFERENT season's
--    window entirely (e.g. a 2026-season league bidding on a film that
--    only makes sense for the 2027 season). Films must now fall within
--    the calling league's own Oscar-to-Oscar season window.
-- 2. There was no way for the client to show real per-team Acquisitions
--    budget in Standings -- only the old hardcoded REMAINDERS constant
--    (see league.html), which was never a real per-league feature, just a
--    hand-written fact about the original sef-2026 league specifically.

-- ── league_season_window() ──────────────────────────────────────────────────
-- Mirrors league.html's ELIGIBILITY_START/END and
-- UniverseFilmsScraper.gs's UF_SEASON_WINDOWS -- same duplication-over-
-- shared-module approach already used throughout this codebase (every
-- .html file is self-contained; normTitle() alone is already triplicated).
-- Add a row here (and to the other two copies) once the 2028 window's
-- exact boundaries are confirmed, the same way 2027's was added.
create or replace function public.league_season_window(p_season text)
returns table(window_start date, window_end date)
language sql
immutable
set search_path = public
as $$
  select
    case p_season when '2026' then '2026-03-16'::date when '2027' then '2027-03-15'::date else null end,
    case p_season when '2026' then '2027-03-14'::date when '2027' then '2028-03-05'::date else null end;
$$;

revoke all on function public.league_season_window(text) from public;
grant execute on function public.league_season_window(text) to authenticated;

-- ── submit_acquisition_bid(): add season-window check ───────────────────────
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
  v_window record;
  v_pending_total numeric;
  v_remaining numeric;
  v_bid_id uuid;
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

  -- New: must have a known release date within THIS league's own season
  -- window -- a film with no release date yet can't be verified against
  -- the window, so it's not eligible for acquisition (unlike the initial
  -- draft, which allows manually-entered estimated dates for that case).
  select * into v_window from public.league_season_window(v_league.season);
  if v_window.window_start is null then
    raise exception 'This league''s season (%) has no configured eligibility window', v_league.season;
  end if;
  if v_film.release_date is null then
    raise exception 'This film has no known release date yet, so it can''t be verified as in-season';
  end if;
  if v_film.release_date < v_window.window_start or v_film.release_date > v_window.window_end then
    raise exception 'This film releases outside this league''s season window (% to %)', v_window.window_start, v_window.window_end;
  end if;

  if exists (select 1 from league_picks where league_id = p_league_id and imdb_id = p_imdb_id) then
    raise exception 'This film is already on this league''s slate';
  end if;

  select coalesce(sum(amount), 0) into v_pending_total
  from acquisition_bids
  where week_id = v_week.id and league_id = p_league_id and user_id = auth.uid() and status = 'pending'
    and imdb_id <> p_imdb_id;

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

-- ── resolve_acquisitions_week(): same season-window check in the ─────────
-- defensive re-validation pass (a film's eligibility could have shifted
-- between submission and resolution, same reasoning as the other checks
-- already there).
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
    return;
  end if;
  if now() < v_week.bid_deadline then
    raise exception 'Bidding window has not closed yet';
  end if;

  update acquisition_declarations d
  set violated = true
  where d.week_id = p_week_id
    and not exists (
      select 1 from acquisition_bids b
      where b.week_id = d.week_id and b.league_id = d.league_id and b.user_id = d.user_id
    );

  update acquisition_bids b
  set status = 'invalid', resolved_at = now()
  where b.week_id = p_week_id
    and b.status = 'pending'
    and (
      exists (select 1 from league_picks lp where lp.league_id = b.league_id and lp.imdb_id = b.imdb_id)
      or exists (
        select 1 from universe_films f, leagues l, public.league_season_window(l.season) w
        where f.imdb_id = b.imdb_id and l.id = b.league_id
          and (
            f.release_date is null
            or f.release_date <= current_date
            or (f.festival_protected_until is not null and f.festival_protected_until > current_date)
            or w.window_start is null
            or f.release_date < w.window_start or f.release_date > w.window_end
          )
      )
    );

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

-- ── league_acquisitions_budgets(): per-team budget breakdown for Standings ──
-- Open to any league member (matches the existing transparency norm --
-- draft-budget-remaining is already visible to everyone in Standings
-- today). Not extended to anon/public-view in this pass.
create or replace function public.league_acquisitions_budgets(p_league_id uuid)
returns table(
  team_name text,
  budget_default numeric,
  remainder_credit numeric,
  refund_credits numeric,
  spent numeric,
  remaining numeric
)
language plpgsql
security definer
stable
set search_path = public
as $$
begin
  if not public.is_league_member(p_league_id, auth.uid()) then
    raise exception 'Not a member of this league';
  end if;

  return query
  select
    lm.team_name,
    l.acq_budget_default,
    lm.acq_remainder_credit,
    coalesce(rf.total, 0),
    coalesce(sp.total, 0),
    l.acq_budget_default + lm.acq_remainder_credit + coalesce(rf.total,0) - coalesce(sp.total,0)
  from league_members lm
  join leagues l on l.id = p_league_id
  left join (
    select user_id, sum(credit_amount) as total from refunds where league_id = p_league_id group by user_id
  ) rf on rf.user_id = lm.user_id
  left join (
    select team_name, sum(bid) as total from league_picks where league_id = p_league_id and source = 'acquisition' group by team_name
  ) sp on sp.team_name = lm.team_name
  where lm.league_id = p_league_id;
end;
$$;

revoke all on function public.league_acquisitions_budgets(uuid) from public;
grant execute on function public.league_acquisitions_budgets(uuid) to authenticated;
