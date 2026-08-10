-- New-leaderboard-leader notification (backlog #11's last and hardest
-- trigger, per the original notes -- standings ranking has always been
-- 100% client-side, computed fresh in league.html's `data` useMemo, with
-- no server-side equivalent to hook a notification into).
--
-- IMPORTANT SIMPLIFICATION: the real grandTotal ranking league.html
-- displays is totalBO + remaining budget (Acquisitions budget when
-- enabled, or the legacy hardcoded REMAINDERS constant otherwise) --
-- faithfully replicating that in SQL means re-deriving getTeamRemainder()'s
-- full branching logic here too. This function ranks by total box office
-- alone instead. In practice remaining budget is small relative to real
-- box office totals once a season is underway, so this should track the
-- real #1 correctly the large majority of the time, but it CAN disagree
-- with the actual displayed standings at the margins (e.g. very early in
-- a season, or a league sitting on a large unspent Acquisitions budget).
-- This is meant as a "go check the real page" heads-up, not an
-- authoritative source -- the standings page itself remains the source of
-- truth. Worth revisiting if false/missed alerts turn out to be common.
--
-- Tracks "who was leading last time we checked" via a new column on
-- leagues itself (current_leader_team) rather than a separate table --
-- one row per league already exists there, and this is genuinely a
-- per-league singleton value, same shape as e.g. draft_status.
alter table leagues add column if not exists current_leader_team text;

-- Called once daily from Apps Script (service_role only), after that
-- day's box office scrape has run so the ranking reflects fresh numbers.
create or replace function public.check_new_leaders()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  r record;
begin
  for r in
    select distinct on (lp.league_id)
      lp.league_id, lp.team_name, l.name as league_name, l.current_leader_team
    from league_picks lp
    join universe_films uf on uf.imdb_id = lp.imdb_id
    join leagues l on l.id = lp.league_id
    where not lp.voided
    group by lp.league_id, lp.team_name, l.name, l.current_leader_team
    order by lp.league_id, sum(coalesce(uf.bo, 0)) desc
  loop
    -- Skip the very first time a league gets a leader recorded -- nothing
    -- to compare against yet, so no false "new leader" on day one.
    if r.current_leader_team is not null and r.current_leader_team <> r.team_name then
      insert into notifications (user_id, league_id, type, title, body, link)
      select lm.user_id, r.league_id, 'new_leader',
        r.team_name || ' takes the lead!',
        r.team_name || ' is now #1 in ' || r.league_name || ' by box office.',
        '/league?id=' || r.league_id
      from league_members lm
      left join notification_preferences np on np.user_id = lm.user_id
      where lm.league_id = r.league_id
        and coalesce(np.notify_new_leader, true);
    end if;

    update leagues set current_leader_team = r.team_name where id = r.league_id;
  end loop;
end;
$$;

revoke all on function public.check_new_leaders() from public;
grant execute on function public.check_new_leaders() to service_role;
