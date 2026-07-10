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
	migrateutil.Main("cwl_groups", runCWLGroups)
}

func runCWLGroups(ctx context.Context, cfg migrateutil.Config) error {
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
	cp, err := migrateutil.LoadCheckpoint(cfg, "cwl_groups")
	if err != nil {
		return err
	}
	rows := make([][]any, 0, cfg.BatchSize)
	flush := func() error {
		if len(rows) == 0 {
			return nil
		}
		err := flushCWLGroupRows(ctx, pool, rows)
		rows = rows[:0]
		return err
	}
	seen, err := migrateutil.StreamByObjectID(ctx, cfg, cp, "cwl_group_id", mongoClient.Database("looper").Collection("cwl_group"), func(doc bson.M) (bool, error) {
		data := migrateutil.Map(doc["data"])
		if data == nil {
			return false, nil
		}
		cwlID := migrateutil.String(firstCWL(doc["cwl_id"], data["cwl_id"]))
		if cwlID == "" {
			return false, nil
		}
		clans := migrateutil.Slice(data["clans"])
		clanTags := make([]string, 0, len(clans))
		for _, raw := range clans {
			clan := migrateutil.Map(raw)
			if tag := migrateutil.String(clan["tag"]); tag != "" {
				clanTags = append(clanTags, tag)
			}
		}
		rounds := make([][]string, 0)
		for _, raw := range migrateutil.Slice(data["rounds"]) {
			round := migrateutil.Map(raw)
			var tags []string
			for _, tag := range migrateutil.Slice(round["warTags"]) {
				tags = append(tags, migrateutil.String(tag))
			}
			rounds = append(rounds, tags)
		}
		rows = append(rows, []any{
			cwlID,
			migrateutil.String(data["season"]),
			firstCWLInt(data["cwlLeagueId"], data["cwl_league_id"], doc["cwl_league_id"]),
			clanTags,
			migrateutil.RawJSON(rounds),
			migrateutil.RawJSON(data),
		})
		return len(rows) >= cfg.BatchSize, nil
	}, flush)
	if err != nil {
		return err
	}
	fmt.Printf("cwl_groups: scanned_docs=%d\n", seen)
	return nil
}

func flushCWLGroupRows(ctx context.Context, pool interface {
	Begin(context.Context) (pgx.Tx, error)
}, rows [][]any) error {
	tx, err := pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, `
		CREATE TEMP TABLE _ck_cwl_groups (
			cwl_id text, season text, cwl_league_id int, clan_tags text[], rounds text, data text
		) ON COMMIT DROP
	`); err != nil {
		return err
	}
	if _, err := tx.CopyFrom(ctx, pgx.Identifier{"_ck_cwl_groups"}, []string{
		"cwl_id", "season", "cwl_league_id", "clan_tags", "rounds", "data",
	}, pgx.CopyFromRows(rows)); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `
		INSERT INTO cwl_groups (cwl_id, season, cwl_league_id, clan_tags, rounds, data)
		SELECT cwl_id, season, cwl_league_id, clan_tags, rounds::jsonb, data::jsonb
		FROM _ck_cwl_groups
		WHERE cwl_id <> '' AND season <> ''
		ON CONFLICT (cwl_id) DO UPDATE SET
			season = EXCLUDED.season,
			cwl_league_id = EXCLUDED.cwl_league_id,
			clan_tags = EXCLUDED.clan_tags,
			rounds = EXCLUDED.rounds,
			data = EXCLUDED.data,
			updated_at = now()
	`); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

func firstCWL(values ...any) any {
	for _, value := range values {
		if migrateutil.String(value) != "" {
			return value
		}
	}
	return nil
}

func firstCWLInt(values ...any) int {
	for _, value := range values {
		if out := migrateutil.Int(value); out != 0 {
			return out
		}
	}
	return 0
}
