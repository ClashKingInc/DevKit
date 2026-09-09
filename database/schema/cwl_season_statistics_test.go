package schema

import (
	"context"
	"os"
	"testing"

	"github.com/jackc/pgx/v5"
)

func TestCWLSeasonStatisticsReconciliation(t *testing.T) {
	if os.Getenv("CLASHKING_DISPOSABLE_TIMESCALE") != "1" {
		t.Skip("requires disposable Timescale fixture")
	}
	ctx := context.Background()
	conn, err := pgx.Connect(ctx, os.Getenv("TEST_DATABASE_URL"))
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close(ctx)
	tx, err := conn.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx)
	_, err = tx.Exec(ctx, `
INSERT INTO cwl_groups(cwl_id,season,cwl_league_id,rounds,state,war_size) VALUES
 ('AAAAAAAAAAAA','2026-09',48000001,'[]','ended',15),
 ('BBBBBBBBBBBB','2026-09',48000001,'[]','ended',15),
 ('CCCCCCCCCCCC','2026-09',NULL,'[]','ended',15);
INSERT INTO cwl_group_clans(cwl_id,clan_tag) VALUES
 ('AAAAAAAAAAAA','#2PP'),('AAAAAAAAAAAA','#9G2YV'),('BBBBBBBBBBBB','#2PP');
INSERT INTO cwl_group_members(cwl_id,clan_tag,tag,town_hall) VALUES
 ('AAAAAAAAAAAA','#2PP','#2PP',17),('AAAAAAAAAAAA','#2PP','#9G2YV',17),
 ('AAAAAAAAAAAA','#9G2YV','#P0Y',16),('BBBBBBBBBBBB','#2PP','#2PP',0);
CALL public.reconcile_cwl_season_statistics(ARRAY['2026-09']);`)
	if err != nil {
		t.Fatal(err)
	}
	var groups, clans, members int64
	var halls []byte
	if err := tx.QueryRow(ctx, `SELECT group_count,clan_count,registered_player_count,town_halls FROM cwl_season_statistics WHERE season='2026-09' AND cwl_league_id=48000001 AND war_size=15`).Scan(&groups, &clans, &members, &halls); err != nil {
		t.Fatal(err)
	}
	if groups != 2 || clans != 3 || members != 4 || string(halls) != `[{"count": 2, "level": 17}, {"count": 1, "level": 16}]` {
		t.Fatalf("stats=%d,%d,%d %s", groups, clans, members, halls)
	}
	var rows int
	if err := tx.QueryRow(ctx, `SELECT count(*) FROM cwl_season_statistics`).Scan(&rows); err != nil || rows != 1 {
		t.Fatalf("eligible statistic rows=%d err=%v", rows, err)
	}
	if _, err := tx.Exec(ctx, `DELETE FROM cwl_group_members WHERE cwl_id='BBBBBBBBBBBB'; CALL public.reconcile_cwl_season_statistics(ARRAY['2026-09']);`); err != nil {
		t.Fatal(err)
	}
	if err := tx.QueryRow(ctx, `SELECT registered_player_count FROM cwl_season_statistics WHERE season='2026-09'`).Scan(&members); err != nil || members != 3 {
		t.Fatalf("replacement members=%d err=%v", members, err)
	}
	for _, invalid := range []string{`{}`, `[{"level":16,"count":1},{"level":17,"count":1}]`, `[{"level":17,"count":-1}]`} {
		var valid bool
		if err := tx.QueryRow(ctx, `SELECT public.cwl_town_halls_valid($1::jsonb)`, invalid).Scan(&valid); err != nil || valid {
			t.Fatalf("invalid town halls accepted: %s err=%v", invalid, err)
		}
	}
}
