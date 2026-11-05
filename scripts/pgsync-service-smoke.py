"""Real canonical Timescale + Valkey + Elasticsearch + PGSync recovery E2E.
Run through with-test-integration.sh; never accepts external service endpoints.
"""
import datetime
import json
import os
from pathlib import Path
import subprocess
import time


def run(args, *, input=None, check=True, timeout=180):
    result = subprocess.run(args, input=input, capture_output=True, text=True, timeout=timeout)
    if check and result.returncode:
        raise RuntimeError(f'{args[0]} failed: {result.stdout[-3000:]} {result.stderr[-3000:]}')
    return result


def check(value, message):
    if not value:
        raise RuntimeError(message)


def main():
    check(os.environ.get('CLASHKING_DISPOSABLE_TIMESCALE') == '1' and os.environ.get('CLASHKING_DISPOSABLE_VALKEY') == '1', 'Disposable canonical fixtures required')
    check(os.environ.get('CLASHKING_FIXTURE_LOGICAL_WAL') == '1', 'Logical WAL fixture required')
    run_id = os.environ['CLASHKING_FIXTURE_RUN_ID']
    check(run_id.isalnum(), 'Invalid fixture run identity')
    containers = run(['docker', 'ps', '-q', '--filter', f'label=io.clashking.fixture.run={run_id}']).stdout.split()
    inspected = json.loads(run(['docker', 'inspect', *containers]).stdout)
    by_owner = {item['Config']['Labels'].get('io.clashking.fixture.owner'): item['Id'] for item in inspected}
    db = by_owner['with-test-timescale']
    cache = by_owner['with-test-integration']
    root = Path(__file__).resolve().parents[1]
    network = 'ck-pgsync-' + run_id.lower()
    es_container = None
    image = os.environ.get('PGSYNC_SMOKE_IMAGE', 'clashking/pgsync:single-pass-local')
    counter = 0

    def sql(query):
        return run(['docker', 'exec', '-i', db, 'psql', '-X', '-At', '-v', 'ON_ERROR_STOP=1', '-U', 'clashking_test', '-d', 'clashking_test'], input=query).stdout.strip()

    def es(path, method='GET', body=None):
        command = ['docker', 'exec', es_container, 'curl', '--silent', '--fail-with-body', '-X', method, 'http://localhost:9200' + path]
        if body is not None:
            command += ['-H', 'Content-Type: application/json', '-d', json.dumps(body)]
        return json.loads(run(command).stdout)

    def pgsync(args=(), entrypoint=None, expect_success=True):
        nonlocal counter
        counter += 1
        command = ['docker', 'run', '--rm', '--network', network, '--name', f'{network}-job-{counter}', '--label', f'io.clashking.fixture.run={run_id}', '--label', 'io.clashking.fixture.owner=pgsync-smoke', '-v', f'{root / "database/pgsync/schema.json"}:/config/schema.json:ro']
        env = {'PG_HOST': 'db', 'PG_PORT': '5432', 'POSTGRES_DB': 'clashking_test', 'PG_USER': 'clashking_test', 'PG_PASSWORD': 'clashking_test', 'PG_SSLMODE': 'disable', 'ELASTICSEARCH': 'true', 'ELASTICSEARCH_HOST': 'search', 'ELASTICSEARCH_PORT': '9200', 'ELASTICSEARCH_SCHEME': 'http', 'ELASTICSEARCH_RAISE_ON_ERROR': 'true', 'ELASTICSEARCH_RAISE_ON_EXCEPTION': 'true', 'ELASTICSEARCH_STREAMING_BULK': 'true', 'REDIS_HOST': 'cache', 'REDIS_PORT': '6379', 'REDIS_DB': '1', 'REDIS_CHECKPOINT': 'true'}
        for key, value in env.items():
            command += ['-e', f'{key}={value}']
        if entrypoint:
            command += ['--entrypoint', entrypoint]
        result = run(command + [image, *args], check=False)
        if expect_success:
            check(result.returncode == 0, result.stdout[-2000:] + result.stderr[-4000:])
        else:
            check(result.returncode != 0, 'Expected actual service failure')
        return result

    slot = 'clashking_test_clashking_players_v2'
    key = 'queue:' + slot + ':meta'
    def checkpoint():
        return run(['docker', 'exec', cache, 'valkey-cli', '--raw', '-n', '1', 'HGET', key, 'checkpoint']).stdout.strip()

    def marker():
        return datetime.datetime.now(datetime.timezone.utc).isoformat()

    def slot_queries(since):
        result = run(['docker', 'logs', '--since', since, db])
        return [line for line in (result.stdout + result.stderr).splitlines() if slot in line and 'PG_LOGICAL_SLOT_' in line]

    try:
        check(sql('SHOW wal_level;') == 'logical', 'Logical WAL not enabled')
        sql("ALTER SYSTEM SET log_statement='all';")
        sql('SELECT pg_reload_conf();')
        run(['docker', 'network', 'create', '--label', f'io.clashking.fixture.run={run_id}', network])
        run(['docker', 'network', 'connect', '--alias', 'db', network, db])
        run(['docker', 'network', 'connect', '--alias', 'cache', network, cache])
        es_container = run(['docker', 'run', '-d', '--network', network, '--network-alias', 'search', '--label', f'io.clashking.fixture.run={run_id}', '--label', 'io.clashking.fixture.owner=pgsync-smoke', '--memory', '2g', '-e', 'discovery.type=single-node', '-e', 'xpack.security.enabled=false', '-e', 'xpack.ml.enabled=false', '-e', 'ES_JAVA_OPTS=-Xms512m -Xmx512m', 'docker.elastic.co/elasticsearch/elasticsearch:8.19.17']).stdout.strip()
        for _ in range(120):
            try:
                if es('/_cluster/health')['status'] in ('green', 'yellow'):
                    break
            except RuntimeError:
                pass
            time.sleep(.5)
        else:
            raise RuntimeError('Elasticsearch did not become ready')
        sql("INSERT INTO basic_clan(tag,name,public_war_log,war_wins,member_count,badge_token,troops_donated,troops_received) VALUES('#CLAN','Fixture',true,0,1,'',0,0); INSERT INTO basic_player(tag,name,townhall_level) VALUES('#BASE','Base',16);")
        pgsync(['--config', '/config/schema.json'], entrypoint='bootstrap')
        sql("INSERT INTO basic_player(tag,name,townhall_level) SELECT '#P'||i,'Player '||i,16 FROM generate_series(1,6001) i;")
        system_id = sql('SELECT system_identifier FROM pg_control_system();')
        # Run the exact forward half of PGSync.pull, then exit as an interrupted
        # process would. The recovery CLI must complete that same observed range.
        forward = "from pgsync.sync import Sync; from pgsync.utils import config_loader; import json; s=Sync(next(d for d in config_loader('/config/schema.json') if d['index']=='clashking_players_v2')); xid=s.txid_current; s.search_client.bulk(s.index,s.sync(txmin=None,txmax=xid)); print(json.dumps({'xid':xid,'lsn':s.current_wal_lsn}))"
        result = pgsync(['-c', forward], entrypoint='python')
        boundary = json.loads(result.stdout.strip().splitlines()[-1])
        es('/clashking_players_v2/_refresh', 'POST')
        check(es('/clashking_players_v2/_count')['count'] == 6002, 'Forward pass incomplete')
        args = ['/opt/clashking/resume_initial.py', '--config', '/config/schema.json', '--index', 'clashking_players_v2', '--expect-database', 'clashking_test', '--expect-host', 'db', '--expect-system-id', system_id, '--expect-index-count', '6002', '--through-xid', str(boundary['xid']), '--through-lsn', boundary['lsn']]
        before_lsn = sql(f"SELECT confirmed_flush_lsn FROM pg_replication_slots WHERE slot_name='{slot}';")
        pgsync(args, entrypoint='python')
        check(checkpoint() == '', 'Preview wrote a checkpoint')
        es('/clashking_players_v2/_settings', 'PUT', {'index.blocks.write': True})
        started = marker()
        failed = pgsync(args + ['--mode', 'apply', '--forward-pass-confirmation', 'completed-forward-pass'], entrypoint='python', expect_success=False)
        check('elasticsearch.helpers.BulkIndexError' in failed.stdout + failed.stderr, 'Expected the real Elasticsearch write block to cause failure: ' + failed.stdout[-1000:] + failed.stderr[-4000:])
        check(checkpoint() == '', 'Failure advanced checkpoint')
        check(sql(f"SELECT confirmed_flush_lsn FROM pg_replication_slots WHERE slot_name='{slot}';") == before_lsn, 'Failure consumed the slot')
        check(not any('PG_LOGICAL_SLOT_GET_CHANGES' in line for line in slot_queries(started)), 'Failure called slot consume')
        es('/clashking_players_v2/_settings', 'PUT', {'index.blocks.write': False})
        started = marker()
        pgsync(args + ['--mode', 'apply', '--forward-pass-confirmation', 'completed-forward-pass'], entrypoint='python')
        queries = slot_queries(started)
        check(sum('PG_LOGICAL_SLOT_PEEK_CHANGES' in line for line in queries) == 1, f'Expected one peek: {queries}')
        check(sum('PG_LOGICAL_SLOT_GET_CHANGES' in line for line in queries) == 1, f'Expected one consume: {queries}')
        check(not any('OFFSET' in line or 'count(' in line.lower() for line in queries), 'Repeated scan/count remains')
        check(checkpoint() == str(boundary['xid']), 'Expected checkpoint not persisted')
        check(sql(f"SELECT confirmed_flush_lsn > '{before_lsn}'::pg_lsn FROM pg_replication_slots WHERE slot_name='{slot}';") == 't', 'Successful recovery did not advance the actual slot')
        check(sql(f"SELECT count(*) FROM pg_logical_slot_peek_changes('{slot}', '{boundary['lsn']}', NULL);") == '0', 'Successful recovery left changes inside its consumed boundary')
        pgsync(args + ['--mode', 'apply', '--forward-pass-confirmation', 'completed-forward-pass'], entrypoint='python')
        sql("UPDATE basic_player SET name='Changed' WHERE tag='#P1'; DELETE FROM basic_player WHERE tag='#P2';")
        pgsync(['--config', '/config/schema.json'])
        es('/_refresh', 'POST')
        check(es('/clashking_players_v2/_count')['count'] == 6001, 'Restart did not preserve deletion')
        check(es('/clashking_players_v2/_doc/%23P1')['_source']['name'] == 'Changed', 'Restart missed update')
        check(es('/clashking_clans_v2/_count')['count'] == 1, 'Other index did not initialize')
        print('PASS real PGSync: canonical schema, >5000 changes, one peek/consume, failed bulk leaves slot/checkpoint, preview/retry, restart update/delete and both indexes')
    finally:
        owned = run(['docker', 'ps', '-aq', '--filter', f'label=io.clashking.fixture.run={run_id}', '--filter', 'label=io.clashking.fixture.owner=pgsync-smoke'], check=False).stdout.split()
        if owned:
            run(['docker', 'rm', '-f', '-v', *owned], check=False)
        for container in (db, cache):
            run(['docker', 'network', 'disconnect', network, container], check=False)
        run(['docker', 'network', 'rm', network], check=False)


if __name__ == '__main__':
    main()
