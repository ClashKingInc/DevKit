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

func main() {
	migrateutil.Main("clan_records", runClanRecords)
}

func runClanRecords(ctx context.Context, cfg migrateutil.Config) error {
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
	cp, err := migrateutil.LoadCheckpoint(cfg, "clan_records")
	if err != nil {
		return err
	}

	rows := make([][]any, 0, cfg.BatchSize)
	flush := func() error {
		if len(rows) == 0 {
			return nil
		}
		if err := flushClanRecords(ctx, pool, rows); err != nil {
			return err
		}
		rows = rows[:0]
		return nil
	}
	projection := bson.D{
		{Key: "tag", Value: 1},
		{Key: "records", Value: 1},
	}
	seen, err := migrateutil.StreamByObjectIDProjected(
		ctx,
		cfg,
		cp,
		"all_clans_records_id",
		mongoClient.Database("looper").Collection("all_clans"),
		projection,
		func(doc bson.M) (bool, error) {
			tag := migrateutil.String(first(doc["tag"], doc["_id"]))
			if tag == "" {
				return false, nil
			}
			records := migrateutil.Map(doc["records"])
			if len(records) == 0 {
				return false, nil
			}
			clanPointsRecord := migrateutil.Map(records["clanPoints"])
			warWinStreakRecord := migrateutil.Map(records["warWinStreak"])
			clanPoints := migrateutil.Int(clanPointsRecord["value"])
			warWinStreak := migrateutil.Int(warWinStreakRecord["value"])
			if clanPoints == 0 && warWinStreak == 0 {
				return false, nil
			}
			clanPointsAt, _ := migrateutil.Time(clanPointsRecord["time"])
			warWinStreakAt, _ := migrateutil.Time(warWinStreakRecord["time"])
			rows = append(rows, []any{
				tag,
				clanPoints,
				optionalTime(clanPointsAt),
				warWinStreak,
				optionalTime(warWinStreakAt),
			})
			return len(rows) >= cfg.BatchSize, nil
		},
		flush,
	)
	if err != nil {
		return err
	}
	fmt.Printf("clan_records: scanned_docs=%d\n", seen)
	return nil
}

func flushClanRecords(ctx context.Context, pool interface {
	Begin(context.Context) (pgx.Tx, error)
}, rows [][]any) error {
	tx, err := pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, `
		CREATE TEMP TABLE _ck_clan_records (
			tag text, clan_points int, clan_points_at timestamptz,
			war_win_streak int, war_win_streak_at timestamptz
		) ON COMMIT DROP
	`); err != nil {
		return err
	}
	if _, err := tx.CopyFrom(ctx, pgx.Identifier{"_ck_clan_records"}, []string{
		"tag", "clan_points", "clan_points_at", "war_win_streak", "war_win_streak_at",
	}, pgx.CopyFromRows(rows)); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `
		INSERT INTO clan_records (tag, clan_points, clan_points_at, war_win_streak, war_win_streak_at)
		SELECT tag, clan_points, clan_points_at, war_win_streak, war_win_streak_at
		FROM _ck_clan_records
		WHERE tag <> ''
		ON CONFLICT (tag) DO UPDATE SET
			clan_points = CASE
				WHEN EXCLUDED.clan_points > clan_records.clan_points THEN EXCLUDED.clan_points
				ELSE clan_records.clan_points
			END,
			clan_points_at = CASE
				WHEN EXCLUDED.clan_points > clan_records.clan_points THEN EXCLUDED.clan_points_at
				ELSE clan_records.clan_points_at
			END,
			war_win_streak = CASE
				WHEN EXCLUDED.war_win_streak > clan_records.war_win_streak THEN EXCLUDED.war_win_streak
				ELSE clan_records.war_win_streak
			END,
			war_win_streak_at = CASE
				WHEN EXCLUDED.war_win_streak > clan_records.war_win_streak THEN EXCLUDED.war_win_streak_at
				ELSE clan_records.war_win_streak_at
			END
		WHERE
			EXCLUDED.clan_points > clan_records.clan_points OR
			EXCLUDED.war_win_streak > clan_records.war_win_streak
	`); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

func first(values ...any) any {
	for _, value := range values {
		if migrateutil.String(value) != "" {
			return value
		}
	}
	return nil
}

func optionalTime(value time.Time) any {
	if value.IsZero() {
		return nil
	}
	return value
}
