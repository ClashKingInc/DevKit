#!/usr/bin/env bash
set -euo pipefail
[[ ${CLASHKING_DISPOSABLE_TIMESCALE:-} == 1 ]] || exit 2
[[ ${TEST_DATABASE_URL:-} == postgres://clashking_test:clashking_test@127.0.0.1:*/clashking_test?sslmode=disable ]] || exit 2
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
goose -env /dev/null -dir "$root/database/timescale" postgres "$TEST_DATABASE_URL" up-to 58
psql "$TEST_DATABASE_URL" -v ON_ERROR_STOP=1 <<'SQL'
INSERT INTO servers(id,name,last_command_at) VALUES
('999999999999999591','Anchor','2026-08-25 20:34:38+00'),
('999999999999999592','Earlier','2026-07-24 15:46:47+00'),
('999999999999999593','Newer','2026-11-05 18:34:38.688226+00'),
('999999999999999594','Undated',NULL);
SQL
goose -env /dev/null -dir "$root/database/timescale" postgres "$TEST_DATABASE_URL" up-to 59
goose -env /dev/null -dir "$root/database/timescale" postgres "$TEST_DATABASE_URL" up-to 59
psql "$TEST_DATABASE_URL" -v ON_ERROR_STOP=1 <<'SQL'
DO $$ BEGIN
 IF (SELECT count(*) FROM server_activity_outage_adjustments)<>2 THEN RAISE EXCEPTION 'Unexpected audit count'; END IF;
 IF NOT EXISTS(SELECT 1 FROM servers WHERE id='999999999999999591' AND last_command_at='2026-11-05 18:29:58.483442+00') THEN RAISE EXCEPTION 'Anchor mismatch or repeat offset'; END IF;
 IF NOT EXISTS(SELECT 1 FROM servers WHERE id='999999999999999592' AND last_command_at='2026-10-04 13:42:07.483442+00') THEN RAISE EXCEPTION 'Relative gap changed'; END IF;
 IF NOT EXISTS(SELECT 1 FROM servers WHERE id='999999999999999593' AND last_command_at='2026-11-05 18:34:38.688226+00') THEN RAISE EXCEPTION 'Newer activity changed'; END IF;
 IF NOT EXISTS(SELECT 1 FROM servers WHERE id='999999999999999594' AND last_command_at IS NULL) THEN RAISE EXCEPTION 'Unknown activity invented'; END IF;
END $$;
UPDATE servers SET last_command_at='2026-11-05 19:00:00+00' WHERE id='999999999999999592';
SQL
goose -env /dev/null -dir "$root/database/timescale" postgres "$TEST_DATABASE_URL" down-to 58
psql "$TEST_DATABASE_URL" -v ON_ERROR_STOP=1 <<'SQL'
DO $$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM servers WHERE id='999999999999999591' AND last_command_at='2026-08-25 20:34:38+00') THEN RAISE EXCEPTION 'Rollback did not restore original'; END IF;
 IF NOT EXISTS(SELECT 1 FROM servers WHERE id='999999999999999592' AND last_command_at='2026-11-05 19:00:00+00') THEN RAISE EXCEPTION 'Rollback rewound real command'; END IF;
END $$;
SQL
goose -env /dev/null -dir "$root/database/timescale" postgres "$TEST_DATABASE_URL" up-to 59
printf 'PASS real SQL/Goose: exact offset, relative inactivity, newer/null dates retained, repeat safe, rollback preserves newer commands.\n'
