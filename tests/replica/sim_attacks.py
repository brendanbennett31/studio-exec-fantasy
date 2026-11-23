"""Try to break things the way a hostile or careless player would, through the real API."""
import json, os
from sef import *

results = []
def expect(name, ok, detail=''):
    results.append((ok, name, detail)); print(('PASS ' if ok else 'FAIL ') + name + (('  -- ' + str(detail)[:160]) if detail else ''), flush=True)
def refused(name, fn, needle=None):
    try:
        r = fn(); expect(name, False, 'was ALLOWED: %s' % (str(r)[:150]))
    except ApiError as e:
        expect(name, needle is None or needle.lower() in e.msg.lower(), e.msg)
def empty(name, rows): expect(name, rows == [] or rows is None, rows if rows else '')

set_clock('2026-02-25T18:00:00Z')
mk = lambda tag, name: signup('%s@atk.test' % tag, 'password123', name)
boss = mk('boss', 'Boss'); eve = mk('eve', 'Eve'); p2 = mk('p2', 'Pat'); p3 = mk('p3', 'Quinn')

# ── league creation rules ─────────────────────────────────────────────────────
def mklg(c, **kw):
    body = {'name': 'Atk League', 'season': '2026', 'budget': 500, 'num_players': 3, 'min_bid': 10, 'created_by': c.user['id'], 'draft_status': 'open'}
    body.update(kw); return c.post('leagues?select=*', body)[0]
refused('league name over 40 chars', lambda: mklg(boss, name='X' * 41), '40')
refused('league with 2 players', lambda: mklg(boss, num_players=2), '3 to 12')
refused('league with 13 players', lambda: mklg(boss, num_players=13), '3 to 12')
refused('league for an unconfigured season', lambda: mklg(boss, season='2099'), 'not open')
forged = None
try:
    forged = mklg(eve, created_by=boss.user['id'], name='Forged')
    expect('created_by forced to the real creator', forged['created_by'] == eve.user['id'], forged['created_by'])
except ApiError as e: expect('created_by forged -> refused', True, e.msg)
lg = mklg(boss, name='  <b>Bold</b>‮ league​  ', num_players=3)
expect('league name cleaned of invisible/override chars', lg['name'] == '<b>Bold</b> league', repr(lg['name']))
LID = lg['id']
boss.post('league_members', {'league_id': LID, 'user_id': boss.user['id'], 'role': 'admin', 'team_name': 'Boss'}, 'return=minimal')
for i in range(4): mklg(eve, name='spam %d' % i)
refused('6th league in a day', lambda: mklg(eve, name='spam 5'), '5 leagues a day')

# ── joining ──────────────────────────────────────────────────────────────────
inv = lg['invite_code']
r = p2.rpc('join_league', p_invite_code=inv.upper()); expect('join is case-insensitive', r['joined'])
p3.rpc('join_league', p_invite_code=inv)
refused('4th player in a 3-player league', lambda: eve.rpc('join_league', p_invite_code=inv), 'full')
refused('anon cannot join', lambda: anon.rpc('join_league', p_invite_code=inv))
refused('direct membership insert (bypassing invite)', lambda: eve.post('league_members', {'league_id': LID, 'user_id': eve.user['id'], 'role': 'player', 'team_name': 'Eve'}))
refused('direct admin insert into someone else\'s league', lambda: eve.post('league_members', {'league_id': LID, 'user_id': eve.user['id'], 'role': 'admin', 'team_name': 'Eve'}))

# ── studio names ─────────────────────────────────────────────────────────────
for label, name in [('script tag', '<script>alert(1)</script>'), ('img onerror', '<img src=x onerror=alert(1)>'),
                    ('21 chars', 'A' * 21), ('emoji', 'Popcorn \U0001F37F Pics'), ('only spaces', '     '), ('quote breakout', "x');alert(1);//")]:
    refused('studio name: ' + label, lambda: p2.rpc('rename_my_team', p_league_id=LID, p_new_name=name))
# invisible tricks are stripped rather than refused -- the stored name must come out clean
for label, name, want in [('right-to-left override', 'Evil\u202eStudio', 'EvilStudio'), ('zalgo', 'Z\u0334\u0321a\u0337l\u0336g\u0338o\u0335', 'Zalgo'),
                          ('newline', 'Two\nLines', 'Two Lines'), ('tab', 'Tab\tName', 'Tab Name'), ('zero-width space', 'Zero\u200bWidth', 'ZeroWidth')]:
    p2.rpc('rename_my_team', p_league_id=LID, p_new_name=name)
    got = p2.get('league_members?league_id=eq.%s&user_id=eq.%s&select=team_name' % (LID, p2.user['id']))[0]['team_name']
    expect('studio name: %s is stripped clean' % label, got == want, repr(got))
p2.rpc('rename_my_team', p_league_id=LID, p_new_name="Pat's Pictures!")
expect("valid name with apostrophe/punctuation accepted", p2.get('league_members?league_id=eq.%s&user_id=eq.%s&select=team_name' % (LID, p2.user['id']))[0]['team_name'] == "Pat's Pictures!")
refused('duplicate studio name (different case)', lambda: p3.rpc('rename_my_team', p_league_id=LID, p_new_name="PAT'S PICTURES!"), 'taken')
refused('rename by direct PATCH (orphans picks)', lambda: p2.patch('league_members?league_id=eq.%s&user_id=eq.%s' % (LID, p2.user['id']), {'team_name': 'Sneaky'}), 'rename')
refused('color outside the palette (RPC)', lambda: p2.rpc('set_my_team_color', p_league_id=LID, p_color='red;background:url(//evil)'), 'colors')
refused('color outside the palette (direct PATCH)', lambda: p2.patch('league_members?league_id=eq.%s&user_id=eq.%s' % (LID, p2.user['id']), {'color': 'url(javascript:alert(1))'}), 'colors')
p2.rpc('set_my_team_color', p_league_id=LID, p_color='#3987e5')
refused('color already taken', lambda: p3.rpc('set_my_team_color', p_league_id=LID, p_color='#3987E5'), 'taken')

