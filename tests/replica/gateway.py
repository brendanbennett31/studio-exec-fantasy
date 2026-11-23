"""Local stand-in for the Supabase gateway: serves the repo's pages, proxies /rest/v1 to PostgREST,
emulates the GoTrue endpoints the pages use, and exposes a simulation clock. Local testing only."""
import base64, hashlib, hmac, json, os, re, subprocess, sys, time, uuid, urllib.request, urllib.error
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.environ.get('SEF_REPO', os.path.abspath(os.path.join(HERE, '..', '..')))
PSQL = os.environ.get('SEF_PSQL', 'psql')  # any psql 14+ client
PORT = int(os.environ.get('GW_PORT', '54321'))
PGRST = 'http://127.0.0.1:54330'
SECRET = b'local-replica-jwt-secret-not-used-anywhere-else-0123456789'
LIVE_URL = 'https://fymkwkbatklfynnhxrsf.supabase.co'
PUBLISHABLE = 'sb_publishable_HOd_kJ4JcmD2srkGPyjEPA_2LIzKFxG'
LOCAL_SECRET_KEY = 'sb_secret_local_replica'
REFRESH = {}  # refresh_token -> user id

def b64(b): return base64.urlsafe_b64encode(b).rstrip(b'=').decode()
def jwt(claims):
    h = b64(json.dumps({'alg': 'HS256', 'typ': 'JWT'}).encode()); p = b64(json.dumps(claims).encode())
    s = b64(hmac.new(SECRET, (h + '.' + p).encode(), hashlib.sha256).digest())
    return h + '.' + p + '.' + s
def jwt_claims(tok):
    try:
        h, p, s = tok.split('.')
        if not hmac.compare_digest(b64(hmac.new(SECRET, (h + '.' + p).encode(), hashlib.sha256).digest()), s): return None
        c = json.loads(base64.urlsafe_b64decode(p + '=' * (-len(p) % 4)))
        if c.get('exp', 0) < time.time(): return None
        return c
    except Exception: return None
ANON_JWT = jwt({'role': 'anon', 'iss': 'local', 'exp': 4102444800})
SERVICE_JWT = jwt({'role': 'service_role', 'iss': 'local', 'exp': 4102444800})

def q(sql, **vars):
    args = [PSQL, '-h', '127.0.0.1', '-p', '54329', '-U', 'postgres', '-d', 'sef', '-X', '-q', '-At', '-v', 'ON_ERROR_STOP=1']
    for k, v in vars.items(): args += ['-v', '%s=%s' % (k, v)]
    p = subprocess.run(args, input=sql, capture_output=True, text=True)
    if p.returncode: raise RuntimeError(p.stderr.strip())
    return p.stdout.strip()

def pw_hash(pw): return hashlib.sha256(('sef-local:' + pw).encode()).hexdigest()
def user_json(uid):
    r = q("select row_to_json(u) from (select id, email, raw_user_meta_data, created_at from auth.users where id = :'id') u;", id=uid)
    if not r: return None
    u = json.loads(r)
    return {'id': u['id'], 'aud': 'authenticated', 'role': 'authenticated', 'email': u['email'],
            'user_metadata': u['raw_user_meta_data'] or {}, 'app_metadata': {'provider': 'email'},
            'created_at': u['created_at'], 'email_confirmed_at': u['created_at']}
def session(uid):
    now = int(time.time()); exp = now + 3600
    rt = uuid.uuid4().hex; REFRESH[rt] = uid
    user = user_json(uid)
    tok = jwt({'sub': uid, 'role': 'authenticated', 'aud': 'authenticated', 'email': user['email'], 'exp': exp + 7 * 86400, 'iat': now})
    off = int(float(q("select offset_s from sim.clock;") or 0))  # the page's clock runs on sim time
    return {'access_token': tok, 'token_type': 'bearer', 'expires_in': 3600, 'expires_at': exp + off, 'refresh_token': rt, 'user': user}

