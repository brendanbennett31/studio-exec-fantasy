"""Round 2: commissioner powers, global data, membership churn, draft races, junk input."""
import json, os, sys, threading, time, random
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sef import *

results = []
def expect(name, ok, detail=''):
    results.append((ok, name, str(detail))); print(('PASS ' if ok else 'FAIL ') + name + (('  -- ' + str(detail)[:200]) if detail != '' else ''), flush=True)
def refused(name, fn, needle=None):
    try:
        r = fn(); expect(name, False, 'was ALLOWED: %s' % (str(r)[:200]))
    except ApiError as e:
        expect(name, e.code < 500 and (needle is None or needle.lower() in e.msg.lower()), '%s %s' % (e.code, e.msg))
def no500(name, fn):
    try: fn(); expect(name, True, 'accepted')
    except ApiError as e: expect(name, e.code < 500, '%s %s' % (e.code, e.msg[:150]))

RUN = os.environ.get('RUN', str(int(time.time()) % 100000))
set_clock('2026-02-26T18:00:00Z')
mk = lambda tag, name: signup('%s.%s@atk2.test' % (tag, RUN), 'password123', name)
boss, p1, p2, p3, out = mk('boss', 'Boss'), mk('p1', 'Ann'), mk('p2', 'Bo'), mk('p3', 'Cy'), mk('out', 'Outsider')

def mklg(c, **kw):
    body = {'name': 'Atk2 %s' % RUN, 'season': '2026', 'budget': 500, 'num_players': 4, 'min_bid': 10, 'created_by': c.user['id'], 'draft_status': 'open'}
    body.update(kw); lg = c.post('leagues?select=*', body)[0]
    c.post('league_members', {'league_id': lg['id'], 'user_id': c.user['id'], 'role': 'admin', 'team_name': c.name}, 'return=minimal')
    return lg
lg = mklg(boss); LID = lg['id']
for p in (p1, p2, p3): p.rpc('join_league', p_invite_code=lg['invite_code'])
films = [r.split('\t') for r in sql("select imdb_id, title from universe_films where imdb_id is not null and release_date between '2026-04-01' and '2027-02-01' order by bo desc nulls last limit 40;").splitlines()]

# ── 1. things that touch every league ────────────────────────────────────────
print('\n== global data ==')
for tbl, body in [('universe_films', {'title': 'Fake Blockbuster', 'imdb_id': 'tt9999991', 'release_date': '2026-06-01'}),
                  ('daily_bo', {'film_title': 'x', 'bo_date': '2026-06-01', 'daily_gross': 1e9}),
                  ('gold_derby_odds', {'season': '2027', 'category': 'Best Picture', 'film_title': 'x'}),
                  ('seasons', {'season': '2030'}), ('acquisition_weeks', {'week_start': '2026-06-01'})]:
    refused('commissioner writes %s directly' % tbl, lambda: boss.post(tbl, body))
r = p1.rpc('request_film_add', p_league_id=LID, p_title='<img src=x onerror=alert(1)> Zzyzx Road %s' % RUN)
reqid = r.get('id')
refused('commissioner approves a film into the shared universe', lambda: boss.rpc('resolve_film_add_request', p_request_id=reqid, p_action='add', p_title='Totally Real Film %s' % RUN, p_release_date='2026-07-04', p_imdb_id='tt7777%s' % RUN))
refused('commissioner links a request', lambda: boss.rpc('resolve_film_add_request', p_request_id=reqid, p_action='reject'))
for i in range(6):
    try: p1.rpc('request_film_add', p_league_id=LID, p_title='Spam Film %s %d' % (RUN, i))
    except ApiError as e: last = e
expect('film-request spam capped at 5 pending', 'several films' in last.msg, last.msg)

