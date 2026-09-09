package schema

import (
	"context"
	"os"
	"testing"

	"github.com/jackc/pgx/v5"
)

func TestGatewayGenerationFencesStaleCoverage(t *testing.T) {
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
	_, err = tx.Exec(ctx, `INSERT INTO discord_cache.gateway_shards(application_id,shard_id,shard_count,generation,healthy,heartbeat_at,last_applied_sequence)
 VALUES ('123',0,1,'00000000-0000-4000-8000-000000000001',true,now(),42);
 INSERT INTO discord_cache.guilds(id,data,application_id,shard_id,generation,available,metadata_complete,members_complete,members_sync_token)
 VALUES ('456','{}','123',0,'00000000-0000-4000-8000-000000000001',true,true,true,'00000000-0000-4000-8000-000000000002');`)
	if err != nil {
		t.Fatal(err)
	}
	current := func() bool {
		t.Helper()
		var ready bool
		err := tx.QueryRow(ctx, `SELECT g.available AND g.metadata_complete AND g.members_complete AND s.healthy AND g.generation=s.generation AND s.heartbeat_at > now()-interval '45 seconds'
 FROM discord_cache.guilds g JOIN discord_cache.gateway_shards s ON (s.application_id,s.shard_id)=(g.application_id,g.shard_id) WHERE g.id='456' AND g.application_id='123'`).Scan(&ready)
		if err != nil {
			t.Fatal(err)
		}
		return ready
	}
	if !current() {
		t.Fatal("healthy complete generation not ready")
	}
	if _, err := tx.Exec(ctx, `UPDATE discord_cache.gateway_shards SET generation='00000000-0000-4000-8000-000000000003' WHERE application_id='123'`); err != nil {
		t.Fatal(err)
	}
	if current() {
		t.Fatal("old guild generation authorized after new session")
	}
	result, err := tx.Exec(ctx, `UPDATE discord_cache.guilds SET members_complete=true WHERE id='456' AND members_sync_token='00000000-0000-4000-8000-000000000004'`)
	if err != nil || result.RowsAffected() != 0 {
		t.Fatalf("stale chunk token accepted: %v", err)
	}
}

func TestInvalidDiscordDestinationStateExistsWithoutReceipts(t *testing.T) {
	if os.Getenv("CLASHKING_DISPOSABLE_TIMESCALE") != "1" {
		t.Skip("requires disposable Timescale fixture")
	}
	ctx := context.Background()
	conn, err := pgx.Connect(ctx, os.Getenv("TEST_DATABASE_URL"))
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close(ctx)
	for _, table := range []string{"server_logs", "reminders", "giveaways"} {
		var fields int
		if err := conn.QueryRow(ctx, `SELECT count(*) FROM information_schema.columns WHERE table_schema='public' AND table_name=$1 AND column_name IN ('disabled','disabled_reason')`, table).Scan(&fields); err != nil || fields != 2 {
			t.Fatalf("missing destination status for %s: %v", table, err)
		}
	}
	var absent bool
	if err := conn.QueryRow(ctx, `SELECT to_regclass('discord_cache.delivery_receipts') IS NULL`).Scan(&absent); err != nil || !absent {
		t.Fatalf("receipts reintroduced: %v", err)
	}
}
