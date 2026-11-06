"""Matched actual-service recovery benchmark; optional, requires local images."""
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
state_dir=tempfile.mkdtemp(prefix='ck-stream-bench-');os.chmod(state_dir,0o777)
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
    # Only the currently measured capture mechanism is enabled for each writer.
    sql("INSERT INTO basic_player(tag,name,townhall_level) SELECT '#P'||lpad(i::text,6,'0'),'Base '||i,16 FROM generate_series(1,20000) i; INSERT INTO basic_clan(tag,name,public_war_log,war_wins,member_count,badge_token,troops_donated,troops_received) VALUES('#CLAN','Clan',true,0,1,'badge',0,0);")
    pgenv={'PG_HOST':'db','PG_PORT':'5432','POSTGRES_DB':'clashking_test','PG_USER':'clashking_test','PG_PASSWORD':'clashking_test','PG_SSLMODE':'disable','ELASTICSEARCH':'true','ELASTICSEARCH_HOST':'search','ELASTICSEARCH_PORT':'9200','ELASTICSEARCH_SCHEME':'http','ELASTICSEARCH_RAISE_ON_ERROR':'true','ELASTICSEARCH_RAISE_ON_EXCEPTION':'true','ELASTICSEARCH_STREAMING_BULK':'true','ELASTICSEARCH_CHUNK_SIZE':'1000','REDIS_HOST':'cache','REDIS_PORT':'6379','REDIS_DB':'1','REDIS_CHECKPOINT':'true'}
    mount=str(root/'database/pgsync/schema.json')+':/config/schema.json:ro'
    pgimage='clashking/pgsync:column-filter-local'
    job(pgimage,pgenv,['--config','/config/schema.json'],entry='bootstrap',mount=mount)
    initial,output=job(pgimage,pgenv,['--config','/config/schema.json'],mount=mount)
    results=[{'engine':'pgsync','phase':'snapshot','seconds':round(initial,3),'rows':20001}]
    def operations(index):return es('/'+index+'/_stats/indexing')['_all']['primaries']['indexing']['index_total']
    def workload(label):
        lsn=sql('SELECT pg_current_wal_insert_lsn()');start=time.monotonic()
        for _ in range(5):sql('UPDATE basic_player SET trophies=coalesce(trophies,0)+1;')
        sql("UPDATE basic_player SET name='"+label+" '||tag;")
        return time.monotonic()-start,int(sql("SELECT pg_wal_lsn_diff(pg_current_wal_insert_lsn(),'"+lsn+"')"))
    for round in range(2):
        before=operations('clashking_players_v2');write,wal=workload('PG'+str(round));elapsed,output=job(pgimage,pgenv,['--config','/config/schema.json'],mount=mount)
        results.append({'engine':'pgsync','phase':'restart_catchup','round':round,'seconds':float(f'{elapsed:.3f}'),'index_operations':operations('clashking_players_v2')-before,'source_write_seconds':float(f'{write:.3f}'),'source_wal_bytes':wal})
    # Disable only the installed PGSync capture triggers, then enable the new queue.
    sql("DO $$DECLARE r record; BEGIN FOR r IN SELECT c.relname,t.tgname FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid WHERE t.tgfoid='table_notify'::regproc AND c.relname IN ('basic_player','basic_clan') LOOP EXECUTE format('ALTER TABLE %I DISABLE TRIGGER %I',r.relname,r.tgname); END LOOP; END$$;")
    goenv={'DATABASE_URL':'postgres://clashking_test:clashking_test@db:5432/clashking_test?sslmode=disable','SEARCH_EXPECT_DATABASE':'clashking_test','SEARCH_EXPECT_SYSTEM_ID':sql('SELECT system_identifier FROM pg_control_system()'),'ELASTICSEARCH_URL':'http://search:9200','SEARCH_PLAYER_INDEX':'clashking_players_v2','SEARCH_CLAN_INDEX':'clashking_clans_v2','SEARCH_SLOT':'clashking_search_go','SEARCH_PLAYER_OLD_SLOT':'clashking_test_clashking_players_v2','SEARCH_CLAN_OLD_SLOT':'clashking_test_clashking_clans_v2','SEARCH_STATE_DIR':'/state','SEARCH_BATCH_SIZE':'1000','SEARCH_RUN_UNTIL_IDLE':'1'}
    initial,_=job('clashking/searchstream:local',goenv,[])
    results.append({'engine':'go_stream','phase':'existing_index_handoff','seconds':float(f'{initial:.3f}'),'rows':20001})
    for round in range(2):
        before=operations('clashking_players_v2');write,wal=workload('GO'+str(round));elapsed,logs=job('clashking/searchstream:local',goenv,[])
        results.append({'engine':'go_stream','phase':'restart_catchup','round':round,'seconds':float(f'{elapsed:.3f}'),'index_operations':operations('clashking_players_v2')-before,'source_write_seconds':float(f'{write:.3f}'),'source_wal_bytes':wal})
    print(json.dumps({'workload_per_round':{'unchanged_search_field_updates':100000,'indexed_name_updates':20000},'same_resources':'2 CPU, 1 GiB per sync container; same PG/ES; batch1000; includes process startup','results':results}))
finally:
    ids=run(['docker','ps','-aq','--filter',f'label=io.clashking.fixture.run={rid}','--filter','label=io.clashking.fixture.owner=searchsync-benchmark']).split()
    if ids:run(['docker','rm','-f','-v',*ids])
    for cid in [db,cache]:subprocess.run(['docker','network','disconnect',network,cid],capture_output=True)
    subprocess.run(['docker','network','rm',network],capture_output=True)

    shutil.rmtree(state_dir)
