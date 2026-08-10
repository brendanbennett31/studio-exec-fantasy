-- Notifications system, session 1: in-app channel only (email/push are
-- deferred backlog items #17/#18). Schema + one trigger wired end-to-end
-- as a proof of concept -- "someone declared intent to bid" is the easiest
-- one to start with: it's a direct client RPC call already, so no new
-- Apps Script work is needed to prove the whole pipe works. The other
-- three requested triggers (new leaderboard leader, new film added,
-- release day arriving) are follow-up work -- see sef_todo memory for
-- where each one naturally hooks in.

create table if not exists notification_preferences (
  user_id uuid primary key references auth.users(id) on delete cascade,
  notify_declarations boolean not null default true,
  notify_new_leader boolean not null default true,
  notify_new_film boolean not null default true,
  notify_release_day boolean not null default true,
  updated_at timestamptz not null default now()
);

alter table notification_preferences enable row level security;
grant select, insert, update on notification_preferences to authenticated;

drop policy if exists "notification_prefs_own" on notification_preferences;
create policy "notification_prefs_own" on notification_preferences
  for all to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

create table if not exists notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  league_id uuid references leagues(id) on delete cascade,
  type text not null check (type in ('declaration','new_leader','new_film','release_day')),
  title text not null,
  body text,
  link text,
  read boolean not null default false,
  created_at timestamptz not null default now()
);

alter table notifications enable row level security;
-- No insert grant to authenticated -- notifications are only ever created
-- server-side (SECURITY DEFINER functions), never directly by a client, so
-- a player can't spoof a notification to themselves or anyone else.
grant select, update on notifications to authenticated;

drop policy if exists "notifications_own_select" on notifications;
create policy "notifications_own_select" on notifications
  for select to authenticated using (user_id = auth.uid());

drop policy if exists "notifications_own_update" on notifications;
create policy "notifications_own_update" on notifications
  for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

create index if not exists notifications_user_unread_idx on notifications(user_id, read, created_at desc);

-- ── mark_notifications_read(): bulk mark-as-read for the current user ──────
create or replace function public.mark_notifications_read(p_ids uuid[])
returns void
language sql
security definer
set search_path = public
as $$
  update notifications set read = true
  where user_id = auth.uid() and id = any(p_ids);
$$;

revoke all on function public.mark_notifications_read(uuid[]) from public;
grant execute on function public.mark_notifications_read(uuid[]) to authenticated;

-- ── declare_for_acquisitions(): now also notifies league mates ────────────
create or replace function public.declare_for_acquisitions(p_league_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_week_id uuid;
  v_deadline timestamptz;
  v_team_name text;
  v_league_name text;
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

  select lm.team_name into v_team_name from league_members lm where lm.league_id = p_league_id and lm.user_id = auth.uid();
  select l.name into v_league_name from leagues l where l.id = p_league_id;

  -- Notify every OTHER member who wants to know (missing preference row
  -- defaults to "on", matching notification_preferences' own column
  -- defaults, via coalesce).
  insert into notifications (user_id, league_id, type, title, body, link)
  select lm.user_id, p_league_id, 'declaration',
    v_team_name || ' declared intent to bid',
    v_team_name || ' is bidding in this week''s Acquisitions market in ' || v_league_name || '.',
    '/league?id=' || p_league_id
  from league_members lm
  left join notification_preferences np on np.user_id = lm.user_id
  where lm.league_id = p_league_id
    and lm.user_id <> auth.uid()
    and coalesce(np.notify_declarations, true);
end;
$$;

revoke all on function public.declare_for_acquisitions(uuid) from public;
grant execute on function public.declare_for_acquisitions(uuid) to authenticated;
