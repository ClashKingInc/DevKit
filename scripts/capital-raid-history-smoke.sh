#!/usr/bin/env bash
set -euo pipefail
[[ ${CLASHKING_DISPOSABLE_TIMESCALE:-} == 1 ]] || { echo 'Disposable Timescale required' >&2; exit 2; }
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
goose -env /dev/null -dir "$root/database/timescale" postgres "$TEST_DATABASE_URL" up-to 41
goose -env /dev/null -dir "$root/database/timescale" postgres "$TEST_DATABASE_URL" up-to 42
psql "$TEST_DATABASE_URL" -v ON_ERROR_STOP=1 <<'SQL'
INSERT INTO capital_raid_history(clan_tag,start_time,end_time,state,data)
VALUES('#PYL','2026-10-16 07:00Z','2026-10-19 07:00Z','ended','{"capitalTotalLoot":1000}');
DO $$ BEGIN
 BEGIN
  INSERT INTO capital_raid_history(clan_tag,start_time,end_time,state,data)
  VALUES('#PYL','2026-10-23 07:00Z','2026-10-20 07:00Z','ended','{}');
  RAISE EXCEPTION 'Inverted raid window accepted';
 EXCEPTION WHEN check_violation THEN NULL;
 END;
 BEGIN
  UPDATE capital_raid_history SET data='[]';
  RAISE EXCEPTION 'Non-object raid accepted';
 EXCEPTION WHEN check_violation THEN NULL;
 END;
 BEGIN
  UPDATE capital_raid_history SET state='unknown';
  RAISE EXCEPTION 'Invalid raid state accepted';
 EXCEPTION WHEN check_violation THEN NULL;
 END;
END $$;
SQL
goose -env /dev/null -dir "$root/database/timescale" postgres "$TEST_DATABASE_URL" down
goose -env /dev/null -dir "$root/database/timescale" postgres "$TEST_DATABASE_URL" up-to 42
echo 'PASS raid history schema constraints, rollback and reapply'
