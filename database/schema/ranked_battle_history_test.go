package schema

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"
)

func TestArmyHashV2Vectors(t *testing.T) {
	raw, err := os.ReadFile("../../contracts/army-hash-v2.json")
	if err != nil {
		t.Fatal(err)
	}
	var contract struct {
		Vectors []struct {
			Normalized string `json:"normalized_share_code"`
			Hex        string `json:"sha256_hex"`
		} `json:"vectors"`
	}
	if err = json.Unmarshal(raw, &contract); err != nil {
		t.Fatal(err)
	}
	for _, vector := range contract.Vectors {
		digest := sha256.Sum256(append([]byte{2}, []byte(vector.Normalized)...))
		if hex.EncodeToString(digest[:]) != vector.Hex {
			t.Fatalf("invalid hash vector for %q", vector.Normalized)
		}
	}
}

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
		`SELECT count(*)=0 FROM timescaledb_information.hypertables WHERE hypertable_name IN ('league_hitrate_stats','ranked_league_tier_stats','legend_daily_stats','army_family_daily_stats')`,
		`SELECT count(*)=0 FROM timescaledb_information.jobs WHERE hypertable_name IN ('league_hitrate_stats','ranked_league_tier_stats','legend_daily_stats','army_family_daily_stats')`,
		`SELECT to_regclass('public.ranked_league_groups') IS NULL AND to_regclass('public.ranked_item_presence_slots') IS NULL AND to_regclass('public.ranked_army_stats_prefix') IS NULL`,
		`SELECT count(*)=9 FROM information_schema.columns WHERE table_schema='public' AND table_name='ranked_league_group_members' AND column_name IN ('season_id','group_tag','league_tier_id','player_tag','player_name','town_hall','placement','league_trophies','maximum_battle_count')`,
		`SELECT count(*)=6 FROM information_schema.columns WHERE table_schema='public' AND table_name='ranked_league_group_members' AND column_name IN ('attack_win_count','attack_loss_count','attack_star_count','defense_win_count','defense_loss_count','defense_star_count')`,
		`SELECT count(*)=0 FROM information_schema.columns WHERE table_schema='public' AND table_name='ranked_league_group_members' AND column_name IN ('clan_tag','clan_name','observed_at','missing_at','promoted','demoted','state')`,
		`SELECT to_regclass('public.legend_history') IS NOT NULL`,
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
	hash := make([]byte, 32)
	_, err = tx.Exec(ctx, `INSERT INTO army_compositions(army_hash,normalized_share_code,main_troops,spells,heroes,equipment,pet_assignments) VALUES($1,'u1x1', '[{"id":1,"quantity":1}]','[{"id":2,"quantity":1,"clanCastle":false},{"id":2,"quantity":1,"clanCastle":true}]','{1}','[{"equipmentId":3,"heroId":1}]','[{"petId":4,"heroId":1}]')`, hash)
	if err != nil {
		t.Fatal(err)
	}
	_, err = tx.Exec(ctx, `INSERT INTO battles_ranked(player_tag,opponent_tag,battle_time,direction,battle_mode,player_town_hall,opponent_town_hall,stars,destruction_percentage,duration_seconds,looted_resources,share_code,army_hash) VALUES ('#2PP','#9G2YV','2026-09-08T12:00:00Z','attack','ranked',17,17,3,100,120,'{"gold":1}','u1x1',$1),('#9G2YV','#2PP','2026-09-08T12:00:00Z','defense','ranked',17,17,3,100,120,NULL,'u1x1',$1)`, hash)
	if err != nil {
		t.Fatal(err)
	}
	var all, attacks int
	if err := tx.QueryRow(ctx, `SELECT count(*),count(*) FILTER(WHERE direction='attack') FROM battles_ranked WHERE battle_time='2026-09-08T12:00:00Z'`).Scan(&all, &attacks); err != nil {
		t.Fatal(err)
	}
	if all != 2 || attacks != 1 {
		t.Fatalf("rows=%d attack aggregate=%d", all, attacks)
	}
}

