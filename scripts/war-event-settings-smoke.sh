#!/usr/bin/env bash
set -euo pipefail
[[ ${CLASHKING_DISPOSABLE_TIMESCALE:-} == 1 ]] || exit 2
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
goose -env /dev/null -dir "$root/database/timescale" postgres "$TEST_DATABASE_URL" up-to 42
psql "$TEST_DATABASE_URL" -v ON_ERROR_STOP=1 <<'SQL'
INSERT INTO servers(id,name) VALUES('99999888','War event migration');
INSERT INTO basic_clan(tag,name,public_war_log,war_wins,member_count,badge_token,troops_donated,troops_received) VALUES('#VQQ','War clan',true,0,0,'',0,0);
INSERT INTO server_clans(server_id,tag) VALUES('99999888','#VQQ');
SQL
goose -env /dev/null -dir "$root/database/timescale" postgres "$TEST_DATABASE_URL" up-to 43
psql "$TEST_DATABASE_URL" -v ON_ERROR_STOP=1 <<'SQL'
DO $$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM server_clans WHERE server_id='99999888' AND NOT war_events_enabled) THEN RAISE EXCEPTION 'default not disabled'; END IF;
 BEGIN UPDATE server_clans SET war_events_enabled=NULL; RAISE EXCEPTION 'null accepted'; EXCEPTION WHEN not_null_violation THEN NULL; END;
END $$;
UPDATE server_clans SET war_events_enabled=true WHERE server_id='99999888';
SQL
goose -env /dev/null -dir "$root/database/timescale" postgres "$TEST_DATABASE_URL" down
goose -env /dev/null -dir "$root/database/timescale" postgres "$TEST_DATABASE_URL" up-to 43
psql "$TEST_DATABASE_URL" -v ON_ERROR_STOP=1 -c "DO \$\$ BEGIN IF NOT EXISTS(SELECT 1 FROM server_clans WHERE server_id='99999888' AND NOT war_events_enabled) THEN RAISE EXCEPTION 'reapply lost clan or enabled unexpectedly'; END IF; END \$\$;"
echo 'PASS war-event settings default, not-null, rollback and reapply'
bash "$root/scripts/donation-log-import-smoke.sh"