# ── 2. duplicate league ──────────────────────────────────────────────────────
print('\n== duplicate league ==')
sql("insert into league_picks (league_id, team_name, imdb_id, title, bid, source) values (:'l', 'Ann', :'i', :'t', 50, 'draft');", l=LID, i=films[0][0], t=films[0][1])
try:
    nid = boss.rpc('duplicate_league', p_source_league_id=LID, p_new_name='Run it back', p_new_season=2027)
    n = boss.get('leagues?id=eq.%s&select=season,draft_status,created_by' % nid)[0]
    picks = int(sql("select count(*) from league_picks where league_id = :'l';", l=nid))
    expect('duplicate into next season starts with no films', picks == 0, '%d 2026 films copied into a %s league' % (picks, n['season']))
    expect('duplicate starts with the draft open', n['draft_status'] == 'open', n['draft_status'])
except ApiError as e: expect('duplicate into 2027 works', False, e.msg)
refused('duplicate into an unconfigured season', lambda: boss.rpc('duplicate_league', p_source_league_id=LID, p_new_name='x', p_new_season=2099), 'not open')
ok = 0
for i in range(8):
    try: boss.rpc('duplicate_league', p_source_league_id=LID, p_new_name='Dup %d' % i, p_new_season=2027); ok += 1
    except ApiError as e: pass
expect('duplicate respects 5 leagues a day', ok <= 4, '%d duplicates made' % ok)
refused('player duplicates a league', lambda: p1.rpc('duplicate_league', p_source_league_id=LID, p_new_name='mine', p_new_season=2027), 'admin')
refused('duplicate with a 41+ char name', lambda: boss.rpc('duplicate_league', p_source_league_id=LID, p_new_name='N' * 60, p_new_season=2027))

# ── 3. commissioner edits to the league row ──────────────────────────────────
print('\n== league settings ==')
for label, body, needle in [('2 players', {'num_players': 2}, '3 to 12'), ('13 players', {'num_players': 13}, '3 to 12'),
                            ('fewer seats than members', {'num_players': 3}, 'already has'), ('41-char name', {'name': 'L' * 41}, '40'),
                            ('season change after films drafted', {'season': '2027'}, "can't change"),
                            ('negative budget', {'budget': -100}, None), ('zero min bid', {'min_bid': 0}, None),
                            ('min bid above budget', {'min_bid': 600}, None), ('max bid below min bid', {'max_bid': 5}, None),
                            ('huge budget', {'budget': 2000000000}, None), ('created_by hijack', {'created_by': p1.user['id']}, None),
                            ('invite code set to another league\'s', {'invite_code': 'aaaa'}, None),
                            ('refund rate 500%', {'acq_refund_rate': 5}, None), ('negative acq budget', {'acq_budget_default': -50}, None),
                            ('draft_status nonsense', {'draft_status': 'banana'}, None)]:
    refused('commissioner sets ' + label, lambda: boss.patch('leagues?id=eq.' + LID, body), needle)
v = boss.patch('leagues?id=eq.' + LID, {'name': '  <script>x</script>‮  '})[0]['name']
expect('league rename cleaned', '‮' not in v and v == v.strip(), repr(v))
v = boss.patch('leagues?id=eq.' + LID, {'description': 'D' * 5000, 'sacko_punishment': 'S' * 5000})[0]
expect('description/punishment capped at 280', len(v['description']) <= 280 and len(v['sacko_punishment']) <= 280, (len(v['description']), len(v['sacko_punishment'])))
boss.patch('leagues?id=eq.' + LID, {'name': 'Atk2 %s' % RUN, 'description': None, 'sacko_punishment': None})
sql("update leagues set budget=500, min_bid=10, max_bid=null, acq_refund_rate=0.5, acq_budget_default=100, draft_status='open', invite_code=:'c' where id=:'l';", l=LID, c=lg['invite_code'])

