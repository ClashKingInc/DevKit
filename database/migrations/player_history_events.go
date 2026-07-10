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
	migrateutil.Main("player_history_events", runPlayerHistoryEvents)
}

func runPlayerHistoryEvents(ctx context.Context, cfg migrateutil.Config) error {
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
	cp, err := migrateutil.LoadCheckpoint(cfg, "player_history_events")
	if err != nil {
		return err
	}
	rows := make([][]any, 0, cfg.BatchSize)
	flush := func() error {
		if len(rows) == 0 {
			return nil
		}
		err := flushPlayerHistoryRows(ctx, pool, rows)
		rows = rows[:0]
		return err
	}
	seen, err := migrateutil.StreamByObjectID(ctx, cfg, cp, "player_history_id", mongoClient.Database("new_looper").Collection("player_history"), func(doc bson.M) (bool, error) {
		eventTime, ok := migrateutil.Time(doc["time"])
		if !ok {
			return false, nil
		}
		rows = append(rows, []any{
			eventTime,
			migrateutil.String(doc["tag"]),
			migrateutil.String(doc["clan"]),
			migrateutil.SeasonFromDate(eventTime),
			migrateutil.String(doc["type"]),
			migrateutil.OptionalInt(doc["value"]),
			migrateutil.RawJSON(doc),
		})
		return len(rows) >= cfg.BatchSize, nil
	}, flush)
	if err != nil {
		return err
	}
	fmt.Printf("player_history_events: scanned_docs=%d\n", seen)
	return nil
}

func flushPlayerHistoryRows(ctx context.Context, pool interface {
	Begin(context.Context) (pgx.Tx, error)
}, rows [][]any) error {
	tx, err := pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, `
		CREATE TEMP TABLE _ck_player_history_events (
			event_time timestamptz, player_tag text, clan_tag text, season text,
			event_type text, value int, data text
		) ON COMMIT DROP
	`); err != nil {
		return err
	}
	if _, err := tx.CopyFrom(ctx, pgx.Identifier{"_ck_player_history_events"}, []string{
		"event_time", "player_tag", "clan_tag", "season", "event_type", "value", "data",
	}, pgx.CopyFromRows(rows)); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `
		INSERT INTO player_history_events (event_time, player_tag, clan_tag, season, event_type, value, data)
		SELECT event_time, player_tag, clan_tag, season, event_type, value, data::jsonb
		FROM _ck_player_history_events
		WHERE player_tag <> '' AND event_type <> ''
	`); err != nil {
		return err
	}
	return tx.Commit(ctx)
}
