#!/usr/bin/env bash
set -euo pipefail
[[ ${CLASHKING_DISPOSABLE_TIMESCALE:-} == 1 ]] || exit 2
[[ ${TEST_DATABASE_URL:-} == postgres://clashking_test:clashking_test@127.0.0.1:*/clashking_test?sslmode=disable ]] || exit 2
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
goose -env /dev/null -dir "$root/database/timescale" postgres "$TEST_DATABASE_URL" down-to 64
psql "$TEST_DATABASE_URL" -Xq -v ON_ERROR_STOP=1 <<'SQL'
INSERT INTO basic_clan(tag,name,public_war_log,war_wins,war_win_streak,member_count,badge_token,troops_donated,troops_received,capital_gold_total,location_id)
SELECT '#CAP'||lpad(i::text,6,'0'),'Cap fixture',true,120006-i,CASE WHEN i<=100 THEN (101-i)%10 ELSE 0 END,10,'',120006-i,120006-i,120006-i,
 CASE WHEN i>120000 THEN 32000008 ELSE 32000006+i%2 END
FROM generate_series(1,120005) i;
REFRESH MATERIALIZED VIEW clan_leaderboards;
CREATE TABLE expected_clan_ranks AS TABLE clan_leaderboards;
SQL
goose -env /dev/null -dir "$root/database/timescale" postgres "$TEST_DATABASE_URL" up-to 65
psql "$TEST_DATABASE_URL" -Xq -v ON_ERROR_STOP=1 <<'SQL'
CREATE TABLE expected_capped_clan_ranks AS SELECT r.tag,r.location_id,CASE WHEN r.donated_rank<=100000 THEN r.donated_rank END AS donated_rank,CASE WHEN r.received_rank<=100000 THEN r.received_rank END AS received_rank,CASE WHEN r.war_wins_rank<=100000 THEN r.war_wins_rank END AS war_wins_rank,CASE WHEN r.capital_gold_rank<=100000 THEN r.capital_gold_rank END AS capital_gold_rank,CASE WHEN r.war_win_streak_rank<=100000 AND c.war_win_streak>0 THEN r.war_win_streak_rank END AS war_win_streak_rank,CASE WHEN r.location_donated_rank<=1000 THEN r.location_donated_rank END AS location_donated_rank,CASE WHEN r.location_received_rank<=1000 THEN r.location_received_rank END AS location_received_rank,CASE WHEN r.location_war_wins_rank<=1000 THEN r.location_war_wins_rank END AS location_war_wins_rank,CASE WHEN r.location_capital_gold_rank<=1000 THEN r.location_capital_gold_rank END AS location_capital_gold_rank FROM expected_clan_ranks r JOIN basic_clan c USING(tag) WHERE (r.donated_rank<=100000) OR (r.received_rank<=100000) OR (r.war_wins_rank<=100000) OR (r.capital_gold_rank<=100000) OR (r.war_win_streak_rank<=100000 AND c.war_win_streak>0) OR (r.location_donated_rank<=1000) OR (r.location_received_rank<=1000) OR (r.location_war_wins_rank<=1000) OR (r.location_capital_gold_rank<=1000);
DO $$ BEGIN
 IF (SELECT count(*) FROM basic_clan)<>120005 THEN RAISE EXCEPTION 'raw clans changed'; END IF;
 IF (SELECT count(*) FROM clan_leaderboards)<>100005 THEN RAISE EXCEPTION 'unexpected capped union size'; END IF;
 IF EXISTS((TABLE clan_leaderboards EXCEPT TABLE expected_capped_clan_ranks) UNION ALL (TABLE expected_capped_clan_ranks EXCEPT TABLE clan_leaderboards)) THEN RAISE EXCEPTION 'rank order, cap or null mismatch'; END IF;
 IF EXISTS(SELECT 1 FROM clan_leaderboards l JOIN basic_clan c USING(tag) WHERE c.war_win_streak=0 AND l.war_win_streak_rank IS NOT NULL) THEN RAISE EXCEPTION 'zero streak retained'; END IF;
 IF NOT EXISTS(SELECT 1 FROM clan_leaderboards WHERE tag='#CAP120005' AND donated_rank IS NULL AND location_donated_rank=5) THEN RAISE EXCEPTION 'country-only qualifier lost'; END IF;
END $$;
REFRESH MATERIALIZED VIEW CONCURRENTLY clan_leaderboards;
SQL
goose -env /dev/null -dir "$root/database/timescale" postgres "$TEST_DATABASE_URL" down-to 64
psql "$TEST_DATABASE_URL" -Xq -v ON_ERROR_STOP=1 <<'SQL'
DO $$ BEGIN
 IF EXISTS((TABLE clan_leaderboards EXCEPT TABLE expected_clan_ranks) UNION ALL (TABLE expected_clan_ranks EXCEPT TABLE clan_leaderboards)) THEN RAISE EXCEPTION 'rollback changed ranks'; END IF;
 IF (SELECT count(*) FROM basic_clan)<>120005 THEN RAISE EXCEPTION 'rollback changed raw clans'; END IF;
END $$;
SQL
goose -env /dev/null -dir "$root/database/timescale" postgres "$TEST_DATABASE_URL" up-to 65
printf 'PASS actual Timescale/Goose: 120005 raw clans retained; exact global/country cap union, null placements, zero-streak exclusion, concurrent refresh and rollback.\n'