# ── display names ────────────────────────────────────────────────────────────
long = signup('longname@atk.test', 'password123', '<svg onload=alert(1)>' + 'W' * 300 + '‮')
pn = long.get('profiles?id=eq.%s&select=display_name' % long.user['id'])[0]['display_name']
expect('signup display name capped at 24 + cleaned', len(pn) <= 24 and '‮' not in pn, repr(pn))
v = p3.rpc('set_my_display_name', p_name='  Quinn​  the\tGreat ' + 'x' * 40)
expect('set_my_display_name cleans + caps', v == ('Quinn the Great ' + 'x' * 40)[:24], repr(v))
jn = signup('joiner@atk.test', 'password123', '🎬🎬<b>')
lg2 = mklg(boss, name='Second', num_players=4); boss.post('league_members', {'league_id': lg2['id'], 'user_id': boss.user['id'], 'role': 'admin', 'team_name': 'Boss'}, 'return=minimal')
jn.rpc('join_league', p_invite_code=lg2['invite_code'])
tn = jn.get('league_members?league_id=eq.%s&user_id=eq.%s&select=team_name' % (lg2['id'], jn.user['id']))[0]['team_name']
expect('join with an emoji/HTML display name gets a valid studio name', tn and all(c.isalnum() or c in " .,'’&!?:-" for c in tn), repr(tn))

# ── escalation and cross-league snooping ─────────────────────────────────────
refused('player promotes self to admin', lambda: p2.patch('league_members?league_id=eq.%s&user_id=eq.%s' % (LID, p2.user['id']), {'role': 'admin'}), 'admin')
refused('player gives self budget credit', lambda: p2.patch('league_members?league_id=eq.%s&user_id=eq.%s' % (LID, p2.user['id']), {'acq_remainder_credit': 999}), 'server')
rows = p2.patch('leagues?id=eq.' + LID, {'budget': 99999})
expect('player cannot edit league settings', rows == [], rows)
refused('player inserts a pick', lambda: p2.post('league_picks', {'league_id': LID, 'team_name': "Pat's Pictures!", 'title': 'Free film', 'bid': 1}))
refused('player chooses draft mode', lambda: p2.rpc('choose_draft_mode', p_league_id=LID, p_mode='live'), 'admin')
refused('player finalizes a season', lambda: p2.rpc('finalize_season', p_season='2026'), 'site admin')
refused('player writes Oscar results', lambda: p2.post('oscar_results', {'season': '2026', 'category': 'Best Picture', 'film_title': 'Mine'}))
rows = p2.patch('seasons?season=eq.2026', {'results_final': True})
expect('player cannot touch the season calendar', rows == [], rows)
refused('admin cannot fake finalized_at', lambda: boss.patch('leagues?id=eq.' + LID, {'finalized_at': '2026-01-01T00:00:00Z'}), 'server')
empty("outsider can't see another league's members", eve.get('league_members?league_id=eq.' + LID))
empty("outsider can't see another league's picks", eve.get('league_picks?league_id=eq.' + LID))
empty("outsider can't see another league", eve.get('leagues?id=eq.' + LID + '&select=id'))
refused("outsider can't read standings of a private league", lambda: eve.rpc('league_standings', p_league_id=LID), 'member')
empty("anon can't see a private league's results", anon.get('league_results?league_id=eq.' + LID))
empty("profiles never readable by others", eve.get('profiles?id=eq.' + boss.user['id']))
refused('anon cannot read client_errors', lambda: anon.get('client_errors?select=*'))

# ── error reports can't be used to flood or snoop ────────────────────────────
for i in range(320):
    try: anon.post('client_errors', {'page': '/x', 'message': 'flood %d' % i + 'Z' * 900}, 'return=minimal')
    except ApiError: pass
n = int(sql("select count(*) from client_errors;")); mx = int(sql("select coalesce(max(length(message)),0) from client_errors;"))
expect('error-report flood capped at 300/hour', n <= 300, n)
expect('error-report message clamped to 500 chars', mx <= 500, mx)

# ── finished leagues are frozen ──────────────────────────────────────────────
sql("update leagues set finalized_at = now() where id = :'l';", l=LID)
refused('rename after the season is final', lambda: p2.rpc('rename_my_team', p_league_id=LID, p_new_name='Late Change'), 'over')
refused('join after the season is final', lambda: jn.rpc('join_league', p_invite_code=inv), None)
sql("update leagues set acquisitions_enabled = true, weekend_picks_enabled = true where id = :'l';", l=LID)
refused('acquisitions declaration after the season is final', lambda: p2.rpc('declare_for_acquisitions', p_league_id=LID))
refused('weekend pick after the season is final', lambda: p2.rpc('submit_weekend_picks', p_league_id=LID, p_pick1='A', p_pick2='B', p_pick3='C'))

bad = [r for r in results if not r[0]]
print('\n%d checks, %d failed' % (len(results), len(bad)))
for b in bad: print('  FAIL', b[1], '--', b[2][:200])
