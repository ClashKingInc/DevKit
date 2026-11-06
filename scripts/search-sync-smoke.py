"""Actual Go search service against disposable canonical Timescale + Elasticsearch."""
import json, os, pathlib, subprocess, tempfile, time, urllib.request, urllib.error
root = pathlib.Path(__file__).resolve().parents[1]
assert os.environ.get('CLASHKING_DISPOSABLE_TIMESCALE') == '1'
dsn = os.environ['TEST_DATABASE_URL']
assert '@127.0.0.1:' in dsn and '/clashking_test?' in dsn
run_id = os.environ['CLASHKING_FIXTURE_RUN_ID']
assert run_id.isalnum()
def run(args, **kw):
    return subprocess.run(args, text=True, capture_output=True, check=True, **kw).stdout.strip()
def sql(q): return run(['psql', dsn, '-XAt', '-v', 'ON_ERROR_STOP=1'], input=q)
def wait_for(predicate, seconds=60):
    end=time.monotonic()+seconds
    while time.monotonic()<end:
        if predicate(): return
        time.sleep(.05)
    raise AssertionError('condition timed out')
container=None
worker=None
with tempfile.TemporaryDirectory(prefix='ck-search-smoke-') as tmp:
    try:
        binary=tmp+'/searchsync'
        run(['go','build','-o',binary,'./searchsync'],cwd=root/'database')
        container=run(['docker','run','-d','--label',f'io.clashking.fixture.run={run_id}','--label','io.clashking.fixture.owner=searchsync-smoke','--memory','2g','-p','127.0.0.1::9200','-e','discovery.type=single-node','-e','xpack.security.enabled=false','-e','xpack.ml.enabled=false','-e','ES_JAVA_OPTS=-Xms512m -Xmx512m','docker.elastic.co/elasticsearch/elasticsearch:8.19.17'])
        endpoint='http://'+run(['docker','port',container,'9200/tcp'])
        def es(path,method='GET',data=None):
            b=None if data is None else json.dumps(data).encode()
            req=urllib.request.Request(endpoint+path,data=b,method=method,headers={'Content-Type':'application/json'})
            with urllib.request.urlopen(req,timeout=20) as res: return json.load(res)
        def ready():
            try:return es('/_cluster/health')['status'] in ('green','yellow')
            except Exception:return False
        wait_for(ready)
        env=os.environ|{'DATABASE_URL':dsn,'SEARCH_EXPECT_DATABASE':'clashking_test','SEARCH_EXPECT_SYSTEM_ID':sql('SELECT system_identifier FROM pg_control_system()'),'ELASTICSEARCH_URL':endpoint,'SEARCH_PLAYER_INDEX':'smoke_players','SEARCH_CLAN_INDEX':'smoke_clans','SEARCH_SCHEMA_FILE':str(root/'database/pgsync/schema.json'),'SEARCH_BATCH_SIZE':'100','SEARCH_RUN_ONCE':'1','SEARCH_ALLOW_INDEX_CREATE':'1'}
        logfile=open(tmp+'/worker.log','w+')
        def start():return subprocess.Popen([binary],env=env,stdout=logfile,stderr=logfile)
        def finish(p, success=True):
            code=p.wait(timeout=180)
            if (code==0)!=success:
                logfile.flush();raise AssertionError(pathlib.Path(tmp+'/worker.log').read_text()[-5000:])
        sql("INSERT INTO basic_player(tag,name,townhall_level) SELECT '#P'||lpad(i::text,6,'0'),'Player '||i,16 FROM generate_series(1,20000) i; INSERT INTO basic_clan(tag,name,public_war_log,war_wins,member_count,badge_token,troops_donated,troops_received) VALUES('#CLAN','Clan',true,0,1,'badge',0,0);")
        # A source transaction rollback must also roll back its queue changes.
        before=sql('SELECT count(*) FROM search_sync_pending')
        sql("BEGIN; UPDATE basic_player SET name='Rollback' WHERE tag='#P000001'; ROLLBACK;")
        assert before==sql('SELECT count(*) FROM search_sync_pending')
        worker=start()
        wait_for(lambda: sql("SELECT count(*) FROM search_sync_state WHERE entity='player' AND cursor_tag<>''")=='1')
        assert sql("SELECT snapshot_done FROM search_sync_state WHERE entity='player'") == 'f'
        # Stop during snapshot and resume the durable cursor on the next process.
        worker.terminate();finish(worker);worker=None
        # Mutate both behind and ahead of the moving snapshot cursor.
        sql("UPDATE basic_player SET name='Changed during snapshot',clan_tag='#CLAN' WHERE tag='#P000001'; DELETE FROM basic_player WHERE tag IN ('#P000002','#P019999'); INSERT INTO basic_player(tag,name,townhall_level) VALUES('#A_NEW','Inserted behind cursor',17); UPDATE basic_clan SET member_count=9 WHERE tag='#CLAN';")
        worker=start();finish(worker);worker=None
        env['SEARCH_BATCH_SIZE']='1000'
        es('/_refresh','POST')
        assert es('/smoke_players/_count')['count']==19999
        assert es('/smoke_players/_doc/%23P000001')['_source']['name']=='Changed during snapshot'
        assert es('/smoke_clans/_doc/%23CLAN')['_source']['member_count']==9
        assert sql('SELECT count(*) FROM search_sync_pending')=='0'
        # Observation-only and equal-value updates must not enqueue anything.
        sql("UPDATE basic_player SET trophies=1234; UPDATE basic_player SET name=name; UPDATE basic_clan SET war_wins=4,troops_donated=20;")
        assert sql('SELECT count(*) FROM search_sync_pending')=='0'
        # Real ES write blocks exercise partial-failure retention and restart.
        es('/smoke_players/_settings','PUT',{'index.blocks.write':True})
        sql("UPDATE basic_player SET name='Retry retained',league_id=NULL,clan_tag=NULL WHERE tag='#P000001'; DELETE FROM basic_player WHERE tag='#P000003';")
        worker=start();finish(worker,False);worker=None
        assert sql('SELECT count(*) FROM search_sync_pending')=='2'
        es('/smoke_players/_settings','PUT',{'index.blocks.write':False})
        # Delete/recreate and repeated updates coalesce to the latest payload.
        sql("INSERT INTO basic_player(tag,name,townhall_level) VALUES('#P000003','Recreated',18); UPDATE basic_player SET name='Latest' WHERE tag='#P000003';")
        worker=start();finish(worker);worker=None
        es('/_refresh','POST')
        assert es('/smoke_players/_doc/%23P000003')['_source']['name']=='Latest'
        assert es('/smoke_players/_doc/%23P000001')['_source']['clan_tag'] is None
        assert sql('SELECT count(*) FROM search_sync_pending')=='0'
        # Force an actual DB acknowledgment failure after ES has accepted data.
        sql("UPDATE basic_player SET name='Accepted before crash' WHERE tag='#P000001'; CREATE FUNCTION block_search_ack() RETURNS trigger LANGUAGE plpgsql AS $$BEGIN RAISE EXCEPTION 'fixture ack failure'; END$$; CREATE TRIGGER block_ack BEFORE DELETE ON search_sync_pending FOR EACH ROW EXECUTE FUNCTION block_search_ack();")
        worker=start();finish(worker,False);worker=None
        assert sql('SELECT count(*) FROM search_sync_pending')=='1'
        es('/_refresh','POST')
        assert es('/smoke_players/_doc/%23P000001')['_source']['name']=='Accepted before crash'
        sql('DROP TRIGGER block_ack ON search_sync_pending; DROP FUNCTION block_search_ack();')
        worker=start();finish(worker);worker=None
        assert sql('SELECT count(*) FROM search_sync_pending')=='0'
        # Primary-key changes remove the old document as well as adding the new.
        sql("UPDATE basic_player SET tag='#RENAMED' WHERE tag='#P000004';")
        worker=start();finish(worker);worker=None
        es('/_refresh','POST')
        assert es('/smoke_players/_doc/%23RENAMED')['found']
        try: es('/smoke_players/_doc/%23P000004');raise AssertionError('old key survived')
        except urllib.error.HTTPError as e: assert e.code==404
        # Active writer/consumer overlap exercises conditional ACK generations.
        env['SEARCH_RUN_ONCE']='0';worker=start()
        for i in range(12):
            sql(f"UPDATE basic_player SET name='Concurrent {i}' WHERE tag >= '#P000100' AND tag <= '#P001099';")
        wait_for(lambda:sql('SELECT count(*) FROM search_sync_pending')=='0')
        worker.terminate();finish(worker);worker=None
        es('/_refresh','POST')
        assert es('/smoke_players/_doc/%23P000500')['_source']['name']=='Concurrent 11'
        # Measure a real 20k-document backlog; no mocked transport or sleeps.
        sql("UPDATE basic_player SET name='Backlog '||tag;")
        count=int(sql('SELECT count(*) FROM search_sync_pending'))
        env['SEARCH_RUN_ONCE']='1';began=time.monotonic();worker=start();finish(worker);worker=None
        elapsed=time.monotonic()-began
        es('/_refresh','POST')
        assert sql('SELECT count(*) FROM search_sync_pending')=='0'
        assert es('/smoke_players/_count')['count']==int(sql('SELECT count(*) FROM basic_player'))
        print(json.dumps({'result':'PASS','backlog_documents':count,'elapsed_seconds':round(elapsed,3),'documents_per_second':round(count/elapsed,1),'coverage':'mid-snapshot crash/resume; ES success with DB ACK failure; canonical snapshots; concurrent inserts updates deletes; rollback; nulls; irrelevant fields; actual ES write failure and restart; delete/recreate; key change; concurrent ACK; bounded backlog'}))
    finally:
        if worker and worker.poll() is None:worker.terminate();worker.wait(timeout=30)
        if container:
            assert run(['docker','inspect','--format','{{ index .Config.Labels "io.clashking.fixture.run" }}',container])==run_id
            run(['docker','rm','-f','-v',container])
