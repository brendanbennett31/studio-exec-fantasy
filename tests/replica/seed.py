import json, subprocess, os, sys
HERE=os.path.dirname(os.path.abspath(__file__))
PSQL=os.environ.get('SEF_PSQL','psql')
def psql(sql):
    p=subprocess.run([PSQL,'-h','127.0.0.1','-p','54329','-U','postgres','-d','sef','-X','-q','-At','-v','ON_ERROR_STOP=1'],input=sql,capture_output=True,text=True)
    if p.returncode: raise SystemExit(p.stderr)
    return p.stdout
out=["set session_replication_role = replica;"]
for t in ['universe_films','gold_derby_odds','daily_bo']:
    rows=json.load(open(os.path.join(HERE,'seed',t+'.json')))
    data=json.dumps(rows).replace('$SEEDJSON$','')
    out.append("insert into public.%s overriding system value select * from json_populate_recordset(null::public.%s, $SEEDJSON$%s$SEEDJSON$);"%(t,t,data))
    out.append("select setval(pg_get_serial_sequence('public.%s','id'), coalesce((select max(id) from public.%s),1));"%(t,t))
psql('\n'.join(out))
print(psql("select 'universe_films', count(*) from universe_films union all select 'gold_derby_odds', count(*) from gold_derby_odds union all select 'daily_bo', count(*) from daily_bo;"))
