"""Phase 2: play a whole season week by week, doing what players and the Apps Script jobs do."""
import json, random, sys, os, datetime as dt
from sef import *

TAGS = sys.argv[1].split(',') if len(sys.argv) > 1 else ['main']
END = sys.argv[2] if len(sys.argv) > 2 else '2027-03-13'
random.seed(11)
states = [json.load(open(os.path.join(HERE, 'state_%s.json' % t))) for t in TAGS]
leagues = []
for st in states:
    ps = [signup(p['email'], 'password123', p['name']) for p in st['players']]
    for p, meta in zip(ps, st['players']): p.team = meta['team']
    leagues.append((st['league'], ps))
errors = []
def attempt(label, fn):
    try: return fn()
    except ApiError as e:
        errors.append('%s: %s' % (label, e.msg)); return None
def relog():
    for _, ps in leagues:
        for p in ps:
            s = signup(p.user['email'], 'password123', p.name); p.token = s.token
truth = {r.split('\t')[0]: (r.split('\t')[1], dt.date.fromisoformat(r.split('\t')[2]), float(r.split('\t')[3]))
         for r in sql("select imdb_id, title, release_date, final_bo from sim.truth;").splitlines()}
def cum(final, weeks):  # cumulative gross after N full weeks in release (0 = opening week)
    if weeks < 0: return 0
    if weeks >= 15: return final
    return round(final * (1 - 0.58 ** (weeks + 1)) / (1 - 0.58 ** 16))

def update_box_office(today):
    sql("""update universe_films u set
             bo = sub.bo, opening_weekend = round(t.final_bo * 0.29), locked = sub.w >= 16, last_check_date = sim.today()
           from sim.truth t, lateral (select floor((sim.today() - t.release_date) / 7.0)::int as w) w0,
                lateral (select w0.w as w, case when w0.w >= 15 then t.final_bo else round(t.final_bo * (1 - 0.58 ^ (w0.w + 1)) / (1 - 0.58 ^ 16)) end as bo) sub
           where u.imdb_id = t.imdb_id and t.release_date <= sim.today();
           update universe_films u set bo = 0, opening_weekend = 0, locked = false
           from sim.truth t where u.imdb_id = t.imdb_id and t.release_date > sim.today();""")

def weekend_top3(friday):
    g = []
    for i, (title, rel, final) in truth.items():
        w = (friday - rel).days // 7
        if w < 0: continue
        g.append((cum(final, w) - cum(final, w - 1), i, title))
    g.sort(reverse=True)
    return g[:3]

