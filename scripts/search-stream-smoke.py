"""Actual no-queue Go stream handoff and recovery with real PGSync/PG/ES."""
import json, os, pathlib, subprocess, tempfile, time, shutil
root=pathlib.Path(__file__).resolve().parents[1]
assert os.environ.get('CLASHKING_DISPOSABLE_TIMESCALE')=='1' and os.environ.get('CLASHKING_DISPOSABLE_VALKEY')=='1'
assert os.environ.get('CLASHKING_FIXTURE_LOGICAL_WAL')=='1'
rid=os.environ['CLASHKING_FIXTURE_RUN_ID'];assert rid.isalnum()
def run(args,input=None):
    p=subprocess.run(args,input=input,capture_output=True,text=True)
    if p.returncode:raise RuntimeError(p.stdout[-1500:]+p.stderr[-3500:])
    return p.stdout.strip()
items=json.loads(run(['docker','inspect',*run(['docker','ps','-q','--filter',f'label=io.clashking.fixture.run={rid}']).split()]))
owners={v['Config']['Labels']['io.clashking.fixture.owner']:v['Id'] for v in items}
state_dir=tempfile.mkdtemp(prefix='ck-stream-state-');os.chmod(state_dir,0o777)
db=owners['with-test-timescale'];cache=owners['with-test-integration'];network='ck-sync-bench-'+rid.lower();esid=None

def sql(q):return run(['docker','exec','-i',db,'psql','-XAt','-U','clashking_test','-d','clashking_test','-v','ON_ERROR_STOP=1'],q)
def es(path):return json.loads(run(['docker','exec',esid,'curl','-fsS','http://localhost:9200'+path]))
def job(image,env,args,entry=None,mount=None):
    cmd=['docker','run','--rm','--cpus','2','--memory','1g','--network',network,'--label',f'io.clashking.fixture.run={rid}','--label','io.clashking.fixture.owner=searchsync-benchmark']
    if image=='clashking/searchstream:local':cmd+=['-v',state_dir+':/state']
    for k,v in env.items():cmd+=['-e',k+'='+v]
    if entry:cmd+=['--entrypoint',entry]
    if mount:cmd+=['-v',mount]
    start=time.monotonic();output=run(cmd+[image]+args);return time.monotonic()-start,output
