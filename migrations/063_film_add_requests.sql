-- "Add a film" requests. A player who can't find a film in the Universe files a
-- request instead of inserting into the shared universe_films table directly
-- (that table is shared by every league, so unreviewed entries would show up
-- everywhere and fire new-film alerts). Flow:
--   1. member calls request_film_add()          -> row in film_add_requests (pending)
--   2. Apps Script (processFilmRequests) researches it on TMDb, flags likely
--      matches already in the Universe, stores them in `candidates`, and
--      emails the admin
--   3. a league admin reviews in the Weekend Picks tab and calls
--      resolve_film_add_request(): add as new film / link to an existing one /
--      reject.
-- The typed title still works as a pick in the meantime (picks are free text).
--
-- Standing rule: no direct table access for clients, every function pairs
-- `revoke all ... from public` with an explicit revoke from anon.

create table if not exists film_add_requests (
  id uuid primary key default gen_random_uuid(),
  league_id uuid not null references leagues(id) on delete cascade,
  requested_by uuid not null references auth.users(id) on delete cascade,
  requester_team text,
  title text not null,
  release_date date,                    -- optional, set by the admin when approving
  status text not null default 'pending' check (status in ('pending', 'added', 'linked', 'rejected')),
  candidates jsonb,                     -- {tmdb: [...], universe: [...]} filled in by Apps Script
  researched_at timestamptz,
  emailed_at timestamptz,
  resolved_at timestamptz,
  resolved_by uuid,
  resolution_imdb_id text,
  created_at timestamptz not null default now()
);
create index if not exists film_add_requests_status_idx on film_add_requests(status, created_at);

alter table film_add_requests enable row level security;
revoke all on film_add_requests from anon, authenticated;

-- ── member: file a request ──────────────────────────────────────────────────
create or replace function public.request_film_add(p_league_id uuid, p_title text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_title text := btrim(coalesce(p_title, ''));
  v_key text := public.weekend_norm_title(btrim(coalesce(p_title, '')));
  v_team text;
  v_existing text;
  v_id uuid;
begin
  if not public.is_league_member(p_league_id, auth.uid()) then
    raise exception 'Not a member of this league';
  end if;
  if length(v_title) < 2 or v_key = '' then
    raise exception 'Type the film''s name first';
  end if;
  if length(v_title) > 120 then
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
revoke all on function public.request_film_add(uuid, text) from public;
revoke execute on function public.request_film_add(uuid, text) from anon;
grant execute on function public.request_film_add(uuid, text) to authenticated;

-- ── admin: pending requests for this league ─────────────────────────────────
create or replace function public.list_film_add_requests(p_league_id uuid)
returns jsonb
language plpgsql
security definer
stable
set search_path = public
as $$
begin
  if not public.is_league_admin(p_league_id, auth.uid()) then
    raise exception 'Only a league admin can do this';
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
revoke all on function public.list_film_add_requests(uuid) from public;
revoke execute on function public.list_film_add_requests(uuid) from anon;
grant execute on function public.list_film_add_requests(uuid) to authenticated;

-- ── admin: decide ───────────────────────────────────────────────────────────
-- p_action: 'add'    -> insert into universe_films (p_title / p_release_date /
--                       p_imdb_id; title defaults to what was requested)
--           'link'   -> it's a film already in the Universe (p_imdb_id); nothing inserted
--           'reject' -> close the request
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
  select * into r from film_add_requests where id = p_request_id for update;
  if not found then
    raise exception 'Request not found';
  end if;
  if not public.is_league_admin(r.league_id, auth.uid()) then
    raise exception 'Only a league admin can do this';
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
    v_title := btrim(coalesce(nullif(btrim(coalesce(p_title, '')), ''), r.title));
    if v_title = '' then
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
revoke all on function public.resolve_film_add_request(uuid, text, text, date, text) from public;
revoke execute on function public.resolve_film_add_request(uuid, text, text, date, text) from anon;
grant execute on function public.resolve_film_add_request(uuid, text, text, date, text) to authenticated;