# ── 4. commissioner edits to rosters ─────────────────────────────────────────
print('\n== rosters ==')
refused('pick with a negative price', lambda: boss.post('league_picks', {'league_id': LID, 'team_name': 'Boss', 'imdb_id': films[1][0], 'title': films[1][1], 'bid': -400, 'source': 'draft'}))
refused('pick for a studio not in the league', lambda: boss.post('league_picks', {'league_id': LID, 'team_name': 'Ghost Studio', 'imdb_id': films[2][0], 'title': films[2][1], 'bid': 10, 'source': 'draft'}))
refused('same film owned twice (different title text)', lambda: boss.post('league_picks', {'league_id': LID, 'team_name': 'Boss', 'imdb_id': films[0][0], 'title': films[0][1] + ' ', 'bid': 10, 'source': 'draft'}))
refused('pick for a film outside the season', lambda: boss.post('league_picks', {'league_id': LID, 'team_name': 'Boss', 'imdb_id': sql("select imdb_id from universe_films where release_date < '2026-01-01' and imdb_id is not null limit 1;"), 'title': 'Old film', 'bid': 10, 'source': 'draft'}))
refused('pick NaN price', lambda: boss.post('league_picks', {'league_id': LID, 'team_name': 'Boss', 'imdb_id': films[3][0], 'title': films[3][1], 'bid': 'NaN', 'source': 'draft'}))
sql("delete from league_picks where league_id = :'l';", l=LID)

# ── 5. live draft: validation + races ────────────────────────────────────────
print('\n== live draft ==')
set_clock('2026-03-01T02:00:00Z')
boss.rpc('choose_draft_mode', p_league_id=LID, p_mode='live')
order = [boss.user['id'], p1.user['id'], p2.user['id'], p3.user['id']]
refused('turn order with an outsider in it', lambda: boss.rpc('configure_draft', p_league_id=LID, p_turn_order=order[:3] + [out.user['id']], p_timer_seconds=30, p_soft_close_seconds=10, p_nomination_timeout_seconds=60))
refused('turn order missing a player', lambda: boss.rpc('configure_draft', p_league_id=LID, p_turn_order=order[:3], p_timer_seconds=30, p_soft_close_seconds=10, p_nomination_timeout_seconds=60))
refused('turn order with a player twice', lambda: boss.rpc('configure_draft', p_league_id=LID, p_turn_order=order + [boss.user['id']], p_timer_seconds=30, p_soft_close_seconds=10, p_nomination_timeout_seconds=60))
refused('0-second bid timer', lambda: boss.rpc('configure_draft', p_league_id=LID, p_turn_order=order, p_timer_seconds=0, p_soft_close_seconds=10, p_nomination_timeout_seconds=60))
refused('week-long bid timer', lambda: boss.rpc('configure_draft', p_league_id=LID, p_turn_order=order, p_timer_seconds=604800, p_soft_close_seconds=10, p_nomination_timeout_seconds=60))
boss.rpc('configure_draft', p_league_id=LID, p_turn_order=order, p_timer_seconds=30, p_soft_close_seconds=10, p_nomination_timeout_seconds=60)
refused('player starts the draft', lambda: p1.rpc('start_draft', p_league_id=LID), 'admin')
boss.rpc('start_draft', p_league_id=LID)
refused('nominate out of turn', lambda: p2.rpc('nominate_film', p_league_id=LID, p_imdb_id=films[0][0]))
refused('nominate a film not in the universe', lambda: boss.rpc('nominate_film', p_league_id=LID, p_imdb_id='tt0000000'))
refused('nominate a film outside the season', lambda: boss.rpc('nominate_film', p_league_id=LID, p_imdb_id=sql("select imdb_id from universe_films where release_date < '2026-01-01' and imdb_id is not null limit 1;")))
refused('outsider nominates', lambda: out.rpc('nominate_film', p_league_id=LID, p_imdb_id=films[0][0]))
# race: the nominator double-clicks two films at once
res = []
def nom(f):
    try: res.append(('ok', boss.rpc('nominate_film', p_league_id=LID, p_imdb_id=f)))
    except ApiError as e: res.append(('err', e.msg))
