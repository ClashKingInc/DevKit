package schema

import (
	"context"
	"os"
	"os/exec"
	"testing"

	"github.com/jackc/pgx/v5"
)

func TestPersonalArmyStorageMigration(t *testing.T) {
	if os.Getenv("CLASHKING_DISPOSABLE_TIMESCALE") != "1" {
		t.Skip("requires disposable Timescale fixture")
	}
	if os.Getenv("CLASHKING_TIMESCALE_PROFILE") != "baseline-021" {
		t.Skip("requires baseline-021 migration profile")
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
		if _, err = tx.Exec(ctx, sql, args...); err == nil {
			t.Fatalf("invalid write accepted: %s", sql)
		}
	}
	migrate := func(command ...string) {
		t.Helper()
		args := append([]string{"-env", "/dev/null", "-dir", "../timescale"}, command...)
		cmd := exec.Command("goose", args...)
		cmd.Env = append(os.Environ(), "GOOSE_DRIVER=postgres", "GOOSE_DBSTRING="+os.Getenv("TEST_DATABASE_URL"), "GOOSE_TABLE=goose_db_version")
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("migration failed: %v\n%s", err, out)
		}
	}

	check(`SELECT max(version_id)=21 FROM goose_db_version WHERE is_applied`)
	run(`
		INSERT INTO auth_users(user_id,provider) VALUES('owner','discord');
		INSERT INTO bases(message_id,base_link) VALUES(
			'700000000000000022',
			'https://link.clashofclans.com/en?action=OpenLayout&id=TH17%3AWB%3ATWENTYTWO'
		);
		INSERT INTO user_saved_bases(user_id,base_id,kind,saved_at)
		SELECT 'owner',id,'legend','2026-09-19T01:02:03Z' FROM bases
		WHERE message_id='700000000000000022';
		INSERT INTO army_compositions(share_code) VALUES('u1x0')`)

	migrate("up-to", "22")
	check(`SELECT max(version_id)=22 FROM goose_db_version WHERE is_applied`)
	check(`SELECT saved_at='2026-09-19T01:02:03Z'::timestamptz FROM user_saved_bases
		WHERE user_id='owner' AND base_id=(SELECT id FROM bases WHERE message_id='700000000000000022')`)
	check(`SELECT NOT EXISTS (
		SELECT 1 FROM information_schema.columns
		WHERE table_schema='public' AND table_name='user_saved_bases' AND column_name='kind'
	) AND to_regclass('public.user_saved_armies') IS NOT NULL`)
	run(`INSERT INTO user_saved_armies(user_id,share_code) VALUES('owner','u1x0')`)
	check(`SELECT saved_at IS NOT NULL FROM user_saved_armies WHERE user_id='owner' AND share_code='u1x0'`)
	reject(`INSERT INTO user_saved_armies(user_id,share_code) VALUES('owner','u1x0')`)
	reject(`INSERT INTO user_saved_armies(user_id,share_code) VALUES('owner','missing')`)
	run(`DELETE FROM user_saved_armies WHERE user_id='owner' AND share_code='u1x0'`)
	check(`SELECT EXISTS(SELECT 1 FROM army_compositions WHERE share_code='u1x0')`)
}