INJECT = """<script>/*local-replica harness*/(function(){
  try{var x=new XMLHttpRequest();x.open('GET','/__sim/clock',false);x.send();var off=JSON.parse(x.responseText).offset_ms||0;}catch(e){var off=0;}
  window.__SIM_OFFSET_MS=off; if(!off) return;
  var R=Date; function D(){ if(!(this instanceof D)) return new R(R.now()+off).toString();
    var a=[].slice.call(arguments); if(a.length===0) return new R(R.now()+off); return new (Function.prototype.bind.apply(R,[null].concat(a)))(); }
  D.prototype=R.prototype; D.now=function(){return R.now()+off}; D.parse=R.parse; D.UTC=R.UTC; window.Date=D;
})();
window.__errs=[]; window.addEventListener('error',function(e){window.__errs.push(String(e.message))});
window.addEventListener('unhandledrejection',function(e){window.__errs.push('rejection: '+String(e.reason&&e.reason.message||e.reason))});
</script>"""

ROUTES = {'/': 'index.html', '/league': 'league.html', '/dashboard': 'dashboard.html', '/reset-password': 'reset-password.html',
          '/join': 'join.html', '/about': 'about.html', '/universe': 'universe.html', '/wrapped': 'wrapped.html', '/landing': 'landing.html'}

