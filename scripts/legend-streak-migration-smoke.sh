#!/usr/bin/env bash
set -euo pipefail
[[ ${CLASHKING_DISPOSABLE_TIMESCALE:-} == 1 ]] || exit 2
[[ ${TEST_DATABASE_URL:-} == postgres://clashking_test:clashking_test@127.0.0.1:*/clashking_test?sslmode=disable ]] || exit 2
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
goose -env /dev/null -dir "$root/database/timescale" postgres "$TEST_DATABASE_URL" up-to 28
psql "$TEST_DATABASE_URL" -v ON_ERROR_STOP=1 <<'SQL'
INSERT INTO battles_ranked(player_tag,opponent_tag,battle_time,direction,battle_mode,player_town_hall,opponent_town_hall,stars,destruction_percentage,duration_seconds,looted_resources) VALUES
('#PYLQ','#PYLR',now()-interval '6 hours',1,2,18,18,3,100,90,'{}'),
('#PYLQ','#PYLR',now()-interval '5 hours',1,2,18,18,1,50,90,'{}'),
('#PYLQ','#PYLR',now()-interval '4 hours',1,2,18,18,3,100,90,'{}'),
('#PYLQ','#PYLR',now()-interval '3 hours',2,2,18,18,0,20,90,NULL),
('#PYLQ','#PYLR',now()-interval '2 hours',1,1,18,18,0,20,90,'{}'),
('#PYLQ','#PYLR',now()-interval '1 hour',1,2,18,18,3,100,90,'{}'),
('#PYLG','#PYLR',now()-interval '1 hour',1,2,18,18,3,100,90,'{}');
SQL
goose -env /dev/null -dir "$root/database/timescale" postgres "$TEST_DATABASE_URL" up
psql "$TEST_DATABASE_URL" -v ON_ERROR_STOP=1 <<'SQL'
DO $$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM legend_attack_streaks WHERE player_tag='#PYLQ' AND current_streak=2 AND last_non_triple_at IS NOT NULL) THEN RAISE EXCEPTION 'Streak reset/backfill wrong'; END IF;
 IF NOT EXISTS(SELECT 1 FROM legend_attack_streaks WHERE player_tag='#PYLG' AND current_streak=1 AND last_non_triple_at IS NULL) THEN RAISE EXCEPTION 'Unobserved start not preserved'; END IF;
END $$;
SQL
goose -env /dev/null -dir "$root/database/timescale" postgres "$TEST_DATABASE_URL" up
printf 'Legend streak migration E2E passed: retained suffix backfilled, other modes/directions excluded, unknown start retained, repeat migration no-op.\n'
