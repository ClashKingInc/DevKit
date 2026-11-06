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
# Publication must work without any historical bootstrap checkpoint.
psql "$TEST_DATABASE_URL" -Xq -v ON_ERROR_STOP=1 <<'SQL'
REFRESH MATERIALIZED VIEW townhall_counts;
REFRESH MATERIALIZED VIEW api_league_tier_counts;
REFRESH MATERIALIZED VIEW war_league_counts;
CREATE TABLE fixture_distribution_definitions AS
SELECT oid,relname,pg_get_viewdef(oid) AS definition FROM pg_class
WHERE relname IN ('townhall_counts','api_league_tier_counts','war_league_counts');
ANALYZE basic_player;
ANALYZE basic_clan;
ANALYZE join_leave_history;
ANALYZE wars;
SQL
goose -env /dev/null -dir "$root/database/timescale" postgres "$TEST_DATABASE_URL" up-to 67
psql "$TEST_DATABASE_URL" -Xq -v ON_ERROR_STOP=1 <<'SQL'
DO $$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM api_global_counts WHERE player_count=approximate_row_count('basic_player') AND clan_count=approximate_row_count('basic_clan') AND wars_stored=approximate_row_count('wars') AND total_join_leaves=approximate_row_count('join_leave_history')) THEN RAISE EXCEPTION 'Published totals do not match the estimator'; END IF;
 IF NOT EXISTS(SELECT 1 FROM townhall_counts WHERE level=16 AND total_count=1) OR NOT EXISTS(SELECT 1 FROM api_league_tier_counts WHERE league_tier_id=0 AND player_count=1) THEN RAISE EXCEPTION 'Published distributions differ'; END IF;
 IF EXISTS(SELECT 1 FROM fixture_distribution_definitions f LEFT JOIN pg_class c ON c.oid=f.oid WHERE c.oid IS NULL OR pg_get_viewdef(c.oid) IS DISTINCT FROM f.definition) THEN RAISE EXCEPTION 'Distribution view changed'; END IF;
 IF to_regclass('stats_join_leave_daily_counts') IS NOT NULL OR to_regclass('stats_war_daily_counts') IS NOT NULL THEN RAISE EXCEPTION 'Unused history aggregates remain'; END IF;
 IF (SELECT count(*) FROM join_leave_history)<>1 OR (SELECT count(*) FROM wars)<>1 THEN RAISE EXCEPTION 'Raw history changed'; END IF;
END $$;
SQL
goose -env /dev/null -dir "$root/database/timescale" postgres "$TEST_DATABASE_URL" down-to 65
psql "$TEST_DATABASE_URL" -Xq -v ON_ERROR_STOP=1 <<'SQL'
DO $$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM api_global_counts WHERE player_count=1 AND clan_count=1 AND wars_stored=1 AND total_join_leaves=1) THEN RAISE EXCEPTION 'Rollback differs'; END IF;
END $$;
SQL
echo 'PASS actual approximate count publication: no bootstrap, estimator values, exact distributions, raw preservation and rollback'
