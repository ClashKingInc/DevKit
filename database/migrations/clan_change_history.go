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
	migrateutil.Main("clan_change_history", runClanChangeHistory)
}

func runClanChangeHistory(ctx context.Context, cfg migrateutil.Config) error {
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
	cp, err := migrateutil.LoadCheckpoint(cfg, "clan_change_history")
	if err != nil {
		return err
	}
	rows := make([][]any, 0, cfg.BatchSize)
	flush := func() error {
		if len(rows) == 0 {
			return nil
		}
		err := flushClanChangeRows(ctx, pool, rows)
		rows = rows[:0]
		return err
	}
	seen, err := migrateutil.StreamByObjectID(ctx, cfg, cp, "all_clans_changes_id", mongoClient.Database("looper").Collection("all_clans_changes"), func(doc bson.M) (bool, error) {
		eventTime, ok := migrateutil.Time(doc["time"])
		if !ok {
			return false, nil
		}
		changeType := normalizeClanChangeType(migrateutil.String(doc["type"]))
		if changeType == "" {
			return false, nil
		}
		rows = append(rows, []any{
			eventTime,
			migrateutil.String(doc["clan"]),
			changeType,
			migrateutil.RawJSON(doc["previous"]),
			migrateutil.RawJSON(doc["current"]),
		})
		return len(rows) >= cfg.BatchSize, nil
	}, flush)
	if err != nil {
		return err
	}
	fmt.Printf("clan_change_history: scanned_docs=%d\n", seen)
	return nil
}

func normalizeClanChangeType(value string) string {
	switch value {
	case "description", "clan_level", "cwl_league_id", "capital_league_id":
		return value
	case "clanLevel", "level":
		return "clan_level"
	case "warLeague", "war_league", "cwl":
		return "cwl_league_id"
	case "capitalLeague", "capital_league":
		return "capital_league_id"
	default:
		return ""
	}
}

func flushClanChangeRows(ctx context.Context, pool interface {
	Begin(context.Context) (pgx.Tx, error)
}, rows [][]any) error {
	tx, err := pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, `
		CREATE TEMP TABLE _ck_clan_change_history (
			event_time timestamptz, clan_tag text, change_type text, previous_value text, current_value text
		) ON COMMIT DROP
	`); err != nil {
		return err
	}
	if _, err := tx.CopyFrom(ctx, pgx.Identifier{"_ck_clan_change_history"}, []string{
		"event_time", "clan_tag", "change_type", "previous_value", "current_value",
	}, pgx.CopyFromRows(rows)); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `
		INSERT INTO clan_change_history (event_time, clan_tag, change_type, previous_value, current_value)
		SELECT event_time, clan_tag, change_type, previous_value::jsonb, current_value::jsonb
		FROM _ck_clan_change_history
		WHERE clan_tag <> ''
	`); err != nil {
		return err
	}
	return tx.Commit(ctx)
}
