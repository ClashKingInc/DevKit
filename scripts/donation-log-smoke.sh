#!/usr/bin/env bash
# Exercise actual Goose rollback/reapply against an owned disposable service.
set -euo pipefail
[[ ${CLASHKING_DISPOSABLE_TIMESCALE:-} == 1 ]] || exit 2
donation_schema_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
donation_migrations="$donation_schema_root/database/timescale"
psql "$TEST_DATABASE_URL" -v ON_ERROR_STOP=1 <<'SQL'
INSERT INTO servers(id,name) VALUES('999999999999998791','Donation migration fixture');
INSERT INTO basic_clan(tag,name,public_war_log,war_wins,member_count,badge_token,troops_donated,troops_received)
VALUES('#QQPY','Donation migration',true,0,0,'',0,0);
INSERT INTO server_clans(server_id,tag) VALUES('999999999999998791','#QQPY');
INSERT INTO server_logs(server_id,clan_tag,type,webhook_id)
VALUES('999999999999998791','#QQPY','donation_log','999999999999998792');
SQL
goose -env /dev/null -dir "$donation_migrations" postgres "$TEST_DATABASE_URL" down-to 78
psql "$TEST_DATABASE_URL" -v ON_ERROR_STOP=1 <<'SQL'
DO $$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM server_logs WHERE server_id='999999999999998791' AND type='donation_log') THEN RAISE EXCEPTION 'Rollback removed a destination'; END IF;
 BEGIN
 INSERT INTO server_logs(server_id,clan_tag,type,webhook_id)
 VALUES('999999999999998791','#QQPY','donation_log','999999999999998793');
 RAISE EXCEPTION 'Rollback allowed a donation log write';
 EXCEPTION WHEN check_violation THEN NULL; END;
END $$;
SQL
goose -env /dev/null -dir "$donation_migrations" postgres "$TEST_DATABASE_URL" up
psql "$TEST_DATABASE_URL" -v ON_ERROR_STOP=1 <<'SQL'
UPDATE server_logs SET webhook_id='999999999999998794'
WHERE server_id='999999999999998791' AND type='donation_log';
DO $$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM server_logs WHERE server_id='999999999999998791' AND webhook_id='999999999999998794') THEN RAISE EXCEPTION 'Reapply did not retain the destination'; END IF;
 BEGIN
 UPDATE server_logs SET type='unknown_log' WHERE server_id='999999999999998791';
 RAISE EXCEPTION 'Allowlist accepted an unknown log';
 EXCEPTION WHEN check_violation THEN NULL; END;
END $$;
DELETE FROM servers WHERE id='999999999999998791';
DELETE FROM basic_clan WHERE tag='#QQPY';
SQL
echo 'PASS donation log Goose rollback preserves destination, blocks new writes, reapplies and retains the type allowlist'
