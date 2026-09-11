package schema

import (
	"context"
	"os"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"
)

func disposableConn(t *testing.T) *pgx.Conn {
	t.Helper()
	if os.Getenv("CLASHKING_DISPOSABLE_TIMESCALE") != "1" {
		t.Skip("requires disposable Timescale fixture")
	}
	conn, err := pgx.Connect(context.Background(), os.Getenv("TEST_DATABASE_URL"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { conn.Close(context.Background()) })
	return conn
}

func TestFinalBattleLeagueSchema(t *testing.T) {
	conn := disposableConn(t)
	ctx := context.Background()
	checks := []string{
		`SELECT count(*)=2 FROM timescaledb_information.hypertables WHERE hypertable_name IN ('battles_farming','battles_ranked')`,
		`SELECT count(*)=4 FROM timescaledb_information.jobs WHERE hypertable_name IN ('battles_farming','battles_ranked') AND proc_name IN ('policy_compression','policy_retention')`,
		`SELECT to_regclass('public.army_family_daily_stats_v2') IS NULL AND to_regclass('public.legend_daily_stats_v2') IS NULL`,
		`SELECT count(*)=0 FROM information_schema.columns WHERE table_schema='public' AND column_name IN ('army_hash','anchor_army_hash','parser_version')`,
		`SELECT data_type='smallint' AND is_nullable='NO' FROM information_schema.columns WHERE table_schema='public' AND table_name='battles_ranked' AND column_name='duration_seconds'`,
		`SELECT data_type='smallint' FROM information_schema.columns WHERE table_schema='public' AND table_name='battles_ranked' AND column_name='battle_mode'`,
		`SELECT to_regclass('public.legend_rankings_current') IS NOT NULL AND to_regclass('public.leaderboard_history_player_home') IS NOT NULL`,
	}
	for _, q := range checks {
		var ok bool
		if err := conn.QueryRow(ctx, q).Scan(&ok); err != nil || !ok {
			t.Fatalf("schema check failed: %s err=%v", q, err)
		}
	}
}

func TestRankedPerspectivesCountOnePhysicalAttackOnce(t *testing.T) {
	conn := disposableConn(t)
	ctx := context.Background()
	tx, err := conn.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx)
	_, err = tx.Exec(ctx, `INSERT INTO battles_ranked(player_tag,opponent_tag,battle_time,direction,battle_mode,player_town_hall,opponent_town_hall,stars,destruction_percentage,duration_seconds,looted_resources,share_code) VALUES ('#2PP','#9G2YV','2026-09-08T12:00:00Z',1,1,17,17,3,100,120,'{"gold":1}','u1x1'),('#9G2YV','#2PP','2026-09-08T12:00:00Z',2,1,17,17,3,100,120,NULL,'u1x1')`)
	if err != nil {
		t.Fatal(err)
	}
	var all, attacks int
	if err := tx.QueryRow(ctx, `SELECT count(*),count(*) FILTER(WHERE direction=1) FROM battles_ranked WHERE battle_time='2026-09-08T12:00:00Z'`).Scan(&all, &attacks); err != nil {
		t.Fatal(err)
	}
	if all != 2 || attacks != 1 {
		t.Fatalf("rows=%d attack aggregate=%d", all, attacks)
	}
}

