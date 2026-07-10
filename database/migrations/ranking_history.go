//go:build ignore

package main

import (
	"context"
	"fmt"
	"time"

	"clashking_devkit_database_migrations/migrateutil"
	"github.com/jackc/pgx/v5"
	"go.mongodb.org/mongo-driver/v2/bson"
)

var rankingCollections = []string{
	"player_trophies",
	"player_versus_trophies",
	"clan_trophies",
	"clan_versus_trophies",
	"capital",
}

func main() {
	migrateutil.Main("ranking_history", runRankingHistory)
}

func runRankingHistory(ctx context.Context, cfg migrateutil.Config) error {
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
	cp, err := migrateutil.LoadCheckpoint(cfg, "ranking_history")
	if err != nil {
		return err
	}

	totalDocs := int64(0)
	totalRows := int64(0)
	for _, name := range rankingCollections {
		rows := make(map[string][]any, cfg.BatchSize)
		flush := func() error {
			if len(rows) == 0 {
				return nil
			}
			written, err := flushRankingRows(ctx, pool, rows)
			totalRows += written
			rows = map[string][]any{}
			return err
		}
		seen, err := migrateutil.StreamByObjectID(ctx, cfg, cp, name+"_id", mongoClient.Database("ranking_history").Collection(name), func(doc bson.M) (bool, error) {
			for _, row := range rankingRows(name, doc) {
				rows[rankingRowKey(row)] = row
			}
			return len(rows) >= cfg.BatchSize, nil
		}, flush)
		if err != nil {
			return err
		}
		totalDocs += seen
		fmt.Printf("%s: scanned_docs=%d\n", name, seen)
	}
	fmt.Printf("ranking_history: scanned_docs=%d rows=%d\n", totalDocs, totalRows)
	return nil
}

func rankingRows(kind string, doc bson.M) [][]any {
	location := migrateutil.String(doc["location"])
	date, ok := normalizeRankingDate(doc["date"])
	if !ok || location == "" {
		return nil
	}
	data := migrateutil.Map(doc["data"])
	items := migrateutil.Slice(data["items"])
	rows := make([][]any, 0, len(items))
	for _, raw := range items {
		item := migrateutil.Map(raw)
		tag := migrateutil.String(item["tag"])
		rank := migrateutil.Int(item["rank"])
		if tag == "" || rank <= 0 {
			continue
		}
		rows = append(rows, []any{
			kind,
			location,
			date,
			tag,
			migrateutil.String(item["name"]),
			rank,
			migrateutil.RawJSON(item),
		})
	}
	return rows
}

func flushRankingRows(ctx context.Context, pool interface {
	Begin(context.Context) (pgx.Tx, error)
}, rows map[string][]any) (int64, error) {
	tx, err := pool.Begin(ctx)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, `
		CREATE TEMP TABLE _ck_leaderboard_snapshot_items (
			kind text, location_id text, date date, tag text, name text, rank int, data text
		) ON COMMIT DROP
	`); err != nil {
		return 0, err
	}
	copyRows := make([][]any, 0, len(rows))
	for _, row := range rows {
		copyRows = append(copyRows, row)
	}
	if _, err := tx.CopyFrom(ctx, pgx.Identifier{"_ck_leaderboard_snapshot_items"}, []string{
		"kind", "location_id", "date", "tag", "name", "rank", "data",
	}, pgx.CopyFromRows(copyRows)); err != nil {
		return 0, err
	}
	if _, err := tx.Exec(ctx, `
		INSERT INTO leaderboard_snapshot_items (kind, location_id, date, tag, name, rank, data)
		SELECT kind, location_id, date, tag, name, rank, data::jsonb
		FROM _ck_leaderboard_snapshot_items
		ON CONFLICT (kind, location_id, date, tag) DO UPDATE SET
			name = EXCLUDED.name,
			rank = EXCLUDED.rank,
			data = EXCLUDED.data
	`); err != nil {
		return 0, err
	}
	if err := tx.Commit(ctx); err != nil {
		return 0, err
	}
	return int64(len(rows)), nil
}

func normalizeRankingDate(value any) (time.Time, bool) {
	out, ok := migrateutil.Time(value)
	if !ok {
		return time.Time{}, false
	}
	year, month, day := out.UTC().Date()
	return time.Date(year, month, day, 0, 0, 0, 0, time.UTC), true
}

func rankingRowKey(row []any) string {
	return fmt.Sprintf("%s\x00%s\x00%s\x00%s", row[0], row[1], row[2].(time.Time).Format("2006-01-02"), row[3])
}
