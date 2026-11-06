#!/usr/bin/env bash
set -euo pipefail
[[ ${CLASHKING_DISPOSABLE_TIMESCALE:-} == 1 ]] || exit 2
[[ ${TEST_DATABASE_URL:-} == postgres://clashking_test:clashking_test@127.0.0.1:*/clashking_test?sslmode=disable ]] || exit 2
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
goose -env /dev/null -dir "$root/database/timescale" postgres "$TEST_DATABASE_URL" down-to 65
psql "$TEST_DATABASE_URL" -Xq -v ON_ERROR_STOP=1 <<'SQL'
INSERT INTO basic_player(tag,name,townhall_level,league_id) VALUES('#COUNTP','Fixture',16,NULL);
INSERT INTO basic_clan(tag,name,public_war_log,war_wins,member_count,badge_token,troops_donated,troops_received) VALUES('#COUNTC','Fixture',true,0,1,'',0,0);
INSERT INTO join_leave_history(time,type,clan_tag,player_tag,townhall_level) VALUES('2020-01-01 12:00Z','join','#COUNTC','#COUNTP',16);
INSERT INTO wars(war_id,clan_tag,opponent_tag,prep_time,start_time,end_time,size,war_type,state) VALUES(1,'#COUNTC','#OTHER','2020-01-01 01:00Z','2020-01-02 01:00Z','2020-01-03 01:00Z',15,'random','warEnded');
SQL
if goose -env /dev/null -dir "$root/database/timescale" postgres "$TEST_DATABASE_URL" up-to 66; then
 echo 'Unsafe publication was not rejected' >&2; exit 1
fi
psql "$TEST_DATABASE_URL" -Xq -v ON_ERROR_STOP=1 -c "INSERT INTO tracking_scheduled_jobs(job,period,last_tag,completed_at) VALUES('count_history_bootstrap_join_leave_history','2000-01-01','2000-01-01',now()),('count_history_bootstrap_wars','2000-01-01','2000-01-01',now())"
if goose -env /dev/null -dir "$root/database/timescale" postgres "$TEST_DATABASE_URL" up-to 66; then
 echo 'Stale partial history marker was accepted' >&2; exit 1
fi
psql "$TEST_DATABASE_URL" -Xq -v ON_ERROR_STOP=1 -c "DELETE FROM tracking_scheduled_jobs WHERE job LIKE 'count_history_bootstrap_%'"
through=$(date -u +%F)
system=$(psql "$TEST_DATABASE_URL" -XAtc 'SELECT system_identifier FROM pg_control_system()')
cd "$root/database"
DATABASE_URL="$TEST_DATABASE_URL" go run ./historycounts --expected-database clashking_test --expected-system "$system" --through "$through"
[[ $(psql "$TEST_DATABASE_URL" -XAtc "SELECT count(*) FROM tracking_scheduled_jobs WHERE job LIKE 'count_history_bootstrap_%'") == 0 ]]
DATABASE_URL="$TEST_DATABASE_URL" go run ./historycounts --expected-database clashking_test --expected-system "$system" --through "$through" --max-batches 1 --apply
[[ $(psql "$TEST_DATABASE_URL" -XAtc "SELECT count(*) FROM tracking_scheduled_jobs WHERE job LIKE 'count_history_bootstrap_%' AND completed_at IS NOT NULL") == 0 ]]
DATABASE_URL="$TEST_DATABASE_URL" go run ./historycounts --expected-database clashking_test --expected-system "$system" --through "$through" --max-batches 100 --apply
DATABASE_URL="$TEST_DATABASE_URL" go run ./historycounts --expected-database clashking_test --expected-system "$system" --through "$through" --max-batches 100 --apply
goose -env /dev/null -dir "$root/database/timescale" postgres "$TEST_DATABASE_URL" up-to 66
psql "$TEST_DATABASE_URL" -Xq -v ON_ERROR_STOP=1 <<'SQL'
DO $$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM api_global_counts WHERE player_count=1 AND clan_count=1 AND wars_stored=1 AND total_join_leaves=1) THEN RAISE EXCEPTION 'Published totals differ'; END IF;
 IF NOT EXISTS(SELECT 1 FROM townhall_counts WHERE level=16 AND total_count=1) OR NOT EXISTS(SELECT 1 FROM api_league_tier_counts WHERE league_tier_id=0 AND player_count=1) THEN RAISE EXCEPTION 'Published distributions differ'; END IF;
END $$;
SQL
goose -env /dev/null -dir "$root/database/timescale" postgres "$TEST_DATABASE_URL" down-to 65
psql "$TEST_DATABASE_URL" -Xq -v ON_ERROR_STOP=1 <<'SQL'
DO $$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM api_global_counts WHERE player_count=1 AND clan_count=1 AND wars_stored=1 AND total_join_leaves=1) THEN RAISE EXCEPTION 'Rollback differs'; END IF;
END $$;
SQL
echo 'PASS actual bounded history initializer: dry-run, one-batch bound, resume, repeat, unsafe publication rejection, exact totals/distributions and rollback'