try:
    run(['docker','network','create','--label',f'io.clashking.fixture.run={rid}',network])
    for cid,alias in [(db,'db'),(cache,'cache')]:run(['docker','network','connect','--alias',alias,network,cid])
    esid=run(['docker','run','-d','--network',network,'--network-alias','search','--memory','2g','--label',f'io.clashking.fixture.run={rid}','--label','io.clashking.fixture.owner=searchsync-benchmark','-e','discovery.type=single-node','-e','xpack.security.enabled=false','-e','xpack.ml.enabled=false','-e','ES_JAVA_OPTS=-Xms512m -Xmx512m','docker.elastic.co/elasticsearch/elasticsearch:8.19.17'])
    for _ in range(120):
        try:
            if es('/_cluster/health')['status'] in ['green','yellow']:break
        except Exception:pass
        time.sleep(.5)
    else:raise RuntimeError('ES startup failed')
    run(['goose','-env','/dev/null','-dir',str(root/'database/timescale'),'postgres',os.environ['TEST_DATABASE_URL'],'down-to','62'])
    sql("INSERT INTO basic_player(tag,name,townhall_level) SELECT '#P'||lpad(i::text,6,'0'),'Base '||i,16 FROM generate_series(1,10000) i; INSERT INTO basic_clan(tag,name,public_war_log,war_wins,member_count,badge_token,troops_donated,troops_received) VALUES('#CLAN','Clan',true,0,1,'badge',0,0);")
    pgenv={'PG_HOST':'db','PG_PORT':'5432','POSTGRES_DB':'clashking_test','PG_USER':'clashking_test','PG_PASSWORD':'clashking_test','PG_SSLMODE':'disable','ELASTICSEARCH':'true','ELASTICSEARCH_HOST':'search','ELASTICSEARCH_PORT':'9200','ELASTICSEARCH_SCHEME':'http','ELASTICSEARCH_RAISE_ON_ERROR':'true','ELASTICSEARCH_RAISE_ON_EXCEPTION':'true','ELASTICSEARCH_STREAMING_BULK':'true','ELASTICSEARCH_CHUNK_SIZE':'1000','REDIS_HOST':'cache','REDIS_PORT':'6379','REDIS_DB':'1','REDIS_CHECKPOINT':'true'}
    mount=str(root/'database/pgsync/schema.json')+':/config/schema.json:ro'
    pgimage='clashking/pgsync:column-filter-local'
    job(pgimage,pgenv,['--config','/config/schema.json'],entry='bootstrap',mount=mount)
    job(pgimage,pgenv,['--config','/config/schema.json'],mount=mount)
    sql("UPDATE basic_player SET trophies=1234; UPDATE basic_player SET name='Old gap' WHERE tag<'#P005000'; DELETE FROM basic_player WHERE tag>='#P009001'; UPDATE basic_player SET tag='#RENAMED' WHERE tag='#P000001'; UPDATE basic_clan SET member_count=12; CREATE TABLE bridge_noise(id int); INSERT INTO bridge_noise SELECT generate_series(1,5000); SELECT pg_logical_emit_message(false,'unrelated','outside transaction');")
    run(['goose','-env','/dev/null','-dir',str(root/'database/timescale'),'postgres',os.environ['TEST_DATABASE_URL'],'up-to','63'])
    slots=['clashking_test_clashking_players_v2','clashking_test_clashking_clans_v2']
    goenv={'DATABASE_URL':'postgres://clashking_test:clashking_test@db:5432/clashking_test?sslmode=disable','SEARCH_EXPECT_DATABASE':'clashking_test','SEARCH_EXPECT_SYSTEM_ID':sql('SELECT system_identifier FROM pg_control_system()'),'ELASTICSEARCH_URL':'http://search:9200','SEARCH_PLAYER_INDEX':'clashking_players_v2','SEARCH_CLAN_INDEX':'clashking_clans_v2','SEARCH_SLOT':'clashking_search_go','SEARCH_PLAYER_OLD_SLOT':slots[0],'SEARCH_CLAN_OLD_SLOT':slots[1],'SEARCH_STATE_DIR':'/state','SEARCH_BATCH_SIZE':'1000','SEARCH_RUN_UNTIL_IDLE':'1'}
    position=sql("SELECT confirmed_flush_lsn FROM pg_replication_slots WHERE slot_name='"+slots[0]+"'")
    def settings(index,blocked):
        run(['docker','exec',esid,'curl','-fsS','-XPUT','http://localhost:9200/'+index+'/_settings','-H','Content-Type: application/json','-d',json.dumps({'index.blocks.write':blocked})])
    def refresh():run(['docker','exec',esid,'curl','-fsS','-XPOST','http://localhost:9200/_refresh'])
    settings('clashking_players_v2',True)
    try:job('clashking/searchstream:local',goenv,[]);raise AssertionError('expected handoff ES failure')
    except RuntimeError as e:assert 'bulk item HTTP 403' in str(e),str(e)
    assert position==sql("SELECT confirmed_flush_lsn FROM pg_replication_slots WHERE slot_name='"+slots[0]+"'")
    # Changes after new-slot creation must be replayed after the old gap.
    sql("UPDATE basic_player SET name='After boundary',clan_tag=NULL WHERE tag='#P000002'; INSERT INTO basic_player(tag,name,townhall_level) VALUES('#P009999','Recreated after boundary',18);")
    settings('clashking_players_v2',False)
    elapsed,out=job('clashking/searchstream:local',goenv,[]);refresh()
    assert es('/clashking_players_v2/_count')['count']==9001
    assert es('/clashking_players_v2/_doc/%23P000002')['_source']['name']=='After boundary'
    assert es('/clashking_players_v2/_doc/%23P009999')['_source']['name']=='Recreated after boundary'
    assert es('/clashking_clans_v2/_doc/%23CLAN')['_source']['member_count']==12
    assert sql("SELECT to_regclass('search_sync_pending') IS NULL")=='t'
    # Fail one index after another index may already have accepted a partial bulk.
    before=sql("SELECT confirmed_flush_lsn FROM pg_replication_slots WHERE slot_name='clashking_search_go'")
    sql("BEGIN; UPDATE basic_player SET name='Large committed change'; UPDATE basic_clan SET name='Clan changed'; COMMIT;")
    settings('clashking_clans_v2',True)
    try:job('clashking/searchstream:local',goenv,[]);raise AssertionError('expected live ES failure')
    except RuntimeError as e:assert 'bulk item HTTP 403' in str(e),str(e)
    # Large transactions can flush earlier rows, but the failed transaction must
    # not have its COMMIT acknowledged. Restart must deliver the whole result.
    assert sql("SELECT confirmed_flush_lsn <= '"+before+"'::pg_lsn FROM pg_replication_slots WHERE slot_name='clashking_search_go'")=='t'
    settings('clashking_clans_v2',False)
    _,out=job('clashking/searchstream:local',goenv,[]);refresh()
    assert es('/clashking_players_v2/_doc/%23P000003')['_source']['name']=='Large committed change'
    assert es('/clashking_clans_v2/_doc/%23CLAN')['_source']['name']=='Clan changed'
    sql("BEGIN; UPDATE basic_player SET name='Rolled back'; ROLLBACK; DELETE FROM basic_player WHERE tag='#P000004'; UPDATE basic_player SET tag='#NEWKEY' WHERE tag='#P000005'; INSERT INTO basic_player(tag,name,townhall_level) VALUES('#P000004','Recreated',18);")
    _,out=job('clashking/searchstream:local',goenv,[]);refresh()
    assert es('/clashking_players_v2/_doc/%23P000004')['_source']['name']=='Recreated'
    assert es('/clashking_players_v2/_doc/%23NEWKEY')['_source']['name']=='Large committed change'
    assert es('/clashking_players_v2/_count')['count']==9001
    # Exercise a continuously running consumer, not just cold restart catch-up.
    daemon_env=dict(goenv);daemon_env.pop('SEARCH_RUN_UNTIL_IDLE')
    command=['docker','run','-d','--cpus','2','--memory','1g','--network',network,'--label',f'io.clashking.fixture.run={rid}','--label','io.clashking.fixture.owner=searchsync-benchmark','-v',state_dir+':/state']
    for k,v in daemon_env.items():command+=['-e',k+'='+v]
    daemon=run(command+['clashking/searchstream:local'])
    def caught_up(target):
        end=time.monotonic()+30
        while time.monotonic()<end:
            if sql("SELECT confirmed_flush_lsn >= '"+target+"'::pg_lsn FROM pg_replication_slots WHERE slot_name='clashking_search_go'")=='t':return
            time.sleep(.05)
        raise AssertionError('stream did not acknowledge completed changes')
    target=sql('UPDATE basic_player SET trophies=trophies+1; SELECT pg_current_wal_lsn();').splitlines()[-1]
    caught_up(target)
    before=es('/clashking_players_v2/_stats/indexing')['_all']['primaries']['indexing']['index_total']
    for _ in range(5):target=sql('UPDATE basic_player SET trophies=trophies+1; SELECT pg_current_wal_lsn();').splitlines()[-1]
    caught_up(target)
    after=es('/clashking_players_v2/_stats/indexing')['_all']['primaries']['indexing']['index_total']
    assert after==before, f'warm unchanged updates produced {after-before} index writes'
    target=sql("UPDATE basic_player SET name='Live final' WHERE tag='#P000002'; SELECT pg_current_wal_lsn();").splitlines()[-1]
    caught_up(target);refresh()
    assert es('/clashking_players_v2/_doc/%23P000002')['_source']['name']=='Live final'
    print('PASS warm stream: 45005 unchanged-field updates produced zero ES index writes; subsequent real name change delivered')
    print(json.dumps({'result':'PASS','mode':'no-queue existing-index WAL stream','rows':9001,'coverage':'old gap; unrelated WAL/message; deletes; key changes; concurrent boundary changes; failed handoff preserves old slot; failed large live transaction preserves commit ACK; partial ES success restart; rollback; no queue or full snapshot','handoff_seconds':float(f'{elapsed:.3f}')}))
finally:
    ids=run(['docker','ps','-aq','--filter',f'label=io.clashking.fixture.run={rid}','--filter','label=io.clashking.fixture.owner=searchsync-benchmark']).split()
    if ids:run(['docker','rm','-f','-v',*ids])
    for cid in [db,cache]:subprocess.run(['docker','network','disconnect',network,cid],capture_output=True)
    subprocess.run(['docker','network','rm',network],capture_output=True)

    shutil.rmtree(state_dir)
