#!/usr/bin/env bash
set -euo pipefail
[[ ${CLASHKING_DISPOSABLE_TIMESCALE:-} == 1 ]] || exit 2
[[ ${TEST_DATABASE_URL:-} == postgres://clashking_test:clashking_test@127.0.0.1:*/clashking_test?sslmode=disable ]] || exit 2
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
goose -env /dev/null -dir "$root/database/timescale" postgres "$TEST_DATABASE_URL" down-to 64
psql "$TEST_DATABASE_URL" -Xq -v ON_ERROR_STOP=1 <<'SQL'
INSERT INTO basic_player(tag,name,townhall_level,league_id,trophies) VALUES
('#COUNT1','One',16,105000036,5000),('#COUNT2','Two',16,NULL,0),('#COUNT3','Three',17,105000036,5100);
INSERT INTO basic_clan(tag,name,public_war_log,war_wins,member_count,badge_token,troops_donated,troops_received,cwl_league_id) VALUES
('#COUNT1','One',true,50,10,'',0,0,0),('#COUNT2','Two',true,51,10,'',0,0,48000001);
INSERT INTO join_leave_history(time,type,clan_tag,player_tag,townhall_level) VALUES
('2020-01-01 12:00Z','join','#COUNT1','#COUNT1',16),('2020-01-02 12:00Z','leave','#COUNT1','#COUNT1',16);
INSERT INTO wars(war_id,clan_tag,opponent_tag,prep_time,start_time,end_time,size,war_type,state) VALUES
(1,'#COUNT1','#COUNT2','2020-01-01 01:00Z','2020-01-02 01:00Z','2020-01-03 01:00Z',15,'random','warEnded'),
(2,'#COUNT2','#COUNT1','2020-01-01 01:00Z','2020-01-02 01:00Z','2020-01-03 01:00Z',15,'random','warEnded');
CALL refresh_continuous_aggregate('stats_join_leave_daily_counts','2020-01-01'::timestamptz,'2020-01-05'::timestamptz);
CALL refresh_continuous_aggregate('stats_war_daily_counts','2020-01-01'::timestamptz,'2020-01-05'::timestamptz);
REFRESH MATERIALIZED VIEW stats_player_count_snapshot;
REFRESH MATERIALIZED VIEW stats_clan_count_snapshot;
DO $$ BEGIN
 IF (SELECT row_count FROM stats_player_count_snapshot WHERE scope='total')<>3
 OR (SELECT row_count FROM stats_player_count_snapshot WHERE scope='townhall' AND dimension_id=16)<>2
 OR (SELECT row_count FROM stats_player_count_snapshot WHERE scope='league' AND dimension_id=0)<>1
 OR (SELECT row_count FROM stats_clan_count_snapshot WHERE scope='total')<>2
 OR (SELECT row_count FROM stats_clan_count_snapshot WHERE scope='cwl' AND dimension_id=0)<>1
 OR (SELECT sum(row_count) FROM stats_join_leave_daily_counts)<>2
 OR (SELECT sum(row_count) FROM stats_war_daily_counts)<>2
 THEN RAISE EXCEPTION 'initial exact count or null-group mismatch'; END IF;
END $$;
-- Late history and metadata-only updates must not require whole-history scans.
INSERT INTO join_leave_history(time,type,clan_tag,player_tag,townhall_level) VALUES ('2020-01-01 13:00Z','leave','#COUNT1','#COUNT2',16);
UPDATE wars SET clan_name='Renamed';
CALL refresh_continuous_aggregate('stats_join_leave_daily_counts',NULL::timestamptz,'2020-01-05'::timestamptz);
CALL refresh_continuous_aggregate('stats_war_daily_counts',NULL::timestamptz,'2020-01-05'::timestamptz);
DO $$ BEGIN
 IF (SELECT sum(row_count) FROM stats_join_leave_daily_counts)<>3 OR (SELECT sum(row_count) FROM stats_war_daily_counts)<>2 THEN RAISE EXCEPTION 'late or metadata update mismatch'; END IF;
END $$;
DELETE FROM join_leave_history WHERE time='2020-01-02 12:00Z';
UPDATE wars SET end_time='2020-01-04 01:00Z' WHERE clan_tag='#COUNT1';
CALL refresh_continuous_aggregate('stats_join_leave_daily_counts',NULL::timestamptz,'2020-01-06'::timestamptz);
CALL refresh_continuous_aggregate('stats_war_daily_counts',NULL::timestamptz,'2020-01-06'::timestamptz);
BEGIN;
REFRESH MATERIALIZED VIEW CONCURRENTLY stats_player_count_snapshot;
REFRESH MATERIALIZED VIEW CONCURRENTLY stats_clan_count_snapshot;
COMMIT;
DO $$ BEGIN
 IF (SELECT sum(row_count) FROM stats_join_leave_daily_counts)<>2 OR (SELECT sum(row_count) FROM stats_war_daily_counts)<>2
 OR (SELECT count(*) FROM stats_war_daily_counts WHERE row_count=1)<>2
 THEN RAISE EXCEPTION 'delete or date-move invalidation mismatch'; END IF;
END $$;
SQL
printf 'PASS actual Timescale count snapshots: grouped scans, nulls, late inserts, metadata updates, deletion, date move and transactional refresh.\n'