func TestArmyCompositionFamilyAndDailyTotals(t *testing.T) {
	conn := disposableConn(t)
	ctx := context.Background()
	tx, err := conn.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx)
	var familyID int64
	err = tx.QueryRow(ctx, `WITH composition AS (
		INSERT INTO army_compositions(share_code,main_troops,clan_castle_troops,spells,heroes,equipment,pet_assignments,siege_machine_id)
		VALUES('u1x1','[{"id":1,"quantity":10}]','[{"id":2,"quantity":1}]','[{"id":3,"quantity":2,"clanCastle":false}]','{4}','[{"equipmentId":5,"heroId":4}]','[{"petId":6,"heroId":4}]',7)
		RETURNING share_code)
		INSERT INTO army_families(representative_share_code,name) SELECT share_code,'Root Riders' FROM composition RETURNING family_id`).Scan(&familyID)
	if err != nil {
		t.Fatal(err)
	}
	_, err = tx.Exec(ctx, `INSERT INTO army_family_members(share_code,family_id) VALUES('u1x1',$1)`, familyID)
	if err == nil {
		_, err = tx.Exec(ctx, `INSERT INTO army_family_daily_stats(day,cohort,family_id,attack_count,distinct_player_count,zero_star_count,one_star_count,two_star_count,three_star_count,destruction_percentage_sum,duration_seconds_sum)
			VALUES('2026-09-10','top_200',$1,2,2,0,0,1,1,180,240)`, familyID)
	}
	if err == nil {
		_, err = tx.Exec(ctx, `INSERT INTO legend_daily_stats(day,cohort,attack_count,distinct_player_count,zero_star_count,one_star_count,two_star_count,three_star_count,destruction_percentage_sum,duration_seconds_sum,hero_stats,pet_stats,equipment_stats,pet_hero_assignments)
			VALUES('2026-09-10','top_200',2,2,0,0,1,1,180,240,'[{"id":4,"uses":2,"triples":1}]','[{"id":6,"uses":2,"triples":1}]','[{"id":5,"uses":2,"triples":1}]','[{"petId":6,"heroId":4,"uses":2,"triples":1}]')`)
	}
	if err != nil {
		t.Fatal(err)
	}
	for _, q := range []string{
		`INSERT INTO army_family_daily_stats(day,cohort,family_id,attack_count,distinct_player_count,zero_star_count,one_star_count,two_star_count,three_star_count,destruction_percentage_sum,duration_seconds_sum) VALUES('2026-09-11','defense',1,1,1,0,0,0,1,100,120)`,
		`INSERT INTO legend_daily_stats(day,cohort,attack_count,distinct_player_count,zero_star_count,one_star_count,two_star_count,three_star_count,destruction_percentage_sum,duration_seconds_sum,hero_stats) VALUES('2026-09-11','legend_i',1,1,0,0,0,1,100,120,'[{"id":4,"uses":2,"triples":1}]')`,
	} {
		if _, err = tx.Exec(ctx, `SAVEPOINT invalid`); err != nil {
			t.Fatal(err)
		}
		if _, err = tx.Exec(ctx, q); err == nil {
			t.Fatalf("invalid aggregate accepted: %s", q)
		}
		if _, err = tx.Exec(ctx, `ROLLBACK TO SAVEPOINT invalid`); err != nil {
			t.Fatal(err)
		}
	}
}

func TestRankedQueryPlansUsePlayerAndAttackIndexes(t *testing.T) {
	conn := disposableConn(t)
	ctx := context.Background()
	tx, err := conn.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx)
	if _, err = tx.Exec(ctx, `INSERT INTO battles_ranked(player_tag,opponent_tag,battle_time,direction,battle_mode,player_town_hall,opponent_town_hall,stars,destruction_percentage,looted_resources) VALUES('#2PP','#9G2YV',now(),1,1,17,17,3,100,'{}')`); err != nil {
		t.Fatal(err)
	}
	if _, err = tx.Exec(ctx, `SET LOCAL enable_seqscan=off`); err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct{ q, want string }{
		{`EXPLAIN (COSTS OFF) SELECT * FROM battles_ranked WHERE player_tag='#2PP' AND battle_time >= now()-interval '30 days' ORDER BY battle_time DESC`, `idx_battles_ranked_player_time`},
		{`EXPLAIN (COSTS OFF) SELECT count(*) FROM battles_ranked WHERE battle_mode=1 AND direction=1 AND battle_time >= now()-interval '30 days'`, `idx_battles_ranked_attacks_time`},
	} {
		rows, e := tx.Query(ctx, tc.q)
		if e != nil {
			t.Fatal(e)
		}
		var plan []string
		for rows.Next() {
			var line string
			if e = rows.Scan(&line); e != nil {
				t.Fatal(e)
			}
			plan = append(plan, line)
		}
		rows.Close()
		if !strings.Contains(strings.Join(plan, "\n"), tc.want) {
			t.Fatalf("plan missing %s:\n%s", tc.want, strings.Join(plan, "\n"))
		}
	}
}