class H(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.0'
    def log_message(self, *a): pass
    def send(self, code, body=b'', ctype='application/json', extra=None):
        if isinstance(body, (dict, list)): body = json.dumps(body).encode()
        if isinstance(body, str): body = body.encode()
        self.send_response(code)
        self.send_header('Content-Type', ctype); self.send_header('Content-Length', str(len(body)))
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Headers', '*'); self.send_header('Access-Control-Allow-Methods', '*')
        self.send_header('Access-Control-Expose-Headers', 'Content-Range')
        for k, v in (extra or {}).items(): self.send_header(k, v)
        self.end_headers(); self.wfile.write(body)
    def body(self):
        n = int(self.headers.get('Content-Length') or 0)
        return self.rfile.read(n) if n else b''
    def do_OPTIONS(self): self.send(204, b'')
    def do_GET(self): self.route('GET')
    def do_POST(self): self.route('POST')
    def do_PATCH(self): self.route('PATCH')
    def do_PUT(self): self.route('PUT')
    def do_DELETE(self): self.route('DELETE')
    def do_HEAD(self): self.route('HEAD')

    def route(self, m):
        u = urlparse(self.path)
        try:
            if u.path.startswith('/rest/v1/'): return self.rest(m, u)
            if u.path.startswith('/auth/v1/'): return self.auth(m, u)
            if u.path == '/__sim/clock':
                if m == 'POST':
                    b = json.loads(self.body() or b'{}')
                    if 'set' in b:  # absolute ISO time
                        q("update sim.clock set offset_s = extract(epoch from (:'t'::timestamptz - now()));", t=b['set'])
                    elif 'offset_s' in b:
                        q("update sim.clock set offset_s = :'o';", o=str(float(b['offset_s'])))
                o = float(q("select offset_s from sim.clock;") or 0)
                return self.send(200, {'offset_ms': int(o * 1000), 'now': q("select sim.now();")})
            if u.path.startswith('/realtime/'): return self.send(404, {'msg': 'realtime not emulated'})
            return self.static(u)
        except Exception as e:
            return self.send(500, {'msg': str(e)})

    def role_jwt(self):
        auth = (self.headers.get('Authorization') or '').replace('Bearer ', '').strip()
        key = (self.headers.get('apikey') or '').strip()
        if auth.count('.') == 2:
            return auth  # a user/session JWT; PostgREST verifies it
        if key == LOCAL_SECRET_KEY: return SERVICE_JWT
        if key == PUBLISHABLE: return ANON_JWT
        return None

    def rest(self, m, u):
        tok = self.role_jwt()
        if tok is None: return self.send(401, {'message': 'Invalid API key'})
        hdrs = {'Authorization': 'Bearer ' + tok}
        for h in ['Content-Type', 'Prefer', 'Range', 'Range-Unit', 'Accept', 'Accept-Profile', 'Content-Profile']:
            if self.headers.get(h): hdrs[h] = self.headers.get(h)
        data = self.body() if m in ('POST', 'PATCH', 'PUT', 'DELETE') else None
        req = urllib.request.Request(PGRST + self.path[len('/rest/v1'):], data=data, method=m, headers=hdrs)
        try: r = urllib.request.urlopen(req); code, body, rh = r.status, r.read(), r.headers
        except urllib.error.HTTPError as e: code, body, rh = e.code, e.read(), e.headers
        extra = {k: rh[k] for k in ['Content-Range', 'Location', 'Preference-Applied'] if rh.get(k)}
        self.send(code, body, rh.get('Content-Type') or 'application/json', extra)

    def auth(self, m, u):
        path = u.path[len('/auth/v1/'):]; qs = parse_qs(u.query)
        if path == 'settings': return self.send(200, {'external': {'email': True, 'google': False}, 'disable_signup': False, 'mailer_autoconfirm': True})
        if path == 'signup' and m == 'POST':
            b = json.loads(self.body() or b'{}'); email = (b.get('email') or '').strip().lower(); pw = b.get('password') or ''
            if not email or len(pw) < 6: return self.send(422, {'code': 422, 'msg': 'Password should be at least 6 characters'})
            if q("select 1 from auth.users where email = :'e';", e=email): return self.send(422, {'code': 422, 'error_code': 'user_already_exists', 'msg': 'User already registered'})
            uid = q("insert into auth.users (email, encrypted_password, raw_user_meta_data) values (:'e', :'p', :'d'::jsonb) returning id;",
                    e=email, p=pw_hash(pw), d=json.dumps(b.get('data') or {}))
            return self.send(200, session(uid))
        if path == 'token' and m == 'POST':
            b = json.loads(self.body() or b'{}'); gt = (qs.get('grant_type') or [''])[0]
            if gt == 'password':
                uid = q("select id from auth.users where email = :'e' and encrypted_password = :'p';", e=(b.get('email') or '').strip().lower(), p=pw_hash(b.get('password') or ''))
                if not uid: return self.send(400, {'code': 400, 'error_code': 'invalid_credentials', 'msg': 'Invalid login credentials'})
                return self.send(200, session(uid))
            if gt == 'refresh_token':
                uid = REFRESH.pop(b.get('refresh_token') or '', None)
                if not uid: return self.send(400, {'code': 400, 'error_code': 'refresh_token_not_found', 'msg': 'Invalid Refresh Token'})
                return self.send(200, session(uid))
        if path == 'user':
            c = jwt_claims((self.headers.get('Authorization') or '').replace('Bearer ', '').strip())
            if not c or not c.get('sub'): return self.send(401, {'code': 401, 'msg': 'invalid JWT'})
            if m == 'PUT':
                b = json.loads(self.body() or b'{}')
                if 'data' in b: q("update auth.users set raw_user_meta_data = coalesce(raw_user_meta_data,'{}'::jsonb) || :'d'::jsonb where id = :'id';", d=json.dumps(b['data']), id=c['sub'])
                if b.get('password'): q("update auth.users set encrypted_password = :'p' where id = :'id';", p=pw_hash(b['password']), id=c['sub'])
            return self.send(200, user_json(c['sub']))
        if path in ('recover', 'logout', 'otp', 'magiclink'): return self.send(200, {})
        if path == 'authorize': return self.send(400, '<h1>OAuth is not available on the local replica</h1>', 'text/html')
        return self.send(404, {'msg': 'not emulated: ' + path})

    def static(self, u):
        p = u.path
        f = ROUTES.get(p) or p.lstrip('/')
        if f.endswith('/') or f == '': f = 'index.html'
        full = os.path.realpath(os.path.join(REPO, f))
        if not full.startswith(REPO) or not os.path.isfile(full):
            if os.path.isfile(full + '.html'): full = full + '.html'
            else: return self.send(404, 'not found', 'text/plain')
        data = open(full, 'rb').read()
        ctype = {'html': 'text/html; charset=utf-8', 'js': 'text/javascript', 'css': 'text/css', 'svg': 'image/svg+xml',
                 'json': 'application/json', 'png': 'image/png'}.get(full.rsplit('.', 1)[-1], 'application/octet-stream')
        if full.endswith('.js'):
            data = data.decode('utf-8').replace(LIVE_URL, 'http://' + (self.headers.get('Host') or 'localhost:%d' % PORT)).encode('utf-8')
        if full.endswith('.html'):
            s = data.decode('utf-8').replace(LIVE_URL, 'http://' + (self.headers.get('Host') or 'localhost:%d' % PORT))
            s = re.sub(r'<head([^>]*)>', lambda mm: '<head' + mm.group(1) + '>' + INJECT, s, count=1)
            data = s.encode('utf-8')
        self.send(200, data, ctype, {'Cache-Control': 'no-store'})

if __name__ == '__main__':
    print('gateway on http://localhost:%d' % PORT, flush=True)
    ThreadingHTTPServer(('127.0.0.1', PORT), H).serve_forever()
