"""Tiny client for driving the local SEF replica the same way the site and Apps Script do."""
import json, os, subprocess, urllib.request, urllib.error, urllib.parse, http.client as http_client
urlq = lambda s: urllib.parse.quote(s, safe="")

GW = os.environ.get('GW', 'http://localhost:54321')
PUB = 'sb_publishable_HOd_kJ4JcmD2srkGPyjEPA_2LIzKFxG'
SECRET = 'sb_secret_local_replica'
HERE = os.path.dirname(os.path.abspath(__file__))
PSQL = os.environ.get('SEF_PSQL', 'psql')  # any psql 14+ client

class ApiError(Exception):
    def __init__(self, code, body): self.code, self.body = code, body; super().__init__('%s %s' % (code, body[:300]))
    @property
    def msg(self):
        try: return json.loads(self.body).get('message') or json.loads(self.body).get('msg') or self.body
        except Exception: return self.body

def http(method, path, body=None, headers=None, _tries=6):
    import time
    for i in range(_tries):
        try: return _http(method, path, body, headers)
        except ApiError as e:
            if e.code == 503 and i < _tries - 1: time.sleep(1.5); continue
            raise
        except (http_client.HTTPException, ConnectionError, urllib.error.URLError) as e:
            if i < _tries - 1: time.sleep(0.5); continue
            raise

def _http(method, path, body=None, headers=None):
    data = json.dumps(body).encode() if body is not None else None
    h = {'Content-Type': 'application/json'}; h.update(headers or {})
    req = urllib.request.Request(GW + path, data=data, method=method, headers=h)
    try:
        r = urllib.request.urlopen(req); raw = r.read().decode()
        return r.status, (json.loads(raw) if raw.strip() else None), r.headers
    except urllib.error.HTTPError as e:
        raise ApiError(e.code, e.read().decode())

class Client:
    def __init__(self, key=PUB, token=None): self.key, self.token, self.user = key, token, None
    def hdr(self, extra=None):
        h = {'apikey': self.key, 'Authorization': 'Bearer ' + (self.token or self.key)}
        h.update(extra or {}); return h
    def get(self, path): return http('GET', '/rest/v1/' + path, headers=self.hdr())[1]
    def post(self, path, body, prefer='return=representation'): return http('POST', '/rest/v1/' + path, body, self.hdr({'Prefer': prefer}))[1]
    def patch(self, path, body, prefer='return=representation'): return http('PATCH', '/rest/v1/' + path, body, self.hdr({'Prefer': prefer}))[1]
    def delete(self, path): return http('DELETE', '/rest/v1/' + path, headers=self.hdr({'Prefer': 'return=representation'}))[1]
    def rpc(self, name, **args): return http('POST', '/rest/v1/rpc/' + name, args, self.hdr())[1]

def signup(email, password, name):
    try: _, s, _ = http('POST', '/auth/v1/token?grant_type=password', {'email': email, 'password': password}, {'apikey': PUB})
    except ApiError:
        _, s, _ = http('POST', '/auth/v1/signup', {'email': email, 'password': password, 'data': {'display_name': name}}, {'apikey': PUB})
    c = Client(token=s['access_token']); c.user = s['user']; c.session = s; c.name = name
    return c

anon = Client()
svc = Client(key=SECRET)

def sql(q, **v):
    args = [PSQL, '-h', '127.0.0.1', '-p', '54329', '-U', 'postgres', '-d', 'sef', '-X', '-q', '-At', '-v', 'ON_ERROR_STOP=1', '-F', '\t']
    for k, val in v.items(): args += ['-v', '%s=%s' % (k, val)]
    p = subprocess.run(args, input=q, capture_output=True, text=True)
    if p.returncode: raise RuntimeError(p.stderr.strip())
    return p.stdout.strip()

def set_clock(iso):
    sql("update sim.clock set offset_s = extract(epoch from (:'t'::timestamptz - now()));", t=iso)
def advance(seconds):
    sql("update sim.clock set offset_s = offset_s + :'s';", s=str(seconds))
def sim_now(): return sql("select sim.now();")
