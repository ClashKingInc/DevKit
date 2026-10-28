#!/usr/bin/env bash
set -euo pipefail
[[ ${CLASHKING_DISPOSABLE_TIMESCALE:-} == 1 ]] || exit 2
[[ ${TEST_DATABASE_URL:-} == postgres://clashking_test:clashking_test@127.0.0.1:*/clashking_test?sslmode=disable ]] || exit 2
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
goose -env /dev/null -dir "$root/database/timescale" postgres "$TEST_DATABASE_URL" up-to 27
psql "$TEST_DATABASE_URL" -v ON_ERROR_STOP=1 <<'SQL'
INSERT INTO servers(id,name) VALUES('99990001','Donation migration');
INSERT INTO basic_clan(tag,name,public_war_log,war_wins,member_count,badge_token,troops_donated,troops_received) VALUES('#PYLQ','Migration Clan',true,0,0,'',0,0),('#PYLR','Other Clan',true,0,0,'',0,0);
INSERT INTO server_clans(tag,server_id) VALUES('#PYLQ','99990001'),('#PYLR','99990001');
INSERT INTO server_logs(server_id,clan_tag,type,webhook_id,thread_id,message_id,disabled) VALUES
('99990001','#PYLQ','donation_log','999901','999911','999921',false),
('99990001','#PYLR','donation_log','999902',NULL,NULL,true),
('99990001',NULL,'donation_log','999903',NULL,NULL,false),
('99990001','#PYLQ','join_log','999904',NULL,NULL,false);
SQL
goose -env /dev/null -dir "$root/database/timescale" postgres "$TEST_DATABASE_URL" up
psql "$TEST_DATABASE_URL" -v ON_ERROR_STOP=1 <<'SQL'
DO $$ BEGIN
 IF EXISTS(SELECT 1 FROM server_logs WHERE type='donation_log') THEN RAISE EXCEPTION 'Old donation log remains'; END IF;
 IF (SELECT count(*) FROM autoboards WHERE server_id='99990001' AND board_type='donations')<>3 THEN RAISE EXCEPTION 'Destination lost'; END IF;
 IF NOT EXISTS(SELECT 1 FROM autoboards a JOIN autoboard_targets t ON t.autoboard_id=a.id WHERE a.webhook_id='999901' AND a.thread_id='999911' AND a.enabled AND a.message_id IS NULL AND t.target='#PYLQ') THEN RAISE EXCEPTION 'Clan/thread destination changed'; END IF;
 IF NOT EXISTS(SELECT 1 FROM autoboards a JOIN autoboard_targets t ON t.autoboard_id=a.id WHERE a.webhook_id='999902' AND NOT a.enabled AND a.next_run_at IS NULL AND t.target='#PYLR') THEN RAISE EXCEPTION 'Disabled destination changed'; END IF;
 IF NOT EXISTS(SELECT 1 FROM autoboards a WHERE a.webhook_id='999903' AND a.target_scope='family' AND NOT EXISTS(SELECT 1 FROM autoboard_targets t WHERE t.autoboard_id=a.id)) THEN RAISE EXCEPTION 'Family scope changed'; END IF;
 IF (SELECT count(*) FROM server_logs WHERE type='join_log' AND server_id='99990001')<>1 THEN RAISE EXCEPTION 'Unrelated log changed'; END IF;
 BEGIN
  INSERT INTO server_logs(server_id,type,webhook_id) VALUES('99990001','donation_log','999901');
  RAISE EXCEPTION 'Retired type accepted';
 EXCEPTION WHEN check_violation THEN NULL;
 END;
END $$;
SQL
goose -env /dev/null -dir "$root/database/timescale" postgres "$TEST_DATABASE_URL" up
printf 'Donation-log migration E2E passed: destination/thread/scope/disabled state preserved; event message not reused; retired type rejected.\n'
