#!/usr/bin/env bash
set -euo pipefail
[[ ${CLASHKING_DISPOSABLE_TIMESCALE:-} == 1 ]] || exit 2
[[ ${TEST_DATABASE_URL:-} == postgres://clashking_test:clashking_test@127.0.0.1:*/clashking_test?sslmode=disable ]] || exit 2
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
goose -env /dev/null -dir "$root/database/timescale" postgres "$TEST_DATABASE_URL" up-to 57
psql "$TEST_DATABASE_URL" -v ON_ERROR_STOP=1 <<'SQL'
INSERT INTO servers(id,name) VALUES('999999999999999581','Giveaway fixture');
INSERT INTO giveaways(id,server_id,prize,status,start_time,end_time,winners,entries,winners_list) VALUES
('absent','999999999999999581','Fixture','ended',now()-interval '2 days',now()-interval '1 day',1,'null','null'),
('retained','999999999999999581','Fixture','ended',now()-interval '2 days',now()-interval '1 day',1,'["999999999999999582"]','[{"user_id":"999999999999999582"}]');
SQL
goose -env /dev/null -dir "$root/database/timescale" postgres "$TEST_DATABASE_URL" up
psql "$TEST_DATABASE_URL" -v ON_ERROR_STOP=1 <<'SQL'
DO $$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM giveaways WHERE id='absent' AND entries='[]'::jsonb AND winners_list='[]'::jsonb) THEN RAISE EXCEPTION 'Absent collections not normalized'; END IF;
 IF NOT EXISTS(SELECT 1 FROM giveaways WHERE id='retained' AND entries='["999999999999999582"]'::jsonb AND winners_list='[{"user_id":"999999999999999582"}]'::jsonb) THEN RAISE EXCEPTION 'Existing entrant or winner changed'; END IF;
 BEGIN UPDATE giveaways SET entries='null'::jsonb WHERE id='absent'; RAISE EXCEPTION 'Invalid entries accepted'; EXCEPTION WHEN check_violation THEN NULL; END;
END $$;
SQL
goose -env /dev/null -dir "$root/database/timescale" postgres "$TEST_DATABASE_URL" down
goose -env /dev/null -dir "$root/database/timescale" postgres "$TEST_DATABASE_URL" up
goose -env /dev/null -dir "$root/database/timescale" postgres "$TEST_DATABASE_URL" up
printf 'Giveaway collection migration E2E passed: absent lists normalized, entrants/winners preserved, rollback/reapply safe.\n'