d = dt.date(2026, 3, 16)  # Monday the season opens
end = dt.date.fromisoformat(END)
week = 0
while d <= end:
    week += 1
    mon = d; fri = mon + dt.timedelta(days=4)
    # Monday 11:00 PT: scraper + weekly snapshot + leader check (Apps Script)
    set_clock('%sT19:00:00Z' % mon.isoformat())
    if week % 6 == 0: relog()  # tokens expire after an hour of real time
    update_box_office(mon)
    svc.rpc('snapshot_weekly_bo_and_poi'); svc.rpc('check_new_leaders')
    # resolve last weekend's picks (Apps Script, Mon 19:00 PT is after resolve_after Mon 17:00)
    set_clock('%sT03:30:00Z' % (mon + dt.timedelta(days=1)).isoformat())
    due = svc.get('weekend_pick_weeks?resolved_at=is.null&resolve_after=lt.%s&select=id,weekend_friday' % sim_now().replace(' ', 'T').replace('+00', 'Z'))
    for w in due:
        top = weekend_top3(dt.date.fromisoformat(w['weekend_friday']))
        if len(top) == 3:
            attempt('resolve weekend', lambda: svc.rpc('resolve_weekend_picks_week', p_week_id=w['id'], p_top3=[t[1] for t in top], p_top3_titles=[t[2] for t in top]))
    # Friday: new acquisitions week opens (Apps Script ensureAcquisitionWeek); some players declare over the weekend
    set_clock('%sT17:00:00Z' % fri.isoformat())
    svc.rpc('ensure_acquisition_week')
    svc.rpc('notify_release_day_films')
    for lid, ps in leagues:
        for p in ps:
            if random.random() < 0.25: attempt('declare', lambda: p.rpc('declare_for_acquisitions', p_league_id=lid)); p.declared = True
            else: p.declared = False
    # following Tuesday 22:00 PT: weekend picks window (Tue 21:00 -> Wed 21:00)
    tue = fri + dt.timedelta(days=4)
    set_clock('%sT06:00:00Z' % (tue + dt.timedelta(days=1)).isoformat())
    upcoming = sorted([(final, title) for i, (title, rel, final) in truth.items() if 0 <= (rel - (tue + dt.timedelta(days=3))).days < 21 or 0 <= ((tue + dt.timedelta(days=3)) - rel).days < 28], reverse=True)[:8]
    for lid, ps in leagues:
        for p in ps:
            if random.random() < 0.7 and len(upcoming) >= 3:
                picks = random.sample([t for _, t in upcoming], 3)
                attempt('weekend picks', lambda: p.rpc('submit_weekend_picks', p_league_id=lid, p_pick1=picks[0], p_pick2=picks[1], p_pick3=picks[2]))
    # Wednesday 12:00 PT: declared players bid (Wed 00:00 -> Thu 00:00 PT)
    wed = tue + dt.timedelta(days=1)
    set_clock('%sT20:00:00Z' % wed.isoformat())
    for lid, ps in leagues:
        slate = {r['imdb_id'] for r in ps[0].get('league_picks?league_id=eq.%s&select=imdb_id' % lid)}
        avail = [i for i, (t, rel, f) in truth.items() if rel > wed + dt.timedelta(days=1) and i not in slate]
        for p in ps:
            if p.declared and avail and random.random() < 0.85:
                film = max(random.sample(avail, min(5, len(avail))), key=lambda i: truth[i][2])
                attempt('acq bid', lambda: p.rpc('submit_acquisition_bid', p_league_id=lid, p_imdb_id=film, p_amount=random.choice([20, 20, 25, 30])))
            # occasional refund of a far-off film
            if random.random() < 0.03:
                mine = p.get('league_picks?league_id=eq.%s&team_name=eq.%s&select=id,imdb_id' % (lid, urllib_quote(p.team)) if False else
                             'league_picks?league_id=eq.%s&select=id,imdb_id,team_name' % lid)
                mine = [m for m in mine if m['team_name'] == p.team and m['imdb_id'] in truth and truth[m['imdb_id']][1] > wed + dt.timedelta(days=20)]
                if mine: attempt('refund', lambda: p.rpc('refund_my_film', p_league_id=lid, p_league_pick_id=random.choice(mine)['id']))
    # Thursday 01:00 PT: resolve due acquisition weeks (Apps Script)
    set_clock('%sT09:00:00Z' % (wed + dt.timedelta(days=1)).isoformat())
    for w in svc.get('acquisition_weeks?resolved_at=is.null&bid_deadline=lt.%s&select=id' % sim_now().replace(' ', 'T').replace('+00', 'Z')):
        attempt('resolve acq', lambda: svc.rpc('resolve_acquisitions_week', p_week_id=w['id']))
    d = mon + dt.timedelta(days=7)
    if week % 8 == 0: print('week', week, mon, 'errors so far', len(errors), flush=True)

set_clock('%sT20:00:00Z' % end.isoformat())
update_box_office(end); svc.rpc('snapshot_weekly_bo_and_poi')
print('season simulated through', end, '(%d weeks)' % week)
from collections import Counter
for k, v in Counter(e.split(':')[0] + ': ' + ':'.join(e.split(':')[1:])[:90] for e in errors).most_common(25): print('%4d  %s' % (v, k))
for lid, ps in leagues:
    print('\nleague', lid)
    print(sql("""select lp.team_name, count(*) films, sum(lp.bid) spent, round(sum(coalesce(u.bo,0))/1e6) bo_m,
                        count(*) filter (where lp.source='acquisition') acq
                 from league_picks lp left join universe_films u on u.imdb_id = lp.imdb_id where lp.league_id = :'l'
                 group by 1 order by bo_m desc;""", l=lid))
