package schema

import (
	"context"
	"testing"
)

func TestPlayerLeaderboardSnapshots(t *testing.T) {
	conn := disposableConn(t)
	ctx := context.Background()
	tx, err := conn.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx)
	_, err = tx.Exec(ctx, `
 INSERT INTO basic_player(tag,name,townhall_level,league_id,trophies)
 SELECT '#BOARD'||lpad(n::text,4,'0'),'Fixture',17,105000034,1000 FROM generate_series(1,501) n;
 INSERT INTO basic_player(tag,name,townhall_level,league_id,trophies) VALUES
 ('#HIGH','Higher tier',17,105000035,0),('#UNRANKED','Unranked',17,105000000,9999),('#UNKNOWN','Unknown',17,NULL,9999);
 REFRESH MATERIALIZED VIEW player_townhall_leaderboards;
 REFRESH MATERIALIZED VIEW player_league_leaderboards;`)
	if err != nil {
		t.Fatal(err)
	}
	var count int
	var tag string
	if err = tx.QueryRow(ctx, `SELECT count(*) FROM player_townhall_leaderboards WHERE townhall_level=17`).Scan(&count); err != nil || count != 500 {
		t.Fatalf("count=%d: %v", count, err)
	}
	if err = tx.QueryRow(ctx, `SELECT tag FROM player_townhall_leaderboards WHERE townhall_level=17 AND rank=1`).Scan(&tag); err != nil || tag != "#HIGH" {
		t.Fatalf("first=%s: %v", tag, err)
	}
	if err = tx.QueryRow(ctx, `SELECT tag FROM player_league_leaderboards WHERE league_id=105000034 AND rank=1`).Scan(&tag); err != nil || tag != "#BOARD0001" {
		t.Fatalf("tie=%s: %v", tag, err)
	}
	if err = tx.QueryRow(ctx, `SELECT count(*) FROM player_league_leaderboards WHERE league_id=105000034`).Scan(&count); err != nil || count != 500 {
		t.Fatalf("league count=%d: %v", count, err)
	}
	_, err = tx.Exec(ctx, `UPDATE basic_player SET trophies=2000 WHERE tag='#BOARD0501'`)
	if err != nil {
		t.Fatal(err)
	}
	if err = tx.QueryRow(ctx, `SELECT count(*) FROM player_league_leaderboards WHERE tag='#BOARD0501'`).Scan(&count); err != nil || count != 0 {
		t.Fatalf("snapshot changed without refresh: %v", err)
	}
	_, err = tx.Exec(ctx, `REFRESH MATERIALIZED VIEW CONCURRENTLY player_league_leaderboards`)
	if err != nil {
		t.Fatal(err)
	}
	if err = tx.QueryRow(ctx, `SELECT tag FROM player_league_leaderboards WHERE league_id=105000034 AND rank=1`).Scan(&tag); err != nil || tag != "#BOARD0501" {
		t.Fatalf("refresh first=%s: %v", tag, err)
	}
}
