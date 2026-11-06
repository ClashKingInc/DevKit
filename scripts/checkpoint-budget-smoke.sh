#!/usr/bin/env bash
set -euo pipefail
[[ ${CLASHKING_DISPOSABLE_TIMESCALE:-} == 1 ]] || exit 2
[[ ${TEST_DATABASE_URL:-} == postgres://clashking_test:clashking_test@127.0.0.1:*/clashking_test?sslmode=disable ]] || exit 2
checkpoint_original="$(psql "$TEST_DATABASE_URL" -XAt -v ON_ERROR_STOP=1 -c 'SHOW max_wal_size')"
[[ $checkpoint_original =~ ^[0-9]+(kB|MB|GB|TB)$ ]] || exit 2
restore_checkpoint() {
  psql "$TEST_DATABASE_URL" -Xq -v ON_ERROR_STOP=1 -c "ALTER SYSTEM SET max_wal_size='$checkpoint_original'" -c 'SELECT pg_reload_conf()' >/dev/null
}
trap restore_checkpoint EXIT
psql "$TEST_DATABASE_URL" -Xq -v ON_ERROR_STOP=1 <<'SQL'
CREATE TABLE checkpoint_reload_probe AS SELECT pg_postmaster_start_time() AS started,
 current_setting('max_slot_wal_keep_size') AS slot_limit,
 current_setting('min_wal_size') AS min_wal_size;
ALTER SYSTEM SET max_wal_size='16GB';
SELECT pg_reload_conf();
SQL
sleep 1
psql "$TEST_DATABASE_URL" -Xq -v ON_ERROR_STOP=1 <<'SQL'
DO $$ BEGIN
 IF current_setting('max_wal_size')<>'16GB' THEN RAISE EXCEPTION 'checkpoint reload failed'; END IF;
 IF NOT EXISTS (SELECT 1 FROM checkpoint_reload_probe WHERE started=pg_postmaster_start_time()
   AND slot_limit=current_setting('max_slot_wal_keep_size') AND min_wal_size=current_setting('min_wal_size'))
 THEN RAISE EXCEPTION 'restart, data, or unrelated WAL setting changed'; END IF;
 IF current_setting('fsync')<>'on' OR current_setting('full_page_writes')<>'on' OR current_setting('synchronous_commit')<>'on'
 THEN RAISE EXCEPTION 'durability setting changed'; END IF;
END $$;
SQL
restore_checkpoint
sleep 1
[[ $(psql "$TEST_DATABASE_URL" -XAt -v ON_ERROR_STOP=1 -c 'SHOW max_wal_size') == "$checkpoint_original" ]]
psql "$TEST_DATABASE_URL" -Xq -v ON_ERROR_STOP=1 -c 'DROP TABLE checkpoint_reload_probe'
trap - EXIT
printf 'PASS real Timescale online checkpoint reload and rollback; data, startup time, retention and durability preserved.\n'
