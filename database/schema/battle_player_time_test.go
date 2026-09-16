package schema

import (
	"context"
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
	insert := `INSERT INTO battles_ranked(player_tag,opponent_tag,battle_time,direction,battle_mode,player_town_hall,opponent_town_hall,stars,destruction_percentage,looted_resources) VALUES($1,$2,'2026-09-09T00:00:00Z',$3::smallint,2,18,17,3,100,CASE WHEN $3::smallint=2 THEN NULL ELSE '{}'::jsonb END) ON CONFLICT(player_tag,battle_time) DO NOTHING`
	for _, v := range []struct {
		player, opponent string
		direction        int16
	}{{"#P0", "#Y2", 1}, {"#Y2", "#P0", 2}} {
		tag, err := tx.Exec(ctx, insert, v.player, v.opponent, v.direction)
		if err != nil || tag.RowsAffected() != 1 {
			t.Fatalf("insert: %v %v", tag, err)
		}
	}
	tag, err := tx.Exec(ctx, insert, "#P0", "#G9", int16(2))
	if err != nil || tag.RowsAffected() != 0 {
		t.Fatalf("collision: %v %v", tag, err)
	}
}
