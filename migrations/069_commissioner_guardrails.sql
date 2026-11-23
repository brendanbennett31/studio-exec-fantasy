-- 069: guardrails found by the second round of break-it testing.
--
--  1. Only the site admin can put a film into the shared Universe. Before this,
--     any league commissioner could approve a film request and the film landed
--     in every league's film list.
--  2. "Duplicate league" becomes "run it back next season": same settings and
--     same studios, but no films (it used to copy last season's roster into the
--     new season), the draft starts open, and it counts toward 5 leagues a day.
--  3. League settings must be sane (budget, bids, bonuses, refund rate, draft
--     status); the invite code can't be hand-picked; share links stay long.
--  4. Commissioner roster edits: no negative / NaN prices, only studios that
--     are actually in the league, and nothing changes once the season is final.
--  5. Leaving: a studio that owns films can't leave (or be removed) mid-season,
--     and if the last commissioner leaves, the longest-standing member takes over.
--
-- Safe to re-run.

-- ── 1. film requests: site admin only ────────────────────────────────────────
create or replace function public.request_film_add(p_league_id uuid, p_title text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_title text := public.sef_clean_text(p_title);
  v_key text := public.weekend_norm_title(public.sef_clean_text(p_title));
  v_team text;
  v_existing text;
  v_id uuid;
begin
  if not public.is_league_member(p_league_id, auth.uid()) then
    raise exception 'Not a member of this league';
  end if;
  if char_length(coalesce(v_title, '')) < 2 or coalesce(v_key, '') = '' then
    raise exception 'Type the film''s name first';
  end if;
  if char_length(v_title) > 120 then
    raise exception 'That film title is too long';
  end if;

  select uf.title into v_existing
  from universe_films uf
  where public.weekend_norm_title(uf.title) = v_key
  limit 1;
  if v_existing is not null then
    return jsonb_build_object('status', 'exists', 'title', v_existing);
  end if;

  select id into v_id from film_add_requests
  where status = 'pending' and public.weekend_norm_title(title) = v_key
  limit 1;
  if v_id is not null then
    return jsonb_build_object('status', 'already_requested', 'id', v_id);
  end if;

  if (select count(*) from film_add_requests where requested_by = auth.uid() and status = 'pending') >= 5 then
    raise exception 'You already have several films waiting for review -- give those a day first';
  end if;

  select team_name into v_team from league_members where league_id = p_league_id and user_id = auth.uid();

  insert into film_add_requests (league_id, requested_by, requester_team, title)
  values (p_league_id, auth.uid(), v_team, v_title)
  returning id into v_id;

  return jsonb_build_object('status', 'requested', 'id', v_id);
end;
$$;
revoke all on function public.request_film_add(uuid, text) from public, anon;
grant execute on function public.request_film_add(uuid, text) to authenticated;

create or replace function public.list_film_add_requests(p_league_id uuid)
returns jsonb
language plpgsql
security definer
stable
set search_path = public
as $$
begin
  if not public.is_site_admin(auth.uid()) then
    raise exception 'Only the site admin reviews film requests';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', r.id,
      'title', r.title,
      'requester_team', r.requester_team,
      'created_at', r.created_at,
      'researched_at', r.researched_at,
      'candidates', r.candidates
    ) order by r.created_at)
    from film_add_requests r
    where r.league_id = p_league_id and r.status = 'pending'
  ), '[]'::jsonb);
end;
$$;
revoke all on function public.list_film_add_requests(uuid) from public, anon;
grant execute on function public.list_film_add_requests(uuid) to authenticated;

