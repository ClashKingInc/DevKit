#!/usr/bin/env bash
set -euo pipefail
[[ ${CLASHKING_DISPOSABLE_TIMESCALE:-} == 1 ]] || exit 2
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
goose -env /dev/null -dir "$root/database/timescale" postgres "$TEST_DATABASE_URL" up-to 47
psql "$TEST_DATABASE_URL" -v ON_ERROR_STOP=1 <<'SQL'
INSERT INTO servers(id,name) VALUES('999999999999998901','Warning retirement');
INSERT INTO basic_clan(tag,name,public_war_log,war_wins,member_count,badge_token,troops_donated,troops_received) VALUES('#PYL','Retained clan',true,0,0,'',0,0);
INSERT INTO server_clans(server_id,tag) VALUES('999999999999998901','#PYL');
INSERT INTO server_clan_member_warnings(server_id,clan_tag,channel_id,below_count) VALUES('999999999999998901','#PYL','999999999999998902',10);
SQL
goose -env /dev/null -dir "$root/database/timescale" postgres "$TEST_DATABASE_URL" up-to 48
psql "$TEST_DATABASE_URL" -v ON_ERROR_STOP=1 <<'SQL'
DO $$ BEGIN
 IF to_regclass('public.server_clan_member_warnings') IS NOT NULL THEN RAISE EXCEPTION 'Warning table remains'; END IF;
 IF NOT EXISTS(SELECT 1 FROM server_clans WHERE server_id='999999999999998901' AND tag='#PYL') THEN RAISE EXCEPTION 'Retirement removed the linked clan'; END IF;
END $$;
SQL
goose -env /dev/null -dir "$root/database/timescale" postgres "$TEST_DATABASE_URL" down
psql "$TEST_DATABASE_URL" -v ON_ERROR_STOP=1 -c "SELECT count(*) FROM server_clan_member_warnings"
goose -env /dev/null -dir "$root/database/timescale" postgres "$TEST_DATABASE_URL" up-to 48
printf 'PASS: member warnings removed; linked clan preserved; rollback structure and reapply verified\n'
