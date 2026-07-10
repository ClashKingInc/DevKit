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
	migrateutil.Main("legend_history_snapshots", runLegendHistorySnapshots)
}

func runLegendHistorySnapshots(ctx context.Context, cfg migrateutil.Config) error {
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
	cp, err := migrateutil.LoadCheckpoint(cfg, "legend_history_snapshots")
	if err != nil {
		return err
	}
	rows := make([][]any, 0, cfg.BatchSize)
	flush := func() error {
		if len(rows) == 0 {
			return nil
		}
		err := flushLegendHistoryRows(ctx, pool, rows)
		rows = rows[:0]
		return err
	}
	seen, err := migrateutil.StreamByObjectID(ctx, cfg, cp, "legend_history_id", mongoClient.Database("looper").Collection("legend_history"), func(doc bson.M) (bool, error) {
		season := migrateutil.String(doc["season"])
		tag := migrateutil.String(doc["tag"])
		rank := migrateutil.Int(doc["rank"])
		if season == "" || tag == "" || rank <= 0 {
			return false, nil
		}
		rows = append(rows, []any{
			season,
			tag,
			rank,
			migrateutil.Int(doc["trophies"]),
			migrateutil.RawJSON(doc),
		})
		return len(rows) >= cfg.BatchSize, nil
	}, flush)
	if err != nil {
		return err
	}
	fmt.Printf("legend_history_snapshots: scanned_docs=%d\n", seen)
	return nil
}

func flushLegendHistoryRows(ctx context.Context, pool interface {
	Begin(context.Context) (pgx.Tx, error)
}, rows [][]any) error {
	tx, err := pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, `
		CREATE TEMP TABLE _ck_legend_history_snapshots (
			season text, player_tag text, rank int, trophies int, data text
		) ON COMMIT DROP
	`); err != nil {
		return err
	}
	if _, err := tx.CopyFrom(ctx, pgx.Identifier{"_ck_legend_history_snapshots"}, []string{
		"season", "player_tag", "rank", "trophies", "data",
	}, pgx.CopyFromRows(rows)); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `
		INSERT INTO legend_history_snapshots (season, player_tag, rank, trophies, data)
		SELECT season, player_tag, rank, trophies, data::jsonb
		FROM _ck_legend_history_snapshots
		ON CONFLICT (season, player_tag) DO UPDATE SET
			rank = EXCLUDED.rank,
			trophies = EXCLUDED.trophies,
			data = EXCLUDED.data
	`); err != nil {
		return err
	}
	return tx.Commit(ctx)
}
