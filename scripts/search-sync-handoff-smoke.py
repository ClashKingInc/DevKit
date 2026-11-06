"""Matched actual-service recovery benchmark; optional, requires local images."""
import json, os, pathlib, subprocess, tempfile, time
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
db=owners['with-test-timescale'];cache=owners['with-test-integration'];network='ck-sync-bench-'+rid.lower();esid=None

def sql(q):return run(['docker','exec','-i',db,'psql','-XAt','-U','clashking_test','-d','clashking_test','-v','ON_ERROR_STOP=1'],q)
def es(path):return json.loads(run(['docker','exec',esid,'curl','-fsS','http://localhost:9200'+path]))
def job(image,env,args,entry=None,mount=None):
    cmd=['docker','run','--rm','--cpus','2','--memory','1g','--network',network,'--label',f'io.clashking.fixture.run={rid}','--label','io.clashking.fixture.owner=searchsync-benchmark']
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
    # Accumulate an old unprocessed gap before the new queue exists.
    sql("UPDATE basic_player SET trophies=1234; UPDATE basic_player SET name='Old gap' WHERE tag<'#P005000'; DELETE FROM basic_player WHERE tag>='#P009001'; UPDATE basic_player SET tag='#RENAMED' WHERE tag='#P000001'; UPDATE basic_clan SET member_count=12; CREATE TABLE bridge_noise(id int); INSERT INTO bridge_noise SELECT generate_series(1,5000);")
    run(['goose','-env','/dev/null','-dir',str(root/'database/timescale'),'postgres',os.environ['TEST_DATABASE_URL'],'up-to','63'])
    sql("UPDATE basic_player SET name='New captured',clan_tag=NULL WHERE tag='#P000002'; INSERT INTO basic_player(tag,name,townhall_level) VALUES('#P009999','Recreated after capture',18); UPDATE basic_player SET name=$q$Literal tag[text]:'#FALSE' inside name$q$ WHERE tag='#P000003';")
    slots=['clashking_test_clashking_players_v2','clashking_test_clashking_clans_v2']
    positions=sql("SELECT slot_name,confirmed_flush_lsn FROM pg_replication_slots ORDER BY slot_name")
    goenv={'DATABASE_URL':'postgres://clashking_test:clashking_test@db:5432/clashking_test?sslmode=disable','SEARCH_EXPECT_DATABASE':'clashking_test','SEARCH_EXPECT_SYSTEM_ID':sql('SELECT system_identifier FROM pg_control_system()'),'ELASTICSEARCH_URL':'http://search:9200','SEARCH_PLAYER_INDEX':'clashking_players_v2','SEARCH_CLAN_INDEX':'clashking_clans_v2','SEARCH_MODE':'handoff','SEARCH_PLAYER_SLOT':slots[0],'SEARCH_CLAN_SLOT':slots[1],'SEARCH_BATCH_SIZE':'1000','SEARCH_RUN_ONCE':'1'}
    # A real SQL enqueue error must stop before either old slot is consumed.
    sql("CREATE FUNCTION fail_bridge() RETURNS trigger LANGUAGE plpgsql AS $$BEGIN RAISE EXCEPTION 'bridge enqueue fixture failure';END$$; CREATE TRIGGER fail_bridge BEFORE INSERT ON search_sync_pending FOR EACH ROW EXECUTE FUNCTION fail_bridge();")
    try:job('clashking/searchsync:local',goenv,[]);raise AssertionError('expected bridge failure')
    except RuntimeError as e:assert 'bridge enqueue fixture failure' in str(e),str(e)
    assert positions==sql("SELECT slot_name,confirmed_flush_lsn FROM pg_replication_slots ORDER BY slot_name")
    sql('DROP TRIGGER fail_bridge ON search_sync_pending; DROP FUNCTION fail_bridge();')
    # Once durable queue transfer succeeds, ES can fail without losing the gap.
    run(['docker','exec',esid,'curl','-fsS','-XPUT','http://localhost:9200/clashking_players_v2/_settings','-H','Content-Type: application/json','-d','{"index.blocks.write":true}'])
    try:job('clashking/searchsync:local',goenv,[]);raise AssertionError('expected ES failure')
    except RuntimeError as e:assert 'bulk item HTTP 403' in str(e),str(e)
    assert sql('SELECT count(*) FROM search_sync_bridge WHERE completed')=='2'
    assert int(sql('SELECT count(*) FROM search_sync_pending'))>0
    run(['docker','exec',esid,'curl','-fsS','-XPUT','http://localhost:9200/clashking_players_v2/_settings','-H','Content-Type: application/json','-d','{"index.blocks.write":false}'])
    elapsed,out=job('clashking/searchsync:local',goenv,[])
    run(['docker','exec',esid,'curl','-fsS','-XPOST','http://localhost:9200/_refresh'])
    assert es('/clashking_players_v2/_count')['count']==9001
    assert es('/clashking_players_v2/_doc/%23P000002')['_source']['name']=='New captured'
    assert es('/clashking_players_v2/_doc/%23P009999')['_source']['name']=='Recreated after capture'
    assert es('/clashking_players_v2/_doc/%23RENAMED')['_source']['name']=='Old gap'
    assert es('/clashking_clans_v2/_doc/%23CLAN')['_source']['member_count']==12
    assert sql('SELECT count(*) FROM search_sync_pending')=='0'
    assert sql("SELECT count(*) FROM search_sync_state WHERE snapshot_done AND cursor_tag=''")=='2'
    assert 'snapshot entity' not in out
    print(json.dumps({'result':'PASS','mode':'existing-index handoff','source_rows':9001,'coverage':'old gap; irrelevant tables/fields; deletes; PK changes; before/after capture; SQL enqueue failure preserves slot; ES failure preserves durable transferred queue; restart; no snapshot','drain_seconds':float(f'{elapsed:.3f}')}))
finally:
    ids=run(['docker','ps','-aq','--filter',f'label=io.clashking.fixture.run={rid}','--filter','label=io.clashking.fixture.owner=searchsync-benchmark']).split()
    if ids:run(['docker','rm','-f','-v',*ids])
    for cid in [db,cache]:subprocess.run(['docker','network','disconnect',network,cid],capture_output=True)
    subprocess.run(['docker','network','rm',network],capture_output=True)
