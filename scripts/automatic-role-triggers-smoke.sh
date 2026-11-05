#!/usr/bin/env bash
set -euo pipefail
[[ ${CLASHKING_DISPOSABLE_TIMESCALE:-} == 1 ]] || exit 2
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
goose -env /dev/null -dir "$root/database/timescale" postgres "$TEST_DATABASE_URL" up-to 46
psql "$TEST_DATABASE_URL" -v ON_ERROR_STOP=1 -c "INSERT INTO servers(id,name) VALUES('999999999999998750','Trigger migration')"
goose -env /dev/null -dir "$root/database/timescale" postgres "$TEST_DATABASE_URL" up-to 47
psql "$TEST_DATABASE_URL" -v ON_ERROR_STOP=1 <<'SQL'
DO $$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM servers WHERE id='999999999999998750' AND auto_role_triggers IS NULL) THEN RAISE EXCEPTION 'Existing default narrowed'; END IF;
 BEGIN UPDATE servers SET auto_role_triggers=ARRAY['invalid'] WHERE id='999999999999998750'; RAISE EXCEPTION 'Invalid trigger accepted'; EXCEPTION WHEN check_violation THEN NULL; END;
 BEGIN UPDATE servers SET auto_role_triggers=ARRAY[NULL]::text[] WHERE id='999999999999998750'; RAISE EXCEPTION 'Null trigger accepted'; EXCEPTION WHEN check_violation THEN NULL; END;
END $$;
UPDATE servers SET auto_role_triggers=ARRAY[]::text[] WHERE id='999999999999998750';
UPDATE servers SET auto_role_triggers=ARRAY['member_join','townhall_change'] WHERE id='999999999999998750';
SQL
goose -env /dev/null -dir "$root/database/timescale" postgres "$TEST_DATABASE_URL" down
goose -env /dev/null -dir "$root/database/timescale" postgres "$TEST_DATABASE_URL" up-to 47
psql "$TEST_DATABASE_URL" -v ON_ERROR_STOP=1 -c "DO \$\$ BEGIN IF NOT EXISTS(SELECT 1 FROM servers WHERE id='999999999999998750' AND auto_role_triggers IS NULL) THEN RAISE EXCEPTION 'Reapply default invalid'; END IF; END \$\$;"
printf 'PASS: automatic trigger migration, constraints, rollback and reapply\n'
