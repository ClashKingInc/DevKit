"""Actual concurrent snapshot/WAL full-resync service against disposable PG and ES."""
import json,os,pathlib,subprocess,tempfile,time,shutil
root=pathlib.Path(__file__).resolve().parents[1]
assert os.environ.get('CLASHKING_DISPOSABLE_TIMESCALE')=='1' and os.environ.get('CLASHKING_FIXTURE_LOGICAL_WAL')=='1'
rid=os.environ['CLASHKING_FIXTURE_RUN_ID'];assert rid.isalnum()
def run(args,input=None):
 p=subprocess.run(args,input=input,capture_output=True,text=True)
 if p.returncode:raise RuntimeError(p.stdout[-1000:]+p.stderr[-3000:])
 return p.stdout.strip()
items=json.loads(run(['docker','inspect',*run(['docker','ps','-q','--filter',f'label=io.clashking.fixture.run={rid}']).split()]))
db=next(v['Id'] for v in items if v['Config']['Labels']['io.clashking.fixture.owner']=='with-test-timescale')
network='ck-full-'+rid.lower();state=tempfile.mkdtemp(prefix='ck-full-state-');os.chmod(state,0o777);esid=None;daemon=None;blocker=None
label=['--label',f'io.clashking.fixture.run={rid}','--label','io.clashking.fixture.owner=search-full']
def sql(q):return run(['docker','exec','-i',db,'psql','-XAt','-U','clashking_test','-d','clashking_test','-v','ON_ERROR_STOP=1'],q)
def es(path,method='GET',body=None):
 cmd=['docker','exec',esid,'curl','-fsS','-X'+method,'http://localhost:9200'+path]
 if body is not None:cmd+=['-H','Content-Type: application/json','-d',json.dumps(body)]
 return json.loads(run(cmd))
def readstate():
 try:return json.loads(run(['docker','exec',daemon,'cat','/state/handoff.json']))
 except (RuntimeError,json.JSONDecodeError):return {}
def wait(fn,label,seconds=60):
 end=time.monotonic()+seconds
 while time.monotonic()<end:
  if fn():return
  time.sleep(.1)
 captured=subprocess.run(['docker','logs','--tail','15',daemon],capture_output=True,text=True) if daemon else None
 logs=(captured.stdout+captured.stderr) if captured else ''
 raise AssertionError(label+' timed out '+logs)
def start(env):
 cmd=['docker','run','-d','--cpus','2','--memory','1g','--network',network,*label,'-v',state+':/state']
 for k,v in env.items():cmd+=['-e',k+'='+v]
 return run(cmd+['clashking/searchstream:local'])
