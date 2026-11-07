#!/usr/bin/env bash
set -euo pipefail
[[ ${CLASHKING_DISPOSABLE_TIMESCALE:-} == 1 ]] || exit 2
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
goose -env /dev/null -dir "$root/database/timescale" postgres "$TEST_DATABASE_URL" down-to 68
psql "$TEST_DATABASE_URL" -Xq -v ON_ERROR_STOP=1 <<'SQL'
INSERT INTO servers(id,name) VALUES('999999999999990601','Reddit split');
INSERT INTO server_logs(server_id,type,webhook_id,thread_id,reddit_role_id,reddit_accounts,disabled)
VALUES('999999999999990601','reddit_feed','999999999999990602','999999999999990603','999999999999990604',ARRAY['One','Two'],true);
SQL
goose -env /dev/null -dir "$root/database/timescale" postgres "$TEST_DATABASE_URL" up-to 69
psql "$TEST_DATABASE_URL" -Xq -v ON_ERROR_STOP=1 <<'SQL'
DO $$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM server_logs WHERE type='reddit_user_feed' AND reddit_accounts=ARRAY['One','Two'] AND reddit_include_comments AND disabled AND thread_id='999999999999990603' AND reddit_role_id='999999999999990604') THEN RAISE EXCEPTION 'Watched feed migration lost settings'; END IF;
 IF NOT EXISTS(SELECT 1 FROM server_logs WHERE type='reddit_feed' AND cardinality(reddit_accounts)=0 AND reddit_min_townhall IS NULL) THEN RAISE EXCEPTION 'Recruitment defaults changed'; END IF;
END $$;
SQL
if goose -env /dev/null -dir "$root/database/timescale" postgres "$TEST_DATABASE_URL" down; then
 echo 'Refused to protect Reddit settings' >&2; exit 1
fi
psql "$TEST_DATABASE_URL" -Xq -v ON_ERROR_STOP=1 -c "DELETE FROM server_logs WHERE server_id='999999999999990601'"
goose -env /dev/null -dir "$root/database/timescale" postgres "$TEST_DATABASE_URL" down-to 68
goose -env /dev/null -dir "$root/database/timescale" postgres "$TEST_DATABASE_URL" up-to 69
echo 'PASS Reddit split migration: destinations, names, role, disabled state and comments preserved; unsafe downgrade blocked; empty downgrade succeeds'