create or replace function public.resolve_film_add_request(
  p_request_id uuid,
  p_action text,
  p_title text default null,
  p_release_date date default null,
  p_imdb_id text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r film_add_requests%rowtype;
  v_title text;
  v_imdb text := nullif(btrim(coalesce(p_imdb_id, '')), '');
begin
  if not public.is_site_admin(auth.uid()) then
    raise exception 'Only the site admin can add films to the Universe';
  end if;
  select * into r from film_add_requests where id = p_request_id for update;
  if not found then
    raise exception 'Request not found';
  end if;
  if r.status <> 'pending' then
    raise exception 'That request was already handled (%)', r.status;
  end if;

  if p_action = 'reject' then
    update film_add_requests set status = 'rejected', resolved_at = now(), resolved_by = auth.uid() where id = r.id;
    return jsonb_build_object('status', 'rejected');
  end if;

  if p_action = 'link' then
    if v_imdb is null or not exists (select 1 from universe_films where imdb_id = v_imdb) then
      raise exception 'Pick a film that is already in the Universe';
    end if;
    update film_add_requests
    set status = 'linked', resolved_at = now(), resolved_by = auth.uid(), resolution_imdb_id = v_imdb
    where id = r.id;
    return jsonb_build_object('status', 'linked', 'imdb_id', v_imdb);
  end if;

  if p_action = 'add' then
    v_title := public.sef_clean_text(coalesce(nullif(btrim(coalesce(p_title, '')), ''), r.title));
    if coalesce(v_title, '') = '' then
      raise exception 'A film needs a title';
    end if;
    if v_imdb is not null and exists (select 1 from universe_films where imdb_id = v_imdb) then
      raise exception 'That film is already in the Universe -- use "link" instead';
    end if;
    if exists (select 1 from universe_films where public.weekend_norm_title(title) = public.weekend_norm_title(v_title)) then
      raise exception 'A film with that title is already in the Universe -- use "link" instead';
    end if;
    insert into universe_films (title, release_date, imdb_id) values (v_title, p_release_date, v_imdb);
    update film_add_requests
    set status = 'added', release_date = p_release_date, resolved_at = now(), resolved_by = auth.uid(), resolution_imdb_id = v_imdb
    where id = r.id;
    return jsonb_build_object('status', 'added', 'title', v_title);
  end if;

  raise exception 'Unknown action';
end;
$$;
revoke all on function public.resolve_film_add_request(uuid, text, text, date, text) from public, anon;
grant execute on function public.resolve_film_add_request(uuid, text, text, date, text) to authenticated;

-- ── 2. run it back next season ───────────────────────────────────────────────
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
  -- runs as the owner, so the per-user daily cap in trg_leagues_rules doesn't see it: apply it here
  if (select count(*) from leagues where created_by = auth.uid() and created_at > now() - interval '1 day') >= 5 then
    raise exception 'You can create up to 5 leagues a day';
  end if;

  v_new_season := coalesce(p_new_season::text, (v_src.season::int + 1)::text);

  insert into leagues (
    name, season, season_number, budget, num_players, min_bid, max_bid,
    oscar_nom_bonus, oscar_win_bonus, bp_bonus, festival_picks,
    is_public, share_token, created_by, draft_status,
    acquisitions_enabled, acq_budget_default, acq_min_bid, acq_refund_rate
  ) values (
    coalesce(nullif(btrim(p_new_name), ''), v_src.name),
    v_new_season,
    coalesce(v_src.season_number, 1) + 1,
    v_src.budget, v_src.num_players, v_src.min_bid, v_src.max_bid,
    v_src.oscar_nom_bonus, v_src.oscar_win_bonus, v_src.bp_bonus, v_src.festival_picks,
    false, substring(replace(gen_random_uuid()::text, '-', '') for 18), auth.uid(), 'open',
    false, v_src.acq_budget_default, v_src.acq_min_bid, v_src.acq_refund_rate
  )
  returning id into v_new_id;

  -- same studios, fresh slate: no films, no budget carry-over
  insert into league_members (league_id, user_id, team_name, role, color, joined_at)
  select v_new_id, user_id, team_name, role, color,
         now() + (row_number() over (order by joined_at) * interval '1 millisecond')
  from league_members
  where league_id = p_source_league_id;

  return v_new_id;
end;
$$;
revoke all on function public.duplicate_league(uuid, text, int) from public, anon;
grant execute on function public.duplicate_league(uuid, text, int) to authenticated;

-- ── 3. league settings ───────────────────────────────────────────────────────
create or replace function public.trg_leagues_rules()
returns trigger language plpgsql set search_path = public as $$
declare v_members int; v_spent numeric;
  v_client boolean := current_user in ('authenticated', 'anon');
begin
  if tg_op = 'INSERT' or new.name is distinct from old.name then
    new.name := public.sef_clean_text(new.name);
    if char_length(coalesce(new.name, '')) not between 1 and 40 then
      raise exception 'League names must be 1 to 40 characters';
    end if;
  end if;
  if tg_op = 'INSERT' or new.description is distinct from old.description then
    new.description := left(public.sef_clean_text(new.description), 280);
  end if;
  if tg_op = 'INSERT' or new.sacko_punishment is distinct from old.sacko_punishment then
    new.sacko_punishment := left(public.sef_clean_text(new.sacko_punishment), 280);
  end if;
  if tg_op = 'INSERT' or new.num_players is distinct from old.num_players then
    if new.num_players is null or new.num_players not between 3 and 12 then
      raise exception 'A league holds 3 to 12 players';
    end if;
    if tg_op = 'UPDATE' then
      select count(*) into v_members from league_members where league_id = new.id;
      if new.num_players < v_members then
        raise exception 'This league already has % players', v_members;
      end if;
    end if;
  end if;
  if tg_op = 'INSERT' or new.season is distinct from old.season then
    if not exists (select 1 from seasons where season = new.season) then
      raise exception 'Season % is not open yet', new.season;
    end if;
    if tg_op = 'UPDATE' and exists (select 1 from league_picks where league_id = new.id) then
      raise exception 'The season can''t change once films are drafted';
    end if;
  end if;

  -- money and scoring settings (only checked when they change, so old leagues are untouched)
  if tg_op = 'INSERT' or new.budget is distinct from old.budget or new.min_bid is distinct from old.min_bid
     or new.max_bid is distinct from old.max_bid then
    if new.budget is null or new.budget not between 50 and 10000 then
      raise exception 'Draft budget must be $50M to $10,000M';
    end if;
    if new.min_bid is null or new.min_bid not between 1 and new.budget then
      raise exception 'Minimum bid must be at least $1M and no more than the budget';
    end if;
    if new.max_bid is not null and new.max_bid not between new.min_bid and new.budget then
      raise exception 'Maximum bid must be between the minimum bid and the budget';
    end if;
    if tg_op = 'UPDATE' and new.budget < old.budget then
      select coalesce(max(s), 0) into v_spent from (
        select sum(bid) s from league_picks where league_id = new.id and source <> 'acquisition' group by team_name) t;
      if new.budget < v_spent then
        raise exception 'A studio has already spent $%M -- the budget can''t go below that', v_spent;
      end if;
    end if;
  end if;
  if (tg_op = 'INSERT' or new.oscar_nom_bonus is distinct from old.oscar_nom_bonus) and coalesce(new.oscar_nom_bonus, 0) not between 0 and 1000 then
    raise exception 'Oscar nomination bonus must be 0 to 1000';
  end if;
  if (tg_op = 'INSERT' or new.oscar_win_bonus is distinct from old.oscar_win_bonus) and coalesce(new.oscar_win_bonus, 0) not between 0 and 1000 then
    raise exception 'Oscar win bonus must be 0 to 1000';
  end if;
  if (tg_op = 'INSERT' or new.bp_bonus is distinct from old.bp_bonus) and coalesce(new.bp_bonus, 0) not between 0 and 1000 then
    raise exception 'Best Picture bonus must be 0 to 1000';
  end if;
  if (tg_op = 'INSERT' or new.acq_budget_default is distinct from old.acq_budget_default) and coalesce(new.acq_budget_default, 0) not between 0 and 10000 then
    raise exception 'Acquisitions budget must be $0M to $10,000M';
  end if;
  if (tg_op = 'INSERT' or new.acq_min_bid is distinct from old.acq_min_bid) and coalesce(new.acq_min_bid, 1) not between 1 and 10000 then
    raise exception 'Acquisitions minimum bid must be $1M to $10,000M';
  end if;
  if (tg_op = 'INSERT' or new.acq_refund_rate is distinct from old.acq_refund_rate) and coalesce(new.acq_refund_rate, 0) not between 0 and 1 then
    raise exception 'Refund rate must be between 0%% and 100%%';
  end if;
  if (tg_op = 'INSERT' or new.draft_status is distinct from old.draft_status) and coalesce(new.draft_status, '') not in ('open', 'locked') then
    raise exception 'Draft status must be open or locked';
  end if;
  if new.share_token is not null and (tg_op = 'INSERT' or new.share_token is distinct from old.share_token)
     and new.share_token !~ '^[A-Za-z0-9_-]{16,64}$' then
    raise exception 'Share links must be at least 16 random characters';
  end if;

  if tg_op = 'INSERT' and v_client then
    new.created_by := auth.uid();
    new.finalized_at := null;
    new.invite_code := substring(md5(gen_random_uuid()::text), 1, 8);
    if (select count(*) from leagues where created_by = auth.uid() and created_at > now() - interval '1 day') >= 5 then
      raise exception 'You can create up to 5 leagues a day';
    end if;
  end if;
  if tg_op = 'UPDATE' and v_client then
    if new.finalized_at is distinct from old.finalized_at then
      raise exception 'Seasons are finalized by the server';
    end if;
    if new.created_by is distinct from old.created_by then
      raise exception 'A league''s creator can''t change';
    end if;
    if new.invite_code is distinct from old.invite_code then
      raise exception 'Invite codes are set by the server';
    end if;
  end if;
  return new;
end;
$$;
drop trigger if exists leagues_rules on public.leagues;
create trigger leagues_rules before insert or update on public.leagues
  for each row execute function public.trg_leagues_rules();

-- ── 4. commissioner roster edits ─────────────────────────────────────────────
create or replace function public.trg_league_picks_rules()
returns trigger language plpgsql set search_path = public as $$
declare v_league uuid := coalesce(new.league_id, old.league_id);
begin
  -- server functions (draft, acquisitions, finalize) run as the owner and are trusted
  if current_user not in ('authenticated', 'anon') then
    return coalesce(new, old);
  end if;
  if exists (select 1 from leagues where id = v_league and finalized_at is not null) then
    raise exception 'This season is over -- the league is final';
  end if;
  if tg_op = 'DELETE' then
    return old;
  end if;
  if new.bid is null or new.bid = 'NaN'::numeric or new.bid < 0 or new.bid > 100000 then
    raise exception 'A film''s price must be $0M or more';
  end if;
  if not exists (select 1 from league_members where league_id = new.league_id and team_name = new.team_name) then
    raise exception 'Studio "%" isn''t in this league', left(new.team_name, 40);
  end if;
  return new;
end;
$$;
drop trigger if exists league_picks_rules on public.league_picks;
create trigger league_picks_rules before insert or update or delete on public.league_picks
  for each row execute function public.trg_league_picks_rules();

-- ── 5. leaving ───────────────────────────────────────────────────────────────
create or replace function public.trg_league_members_leave()
returns trigger language plpgsql set search_path = public as $$
begin
  if current_user not in ('authenticated', 'anon') then
    return old;
  end if;
  -- the whole league is being deleted: let the cascade through
  if not exists (select 1 from leagues where id = old.league_id) then
    return old;
  end if;
  if exists (select 1 from leagues where id = old.league_id and finalized_at is not null) then
    raise exception 'This season is final -- it stays in your Past seasons';
  end if;
  if exists (select 1 from league_picks where league_id = old.league_id and team_name = old.team_name) then
    raise exception '% owns films this season, so it stays in the league until the season ends', old.team_name;
  end if;
  return old;
end;
$$;
drop trigger if exists league_members_leave on public.league_members;
create trigger league_members_leave before delete on public.league_members
  for each row execute function public.trg_league_members_leave();

-- runs as the owner so the member guard lets the promotion through
create or replace function public.trg_league_members_keep_admin()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_next bigint;
begin
  if old.role = 'admin'
     and exists (select 1 from leagues where id = old.league_id)
     and not exists (select 1 from league_members where league_id = old.league_id and role = 'admin') then
    select id into v_next from league_members where league_id = old.league_id order by joined_at, id limit 1;
    if v_next is not null then
      update league_members set role = 'admin' where id = v_next;
    end if;
  end if;
  return null;
end;
$$;
revoke all on function public.trg_league_members_keep_admin() from public, anon, authenticated;
drop trigger if exists league_members_keep_admin on public.league_members;
create trigger league_members_keep_admin after delete on public.league_members
  for each row execute function public.trg_league_members_keep_admin();

notify pgrst, 'reload schema';

-- ── checks (all should be true) ──────────────────────────────────────────────
select
  (select prosrc like '%is_site_admin%' from pg_proc where proname = 'resolve_film_add_request') as film_adds_site_admin_only,
  (select prosrc not like '%insert into league_picks%' from pg_proc where proname = 'duplicate_league') as duplicate_copies_no_films,
  exists (select 1 from pg_trigger where tgname = 'league_picks_rules') as roster_rules,
  exists (select 1 from pg_trigger where tgname = 'league_members_leave') as leave_rules,
  exists (select 1 from pg_trigger where tgname = 'league_members_keep_admin') as keep_admin;
