#!/usr/bin/env bash
set -euo pipefail
[[ ${CLASHKING_DISPOSABLE_TIMESCALE:-} == 1 ]] || { echo 'Disposable Timescale required' >&2; exit 2; }
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
goose -env /dev/null -dir "$root/database/timescale" postgres "$TEST_DATABASE_URL" up-to 34
psql "$TEST_DATABASE_URL" -v ON_ERROR_STOP=1 <<'SQL'
INSERT INTO servers(id,name) VALUES('999999999999998801','Group fixture'),('999999999999998802','Other group fixture');
INSERT INTO rosters(id,server_id,alias) VALUES('00000000-0000-4000-8000-000000000001','999999999999998801','Existing');
INSERT INTO roster_members(roster_id,tag,name) VALUES('00000000-0000-4000-8000-000000000001','#PYL','Existing member');
SQL
goose -env /dev/null -dir "$root/database/timescale" postgres "$TEST_DATABASE_URL" up-to 35
psql "$TEST_DATABASE_URL" -v ON_ERROR_STOP=1 <<'SQL'
DO $$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM roster_members WHERE tag='#PYL' AND member_group_id IS NULL) THEN RAISE EXCEPTION 'Existing member changed'; END IF;
END $$;
INSERT INTO roster_member_groups(id,server_id,name) VALUES('00000000-0000-4000-8000-000000000011','999999999999998801','Group A'),('00000000-0000-4000-8000-000000000012','999999999999998802','Other server');
INSERT INTO roster_member_group_settings(roster_id,member_group_id,server_id) VALUES('00000000-0000-4000-8000-000000000001','00000000-0000-4000-8000-000000000011','999999999999998801');
UPDATE roster_members SET member_group_id='00000000-0000-4000-8000-000000000011' WHERE tag='#PYL';
DO $$ BEGIN
 BEGIN
  INSERT INTO roster_member_group_settings(roster_id,member_group_id,server_id) VALUES('00000000-0000-4000-8000-000000000001','00000000-0000-4000-8000-000000000012','999999999999998801');
  RAISE EXCEPTION 'Cross-server label accepted';
 EXCEPTION WHEN foreign_key_violation THEN NULL;
 END;
 BEGIN
  DELETE FROM roster_member_groups WHERE id='00000000-0000-4000-8000-000000000011';
  RAISE EXCEPTION 'Assigned label deleted';
 EXCEPTION WHEN foreign_key_violation THEN NULL;
 END;
END $$;
UPDATE roster_members SET member_group_id=NULL WHERE tag='#PYL';
DELETE FROM roster_member_groups WHERE id='00000000-0000-4000-8000-000000000011';
DO $$ BEGIN
 IF EXISTS(SELECT 1 FROM roster_member_group_settings) THEN RAISE EXCEPTION 'Unused settings did not cascade'; END IF;
END $$;
DELETE FROM servers WHERE id IN ('999999999999998801','999999999999998802');
SQL
goose -env /dev/null -dir "$root/database/timescale" postgres "$TEST_DATABASE_URL" down
goose -env /dev/null -dir "$root/database/timescale" postgres "$TEST_DATABASE_URL" up-to 35
echo 'PASS roster label upgrade, existing member preservation, tenant constraints, assigned-label protection and rollback/reapply'
