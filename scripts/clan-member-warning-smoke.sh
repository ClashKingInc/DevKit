#!/usr/bin/env bash
set -euo pipefail
[[ ${CLASHKING_DISPOSABLE_TIMESCALE:-} == 1 ]] || { echo 'Disposable Timescale required' >&2; exit 2; }
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
goose -env /dev/null -dir "$root/database/timescale" postgres "$TEST_DATABASE_URL" up-to 40
psql "$TEST_DATABASE_URL" -v ON_ERROR_STOP=1 <<'SQL'
INSERT INTO servers(id,name) VALUES('999999999999998901','Warning fixture');
INSERT INTO basic_clan(tag,name,public_war_log,war_wins,member_count,badge_token,troops_donated,troops_received) VALUES('#PYL','Warning clan',true,0,0,'',0,0);
INSERT INTO server_clans(server_id,tag) VALUES('999999999999998901','#PYL');
SQL
goose -env /dev/null -dir "$root/database/timescale" postgres "$TEST_DATABASE_URL" up-to 41
psql "$TEST_DATABASE_URL" -v ON_ERROR_STOP=1 <<'SQL'
INSERT INTO server_clan_member_warnings(server_id,clan_tag,channel_id,below_count,above_count)
VALUES('999999999999998901','#PYL','999999999999998902',10,45);
DO $$ BEGIN
 BEGIN
  INSERT INTO server_clan_member_warnings(server_id,clan_tag,channel_id,below_count)
  VALUES('999999999999998901','#OTHER','999999999999998902',10);
  RAISE EXCEPTION 'Unlinked clan accepted';
 EXCEPTION WHEN foreign_key_violation THEN NULL;
 END;
 BEGIN
  UPDATE server_clan_member_warnings SET below_count=50,above_count=10;
  RAISE EXCEPTION 'Overlapping thresholds accepted';
 EXCEPTION WHEN check_violation THEN NULL;
 END;
 BEGIN
  UPDATE server_clan_member_warnings SET below_count=NULL,above_count=NULL;
  RAISE EXCEPTION 'Empty thresholds accepted';
 EXCEPTION WHEN check_violation THEN NULL;
 END;
 BEGIN
  UPDATE server_clan_member_warnings SET channel_id='bad';
  RAISE EXCEPTION 'Malformed destination accepted';
 EXCEPTION WHEN check_violation THEN NULL;
 END;
END $$;
DELETE FROM server_clans WHERE server_id='999999999999998901';
DO $$ BEGIN
 IF EXISTS(SELECT 1 FROM server_clan_member_warnings) THEN RAISE EXCEPTION 'Unlinked clan warning survived'; END IF;
END $$;
SQL
goose -env /dev/null -dir "$root/database/timescale" postgres "$TEST_DATABASE_URL" down
psql "$TEST_DATABASE_URL" -v ON_ERROR_STOP=1 <<'SQL'
DO $$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM servers WHERE id='999999999999998901') THEN RAISE EXCEPTION 'Rollback removed server'; END IF;
END $$;
SQL
goose -env /dev/null -dir "$root/database/timescale" postgres "$TEST_DATABASE_URL" up-to 41
echo 'PASS member warning settings constraints, unlink cascade, rollback and reapply'