try:
 run(['docker','network','create',*label,network]);run(['docker','network','connect','--alias','db',network,db])
 esid=run(['docker','run','-d','--network',network,'--network-alias','search','--memory','2g',*label,'-e','discovery.type=single-node','-e','xpack.security.enabled=false','-e','xpack.ml.enabled=false','-e','ES_JAVA_OPTS=-Xms512m -Xmx512m','docker.elastic.co/elasticsearch/elasticsearch:8.19.17'])
 for _ in range(120):
  try:
   if es('/_cluster/health')['status'] in ['green','yellow']:break
  except Exception:pass
  time.sleep(.5)
 else:raise RuntimeError('ES startup failed')
 for spec in json.loads((root/'database/pgsync/schema.json').read_text()):
  spec['setting']['gc_deletes']='24h';es('/'+spec['index'],'PUT',{'settings':spec['setting'],'mappings':spec['mapping']})
 sql("INSERT INTO basic_player(tag,name,townhall_level) SELECT '#P'||lpad(i::text,6,'0'),'Base '||i,16 FROM generate_series(1,100000)i; INSERT INTO basic_clan(tag,name,public_war_log,war_wins,member_count,badge_token,troops_donated,troops_received) VALUES('#CLAN','Clan',true,0,1,'badge',0,0);")
 env={'DATABASE_URL':'postgres://clashking_test:clashking_test@db:5432/clashking_test?sslmode=disable','SEARCH_EXPECT_DATABASE':'clashking_test','SEARCH_EXPECT_SYSTEM_ID':sql('SELECT system_identifier FROM pg_control_system()'),'ELASTICSEARCH_URL':'http://search:9200','SEARCH_PLAYER_INDEX':'clashking_players_v2','SEARCH_CLAN_INDEX':'clashking_clans_v2','SEARCH_SLOT':'clashking_full_test','SEARCH_STATE_DIR':'/state','SEARCH_MODE':'full','SEARCH_BATCH_SIZE':'20000','SEARCH_SNAPSHOT_RATE':'2000'}
 daemon=start(env)
 wait(lambda:readstate().get('Snapshot',{}).get('Rows',{}).get('player',0)>=1000,'snapshot start')
 target=sql("BEGIN; UPDATE basic_player SET name='Changed behind' WHERE tag='#P000001'; UPDATE basic_player SET name='Changed ahead' WHERE tag='#P099999'; DELETE FROM basic_player WHERE tag IN('#P000002','#P098888'); UPDATE basic_player SET tag='#RENAMED' WHERE tag='#P000003'; UPDATE basic_clan SET member_count=42; COMMIT; SELECT pg_current_wal_lsn();").splitlines()[-1]
 wait(lambda:sql("SELECT confirmed_flush_lsn>='"+target+"'::pg_lsn FROM pg_replication_slots WHERE slot_name='clashking_full_test'")=='t','WAL advances while snapshot incomplete')
 # Block only the snapshot's player reads; the real clan WAL stream can still
 # change. A 30-second snapshot timeout must not replace the running consumer.
 blocker=subprocess.Popen(['docker','exec','-i',db,'psql','-XAt','-U','clashking_test','-d','clashking_test','-v','ON_ERROR_STOP=1'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
 blocker.stdin.write("BEGIN; LOCK TABLE basic_player IN ACCESS EXCLUSIVE MODE; SELECT 'LOCKED';\n");blocker.stdin.flush()
 while blocker.stdout.readline().strip()!='LOCKED':
  assert blocker.poll() is None,'snapshot lock failed'
 started=run(['docker','inspect','--format','{{.State.StartedAt}}',daemon])
 def retried():
  p=subprocess.run(['docker','logs',daemon],capture_output=True,text=True)
  return 'retrying current cursor while WAL stream continues' in p.stdout+p.stderr
 wait(retried,'isolated snapshot timeout',50)
 target=sql("UPDATE basic_clan SET member_count=43; SELECT pg_current_wal_lsn();").splitlines()[-1]
 wait(lambda:sql("SELECT confirmed_flush_lsn>='"+target+"'::pg_lsn FROM pg_replication_slots WHERE slot_name='clashking_full_test'")=='t','WAL advances during snapshot retry')
 assert run(['docker','inspect','--format','{{.State.StartedAt}}',daemon])==started,'snapshot timeout restarted the service'
 blocker.stdin.write('ROLLBACK;\n');blocker.stdin.close();assert blocker.wait(timeout=10)==0;blocker=None
 before=readstate()['Snapshot']['Rows']['player'];assert before<100000,'fixture did not overlap snapshot and WAL'
 run(['docker','rm','-f',daemon]);daemon=None
 sql("INSERT INTO basic_player(tag,name,townhall_level) VALUES('#P000002','Recreated while stopped',18); UPDATE basic_player SET clan_tag=NULL,name='After restart' WHERE tag='#P000010';")
 env['SEARCH_SNAPSHOT_RATE']='20000';daemon=start(env)
 wait(lambda:all(readstate().get('Snapshot',{}).get('Done',{}).get(k,False) for k in ['player','clan']),'snapshot resume completion')
 target=sql('SELECT pg_current_wal_lsn()')
 wait(lambda:sql("SELECT confirmed_flush_lsn>='"+target+"'::pg_lsn FROM pg_replication_slots WHERE slot_name='clashking_full_test'")=='t','final WAL checkpoint')
 es('/_refresh','POST');assert es('/clashking_players_v2/_count')['count']==99999
 assert es('/clashking_players_v2/_doc/%23P000001')['_source']['name']=='Changed behind'
 assert es('/clashking_players_v2/_doc/%23P099999')['_source']['name']=='Changed ahead'
 assert es('/clashking_players_v2/_doc/%23P000002')['_source']['name']=='Recreated while stopped'
 assert es('/clashking_players_v2/_doc/%23P000010')['_source']['name']=='After restart'
 assert es('/clashking_players_v2/_doc/%23RENAMED')['_source']['name']=='Base 3'
 assert es('/clashking_clans_v2/_doc/%23CLAN')['_source']['member_count']==43
 assert sql("SELECT to_regclass('search_sync_pending') IS NULL")=='t'
 print(json.dumps({'result':'PASS','mode':'full snapshot plus concurrent WAL','rows':99999,'snapshot_rows_before_restart':before,'coverage':'snapshot SQL timeout retries without interrupting WAL; checkpoint advances during snapshot; changes behind/ahead; deletes; key move; crash/resume; recreate while stopped; unchanged existing schema; no DB queue'}))
finally:
 if blocker is not None:
  blocker.stdin.close();blocker.wait(timeout=10)
 ids=run(['docker','ps','-aq','--filter',f'label=io.clashking.fixture.run={rid}','--filter','label=io.clashking.fixture.owner=search-full']).split()
 if ids:run(['docker','rm','-f','-v',*ids])
 subprocess.run(['docker','network','disconnect',network,db],capture_output=True);subprocess.run(['docker','network','rm',network],capture_output=True);shutil.rmtree(state)