func TestRankedGroupMemberConvergesOnCorrectedGroup(t *testing.T) {
	conn := disposableConn(t)
	ctx := context.Background()
	tx, err := conn.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx)
	_, err = tx.Exec(ctx, `INSERT INTO ranked_league_group_members(season_id,group_tag,league_tier_id,player_tag,player_name,placement,league_trophies,attack_win_count,attack_loss_count,defense_win_count,defense_loss_count) VALUES(1,'#2PP',1,'#9G2YV','Player',1,1000,1,0,1,0) ON CONFLICT(season_id,player_tag) DO UPDATE SET group_tag=EXCLUDED.group_tag`)
	if err != nil {
		t.Fatal(err)
	}
	_, err = tx.Exec(ctx, `INSERT INTO ranked_league_group_members(season_id,group_tag,league_tier_id,player_tag,player_name,placement,league_trophies,attack_win_count,attack_loss_count,defense_win_count,defense_loss_count) VALUES(1,'#P0Y',1,'#9G2YV','Player',1,1000,1,0,1,0) ON CONFLICT(season_id,player_tag) DO UPDATE SET group_tag=EXCLUDED.group_tag`)
	if err != nil {
		t.Fatal(err)
	}
	var group string
	var count int
	if err = tx.QueryRow(ctx, `SELECT max(group_tag),count(*) FROM ranked_league_group_members WHERE season_id=1 AND player_tag='#9G2YV'`).Scan(&group, &count); err != nil {
		t.Fatal(err)
	}
	if group != "#P0Y" || count != 1 {
		t.Fatalf("group=%s rows=%d", group, count)
	}
}

func TestArmyIdentityAndFamilyAssignmentAreImmutable(t *testing.T) {
	conn := disposableConn(t)
	ctx := context.Background()
	tx, err := conn.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx)
	hash := make([]byte, 32)
	for _, q := range []string{
		`INSERT INTO army_compositions(army_hash,normalized_share_code) VALUES($1,'u1x1')`,
		`INSERT INTO army_families(anchor_army_hash,representative_share_code,family_name,source,named_by_subject) VALUES($1,'u1x1','Root Riders','admin','subject-1')`,
		`INSERT INTO army_family_members(army_hash,anchor_army_hash,troop_housing_similarity,spell_capacity_similarity,heroes_exact,equipment_similarity,equipment_difference_count,matching_version) VALUES($1,$1,1,1,true,1,0,'v1')`,
	} {
		if _, err = tx.Exec(ctx, q, hash); err != nil {
			t.Fatal(err)
		}
	}
	if _, err = tx.Exec(ctx, `UPDATE army_families SET family_name='Root Riders Updated'`); err != nil {
		t.Fatalf("mutable family metadata rejected: %v", err)
	}
	for _, q := range []string{`UPDATE army_compositions SET normalized_share_code='changed'`, `UPDATE army_families SET anchor_army_hash=decode(repeat('01',32),'hex')`, `DELETE FROM army_family_members`} {
		if _, err = tx.Exec(ctx, `SAVEPOINT immutable`); err != nil {
			t.Fatal(err)
		}
		if _, err = tx.Exec(ctx, q); err == nil {
			t.Fatalf("immutable write accepted: %s", q)
		}
		if _, err = tx.Exec(ctx, `ROLLBACK TO SAVEPOINT immutable`); err != nil {
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
	hash := make([]byte, 32)
	if _, err = tx.Exec(ctx, `INSERT INTO army_compositions(army_hash,normalized_share_code) VALUES($1,'plan')`, hash); err != nil {
		t.Fatal(err)
	}
	if _, err = tx.Exec(ctx, `INSERT INTO battles_ranked(player_tag,opponent_tag,battle_time,direction,battle_mode,player_town_hall,opponent_town_hall,stars,destruction_percentage,army_hash) VALUES('#2PP','#9G2YV',now(),'attack','ranked',17,17,3,100,$1)`, hash); err != nil {
		t.Fatal(err)
	}
	if _, err = tx.Exec(ctx, `SET LOCAL enable_seqscan=off`); err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct{ q, want string }{
		{`EXPLAIN (COSTS OFF) SELECT * FROM battles_ranked WHERE player_tag='#2PP' AND battle_time >= now()-interval '30 days' ORDER BY battle_time DESC`, `idx_battles_ranked_player_time`},
		{`EXPLAIN (COSTS OFF) SELECT count(*) FROM battles_ranked WHERE battle_mode='ranked' AND direction='attack' AND battle_time >= now()-interval '30 days'`, `idx_battles_ranked_attacks_time`},
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
