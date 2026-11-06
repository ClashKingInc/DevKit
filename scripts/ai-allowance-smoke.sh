#!/usr/bin/env bash
set -euo pipefail
[[ ${CLASHKING_DISPOSABLE_TIMESCALE:-} == 1 ]] || exit 2
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
goose -env /dev/null -dir "$root/database/timescale" postgres "$TEST_DATABASE_URL" down-to 67
psql "$TEST_DATABASE_URL" -Xq -v ON_ERROR_STOP=1 <<'SQL'
INSERT INTO servers(id,name,ai_monthly_limit_usd) VALUES
('999999999999997801','Old default',0.05),
('999999999999997802','Higher override',1),
('999999999999997803','Lower override',0.02);
SQL
goose -env /dev/null -dir "$root/database/timescale" postgres "$TEST_DATABASE_URL" up-to 68
psql "$TEST_DATABASE_URL" -Xq -v ON_ERROR_STOP=1 <<'SQL'
INSERT INTO servers(id,name) VALUES('999999999999997804','New default');
DO $$ BEGIN
 IF (SELECT count(*) FROM servers WHERE id IN ('999999999999997801','999999999999997804') AND ai_monthly_limit_usd=0.10)<>2 THEN RAISE EXCEPTION 'Standard allowance not raised'; END IF;
 IF NOT EXISTS(SELECT 1 FROM servers WHERE id='999999999999997802' AND ai_monthly_limit_usd=1) OR NOT EXISTS(SELECT 1 FROM servers WHERE id='999999999999997803' AND ai_monthly_limit_usd=0.02) THEN RAISE EXCEPTION 'Manual allowance changed'; END IF;
END $$;
SQL
goose -env /dev/null -dir "$root/database/timescale" postgres "$TEST_DATABASE_URL" down-to 67
psql "$TEST_DATABASE_URL" -Xq -v ON_ERROR_STOP=1 <<'SQL'
INSERT INTO servers(id,name) VALUES('999999999999997805','Rollback default');
DO $$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM servers WHERE id='999999999999997805' AND ai_monthly_limit_usd=0.05) OR NOT EXISTS(SELECT 1 FROM servers WHERE id='999999999999997804' AND ai_monthly_limit_usd=0.10) THEN RAISE EXCEPTION 'Rollback changed existing allowance'; END IF;
END $$;
SQL
echo 'PASS ten-cent AI migration: old/new defaults, custom overrides and non-destructive rollback'
