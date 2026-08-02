-- Acquisitions feature, step 2: the two pieces that actually unblock the
-- user's immediate need -- a safe duplicate of the live season's league to
-- build and test the rest of Acquisitions against, without ever touching
-- the original. Everything else (the bidding-engine tables/RPCs) comes in
-- later migrations.

-- ── convert_draft_remainder() ───────────────────────────────────────────────
-- For each member of a league who hasn't already been converted
-- (remainder_converted_at is null), credits 25% of their unspent draft
-- budget into acq_remainder_credit. Two-step set-based update rather than a
-- loop: the first UPDATE handles members with at least one league_picks row
-- (joins on team_name -- league_picks isn't reliably keyed by user_id, see
-- migration 012's design notes), the second catches anyone left over whose
-- remainder_converted_at is still null (i.e. they had zero picks, so their
-- entire budget counts as leftover).
--
-- Deliberately NOT granted to anon/authenticated -- this only runs from
-- inside the trigger below or from duplicate_league(), both of which
-- execute with the owning role's privileges. No player should ever be able
-- to call this directly against an arbitrary league_id.
create or replace function public.convert_draft_remainder(p_league_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_budget numeric;
begin
  select budget into v_budget from leagues where id = p_league_id;
  if v_budget is null then
    return;
  end if;

  update league_members lm
  set acq_remainder_credit = greatest(0, v_budget - coalesce(lp.spent, 0)) * 0.25,
      remainder_converted_at = now()
  from (
    select team_name, sum(bid) as spent
    from league_picks
    where league_id = p_league_id
    group by team_name
  ) lp
  where lm.league_id = p_league_id
    and lm.remainder_converted_at is null
    and lp.team_name = lm.team_name;

  -- Members with no matching league_picks row at all (never spent anything).
  update league_members lm
  set acq_remainder_credit = v_budget * 0.25,
      remainder_converted_at = now()
  where lm.league_id = p_league_id
    and lm.remainder_converted_at is null;
end;
$$;

revoke all on function public.convert_draft_remainder(uuid) from public, anon, authenticated;

-- ── trigger: convert on draft_status open -> locked ─────────────────────────
create or replace function public.trg_convert_draft_remainder()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if OLD.draft_status = 'open' and NEW.draft_status = 'locked' then
    perform public.convert_draft_remainder(NEW.id);
  end if;
  return NEW;
end;
$$;

drop trigger if exists leagues_draft_locked_convert_remainder on leagues;
create trigger leagues_draft_locked_convert_remainder
  after update on leagues
  for each row
  execute function public.trg_convert_draft_remainder();

-- ── duplicate_league() ───────────────────────────────────────────────────────
-- Admin-only (checked internally, same pattern as rename_my_team). Copies a
-- league's rule settings, its member roster, and its current league_picks
-- into a brand-new league -- built specifically so Acquisitions can ship
-- opt-in on a "next season" copy without touching the live in-progress
-- league at all. is_public/acquisitions_enabled are deliberately reset to
-- false on the copy (an admin opts back in explicitly); invite_code gets a
-- fresh value from its own column default; share_token is freshly
-- generated here since (unlike invite_code) it's normally generated
-- client-side at creation, not by a DB default.
create or replace function public.duplicate_league(
  p_source_league_id uuid,
  p_new_name text,
  p_new_season int default null
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_src leagues%rowtype;
  v_new_id uuid;
  v_new_season text;
begin
  if not public.is_league_admin(p_source_league_id, auth.uid()) then
    raise exception 'Only an admin of the source league can duplicate it';
  end if;

  select * into v_src from leagues where id = p_source_league_id;
  if not found then
    raise exception 'Source league not found';
  end if;

  -- leagues.season is stored as text (matches dashboard.html's create-league
  -- form, which never parses it to a number), so p_new_season (an int
  -- parameter -- callers think of a season as a number) and v_src.season
  -- both need casting before they can be combined.
  v_new_season := coalesce(p_new_season::text, (v_src.season::int + 1)::text);

  insert into leagues (
    name, season, budget, num_players, min_bid, max_bid,
    oscar_nom_bonus, oscar_win_bonus, bp_bonus, festival_picks,
    is_public, share_token, created_by, draft_status,
    acquisitions_enabled, acq_budget_default, acq_min_bid, acq_refund_rate
  ) values (
    coalesce(nullif(trim(p_new_name), ''), v_src.name),
    v_new_season,
    v_src.budget, v_src.num_players, v_src.min_bid, v_src.max_bid,
    v_src.oscar_nom_bonus, v_src.oscar_win_bonus, v_src.bp_bonus, v_src.festival_picks,
    false, substring(replace(gen_random_uuid()::text, '-', '') for 18), v_src.created_by, v_src.draft_status,
    false, v_src.acq_budget_default, v_src.acq_min_bid, v_src.acq_refund_rate
  )
  returning id into v_new_id;

  insert into league_members (league_id, user_id, team_name, role, color)
  select v_new_id, user_id, team_name, role, color
  from league_members
  where league_id = p_source_league_id;

  insert into league_picks (league_id, imdb_id, team_name, bid, voided, title, release_date, source)
  select v_new_id, imdb_id, team_name, bid, voided, title, release_date, 'draft'
  from league_picks
  where league_id = p_source_league_id;

  -- The new row's draft_status was inserted (not UPDATEd), so the trigger
  -- above never fires for it -- run the same conversion explicitly if it
  -- was copied in as already-locked.
  if v_src.draft_status = 'locked' then
    perform public.convert_draft_remainder(v_new_id);
  end if;

  return v_new_id;
end;
$$;

revoke all on function public.duplicate_league(uuid, text, int) from public;
grant execute on function public.duplicate_league(uuid, text, int) to authenticated;

-- Verify (run by hand against your live season league, replace the uuid):
-- select duplicate_league('c388b799-6240-46c4-ba75-da8a0d2e8db5', 'SEF 2027', 2027);
-- Then confirm: the new league appears with matching settings/roster/picks,
-- acquisitions_enabled = false on both, and the original league's rows are
-- completely unchanged.