ts = [threading.Thread(target=nom, args=(films[i][0],)) for i in (0, 1)]; [t.start() for t in ts]; [t.join() for t in ts]
act = int(sql("select count(*) from draft_items where league_id = :'l' and status = 'active';", l=LID))
expect('double-nominate race leaves one live film', act == 1, res)
item = sql("select id from draft_items where league_id = :'l' and status = 'active';", l=LID)
for label, amt in [('below min bid', 5), ('zero', 0), ('negative', -10), ('NaN', 'NaN'), ('Infinity', 'Infinity'),
                   ('over the whole budget', 501), ('1e308', 1e308)]:
    refused('bid ' + label, lambda: p1.rpc('place_draft_bid', p_league_id=LID, p_draft_item_id=item, p_amount=amt))
refused('outsider bids', lambda: out.rpc('place_draft_bid', p_league_id=LID, p_draft_item_id=item, p_amount=20))
# race: everyone bids at once, then everyone bids the same next amount at once
def bid(c, a, box):
    try: c.rpc('place_draft_bid', p_league_id=LID, p_draft_item_id=item, p_amount=a); box.append((c.name, a, 'ok'))
    except ApiError as e: box.append((c.name, a, e.msg[:60]))
box = []
ts = [threading.Thread(target=bid, args=(c, 40, box)) for c in (p1, p2, p3)]; [t.start() for t in ts]; [t.join() for t in ts]
wins = [b for b in box if b[2] == 'ok']
expect('three simultaneous $40 bids: only one stands', len(wins) == 1, box)
row = sql("select current_high_bid, current_high_bidder from draft_items where id = :'i';", i=item).split('\t')
expect('high bid recorded once', float(row[0]) == 40, row)
box = []
ts = [threading.Thread(target=bid, args=(c, a, box)) for c, a in ((p1, 41), (p2, 60), (p3, 45))]; [t.start() for t in ts]; [t.join() for t in ts]
hi = float(sql("select current_high_bid from draft_items where id = :'i';", i=item))
expect('racing bids end on the highest accepted', hi == max([a for n, a, s in box if s == 'ok'] or [40]), (hi, box))
refused('resolve while the clock is still running', lambda: p3.rpc('resolve_draft_item', p_league_id=LID, p_draft_item_id=item))
advance(31)
box = []
def resolve(c):
    try: c.rpc('resolve_draft_item', p_league_id=LID, p_draft_item_id=item); box.append('ok')
    except ApiError as e: box.append(e.msg[:60])
ts = [threading.Thread(target=resolve, args=(c,)) for c in (boss, p1, p2, p3)]; [t.start() for t in ts]; [t.join() for t in ts]
n = int(sql("select count(*) from league_picks where league_id = :'l';", l=LID))
expect('four simultaneous resolves create exactly one pick', n == 1, (n, box))
refused('bid on a sold film', lambda: p1.rpc('place_draft_bid', p_league_id=LID, p_draft_item_id=item, p_amount=200))
s = boss.get('draft_sessions?league_id=eq.%s&select=*' % LID)[0]
cur = {c.user['id']: c for c in (boss, p1, p2, p3)}[s['turn_order'][s['current_turn_idx']]]
refused('re-nominate an owned film', lambda: cur.rpc('nominate_film', p_league_id=LID, p_imdb_id=films[0][0] if int(sql("select count(*) from league_picks where league_id=:'l' and imdb_id=:'i';", l=LID, i=films[0][0])) else films[1][0]))
refused('pass someone else\'s turn', lambda: [c for c in (p1, p2, p3) if c is not cur][0].rpc('pass_turn', p_league_id=LID), 'only the current')

