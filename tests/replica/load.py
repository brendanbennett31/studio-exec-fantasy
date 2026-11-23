"""Rebuild the local SEF replica: wipe DB, Supabase bootstrap, live schema export, repo migrations after 066 (optional)."""
import csv, subprocess, sys, os, re
HERE = os.path.dirname(os.path.abspath(__file__))
PSQL = os.environ.get('SEF_PSQL', 'psql')  # any psql 14+ client
CSV = os.environ.get('SEF_SCHEMA_CSV', os.path.join(HERE, 'sef_schema.csv'))

def psql(sql, db='postgres', stop=True):
    import tempfile
    with tempfile.NamedTemporaryFile('w', suffix='.sql', dir=HERE, delete=False) as fh:
        fh.write(sql); path = fh.name
    args = [PSQL, '-h', '127.0.0.1', '-p', '54329', '-U', 'postgres', '-d', db, '-X', '-q', '-f', path]
    if stop: args += ['-v', 'ON_ERROR_STOP=1']
    env = dict(os.environ, PGOPTIONS='-c client_min_messages=warning')
    p = subprocess.run(args, capture_output=True, text=True, env=env)
    os.unlink(path)
    return p.returncode, p.stdout, p.stderr

def run_batch(stmts, db):
    """Run statements one block at a time in a single psql session; return list of (key, error)."""
    script = ['set check_function_bodies = off;']
    for i, (k, s) in enumerate(stmts):
        script.append("\\echo '@@%d'" % i)
        script.append(s.rstrip().rstrip(';') + ';')
    code, out, err = psql('\n'.join(script), db, stop=False)
    # psql prints errors to stderr; correlate by re-running failures individually
    if 'ERROR' not in err:
        return []
    fails = []
    for k, s in stmts:
        c, o, e = psql('set check_function_bodies = off;\n' + s.rstrip().rstrip(';') + ';', db)
        if c != 0 and 'already exists' not in e:
            fails.append((k, e.strip().splitlines()[0] if e.strip() else 'error'))
    return fails

def main():
    psql("drop database if exists sef with (force);")
    psql("create database sef;")
    for r in ['anon', 'authenticated', 'service_role', 'authenticator']:
        psql("do $$ begin if exists (select 1 from pg_roles where rolname='%s') then execute 'drop owned by %s cascade'; end if; end $$;" % (r, r), 'sef')
    c, o, e = psql("do $$ begin if not exists (select 1 from pg_roles where rolname='anon') then raise notice 'fresh'; end if; end $$;", 'sef')
    boot = open(os.path.join(HERE, 'bootstrap.sql')).read()
    if 'fresh' not in e:
        boot = '\n'.join(l for l in boot.splitlines() if not l.startswith(('create role', 'grant anon, authenticated')))
    c, o, e = psql(boot, 'sef')
    if c: print('BOOTSTRAP FAILED', e); sys.exit(1)

    rows = list(csv.DictReader(open(CSV)))
    rows = [r for r in rows if r['ord'] != '10']
    # local-only: route every clock read through the simulator's dial
    for r in rows:
        if r['ord'] in ('30', '80'):
            r['ddl'] = re.sub(r'\bnow\(\)', 'sim.now()', r['ddl'], flags=re.I)
            r['ddl'] = re.sub(r'\bcurrent_date\b', 'sim.today()', r['ddl'], flags=re.I)
    by = {}
    for r in rows: by.setdefault(int(r['ord']), []).append((r['k'], r['ddl']))
    total_fail = []
    for ord_ in sorted(by):
        fails = run_batch(by[ord_], 'sef')
        # retry once (ordering inside a group, e.g. views/functions depending on each other)
        if fails:
            keys = {k for k, _ in fails}
            fails = run_batch([x for x in by[ord_] if x[0] in keys], 'sef')
        total_fail += [(ord_, k, e) for k, e in fails]
        print('ord %3d: %3d stmts, %d failed' % (ord_, len(by[ord_]), len(fails)))
    for f in total_fail: print('  FAIL', f)

    # repo migrations newer than the export (none yet; new ones get appended here)
    extra = [a for a in sys.argv[1:]]
    for path in extra:
        body = open(path).read()
        body = re.sub(r'\bnow\(\)', 'sim.now()', body, flags=re.I)        # local-only clock dial
        body = re.sub(r'\bcurrent_date\b', 'sim.today()', body, flags=re.I)
        c, o, e = psql(body, 'sef')
        print('migration', os.path.basename(path), 'OK' if c == 0 else 'FAILED: ' + e.strip()[:600]); print(o[-800:])
    psql("notify pgrst, 'reload schema';", 'sef')

if __name__ == '__main__':
    main()
