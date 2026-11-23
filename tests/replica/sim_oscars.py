"""Phase 3: Oscar nominations (late Jan) and winners (Oscar Sunday), entered once by the site admin;
then the daily finalize job crowns every league of the season."""
import json, sys
from sef import *
SEASON = '2026'; GD_SEASON = '2027'
stage = sys.argv[1] if len(sys.argv) > 1 else 'all'

sql("insert into auth.users (email, encrypted_password) values ('siteadmin@sim.test', 'x') on conflict do nothing;")
sql("update profiles set is_admin = true where email = 'siteadmin@sim.test';")
sql("update auth.users set encrypted_password = encode(sha256(('sef-local:' || 'password123')::bytea), 'hex') where email = 'siteadmin@sim.test';")
boss = signup('siteadmin@sim.test', 'password123', 'Site Admin')

odds = json.loads(sql("select json_agg(o) from gold_derby_odds o where season = :'s';", s=GD_SEASON))
uni = {r.split('\t')[0].lower(): r.split('\t')[1] for r in sql("select title, imdb_id from universe_films where imdb_id is not null;").splitlines()}
by_cat = {}
for o in odds: by_cat.setdefault(o['category'], []).append(o)

if stage in ('noms', 'all'):
    set_clock('2027-01-22T14:00:00Z')
    # a regular player must NOT be able to write results
    try:
        signup('ava.main@sim.test', 'password123', 'Ava').post('oscar_results', {'season': SEASON, 'category': 'Best Picture', 'film_title': 'Hack'})
        print('!! player could insert oscar_results')
    except ApiError as e: print('player blocked from oscar_results:', e.code)
    n = 0
    for cat, rows in by_cat.items():
        slots = 10 if cat == 'Best Picture' else 5
        for o in sorted(rows, key=lambda r: -(r['nom_odds'] or 0))[:slots]:
            boss.post('oscar_results', {'season': SEASON, 'category': cat, 'imdb_id': uni.get(o['film_title'].lower()),
                                        'film_title': o['film_title'], 'performer': o.get('performer_name')}, 'return=minimal')
            n += 1
    print('nominations entered:', n, 'across', len(by_cat), 'categories; unmatched to Universe:',
          sql("select count(*) from oscar_results where season = :'s' and imdb_id is null;", s=SEASON))

if stage in ('wins', 'all'):
    set_clock('2027-03-15T07:00:00Z')  # Oscar night, 11pm PT
    for cat, rows in by_cat.items():
        nominated = boss.get("oscar_results?season=eq.%s&category=eq.%s&select=id,film_title,performer" % (SEASON, urlq(cat)))
        best = max(rows, key=lambda r: (r['win_odds'] or 0, r['nom_odds'] or 0))
        win = next((x for x in nominated if x['film_title'].lower() == best['film_title'].lower()), nominated[0] if nominated else None)
        if win: boss.patch('oscar_results?id=eq.%d' % win['id'], {'is_winner': True}, 'return=minimal')
    try:
        boss.patch('oscar_results?season=eq.%s&category=eq.Best%%20Picture&is_winner=eq.false' % SEASON, {'is_winner': True}, 'return=minimal')
        print('!! second Best Picture winner accepted')
    except ApiError as e: print('second winner refused:', e.msg)
    print('winners:', sql("select count(*) from oscar_results where season = :'s' and is_winner;", s=SEASON))
    boss.patch('seasons?season=eq.' + SEASON, {'results_final': True}, 'return=minimal')
    # the daily Apps Script job
    print('finalize before Sunday passes? ->', end=' ')
    set_clock('2027-03-15T16:00:00Z')
    print(json.dumps(svc.rpc('finalize_season', p_season=SEASON))[:600])