# ── 6. membership churn mid-draft / mid-season ───────────────────────────────
print('\n== membership churn ==')
# the player whose turn it is walks out
owner_id = sql("select current_high_bidder from draft_items where id = :'i';", i=item)
winner = {c.user['id']: c for c in (boss, p1, p2, p3)}[owner_id]
refused('a studio with films leaves mid-season', lambda: winner.delete('league_members?league_id=eq.%s&user_id=eq.%s' % (LID, winner.user['id'])), 'owns films')
refused('commissioner removes a studio with films', lambda: boss.delete('league_members?league_id=eq.%s&user_id=eq.%s' % (LID, winner.user['id'])) if winner is not boss else boss.delete('league_members?league_id=eq.%s&user_id=eq.%s' % (LID, boss.user['id'])), 'owns films')
# commissioner leaves their own league
lg3 = mklg(p1, name='Lonely %s' % RUN, num_players=3); p2.rpc('join_league', p_invite_code=lg3['invite_code'])
try:
    p1.delete('league_members?league_id=eq.%s&user_id=eq.%s' % (lg3['id'], p1.user['id']))
    admins = int(sql("select count(*) from league_members where league_id = :'l' and role = 'admin';", l=lg3['id']))
    expect('league is never left without a commissioner', admins >= 1, '%d admins left' % admins)
    expect('next member is promoted', sql("select role from league_members where league_id=:'l' and user_id=:'u';", l=lg3['id'], u=p2.user['id']) == 'admin')
except ApiError as e: expect('sole commissioner cannot just leave', True, e.msg)
# kicked player's films
sql("insert into league_picks (league_id, team_name, imdb_id, title, bid, source) values (:'l', 'Bo', :'i', :'t', 50, 'draft');", l=lg3['id'], i=films[5][0], t=films[5][1])
try:
    p2.delete('league_members?league_id=eq.%s&user_id=eq.%s' % (lg3['id'], p2.user['id']))
    orphan = int(sql("select count(*) from league_picks lp where league_id = :'l' and not exists (select 1 from league_members m where m.league_id = lp.league_id and m.team_name = lp.team_name);", l=lg3['id']))
    expect('leaving a league with films leaves no orphan films', orphan == 0, '%d orphaned picks' % orphan)
except ApiError as e: expect('a player with films cannot just leave', True, e.msg)

# finished leagues: frozen but deletable
lg4 = mklg(p3, name='Done %s' % RUN, num_players=3)
sql("insert into league_picks (league_id, team_name, imdb_id, title, bid, source) values (:'l', 'Cy', :'i', :'t', 50, 'draft'); update leagues set finalized_at = now() where id = :'l';", l=lg4['id'], i=films[7][0], t=films[7][1])
refused('commissioner edits picks after the season is final', lambda: p3.patch('league_picks?league_id=eq.' + lg4['id'], {'bid': 1}), 'final')
refused('commissioner deletes picks after the season is final', lambda: p3.delete('league_picks?league_id=eq.' + lg4['id']), 'final')
p3.delete('leagues?id=eq.' + lg4['id'])
expect('a finished league can still be deleted in one step', sql("select count(*) from leagues where id = :'l';", l=lg4['id']) == '0')
lg5 = p3.post('leagues?select=*', {'name': 'Pick code', 'season': '2026', 'budget': 500, 'num_players': 3, 'min_bid': 10, 'invite_code': 'aaaa', 'created_by': p3.user['id'], 'draft_status': 'open'})[0]
expect('invite codes cannot be hand-picked', lg5['invite_code'] != 'aaaa' and len(lg5['invite_code']) == 8, lg5['invite_code'])
refused('invite code changed later', lambda: p3.patch('leagues?id=eq.' + lg5['id'], {'invite_code': 'bbbb'}), 'server')
refused('short guessable share link', lambda: p3.patch('leagues?id=eq.' + lg5['id'], {'is_public': True, 'share_token': 'abc'}), '16')
# ── 7. acquisitions / refunds / notifications ────────────────────────────────
print('\n== acquisitions ==')
sql("update leagues set acquisitions_enabled = true where id = :'l';", l=LID)
for label, amt in [('NaN', 'NaN'), ('Infinity', 'Infinity'), ('negative', -5), ('huge', 1e12)]:
    refused('acquisition bid ' + label, lambda: p1.rpc('submit_acquisition_bid', p_league_id=LID, p_imdb_id=films[9][0], p_amount=amt))
