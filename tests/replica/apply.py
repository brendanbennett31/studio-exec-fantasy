"""Apply one repo migration to the running replica (with the local sim clock rewrite)."""
import re, sys, os, subprocess
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sef import PSQL
for path in sys.argv[1:]:
    body = open(path).read()
    body = re.sub(r'\bnow\(\)', 'sim.now()', body, flags=re.I)
    body = re.sub(r'\bcurrent_date\b', 'sim.today()', body, flags=re.I)
    tmp = os.path.join(os.path.dirname(os.path.abspath(__file__)), '_apply.sql')
    open(tmp, 'w').write(body)
    env = dict(os.environ, PGOPTIONS='-c client_min_messages=warning')
    p = subprocess.run([PSQL, '-h', '127.0.0.1', '-p', '54329', '-U', 'postgres', '-d', 'sef', '-X', '-v', 'ON_ERROR_STOP=1', '-f', tmp],
                       capture_output=True, text=True, env=env, stdin=subprocess.DEVNULL)
    print(os.path.basename(path), 'OK' if p.returncode == 0 else 'FAILED')
    print(p.stdout[-1500:], p.stderr[-1500:])
