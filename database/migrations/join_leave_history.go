//go:build ignore

package main

import (
	"context"
	"fmt"
	"strings"

	"clashking_devkit_database_migrations/migrateutil"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"go.mongodb.org/mongo-driver/v2/bson"
)

func main() {
	migrateutil.Main("join_leave_history", runJoinLeaveHistory)
}

func runJoinLeaveHistory(ctx context.Context, cfg migrateutil.Config) error {
	clanTag := normalizeJoinLeaveClanTag(cfg.Env["JOIN_LEAVE_HISTORY_CLAN_TAG"])
	playerTag := normalizeJoinLeavePlayerTag(cfg.Env["JOIN_LEAVE_HISTORY_PLAYER_TAG"])
	filtered := clanTag != "" || playerTag != ""
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
	if !filtered {
		if err := dropJoinLeaveIndexes(ctx, pool); err != nil {
			return err
		}
	}
	if playerTag != "" {
		query := `DELETE FROM public.join_leave_history WHERE player_tag = $1`
		args := []any{playerTag}
		if clanTag != "" {
			query += ` AND clan_tag = $2`
			args = append(args, clanTag)
		}
		if _, err := pool.Exec(ctx, query, args...); err != nil {
			return err
		}
	} else {
		if _, err := pool.Exec(ctx, `TRUNCATE TABLE public.join_leave_history`); err != nil {
			return err
		}
	}
	rows := make([][]any, 0, cfg.BatchSize)
	flush := func() error {
		if len(rows) == 0 {
			return nil
		}
		err := flushJoinLeaveRows(ctx, pool, rows)
		rows = rows[:0]
		return err
	}
	seen, err := migrateutil.StreamAllFiltered(ctx, cfg, "join_leave_history", mongoClient.Database("looper").Collection("join_leave_history"), joinLeaveHistoryFilter(clanTag, playerTag), func(doc bson.M) (bool, error) {
		eventTime, ok := migrateutil.Time(doc["time"])
		if !ok {
			return false, nil
		}
		eventType := migrateutil.String(doc["type"])
		if eventType == "joined" {
			eventType = "join"
		}
		if eventType == "left" {
			eventType = "leave"
		}
		if eventType != "join" && eventType != "leave" {
			return false, nil
		}
		clanTag := migrateutil.String(doc["clan"])
		playerTag := migrateutil.String(doc["tag"])
		if clanTag == "" || playerTag == "" {
			return false, nil
		}
		rows = append(rows, []any{
			eventTime,
			eventType,
			clanTag,
			playerTag,
			migrateutil.Int(doc["th"]),
			nullString(migrateutil.String(doc["name"])),
		})
		return len(rows) >= cfg.BatchSize, nil
	}, flush)
	if err != nil {
		return err
	}
	if err := createJoinLeaveIndexes(ctx, pool); err != nil {
		return err
	}
	if filtered {
		fmt.Printf("join_leave_history: clan_tag=%s player_tag=%s scanned_docs=%d\n", clanTag, playerTag, seen)
	} else {
		fmt.Printf("join_leave_history: scanned_docs=%d\n", seen)
	}
	return nil
}

func normalizeJoinLeaveClanTag(value string) string {
	return normalizeJoinLeaveTag(value)
}

func normalizeJoinLeavePlayerTag(value string) string {
	return normalizeJoinLeaveTag(value)
}

func normalizeJoinLeaveTag(value string) string {
	value = strings.ToUpper(strings.TrimSpace(value))
	if value == "" {
		return ""
	}
	if !strings.HasPrefix(value, "#") {
		value = "#" + value
	}
	return value
}

func joinLeaveHistoryFilter(clanTag, playerTag string) bson.D {
	filter := bson.D{}
	if clanTag != "" {
		filter = append(filter, bson.E{Key: "clan", Value: clanTag})
	}
	if playerTag != "" {
		filter = append(filter, bson.E{Key: "tag", Value: playerTag})
	}
	return filter
}

func flushJoinLeaveRows(ctx context.Context, pool interface {
	Begin(context.Context) (pgx.Tx, error)
}, rows [][]any) error {
	tx, err := pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, `SET LOCAL synchronous_commit = off`); err != nil {
		return err
	}
	if _, err := tx.CopyFrom(ctx, pgx.Identifier{"join_leave_history"}, []string{
		"time", "type", "clan_tag", "player_tag", "townhall_level", "player_name",
	}, pgx.CopyFromRows(rows)); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

func dropJoinLeaveIndexes(ctx context.Context, exec interface {
	Exec(context.Context, string, ...any) (pgconn.CommandTag, error)
}) error {
	for _, sql := range []string{
		`DROP INDEX IF EXISTS public.idx_join_leave_history_clan_time`,
		`DROP INDEX IF EXISTS public.idx_join_leave_history_player_time`,
		`DROP INDEX IF EXISTS public.idx_join_leave_history_player`,
		`DROP INDEX IF EXISTS public.join_leave_history_time_idx`,
		`DROP INDEX IF EXISTS public.join_leave_history_event_time_idx`,
	} {
		if _, err := exec.Exec(ctx, sql); err != nil {
			return err
		}
	}
	return nil
}

func createJoinLeaveIndexes(ctx context.Context, exec interface {
	Exec(context.Context, string, ...any) (pgconn.CommandTag, error)
}) error {
	for _, sql := range []string{
		`CREATE INDEX IF NOT EXISTS idx_join_leave_history_clan_time ON public.join_leave_history USING btree (clan_tag, "time" DESC)`,
		`CREATE INDEX IF NOT EXISTS idx_join_leave_history_player ON public.join_leave_history USING btree (player_tag)`,
	} {
		if _, err := exec.Exec(ctx, sql); err != nil {
			return err
		}
	}
	return nil
}

func nullString(value string) any {
	if value == "" {
		return nil
	}
	return value
}
