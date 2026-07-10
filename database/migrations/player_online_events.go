//go:build ignore

package main

import (
	"context"
	"fmt"

	"clashking_devkit_database_migrations/migrateutil"
	"github.com/jackc/pgx/v5"
	"go.mongodb.org/mongo-driver/v2/bson"
)

func main() {
	migrateutil.Main("player_online_events", runPlayerOnlineEvents)
}

func runPlayerOnlineEvents(ctx context.Context, cfg migrateutil.Config) error {
	mongoClient, err := migrateutil.StatsClient(ctx, cfg)
	if err != nil {
		return err
	}
	defer mongoClient.Disconnect(ctx)
	pool, err := migrateutil.TimescalePool(ctx, cfg)
	if err != nil {
		return err
	}
	defer pool.Close()
	cp, err := migrateutil.LoadCheckpoint(cfg, "player_online_events")
	if err != nil {
		return err
	}
	rows := make([][]any, 0, cfg.BatchSize)
	flush := func() error {
		if len(rows) == 0 {
			return nil
		}
		err := flushPlayerOnlineRows(ctx, pool, rows)
		rows = rows[:0]
		return err
	}
	seen, err := migrateutil.StreamByObjectID(ctx, cfg, cp, "last_online_id", mongoClient.Database("looper").Collection("last_online"), func(doc bson.M) (bool, error) {
		meta := migrateutil.Map(doc["meta"])
		seenAt, ok := migrateutil.Time(doc["timestamp"])
		if !ok || meta == nil {
			return false, nil
		}
		tag := firstOnlineString(meta["tag"], meta["player_tag"], meta["player"])
		clanTag := firstOnlineString(meta["clan_tag"], meta["clan"])
		if tag == "" || clanTag == "" {
			return false, nil
		}
		rows = append(rows, []any{
			seenAt,
			tag,
			clanTag,
			migrateutil.Int(firstOnlineAny(meta["townhall_level"], meta["townhall"], meta["th"])),
		})
		return len(rows) >= cfg.BatchSize, nil
	}, flush)
	if err != nil {
		return err
	}
	fmt.Printf("player_online_events: scanned_docs=%d\n", seen)
	return nil
}

func flushPlayerOnlineRows(ctx context.Context, pool interface {
	Begin(context.Context) (pgx.Tx, error)
}, rows [][]any) error {
	tx, err := pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, `
		CREATE TEMP TABLE _ck_player_online_events (
			seen_at timestamptz, tag text, clan_tag text, townhall_level smallint
		) ON COMMIT DROP
	`); err != nil {
		return err
	}
	if _, err := tx.CopyFrom(ctx, pgx.Identifier{"_ck_player_online_events"}, []string{
		"seen_at", "tag", "clan_tag", "townhall_level",
	}, pgx.CopyFromRows(rows)); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `
		INSERT INTO player_online_events (seen_at, tag, clan_tag, townhall_level)
		SELECT seen_at, tag, clan_tag, townhall_level
		FROM _ck_player_online_events
		WHERE tag <> '' AND clan_tag <> ''
	`); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

func firstOnlineAny(values ...any) any {
	for _, value := range values {
		if migrateutil.String(value) != "" {
			return value
		}
	}
	return nil
}

func firstOnlineString(values ...any) string {
	return migrateutil.String(firstOnlineAny(values...))
}
