"""Phase 1: N players sign up, one creates a league, the rest join by invite code, and they run a full live auction draft."""
import json, random, sys, os
from sef import *

N = int(sys.argv[1]) if len(sys.argv) > 1 else 6
TAG = sys.argv[2] if len(sys.argv) > 2 else 'main'
ROSTER = int(sys.argv[3]) if len(sys.argv) > 3 else max(4, min(10, 48 // N))
SEASON = '2026'
random.seed(hash(TAG) & 0xffff)
log = []
def note(*a):
    s = ' '.join(str(x) for x in a); log.append(s); print(s, flush=True)

NAMES = ['Ava', 'Ben', 'Cleo', 'Dev', 'Elle', 'Finn', 'Gia', 'Hank', 'Iris', 'Jax', 'Kira', 'Leo', 'Mia', 'Nico', 'Omar', 'Pia',
         'Quin', 'Rae', 'Sol', 'Tess', 'Uma', 'Vic', 'Wren', 'Xan', 'Yara', 'Zed', 'Abe', 'Bo', 'Cy', 'Dot']
STUDIOS = ['Nightjar Pictures', 'Lantern Films', 'Copper Reel', 'Paper Moon', 'Velvet Static', 'Harbor Light', 'Sundial',
           'Blue Hour Co', 'Kestrel Studios', 'Marquee Ghost', 'Oxbow Films', 'Red Ladder', 'Small Hours', 'Tin Star',
           'Undertow', 'Wild Pine', 'Arcade Fire Films', 'Bramble', 'Cinder', 'Driftwood', 'Ember', 'Foxglove', 'Gilded',
           'Hollow Oak', 'Ironwood', 'Juniper', 'Kite Hill', 'Larkspur', 'Moonrise', 'Nettle']

set_clock('2026-02-20T18:00:00Z')
players = [signup('%s.%s@sim.test' % (NAMES[i].lower(), TAG), 'password123', NAMES[i]) for i in range(N)]
admin = players[0]
note('signed up', N, 'players; clock', sim_now())

# ---- create league exactly like dashboard.html ----
lg = admin.post('leagues?select=*', {
    'name': 'Sim League %s (%d players)' % (TAG, N), 'season': SEASON, 'budget': 500, 'num_players': min(N, 12), 'min_bid': 10, 'max_bid': None,
    'oscar_nom_bonus': 25, 'oscar_win_bonus': 25, 'bp_bonus': 50, 'festival_picks': True, 'is_public': False,
    'share_token': os.urandom(9).hex(), 'draft_open_date': None, 'draft_close_date': None, 'season_end_date': None,
    'created_by': admin.user['id'], 'draft_status': 'open'})[0]
LID = lg['id']
admin.post('league_members', {'league_id': LID, 'user_id': admin.user['id'], 'role': 'admin', 'team_name': admin.name}, 'return=minimal')
note('league', LID, 'invite', lg['invite_code'])
for i, p in enumerate(players[1:], start=2):
    if i <= 12:
        r = p.rpc('join_league', p_invite_code=lg['invite_code'])
        assert r['joined'], r
    else:
        # beyond the 12-player cap: forced in behind the rules, only to see where the pages break
        sql("set session_replication_role = replica; insert into league_members (league_id, user_id, role, team_name) values (:'l', :'u', 'player', :'t');",
            l=LID, u=p.user['id'], t=p.name)
if N > 12:
    sql("set session_replication_role = replica; update leagues set num_players = :'n' where id = :'l';", n=str(N), l=LID)
# everyone renames to a studio name like a real player would
for i, p in enumerate(players):
    p.rpc('rename_my_team', p_league_id=LID, p_new_name=STUDIOS[i])
    p.team = STUDIOS[i]
admin.patch('leagues?id=eq.' + LID, {'acquisitions_enabled': True, 'weekend_picks_enabled': True}, 'return=minimal')
note('members:', len(admin.get('league_members?league_id=eq.%s&select=team_name' % LID)))

# ---- the film pool + the simulator's hidden "true" box office ----
sql("create table if not exists sim.truth (imdb_id text primary key, title text, release_date date, final_bo numeric, real boolean);")
films = json.loads(sql("select coalesce(json_agg(f), '[]') from (select imdb_id, title, release_date, bo from universe_films "
                       "where imdb_id is not null and release_date between '2026-03-16' and '2027-03-14') f;"))
rng = random.Random(7)
for f in films:
    known = f['release_date'] <= '2026-11-10' and (f['bo'] or 0) > 0
    final = float(f['bo']) if known else round(rng.lognormvariate(17.4, 1.15))  # median ~$36M, long tail
    sql("insert into sim.truth values (:'i', :'t', :'d', :'b', :'k') on conflict (imdb_id) do nothing;",
        i=f['imdb_id'], t=f['title'], d=f['release_date'], b=str(final), k=str(known).lower())
truth = {r.split('\t')[0]: (r.split('\t')[1], float(r.split('\t')[2])) for r in sql("select imdb_id, title, final_bo from sim.truth;").splitlines()}
note('pool:', len(truth), 'eligible films (real BO for', sql("select count(*) from sim.truth where real;"), ')')

# ---- live draft ----
set_clock('2026-03-01T02:00:00Z')  # Saturday evening PT, before the season window opens
admin.rpc('choose_draft_mode', p_league_id=LID, p_mode='live')
order = [p.user['id'] for p in players]; random.shuffle(order)
admin.rpc('configure_draft', p_league_id=LID, p_turn_order=order, p_timer_seconds=30, p_soft_close_seconds=10, p_nomination_timeout_seconds=60)
admin.rpc('start_draft', p_league_id=LID)
by_id = {p.user['id']: p for p in players}
# each player values films with their own noise; total league budget ~ maps to total pool value
scale = (500 * N) / sum(sorted((v for _, v in truth.values()), reverse=True)[:N * ROSTER]) * 1e6
val = {p.user['id']: {i: max(1, v / 1e6 * scale * random.uniform(0.6, 1.5)) for i, (_, v) in truth.items()} for p in players}
owned = {p.user['id']: 0 for p in players}; spent = {p.user['id']: 0 for p in players}
taken = set(); items = 0; passes = 0
while True:
    s = admin.get('draft_sessions?league_id=eq.%s&select=*' % LID)[0]
    if s['status'] != 'active': break
    cur = s['turn_order'][s['current_turn_idx']]; p = by_id[cur]
    if all(owned[u] >= ROSTER for u in owned) or passes > N * 2: break
    if owned[cur] >= ROSTER or 500 - spent[cur] < 10:
        p.rpc('pass_turn', p_league_id=LID); passes += 1; continue
    passes = 0
    choices = sorted((i for i in truth if i not in taken), key=lambda i: -val[cur][i])
    if not choices: break
    pick = choices[0] if random.random() < 0.7 else random.choice(choices[:12])
    try: item = p.rpc('nominate_film', p_league_id=LID, p_imdb_id=pick)
    except ApiError as e:
        note('  nominate refused', truth[pick][0], e.msg); taken.add(pick); continue
    taken.add(pick); items += 1
    # bidding war
    high, holder = None, None
    for _ in range(200):
        moved = False
        for b in random.sample(players, len(players)):
            u = b.user['id']
            if u == holder or owned[u] >= ROSTER: continue
            reserve = (ROSTER - owned[u] - 1) * 10
            cap = min(val[u][pick], 500 - spent[u] - reserve)
            nxt = 10 if high is None else high + random.choice([1, 1, 2, 5])
            if nxt <= cap:
                b.rpc('place_draft_bid', p_league_id=LID, p_draft_item_id=item, p_amount=nxt)
                high, holder, moved = nxt, u, True
        if not moved: break
    advance(31)
    p.rpc('resolve_draft_item', p_league_id=LID, p_draft_item_id=item)
    if holder: owned[holder] += 1; spent[holder] += high
note('draft items nominated:', items)
admin.rpc('admin_end_draft', p_league_id=LID)
rows = admin.get('league_picks?league_id=eq.%s&select=team_name,bid' % LID)
by = {}
for r in rows: by.setdefault(r['team_name'], []).append(float(r['bid']))
for t, b in sorted(by.items()): note('  %-18s %2d films  $%dM spent' % (t, len(b), sum(b)))
mem = admin.get('league_members?league_id=eq.%s&select=team_name,acq_remainder_credit' % LID)
note('remainder credits:', {m['team_name']: float(m['acq_remainder_credit']) for m in mem})
json.dump({'league': LID, 'invite': lg['invite_code'], 'tag': TAG, 'N': N,
           'players': [{'email': '%s.%s@sim.test' % (NAMES[i].lower(), TAG), 'name': NAMES[i], 'team': STUDIOS[i], 'id': players[i].user['id']} for i in range(N)]},
          open(os.path.join(HERE, 'state_%s.json' % TAG), 'w'), indent=1)
