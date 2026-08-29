//go:build ignore

package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/ClashKingInc/DevKit/database/migrations/migrateutil"
	"github.com/ClashKingInc/DevKit/database/warhistory"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

type historyRow struct {
	tag    string
	warIDs []int32
}

func main() {
	migrateutil.Main("player_war_history", runPlayerWarHistory)
}

func runPlayerWarHistory(ctx context.Context, cfg migrateutil.Config) error {
	root := strings.TrimSpace(cfg.Env["WAR_ARCHIVE_HISTORY_SHARD_DIR"])
	if root == "" {
		return errors.New("WAR_ARCHIVE_HISTORY_SHARD_DIR is required")
	}
	workers := envInt(cfg.Env, "PLAYER_WAR_HISTORY_WORKERS", 2)
	pollInterval := time.Duration(envInt(cfg.Env, "PLAYER_WAR_HISTORY_POLL_SECONDS", 5)) * time.Second
	continuous := envBool(cfg.Env, "PLAYER_WAR_HISTORY_CONTINUOUS")
	if workers <= 0 || pollInterval <= 0 {
		return errors.New("player-history workers and poll interval must be positive")
	}
	if err := os.MkdirAll(root, 0o700); err != nil {
		return err
	}
	pool, err := migrateutil.TimescalePool(ctx, cfg)
	if err != nil {
		return err
	}
	defer pool.Close()

	for {
		processed, err := consumeHistoryWindows(ctx, pool, root, workers)
		if err != nil {
			return err
		}
		if !continuous {
			fmt.Printf("player_war_history: ready_windows_processed=%d\n", processed)
			return nil
		}
		if processed == 0 {
			select {
			case <-time.After(pollInterval):
			case <-ctx.Done():
				return ctx.Err()
			}
		}
	}
}

func consumeHistoryWindows(ctx context.Context, pool *pgxpool.Pool, root string, workers int) (int, error) {
	paths, err := warhistory.DiscoverReady(root)
	if err != nil {
		return 0, err
	}
	processed := 0
	for _, path := range paths {
		claimed, err := warhistory.Claim(path)
		if err != nil {
			if errors.Is(err, os.ErrNotExist) {
				continue
			}
			return processed, err
		}
		if err := consumeHistoryWindow(ctx, pool, claimed, workers); err != nil {
			return processed, err
		}
		if err := os.RemoveAll(claimed); err != nil {
			return processed, fmt.Errorf("remove completed player-history window %s: %w", claimed, err)
		}
		processed++
	}
	return processed, nil
}

func consumeHistoryWindow(ctx context.Context, pool *pgxpool.Pool, path string, workers int) error {
	manifest, err := warhistory.ReadManifest(path)
	if err != nil {
		return err
	}
	started := time.Now()
	workerCtx, cancel := context.WithCancel(ctx)
	defer cancel()
	jobs := make(chan int)
	errCh := make(chan error, 1)
	var loadedPlayers atomic.Int64
	var wait sync.WaitGroup
	for range workers {
		wait.Add(1)
		go func() {
			defer wait.Done()
			for shard := range jobs {
				donePath := warhistory.DonePath(path, shard)
				if _, err := os.Stat(donePath); err == nil {
					continue
				} else if !errors.Is(err, os.ErrNotExist) {
					reportHistoryError(errCh, cancel, err)
					return
				}
				count, err := upsertHistoryShard(workerCtx, pool, warhistory.ShardPath(path, shard))
				if err != nil {
					reportHistoryError(errCh, cancel, err)
					return
				}
				if err := os.WriteFile(donePath, nil, 0o600); err != nil {
					reportHistoryError(errCh, cancel, err)
					return
				}
				loadedPlayers.Add(int64(count))
			}
		}()
	}
	go func() {
		defer close(jobs)
		for shard := range manifest.ShardCount {
			select {
			case jobs <- shard:
			case <-workerCtx.Done():
				return
			}
		}
	}()
	wait.Wait()
	select {
	case err := <-errCh:
		return err
	default:
	}
	fmt.Printf("player_war_history: run=%s window=%d wars=%d players=%d duration=%s\n",
		manifest.RunID, manifest.Sequence, manifest.WarCount, loadedPlayers.Load(), time.Since(started))
	return nil
}

func upsertHistoryShard(ctx context.Context, pool *pgxpool.Pool, path string) (int, error) {
	grouped, err := warhistory.ReadShard(path)
	if err != nil {
		return 0, err
	}
	if len(grouped) == 0 {
		return 0, nil
	}
	rows := make([]historyRow, 0, len(grouped))
	for tag, warIDs := range grouped {
		rows = append(rows, historyRow{tag: tag, warIDs: warIDs})
	}
	sort.Slice(rows, func(i, j int) bool { return rows[i].tag < rows[j].tag })
	tx, err := pool.Begin(ctx)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, `CREATE TEMP TABLE player_war_history_stage (player_tag text, war_ids integer[]) ON COMMIT DROP`); err != nil {
		return 0, err
	}
	if _, err := tx.CopyFrom(ctx, pgx.Identifier{"player_war_history_stage"}, []string{"player_tag", "war_ids"}, pgx.CopyFromSlice(len(rows), func(index int) ([]any, error) {
		return []any{rows[index].tag, rows[index].warIDs}, nil
	})); err != nil {
		return 0, err
	}
	if _, err := tx.Exec(ctx, `
		INSERT INTO player_war_history (player_tag, war_ids)
		SELECT player_tag, war_ids
		FROM player_war_history_stage
		ORDER BY player_tag
		ON CONFLICT (player_tag) DO UPDATE SET
			war_ids = ARRAY(
				SELECT DISTINCT war_id
				FROM unnest(player_war_history.war_ids || EXCLUDED.war_ids) AS war_id
				ORDER BY war_id
			)
	`); err != nil {
		return 0, err
	}
	if err := tx.Commit(ctx); err != nil {
		return 0, err
	}
	return len(rows), nil
}

func reportHistoryError(channel chan<- error, cancel context.CancelFunc, err error) {
	select {
	case channel <- err:
	default:
	}
	cancel()
}

func envInt(env map[string]string, key string, fallback int) int {
	value := strings.TrimSpace(env[key])
	if value == "" {
		return fallback
	}
	parsed, err := strconv.Atoi(value)
	if err != nil {
		return fallback
	}
	return parsed
}

func envBool(env map[string]string, key string) bool {
	value, _ := strconv.ParseBool(strings.TrimSpace(env[key]))
	return value
}
