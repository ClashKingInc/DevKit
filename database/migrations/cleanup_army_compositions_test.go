//go:build ignore

package main

import (
	"github.com/ClashKingInc/DevKit/database/migrations/migrateutil"
	"github.com/jackc/pgx/v5"
	"os"
	"os/exec"
	"testing"
)

func TestCleanupDefaultsAndApplyGuard(t *testing.T) {
	apply, batch, err := cleanupSettings(nil)
	if err != nil || apply || batch != 1000 {
		t.Fatal(apply, batch, err)
	}
	if _, _, err := cleanupSettings(map[string]string{"ARMY_COMPOSITION_CLEANUP_APPLY": "true"}); err == nil {
		t.Fatal("must require writers paused")
	}
	apply, _, err = cleanupSettings(map[string]string{"ARMY_COMPOSITION_CLEANUP_APPLY": "true", "ARMY_COMPOSITION_WRITERS_PAUSED": "true"})
	if err != nil || !apply {
		t.Fatal(apply, err)
	}
	for _, value := range []string{"0", "5001", "bad"} {
		if _, _, err := cleanupSettings(map[string]string{"ARMY_COMPOSITION_CLEANUP_BATCH_SIZE": value}); err == nil {
			t.Fatal(value)
		}
	}
}

func TestCleanupDisposableTimescale(t *testing.T) {
	if os.Getenv("CLASHKING_DISPOSABLE_TIMESCALE") != "1" {
		t.Skip("requires disposable Goose fixture")
	}
	dsn := os.Getenv("TEST_DATABASE_URL")
	goose := func(args ...string) {
		t.Helper()
		cmd := exec.Command("goose", append([]string{"-env", "/dev/null", "-dir", "../timescale", "postgres", dsn}, args...)...)
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("goose: %v: %s", err, out)
		}
	}
	goose("down-to", "11")
	conn, err := pgx.Connect(t.Context(), dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close(t.Context())
	_, err = conn.Exec(t.Context(), `INSERT INTO army_compositions(army_hash,normalized_share_code)
 SELECT decode(repeat(n::text,64),'hex'),'u'||n||'x0' FROM generate_series(1,4) n;
 INSERT INTO army_families(anchor_army_hash,representative_share_code,family_name,source)
 VALUES(decode(repeat('3',64),'hex'),'u3x0','Protected family','fallback');
 INSERT INTO battles_ranked(player_tag,opponent_tag,battle_time,direction,battle_mode,player_town_hall,opponent_town_hall,stars,destruction_percentage,army_hash,share_code)
 VALUES('#P0Y','#P0L',now(),'attack','ranked',18,18,3,100,decode(repeat('1',64),'hex'),'u1x0'),
	 ('#P0Y','#P0L',now(),'attack','legend',18,18,3,100,decode(repeat('2',64),'hex'),'u2x0');`)
	if err != nil {
		t.Fatal(err)
	}
	goose("up-to", "12")
	_, err = conn.Exec(t.Context(), `INSERT INTO battles_ranked(player_tag,opponent_tag,battle_time,direction,battle_mode,player_town_hall,opponent_town_hall,stars,destruction_percentage,army_hash,share_code)
 VALUES('#P0Y','#P0L',now()+interval '1 second','attack','ranked',18,18,3,100,decode(repeat('5',64),'hex'),'u5x0')`)
	if err != nil {
		t.Fatal("Ranked insert after upgrade:", err)
	}
	cfg := migrateutil.Config{TimescaleURL: dsn, Env: map[string]string{}}
	if err = cleanupArmyCompositions(t.Context(), cfg); err != nil {
		t.Fatal(err)
	}
	var count int
	if err = conn.QueryRow(t.Context(), "SELECT count(*) FROM army_compositions").Scan(&count); err != nil || count != 4 {
		t.Fatalf("dry run mutated data: %d %v", count, err)
	}
	cfg.Env = map[string]string{"ARMY_COMPOSITION_CLEANUP_APPLY": "true", "ARMY_COMPOSITION_WRITERS_PAUSED": "true", "ARMY_COMPOSITION_CLEANUP_BATCH_SIZE": "1"}
	if err = cleanupArmyCompositions(t.Context(), cfg); err != nil {
		t.Fatal(err)
	}
	if err = conn.QueryRow(t.Context(), "SELECT count(*) FROM army_compositions").Scan(&count); err != nil || count != 2 {
		t.Fatalf("unexpected remaining: %d %v", count, err)
	}
	if err = conn.QueryRow(t.Context(), "SELECT count(*) FROM battles_ranked").Scan(&count); err != nil || count != 3 {
		t.Fatalf("raw history changed: %d %v", count, err)
	}
	if _, err = conn.Exec(t.Context(), "DELETE FROM army_compositions WHERE army_hash=decode(repeat('3',64),'hex')"); err == nil {
		t.Fatal("family FK lost")
	}
	if _, err = conn.Exec(t.Context(), "UPDATE army_compositions SET normalized_share_code='u99x0'"); err == nil {
		t.Fatal("immutability lost")
	}
	if err = cleanupArmyCompositions(t.Context(), cfg); err != nil {
		t.Fatal("rerun:", err)
	}
}
