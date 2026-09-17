package schema

import (
	"context"
	"os"
	"os/exec"
	"testing"

	"github.com/jackc/pgx/v5"
)

func TestPersonalBaseStorageMigration(t *testing.T) {
	if os.Getenv("CLASHKING_DISPOSABLE_TIMESCALE") != "1" {
		t.Skip("requires disposable Timescale fixture")
	}
	if os.Getenv("CLASHKING_TIMESCALE_PROFILE") != "baseline-018" {
		t.Skip("requires baseline-018 migration profile")
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

	check(`SELECT max(version_id)=18 FROM goose_db_version WHERE is_applied`)
	run(`
		INSERT INTO auth_users(user_id,provider) VALUES('owner','discord');
		INSERT INTO player_links(tag,is_verified,source,user_id) VALUES('#P0Y',true,'api_token','owner');
		INSERT INTO bases(message_id,base_link,description) VALUES
			('700000000000000001','https://link.clashofclans.com/en?action=OpenLayout&id=TH17%3AWB%3AONE','One'),
			('700000000000000002','https://link.clashofclans.com/en?action=OpenLayout&id=TH17%3AWB%3ATWO','Two');
		INSERT INTO base_downloaders(base_id,user_id,downloaded_at)
		SELECT id,'111111111111111111','2026-01-02T03:04:05.123456Z'::timestamptz FROM bases WHERE message_id='700000000000000001'
		UNION ALL
		SELECT id,'222222222222222222','2026-02-03T04:05:06Z'::timestamptz FROM bases WHERE message_id='700000000000000001';
		INSERT INTO base_votes(base_id,user_id,vote)
		SELECT id,'111111111111111111',1 FROM bases WHERE message_id='700000000000000001'
		UNION ALL
		SELECT id,'222222222222222222',-1 FROM bases WHERE message_id='700000000000000001';
		INSERT INTO user_saved_bases(user_id,base_id)
		SELECT 'owner',id FROM bases WHERE message_id IN ('700000000000000001','700000000000000002');
		INSERT INTO user_base_slots(user_id,player_tag,slot_kind,slot_number,base_id)
		SELECT 'owner','#P0Y','war',1,id FROM bases WHERE message_id='700000000000000001';`)

	migrate("up-to", "19")
	check(`SELECT max(version_id)=19 FROM goose_db_version WHERE is_applied`)
	check(`SELECT to_regclass('public.base_downloaders') IS NULL
		AND to_regclass('public.user_base_slots') IS NULL
		AND to_regprocedure('public.require_verified_base_slot()') IS NULL
		AND to_regprocedure('public.reset_base_slots_on_link_change()') IS NULL`)
	check(`SELECT kind IS NULL FROM user_saved_bases
		WHERE user_id='owner' AND base_id=(SELECT id FROM bases WHERE message_id='700000000000000001')`)
	check(`SELECT (SELECT count(*) FROM jsonb_object_keys(downloads))=2
		AND (downloads->>'111111111111111111')::timestamptz='2026-01-02T03:04:05.123456Z'::timestamptz
		AND (downloads->>'222222222222222222')::timestamptz='2026-02-03T04:05:06Z'::timestamptz
		FROM bases WHERE message_id='700000000000000001'`)
	check(`SELECT download_count=2 AND upvote_count=1 AND downvote_count=1
		FROM base_public_counts WHERE base_id=(SELECT id FROM bases WHERE message_id='700000000000000001')`)

	run(`UPDATE user_saved_bases SET kind='war' WHERE user_id='owner'`)
	reject(`UPDATE user_saved_bases SET kind='farming' WHERE user_id='owner'`)
	reject(`UPDATE bases SET downloads=downloads-'111111111111111111' WHERE message_id='700000000000000001'`)
	reject(`UPDATE bases SET downloads=jsonb_set(downloads,'{111111111111111111}','"2026-09-15T00:00:00Z"')
		WHERE message_id='700000000000000001'`)
	reject(`UPDATE bases SET downloads='[]'::jsonb WHERE message_id='700000000000000002'`)
	reject(`UPDATE bases SET downloads='{"not-a-user":"2026-09-15T00:00:00Z"}'::jsonb WHERE message_id='700000000000000002'`)
	reject(`UPDATE bases SET downloads='{"333333333333333333":"not-a-time"}'::jsonb WHERE message_id='700000000000000002'`)

	run(`UPDATE bases SET downloads=CASE
		WHEN downloads ? '333333333333333333' THEN downloads
		ELSE downloads||jsonb_build_object('333333333333333333','2026-03-04T05:06:07Z') END
		WHERE message_id='700000000000000001'`)
	run(`UPDATE bases SET downloads=CASE
		WHEN downloads ? '333333333333333333' THEN downloads
		ELSE downloads||jsonb_build_object('333333333333333333','2026-09-15T00:00:00Z') END
		WHERE message_id='700000000000000001'`)
	check(`SELECT download_count=3
		AND downloads->>'333333333333333333'='2026-03-04T05:06:07Z'
		FROM bases JOIN base_public_counts counts ON counts.base_id=bases.id
		WHERE message_id='700000000000000001'`)

	run(`UPDATE user_saved_bases SET saved_at=now()-interval '100 days' WHERE user_id='owner';
		DELETE FROM user_saved_bases WHERE user_id='owner' AND saved_at < now()-interval '90 days';
		INSERT INTO user_saved_bases(user_id,base_id,kind)
		SELECT 'owner',id,'legend' FROM bases WHERE message_id='700000000000000001'`)
	check(`SELECT download_count=3 AND downloads ? '111111111111111111'
		FROM bases JOIN base_public_counts counts ON counts.base_id=bases.id
		WHERE message_id='700000000000000001'`)

	run(`INSERT INTO base_images(base_id,position,image_url)
 SELECT id,3,'https://api.clashk.ing/v2/media/third.png' FROM bases WHERE message_id='700000000000000001';
 UPDATE base_votes SET updated_at='2026-09-01T02:03:04Z'`)
	migrate("up-to", "21")
	check(`SELECT to_regclass('public.base_images') IS NULL AND to_regclass('public.base_votes') IS NULL`)
	check(`SELECT images=ARRAY[NULL,NULL,'https://api.clashk.ing/v2/media/third.png']::text[]
 AND votes->'111111111111111111'->>'vote'='1'
 AND votes->'222222222222222222'->>'vote'='-1'
 AND (votes->'111111111111111111'->>'updatedAt')::timestamptz='2026-09-01T02:03:04Z'::timestamptz
 AND download_count=3 AND upvote_count=1 AND downvote_count=1
 FROM bases JOIN base_public_counts counts ON counts.base_id=bases.id WHERE message_id='700000000000000001'`)
	check(`SELECT images='{}'::text[] AND votes='{}'::jsonb FROM bases WHERE message_id='700000000000000002'`)
	reject(`UPDATE bases SET votes='{"bad":{"vote":1,"updatedAt":"2026-09-01T00:00:00Z"}}'`)
	reject(`UPDATE bases SET images=ARRAY['https://api.clashk.ing/v2/media/a.png','https://api.clashk.ing/v2/media/a.png']`)
}
