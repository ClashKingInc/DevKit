package schema

import (
	"context"
	"os"
	"os/exec"
	"testing"

	"github.com/ClashKingInc/DevKit/database/migrations/migrateutil"
	"github.com/jackc/pgx/v5"
)

func TestArmyCodeFamilyCompatibilityMigration(t *testing.T) {
	if os.Getenv("CLASHKING_DISPOSABLE_TIMESCALE") != "1" {
		t.Skip("requires disposable Timescale fixture")
	}
	if os.Getenv("CLASHKING_TIMESCALE_PROFILE") != "baseline-013" {
		t.Skip("requires baseline-013 migration profile")
	}
	ctx := context.Background()
	conn, err := pgx.Connect(ctx, os.Getenv("TEST_DATABASE_URL"))
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close(ctx)

	run := func(sql string, args ...any) {
		t.Helper()
		if _, err := conn.Exec(ctx, sql, args...); err != nil {
			t.Fatal(err)
		}
	}
	check := func(sql string, args ...any) {
		t.Helper()
		var ok bool
		if err := conn.QueryRow(ctx, sql, args...).Scan(&ok); err != nil || !ok {
			t.Fatalf("check failed: %s (%v)", sql, err)
		}
	}
	reject := func(sql string, args ...any) {
		t.Helper()
		tx, err := conn.Begin(ctx)
		if err != nil {
			t.Fatal(err)
		}
		defer tx.Rollback(ctx)
		if _, err := tx.Exec(ctx, sql, args...); err == nil {
			t.Fatalf("invalid write accepted: %s", sql)
		}
	}
	migrate := func(command ...string) error {
		t.Helper()
		args := append([]string{"-env", "/dev/null", "-dir", "../timescale"}, command...)
		cmd := exec.Command("goose", args...)
		cmd.Env = append(os.Environ(),
			"GOOSE_DRIVER=postgres",
			"GOOSE_DBSTRING="+os.Getenv("TEST_DATABASE_URL"),
			"GOOSE_TABLE=goose_db_version",
		)
		output, err := cmd.CombinedOutput()
		if err != nil {
			t.Log(string(output))
		}
		return err
	}

	check(`SELECT max(version_id)=13 FROM goose_db_version WHERE is_applied`)
	run(`INSERT INTO army_compositions(
		army_hash,normalized_share_code,heroes,equipment
	) VALUES
		(decode(repeat('aa',32),'hex'),'u1x0','{1,2}','[{"equipmentId":3,"heroId":1},{"equipmentId":4,"heroId":2}]'),
		(decode(repeat('bb',32),'hex'),'u2x0','{1,2}','[{"equipmentId":3,"heroId":1}]');
	INSERT INTO army_families(
		anchor_army_hash,representative_share_code,family_name,source,named_by_subject
	) VALUES (
		decode(repeat('aa',32),'hex'),'u1x0','  Root   Riders  ','admin','subject-1'
	);
	INSERT INTO army_family_members(
		army_hash,anchor_army_hash,troop_housing_similarity,spell_capacity_similarity,
		heroes_exact,equipment_similarity,equipment_difference_count,matching_version
	) VALUES (
		decode(repeat('bb',32),'hex'),decode(repeat('aa',32),'hex'),0.9000,0.8000,
		true,0.7500,2,'v1'
	);
	INSERT INTO army_family_daily_stats(
		anchor_army_hash,day,attack_count,distinct_player_count,
		zero_star_count,one_star_count,two_star_count,three_star_count,
		destruction_percentage_sum,duration_seconds_sum
	) VALUES (
		decode(repeat('aa',32),'hex'),'2026-08-01',2,2,0,0,1,1,180,200
	);
	INSERT INTO legend_daily_stats(
		day,league_tier_id,town_hall,attack_count,distinct_player_count,
		perfect_320_player_count,zero_star_count,one_star_count,two_star_count,
		three_star_count,destruction_percentage_sum,duration_seconds_sum
	) VALUES ('2026-08-01',1,18,2,2,0,0,0,1,1,180,200);
	INSERT INTO battles_ranked(
		player_tag,opponent_tag,battle_time,direction,battle_mode,
		player_town_hall,opponent_town_hall,stars,destruction_percentage,
		duration_seconds,share_code,army_hash
	) VALUES
		('#P0Y','#P0L',now()-interval '1 day','attack','legend',
		 18,18,3,100,120,'u2x0',decode(repeat('bb',32),'hex')),
		('#P0L','#P0Y',now()-interval '1 day','defense','legend',
		 18,18,3,100,120,'u2x0',decode(repeat('bb',32),'hex'));
	`)
	check(`SELECT count(*)=0 FROM timescaledb_information.chunks
		WHERE hypertable_name='battles_ranked' AND is_compressed`)
	if err := migrate("up-to", "14"); err != nil {
		t.Fatal("nullable defense loot expansion:", err)
	}
	check(`SELECT max(version_id)=14 FROM goose_db_version WHERE is_applied`)
	cfg := migrateutil.Config{TimescaleURL: os.Getenv("TEST_DATABASE_URL"), Env: map[string]string{}}
	if err := migrateutil.ClearRankedDefenseLoot(ctx, cfg); err != nil {
		t.Fatal("defense loot dry run:", err)
	}
	check(`SELECT looted_resources='{}'::jsonb FROM battles_ranked WHERE player_tag='#P0L'`)
	cfg.Env = map[string]string{
		"RANKED_DEFENSE_LOOT_CLEANUP_APPLY":      "true",
		"RANKED_BATTLELOG_WRITERS_PAUSED":        "true",
		"RANKED_DEFENSE_LOOT_CLEANUP_BATCH_SIZE": "1",
		"RANKED_DEFENSE_LOOT_CLEANUP_DATABASE":   "clashking_test",
	}
	if err := migrateutil.ClearRankedDefenseLoot(ctx, cfg); err != nil {
		t.Fatal("defense loot apply:", err)
	}
	check(`SELECT looted_resources IS NULL FROM battles_ranked WHERE player_tag='#P0L'`)
	check(`SELECT looted_resources='{}'::jsonb FROM battles_ranked WHERE player_tag='#P0Y'`)

	if err := migrate("up-to", "15"); err != nil {
		t.Fatal(err)
	}
	check(`SELECT max(version_id)=15 FROM goose_db_version WHERE is_applied`)
	check(`SELECT pg_get_constraintdef(oid)='PRIMARY KEY (family_id)'
		FROM pg_constraint WHERE conrelid='public.army_families'::regclass AND contype='p'`)
	check(`SELECT pg_get_constraintdef(oid)='PRIMARY KEY (share_code)'
		FROM pg_constraint WHERE conrelid='public.army_family_members'::regclass AND contype='p'`)
	check(`SELECT family_id IS NOT NULL AND name='Root Riders'
		AND hero_ids='{1,2}'::integer[] AND equipment_ids='{3,4}'::integer[]
		FROM army_families WHERE representative_share_code='u1x0'`)
	check(`SELECT member.share_code='u2x0' AND member.family_id=family.family_id
		AND member.troop_similarity=0.9000 AND member.spell_similarity=0.8000
		AND member.equipment_similarity=0.7500
		FROM army_family_members member
		JOIN army_families family ON family.representative_share_code='u1x0'`)
	check(`SELECT attack_count=2 AND duration_seconds_sum=200
		FROM army_family_daily_stats WHERE day='2026-08-01'`)
	check(`SELECT attack_count=2 AND duration_seconds_sum=200
		FROM legend_daily_stats WHERE day='2026-08-01' AND league_tier_id=1 AND town_hall=18`)
	check(`SELECT NOT EXISTS(SELECT 1 FROM army_family_daily_stats_v2)
		AND NOT EXISTS(SELECT 1 FROM legend_daily_stats_v2)`)
	check(`SELECT army_hash=decode(repeat('bb',32),'hex')
		FROM battles_ranked WHERE player_tag='#P0Y'`)
	if err := migrate("down"); err != nil {
		t.Fatal("empty replacement rollback:", err)
	}
	check(`SELECT max(version_id)=14 FROM goose_db_version WHERE is_applied`)
	check(`SELECT to_regclass('public.legend_daily_stats_v2') IS NULL
		AND to_regclass('public.army_family_daily_stats_v2') IS NULL`)
	check(`SELECT family_name='  Root   Riders  '
		FROM army_families WHERE anchor_army_hash=decode(repeat('aa',32),'hex')`)
	if err := migrate("down"); err == nil {
		t.Fatal("nullable-loot rollback discarded cleaned defense state")
	}
	check(`SELECT max(version_id)=14 FROM goose_db_version WHERE is_applied`)
	// Remove the deliberately cleaned defense fixture only inside this disposable
	// test so migration 014 can prove its structural rollback path.
	run(`DELETE FROM battles_ranked WHERE player_tag='#P0L'`)
	if err := migrate("down"); err != nil {
		t.Fatal("nullable-loot rollback after fixture cleanup:", err)
	}
	check(`SELECT max(version_id)=13 FROM goose_db_version WHERE is_applied`)
	if err := migrate("up-to", "15"); err != nil {
		t.Fatal("repeat compatibility upgrade:", err)
	}

	var familyID int64
	if err := conn.QueryRow(ctx, `INSERT INTO army_families(
		representative_share_code,name,hero_ids,equipment_ids
	) VALUES ('u3x0',NULL,'{1,2}','{3,4}') RETURNING family_id`).Scan(&familyID); err != nil {
		t.Fatal(err)
	}
	run(`INSERT INTO army_family_members(
		share_code,family_id,troop_similarity,spell_similarity,equipment_similarity
	) VALUES ('u3x0',$1,1.0000,1.0000,1.0000)`, familyID)
	check(`SELECT anchor_army_hash IS NULL AND family_name IS NULL AND source IS NULL AND name IS NULL
		FROM army_families WHERE family_id=$1`, familyID)
	check(`SELECT army_hash IS NULL AND anchor_army_hash IS NULL
		AND matching_version IS NULL AND equipment_difference_count IS NULL
		FROM army_family_members WHERE share_code='u3x0'`)
	check(`SELECT NOT EXISTS (
		SELECT 1 FROM army_compositions WHERE normalized_share_code='u3x0'
	)`)

	// An old hash writer still receives the new identity columns.
	run(`INSERT INTO army_compositions(
		army_hash,normalized_share_code,heroes,equipment
	) VALUES (
		decode(repeat('cc',32),'hex'),'u4x0','{5}',
		'[{"equipmentId":6,"heroId":5}]'
	);
	INSERT INTO army_families(
		anchor_army_hash,representative_share_code,family_name,source
	) VALUES (
		decode(repeat('cc',32),'hex'),'u4x0','Legacy Family','fallback'
	);
	INSERT INTO army_family_members(
		army_hash,anchor_army_hash,troop_housing_similarity,spell_capacity_similarity,
		heroes_exact,equipment_similarity,equipment_difference_count,matching_version
	) VALUES (
		decode(repeat('cc',32),'hex'),decode(repeat('cc',32),'hex'),
		1.0000,1.0000,true,1.0000,0,'v1'
	);`)
	check(`SELECT name='Legacy Family' AND hero_ids='{5}'::integer[]
		AND equipment_ids='{6}'::integer[] AND family_id IS NOT NULL
		FROM army_families WHERE representative_share_code='u4x0'`)
	check(`SELECT share_code='u4x0' AND family_id IS NOT NULL
		AND troop_similarity=1 AND spell_similarity=1
		FROM army_family_members WHERE army_hash=decode(repeat('cc',32),'hex')`)

	run(`INSERT INTO battles_ranked(
		player_tag,opponent_tag,battle_time,direction,battle_mode,
		player_town_hall,opponent_town_hall,stars,destruction_percentage,share_code
	) VALUES (
		'#P0Y','#P0L',now(),'attack','legend',18,18,3,100,'u3x0'
	) ON CONFLICT(player_tag,battle_time) DO NOTHING`)
	check(`SELECT army_hash IS NULL AND share_code='u3x0'
		FROM battles_ranked WHERE player_tag='#P0Y' ORDER BY battle_time DESC LIMIT 1`)

	run(`UPDATE army_families SET name=NULL
		WHERE representative_share_code='u1x0'`)
	check(`SELECT name IS NULL AND family_name='  Root   Riders  '
		FROM army_families WHERE representative_share_code='u1x0'`)

	run(`INSERT INTO army_family_daily_stats_v2(
		family_id,day,attack_count,distinct_player_count,
		zero_star_count,one_star_count,two_star_count,three_star_count,
		destruction_percentage_sum,duration_seconds_sum,duration_count
	) VALUES ($1,'2026-09-09',2,2,0,0,1,1,180,120,1)`, familyID)
	run(`INSERT INTO legend_daily_stats_v2(
		day,attack_count,distinct_player_count,perfect_320_player_count,
		zero_star_count,one_star_count,two_star_count,three_star_count,
		destruction_percentage_sum,duration_seconds_sum,duration_count,
		hero_stats,pet_stats,equipment_stats,pet_hero_assignments
	) VALUES (
		'2026-09-09',2,2,0,0,0,1,1,180,120,1,
		'[{"id":1,"uses":2,"triples":1}]','[]','[]','[]'
	)`)

	reject(`INSERT INTO army_family_members(
		share_code,family_id,troop_similarity,spell_similarity,equipment_similarity
	) VALUES('bad',$1,0.8599,1,1)`, familyID)
	reject(`UPDATE army_families SET representative_share_code='changed'
		WHERE family_id=$1`, familyID)
	reject(`DELETE FROM army_family_members WHERE share_code='u3x0'`)
	reject(`INSERT INTO legend_daily_stats_v2(
		day,attack_count,distinct_player_count,perfect_320_player_count,
		zero_star_count,one_star_count,two_star_count,three_star_count,
		destruction_percentage_sum,duration_seconds_sum,duration_count,hero_stats
	) VALUES(
		'2026-09-10',1,1,0,0,0,0,1,100,0,0,
		'[{"id":1,"uses":2,"triples":1}]'
	)`)

	if err := migrate("down"); err == nil {
		t.Fatal("rollback discarded v2-only data")
	}
	check(`SELECT max(version_id)=15 FROM goose_db_version WHERE is_applied`)
}
