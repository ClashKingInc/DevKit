#!/usr/bin/env bash
set -euo pipefail
[[ ${CLASHKING_DISPOSABLE_TIMESCALE:-} == 1 ]] || { echo 'Disposable Timescale required' >&2; exit 2; }
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
goose -env /dev/null -dir "$root/database/timescale" postgres "$TEST_DATABASE_URL" up-to 35
psql "$TEST_DATABASE_URL" -v ON_ERROR_STOP=1 <<'SQL'
INSERT INTO servers(id,name) VALUES('999999999999998810','Roster role fixture');
INSERT INTO role_refresh_jobs(id,server_id,user_id) VALUES('roster-fixture','999999999999998810','999999999999998811');
SQL
goose -env /dev/null -dir "$root/database/timescale" postgres "$TEST_DATABASE_URL" up-to 40
psql "$TEST_DATABASE_URL" -v ON_ERROR_STOP=1 <<'SQL'
DO $$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM role_refresh_jobs WHERE id='roster-fixture' AND cardinality(roster_role_ids)=0) THEN RAISE EXCEPTION 'Existing job inputs changed'; END IF;
 BEGIN
  UPDATE role_refresh_jobs SET roster_role_ids=ARRAY['bad'] WHERE id='roster-fixture';
  RAISE EXCEPTION 'Malformed role accepted';
 EXCEPTION WHEN check_violation THEN NULL;
 END;
 BEGIN
  UPDATE role_refresh_jobs SET roster_role_ids=ARRAY[NULL]::text[] WHERE id='roster-fixture';
  RAISE EXCEPTION 'Null role accepted';
 EXCEPTION WHEN check_violation THEN NULL;
 END;
END $$;
UPDATE role_refresh_jobs SET roster_role_ids=ARRAY['999999999999998812','999999999999998813'] WHERE id='roster-fixture';
SQL
goose -env /dev/null -dir "$root/database/timescale" postgres "$TEST_DATABASE_URL" down
psql "$TEST_DATABASE_URL" -v ON_ERROR_STOP=1 <<'SQL'
DO $$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM role_refresh_jobs WHERE id='roster-fixture') THEN RAISE EXCEPTION 'Rollback deleted the existing job'; END IF;
END $$;
SQL
goose -env /dev/null -dir "$root/database/timescale" postgres "$TEST_DATABASE_URL" up-to 40
echo 'PASS roster role job migration, validation, rollback preservation and reapply'
