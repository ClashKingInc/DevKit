#!/usr/bin/env bash
set -euo pipefail
[[ ${CLASHKING_DISPOSABLE_TIMESCALE:-} == 1 ]] || { echo 'Disposable Timescale required' >&2; exit 2; }
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Exercise this migration even when later release migrations are in the fixture.
goose -env /dev/null -dir "$root/database/timescale" postgres "$TEST_DATABASE_URL" down-to 66
psql "$TEST_DATABASE_URL" -v ON_ERROR_STOP=1 <<'SQL'
INSERT INTO servers(id,name) VALUES('999999999999994900','Manual refresh migration');
INSERT INTO role_refresh_requests(id,server_id,actor_id,target_id,target_kind,channel_id,categories)
VALUES('999999999999994901','999999999999994900','999999999999994902','999999999999994902','user','999999999999994903',ARRAY['nicknames']);
INSERT INTO role_refresh_jobs(id,server_id,user_id,request_id)
VALUES('manual-refresh-migration','999999999999994900','999999999999994902','999999999999994901');
SQL
if goose -env /dev/null -dir "$root/database/timescale" postgres "$TEST_DATABASE_URL" down; then
  echo 'Rollback stranded active manual work' >&2; exit 1
fi
psql "$TEST_DATABASE_URL" -v ON_ERROR_STOP=1 -c "UPDATE role_refresh_jobs SET completed_at=now() WHERE id='manual-refresh-migration'"
goose -env /dev/null -dir "$root/database/timescale" postgres "$TEST_DATABASE_URL" down
psql "$TEST_DATABASE_URL" -v ON_ERROR_STOP=1 <<'SQL'
DO $$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM role_refresh_jobs WHERE id='manual-refresh-migration' AND completed_at IS NOT NULL) THEN
 RAISE EXCEPTION 'Rollback removed completed member work'; END IF;
END $$;
SQL
goose -env /dev/null -dir "$root/database/timescale" postgres "$TEST_DATABASE_URL" up-to 66
echo 'PASS manual refresh header migration, active rollback guard, member-work preservation and reapply'
