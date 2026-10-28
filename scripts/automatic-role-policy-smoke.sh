#!/usr/bin/env bash
# Actual additive upgrade and rollback against the canonical disposable database.
set -euo pipefail
[[ ${CLASHKING_DISPOSABLE_TIMESCALE:-} == 1 ]] || exit 2
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
goose -env /dev/null -dir "$root/database/timescale" postgres "$TEST_DATABASE_URL" up-to 44
psql "$TEST_DATABASE_URL" -v ON_ERROR_STOP=1 <<'SQL'
INSERT INTO servers(id,name) VALUES('999999999999998740','Automatic policy migration');
INSERT INTO role_refresh_jobs(id,server_id,user_id) VALUES('policy-migration','999999999999998740','999999999999998741');
SQL
goose -env /dev/null -dir "$root/database/timescale" postgres "$TEST_DATABASE_URL" up-to 46
psql "$TEST_DATABASE_URL" -v ON_ERROR_STOP=1 <<'SQL'
DO $$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM servers WHERE id='999999999999998740' AND auto_role_treatment='both' AND cardinality(auto_role_blacklist_ids)=0) THEN RAISE EXCEPTION 'Existing server policy changed'; END IF;
 IF NOT EXISTS(SELECT 1 FROM role_refresh_jobs WHERE id='policy-migration' AND role_treatment='both') THEN RAISE EXCEPTION 'Existing job policy changed'; END IF;
 BEGIN UPDATE servers SET auto_role_treatment='invalid' WHERE id='999999999999998740'; RAISE EXCEPTION 'Invalid policy accepted'; EXCEPTION WHEN check_violation THEN NULL; END;
 BEGIN UPDATE servers SET auto_role_blacklist_ids=ARRAY['bad'] WHERE id='999999999999998740'; RAISE EXCEPTION 'Invalid role ID accepted'; EXCEPTION WHEN check_violation THEN NULL; END;
 BEGIN UPDATE servers SET auto_role_blacklist_ids=ARRAY[NULL]::text[] WHERE id='999999999999998740'; RAISE EXCEPTION 'Null role accepted'; EXCEPTION WHEN check_violation THEN NULL; END;
END $$;
UPDATE servers SET auto_role_treatment='remove',auto_role_blacklist_ids=ARRAY['999999999999998742'] WHERE id='999999999999998740';
UPDATE role_refresh_jobs SET role_treatment='add' WHERE id='policy-migration';
SQL
goose -env /dev/null -dir "$root/database/timescale" postgres "$TEST_DATABASE_URL" down
psql "$TEST_DATABASE_URL" -v ON_ERROR_STOP=1 -c "DO \$\$ BEGIN IF NOT EXISTS(SELECT 1 FROM role_refresh_jobs WHERE id='policy-migration' AND role_treatment='add') THEN RAISE EXCEPTION 'Automatic rollback removed manual policy'; END IF; END \$\$;"
goose -env /dev/null -dir "$root/database/timescale" postgres "$TEST_DATABASE_URL" up-to 46
psql "$TEST_DATABASE_URL" -v ON_ERROR_STOP=1 -c "DO \$\$ BEGIN IF NOT EXISTS(SELECT 1 FROM servers WHERE id='999999999999998740' AND auto_role_treatment='both' AND cardinality(auto_role_blacklist_ids)=0) THEN RAISE EXCEPTION 'Reapply did not restore defaults'; END IF; END \$\$;"
printf 'PASS: automatic role policy upgrade, defaults, constraints, rollback and reapply\n'
