#!/usr/bin/env bash
# Actual Goose upgrades/rollbacks against the owned disposable Timescale service.
set -euo pipefail
[[ ${CLASHKING_DISPOSABLE_TIMESCALE:-} == 1 ]] || exit 2
dashboard_schema_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dashboard_migrations="$dashboard_schema_root/database/timescale"
goose -env /dev/null -dir "$dashboard_migrations" postgres "$TEST_DATABASE_URL" down-to 76
psql "$TEST_DATABASE_URL" -v ON_ERROR_STOP=1 <<'SQL'
INSERT INTO auth_users(user_id,provider) VALUES('999999999999998780','discord');
INSERT INTO servers(id,name) VALUES('999999999999998781','Dashboard migration fixture');
INSERT INTO server_clan_categories(id,server_id,name,position)
VALUES('00000000-0000-4000-8000-000000000078','999999999999998781','Main',0);
INSERT INTO basic_clan(tag,name,public_war_log,war_wins,member_count,badge_token,troops_donated,troops_received)
VALUES('#QQY','Zeta',true,0,1,'',0,0),('#QQG','Alpha',true,0,1,'',0,0),('#QQJ','Alpha',true,0,1,'',0,0),('#QQL','Uncategorized',true,0,1,'',0,0);
INSERT INTO server_clans(server_id,tag,category_id)
VALUES('999999999999998781','#QQY','00000000-0000-4000-8000-000000000078'),
('999999999999998781','#QQG','00000000-0000-4000-8000-000000000078'),
('999999999999998781','#QQJ','00000000-0000-4000-8000-000000000078'),
('999999999999998781','#QQL',NULL);
SQL
goose -env /dev/null -dir "$dashboard_migrations" postgres "$TEST_DATABASE_URL" up-to 78
psql "$TEST_DATABASE_URL" -v ON_ERROR_STOP=1 <<'SQL'
DO $$ BEGIN
 IF (SELECT array_agg(tag ORDER BY position) FROM server_clans WHERE server_id='999999999999998781' AND category_id IS NOT NULL)<>ARRAY['#QQG','#QQJ','#QQY'] THEN RAISE EXCEPTION 'Initial name/tag order changed'; END IF;
 IF (SELECT position FROM server_clans WHERE server_id='999999999999998781' AND category_id IS NULL)<>0 THEN RAISE EXCEPTION 'Uncategorized order is not independent'; END IF;
 BEGIN UPDATE server_clans SET position=-1 WHERE server_id='999999999999998781'; RAISE EXCEPTION 'Negative position allowed'; EXCEPTION WHEN check_violation THEN NULL; END;
END $$;
INSERT INTO dashboard_access_grants(id,token_hash,user_id,server_id,source,permissions)
VALUES('00000000-0000-4000-8000-000000000079','grant-fixture','999999999999998780','999999999999998781','bot','{"manager":true,"sections":{}}');
INSERT INTO dashboard_scoped_sessions(id,grant_id,user_id,server_id,permissions,refresh_hash,expires_at)
VALUES('00000000-0000-4000-8000-000000000080','00000000-0000-4000-8000-000000000079','999999999999998780','999999999999998781','{"manager":true,"sections":{}}','first-browser',now()+interval '1 hour'),
('00000000-0000-4000-8000-000000000081','00000000-0000-4000-8000-000000000079','999999999999998780','999999999999998781','{"manager":true,"sections":{}}','second-browser',now()+interval '1 hour');
SQL
goose -env /dev/null -dir "$dashboard_migrations" postgres "$TEST_DATABASE_URL" down-to 76
psql "$TEST_DATABASE_URL" -v ON_ERROR_STOP=1 <<'SQL'
DO $$ BEGIN
 IF (SELECT count(*) FROM server_clans WHERE server_id='999999999999998781')<>4 THEN RAISE EXCEPTION 'Rollback lost clan memberships'; END IF;
 IF NOT EXISTS(SELECT 1 FROM dashboard_scoped_sessions WHERE id='00000000-0000-4000-8000-000000000081') OR EXISTS(SELECT 1 FROM dashboard_scoped_sessions WHERE id='00000000-0000-4000-8000-000000000080') THEN RAISE EXCEPTION 'Grant rollback did not retain newest browser session'; END IF;
END $$;
SQL
goose -env /dev/null -dir "$dashboard_migrations" postgres "$TEST_DATABASE_URL" up-to 78
psql "$TEST_DATABASE_URL" -v ON_ERROR_STOP=1 <<'SQL'
DO $$ BEGIN
 IF (SELECT array_agg(position ORDER BY position) FROM server_clans WHERE server_id='999999999999998781' AND category_id IS NOT NULL)<>ARRAY[0,1,2] THEN RAISE EXCEPTION 'Reapply did not restore consecutive order'; END IF;
END $$;
DELETE FROM servers WHERE id='999999999999998781';
DELETE FROM basic_clan WHERE tag=ANY(ARRAY['#QQY','#QQG','#QQJ','#QQL']);
DELETE FROM auth_users WHERE user_id='999999999999998780';
SQL
printf 'PASS: Dashboard clan order upgrade/defaults/constraint/rollback/reapply and reusable-grant rollback retains newest browser\n'
