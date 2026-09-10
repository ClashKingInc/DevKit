package schema

import (
	"context"
	"os"
	"strings"
	"testing"
)

func TestBattlePlayerTimeIdentity(t *testing.T) {
	conn := disposableConn(t)
	ctx := context.Background()
	tx, err := conn.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx)
	var definition string
	if err := tx.QueryRow(ctx, `SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conrelid='public.battles_ranked'::regclass AND contype='p'`).Scan(&definition); err != nil {
		t.Fatal(err)
	}
	if definition != "PRIMARY KEY (player_tag, battle_time)" {
		t.Fatal(definition)
	}
	insert := `INSERT INTO battles_ranked(player_tag,opponent_tag,battle_time,direction,battle_mode,player_town_hall,opponent_town_hall,stars,destruction_percentage,looted_resources,army_hash) VALUES($1,$2,'2026-09-09T00:00:00Z',$3,'legend',18,17,3,100,CASE WHEN $3='defense' THEN NULL ELSE '{}'::jsonb END,decode(repeat('ab',32),'hex')) ON CONFLICT(player_tag,battle_time) DO NOTHING`
	for _, v := range [][3]string{{"#P0", "#Y2", "attack"}, {"#Y2", "#P0", "defense"}} {
		tag, err := tx.Exec(ctx, insert, v[0], v[1], v[2])
		if err != nil || tag.RowsAffected() != 1 {
			t.Fatalf("insert: %v %v", tag, err)
		}
	}
	tag, err := tx.Exec(ctx, insert, "#P0", "#G9", "defense")
	if err != nil || tag.RowsAffected() != 0 {
		t.Fatalf("collision: %v %v", tag, err)
	}
}

func TestBattleIdentityMigrationRejectsCollisionsWithoutDataLoss(t *testing.T) {
	conn := disposableConn(t)
	ctx := context.Background()
	tx, err := conn.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx)
	raw, err := os.ReadFile("../timescale/013_battle_player_time_identity.sql")
	if err != nil {
		t.Fatal(err)
	}
	parts := strings.Split(string(raw), "-- +goose Down")
	if _, err = tx.Exec(ctx, parts[1]); err != nil {
		t.Fatal(err)
	}
	if _, err = tx.Exec(ctx, `INSERT INTO battles_ranked(player_tag,opponent_tag,battle_time,direction,battle_mode,player_town_hall,opponent_town_hall,stars,destruction_percentage,looted_resources,army_hash) VALUES('#P0','#Y2','2026-09-09T00:00:00Z','attack','legend',18,17,3,100,'{}',decode(repeat('ab',32),'hex')),('#P0','#G9','2026-09-09T00:00:00Z','defense','legend',18,17,3,100,NULL,decode(repeat('ab',32),'hex'))`); err != nil {
		t.Fatal(err)
	}
	if _, err = tx.Exec(ctx, "SAVEPOINT upgrade"); err != nil {
		t.Fatal(err)
	}
	if _, err = tx.Exec(ctx, parts[0]); err == nil {
		t.Fatal("migration accepted collisions")
	}
	if _, err = tx.Exec(ctx, "ROLLBACK TO SAVEPOINT upgrade"); err != nil {
		t.Fatal(err)
	}
	var n int
	if err = tx.QueryRow(ctx, `SELECT count(*) FROM battles_ranked WHERE player_tag='#P0' AND battle_time='2026-09-09T00:00:00Z'`).Scan(&n); err != nil || n != 2 {
		t.Fatalf("rows=%d err=%v", n, err)
	}
}

func TestExplicitBattleReset(t *testing.T) {
	for _, withFamily := range []bool{false, true} {
		t.Run(map[bool]string{false: "empty dependents", true: "retained family"}[withFamily], func(t *testing.T) {
			conn := disposableConn(t)
			ctx := context.Background()
			tx, err := conn.Begin(ctx)
			if err != nil {
				t.Fatal(err)
			}
			defer tx.Rollback(ctx)
			_, err = tx.Exec(ctx, `INSERT INTO army_compositions(army_hash,normalized_share_code) VALUES(decode(repeat('ac',32),'hex'),'u1x0'); INSERT INTO battles_ranked(player_tag,opponent_tag,battle_time,direction,battle_mode,player_town_hall,opponent_town_hall,stars,destruction_percentage,army_hash) VALUES('#P0','#Y2','2026-09-09T00:00:00Z','attack','legend',18,17,3,100,decode(repeat('ac',32),'hex'))`)
			if err != nil {
				t.Fatal(err)
			}
			if withFamily {
				_, err = tx.Exec(ctx, `INSERT INTO army_families(anchor_army_hash,representative_share_code,family_name,source) VALUES(decode(repeat('ac',32),'hex'),'u1x0','retained test family','fallback')`)
				if err != nil {
					t.Fatal(err)
				}
			}
			raw, err := os.ReadFile("../../scripts/reset-battle-history.sql")
			if err != nil {
				t.Fatal(err)
			}
			reset := strings.Replace(string(raw), "BEGIN;", "", 1)
			reset = strings.Replace(reset, "COMMIT;", "", 1)
			if _, err = tx.Exec(ctx, "SAVEPOINT reset_test"); err != nil {
				t.Fatal(err)
			}
			_, err = tx.Exec(ctx, reset)
			if withFamily {
				if err == nil || !strings.Contains(err.Error(), "Reset refused") {
					t.Fatalf("expected refusal: %v", err)
				}
				if _, err = tx.Exec(ctx, "ROLLBACK TO SAVEPOINT reset_test"); err != nil {
					t.Fatal(err)
				}
			} else if err != nil {
				t.Fatal(err)
			}
			var battles, compositions int
			if err = tx.QueryRow(ctx, `SELECT (SELECT count(*) FROM battles_ranked),(SELECT count(*) FROM army_compositions)`).Scan(&battles, &compositions); err != nil {
				t.Fatal(err)
			}
			want := 0
			if withFamily {
				want = 1
			}
			if battles != want || compositions != want {
				t.Fatalf("battles=%d compositions=%d want=%d", battles, compositions, want)
			}
		})
	}
}