refused('outsider acquisition bid', lambda: out.rpc('submit_acquisition_bid', p_league_id=LID, p_imdb_id=films[9][0], p_amount=10))
pk = sql("select id from league_picks where league_id = :'l' limit 1;", l=LID)
owner = sql("select team_name from league_picks where id = :'p';", p=pk)
other = [c for c in (boss, p1, p2, p3) if c.name != owner and int(sql("select count(*) from league_members where league_id=:'l' and user_id=:'u' and team_name<>:'t';", l=LID, u=c.user['id'], t=owner))][0]
refused("refund someone else's film", lambda: other.rpc('refund_my_film', p_league_id=LID, p_league_pick_id=int(pk)), 'own')
refused('anon resolves an acquisitions week', lambda: anon.rpc('admin_resolve_acquisitions_week', p_league_id=LID, p_week_id='00000000-0000-0000-0000-000000000000'))

# ── 8. junk input to every RPC ───────────────────────────────────────────────
print('\n== junk input ==')
rpcs = [r.split('\t') for r in sql("""select p.proname, pg_get_function_identity_arguments(p.oid) from pg_proc p where p.pronamespace = 'public'::regnamespace
  and has_function_privilege('authenticated', p.oid, 'execute') and p.prorettype not in ('trigger'::regtype, 'event_trigger'::regtype);""").splitlines()]
JUNK = {'uuid': ['not-a-uuid', None, '00000000-0000-0000-0000-000000000000'], 'text': [None, '', 'x' * 100000, "'; drop table leagues; --", '\u0000nul'],
        'numeric': ['NaN', None, 'abc', -1e308], 'integer': [None, 2**40, 'abc'], 'uuid[]': [None, [], ['bad']], 'text[]': [None, ['x'] * 5000],
        'jsonb': [None, {'a': 'b' * 10000}], 'date': ['not a date', '99999-01-01'], 'bigint': [None, -1], 'timestamp with time zone': ['nope'], 'boolean': ['maybe']}
fivehundreds = []; slow = []
for name, args in rpcs:
    if name in ('finalize_season',): continue
    params = [a.strip().split(' ', 1) for a in args.split(',') if a.strip()]
    for i, (pn, pt) in enumerate(params):
        for j in JUNK.get(pt, [None]):
            body = {}
            for k, (qn, qt) in enumerate(params):
                body[qn] = j if k == i else {'uuid': LID, 'text': 'x', 'numeric': 10, 'integer': 1, 'bigint': 1, 'date': '2026-06-01', 'boolean': True}.get(qt)
            t0 = time.time()
            try: p1.rpc(name, **body)
            except ApiError as e:
                if e.code >= 500: fivehundreds.append('%s(%s=%r): %s %s' % (name, pn, str(j)[:20], e.code, e.msg[:80]))
            except Exception as e: fivehundreds.append('%s(%s): %s' % (name, pn, e))
            if time.time() - t0 > 2: slow.append('%s %.1fs' % (name, time.time() - t0))
expect('no junk input causes a server error', not fivehundreds, '\n   '.join([''] + fivehundreds[:25]))
expect('no junk input takes over 2s', not slow, slow[:10])
alive = anon.get('seasons?select=season')
expect('database still answering after the junk', bool(alive), alive)
sql("delete from league_picks where league_id in (select id from leagues where name like 'Atk2%%' or name like 'Dup %%' or name = 'Run it back');")

bad = [r for r in results if not r[0]]
print('\n%d checks, %d failed' % (len(results), len(bad)))
for b in bad: print('  FAIL', b[1], '--', b[2][:300])
