"""Exercise actual PostgreSQL notifications through the installed PGSync trigger."""
import json
import os
import select
import time

import psycopg2

assert os.environ['POSTGRES_DB'] == 'clashking_test'
assert os.environ['PG_HOST'] == 'db'
args = dict(host='db', dbname='clashking_test', user=os.environ['PG_USER'], password=os.environ['PG_PASSWORD'])
listener = psycopg2.connect(**args)
writer = psycopg2.connect(**args)
listener.autocommit = writer.autocommit = True
try:
    with listener.cursor() as cursor:
        cursor.execute('LISTEN clashking_test')

    def events():
        deadline = time.monotonic() + .2
        result = []
        while time.monotonic() < deadline:
            select.select([listener], [], [], max(0, deadline - time.monotonic()))
            listener.poll()
            while listener.notifies:
                result.append(json.loads(listener.notifies.pop(0).payload))
        return result

    def execute(query, parameters=(), operation=None):
        with writer.cursor() as cursor:
            cursor.execute(query, parameters)
        received = events()
        if operation is None:
            assert not received, received
            return
        assert len(received) == 1, received
        message = received[0]
        assert message['tg_op'] == operation, message
        assert message['table'] == 'basic_player' and message['schema'] == 'public', message
        assert 'clashking_players_v2' in message['indices'], message
        assert message['xmin'] is not None, message
        identity = message['old'] if operation == 'DELETE' else message['new']
        assert identity['tag'] == '#NOTIFY', message

    execute("INSERT INTO basic_player(tag,name,townhall_level) VALUES('#NOTIFY','Notify',16)", operation='INSERT')
    execute("UPDATE basic_player SET observed_at=clock_timestamp(),trophies=100 WHERE tag='#NOTIFY'")
    execute("UPDATE basic_player SET name='Changed' WHERE tag='#NOTIFY'", operation='UPDATE')
    execute("UPDATE basic_player SET name='Changed' WHERE tag='#NOTIFY'")
    execute("UPDATE basic_player SET clan_tag='#CLAN' WHERE tag='#NOTIFY'", operation='UPDATE')
    execute("UPDATE basic_player SET clan_tag=NULL WHERE tag='#NOTIFY'", operation='UPDATE')
    execute("UPDATE basic_player SET league_id=105000036 WHERE tag='#NOTIFY'", operation='UPDATE')
    execute("UPDATE basic_player SET league_id=NULL WHERE tag='#NOTIFY'", operation='UPDATE')
    execute("UPDATE basic_player SET townhall_level=17 WHERE tag='#NOTIFY'", operation='UPDATE')
    execute("DELETE FROM basic_player WHERE tag='#NOTIFY'", operation='DELETE')
    print('PASS real PGSync notifications: insert/delete, configured changes, null transitions, unchanged values and observation-only suppression')
finally:
    writer.close()
    listener.close()
