package migrateutil

import (
	"context"
	"fmt"
	"strconv"
)

func rankedDefenseLootSettings(env map[string]string) (bool, int, string, error) {
	apply := env["RANKED_DEFENSE_LOOT_CLEANUP_APPLY"] == "true"
	if apply && env["RANKED_BATTLELOG_WRITERS_PAUSED"] != "true" {
		return false, 0, "", fmt.Errorf("apply requires RANKED_BATTLELOG_WRITERS_PAUSED=true")
	}
	expectedDatabase := env["RANKED_DEFENSE_LOOT_CLEANUP_DATABASE"]
	if apply && expectedDatabase == "" {
		return false, 0, "", fmt.Errorf("apply requires RANKED_DEFENSE_LOOT_CLEANUP_DATABASE")
	}
	batch := 1000
	if raw := env["RANKED_DEFENSE_LOOT_CLEANUP_BATCH_SIZE"]; raw != "" {
		value, err := strconv.Atoi(raw)
		if err != nil || value < 1 || value > 10000 {
			return false, 0, "", fmt.Errorf("batch size must be 1..10000")
		}
		batch = value
	}
	return apply, batch, expectedDatabase, nil
}

// ClearRankedDefenseLoot clears only existing ranked defense loot in bounded,
// committed batches. Rerunning resumes from rows that still have non-null loot.
func ClearRankedDefenseLoot(ctx context.Context, cfg Config) error {
	apply, batch, expectedDatabase, err := rankedDefenseLootSettings(cfg.Env)
	if err != nil {
		return err
	}
	pool, err := TimescalePool(ctx, cfg)
	if err != nil {
		return err
	}
	defer pool.Close()
	conn, err := pool.Acquire(ctx)
	if err != nil {
		return err
	}
	defer conn.Release()
	var database string
	if err = conn.QueryRow(ctx, "SELECT current_database()").Scan(&database); err != nil {
		return err
	}
	if apply && database != expectedDatabase {
		return fmt.Errorf("cleanup target is %q, expected %q", database, expectedDatabase)
	}
	if _, err = conn.Exec(ctx, "SET application_name='ck_ranked_defense_loot_cleanup'; SET lock_timeout='5s'; SET statement_timeout='120s'"); err != nil {
		return err
	}
	var locked bool
	if err = conn.QueryRow(ctx, "SELECT pg_try_advisory_lock(719233813)").Scan(&locked); err != nil {
		return err
	}
	if !locked {
		return fmt.Errorf("another ranked defense loot cleanup is running")
	}
	defer conn.Exec(context.Background(), "SELECT pg_advisory_unlock(719233813)")

	var version int64
	if err = conn.QueryRow(ctx, "SELECT max(version_id) FROM goose_db_version WHERE is_applied").Scan(&version); err != nil {
		return err
	}
	if version != 14 {
		return fmt.Errorf("cleanup requires Goose version 14 exactly; current version is %d", version)
	}

	var compressedChunks int64
	if err = conn.QueryRow(ctx, `SELECT count(*)
		FROM timescaledb_information.chunks
		WHERE hypertable_schema='public' AND hypertable_name='battles_ranked'
		  AND is_compressed`).Scan(&compressedChunks); err != nil {
		return err
	}
	if compressedChunks != 0 {
		return fmt.Errorf("cleanup refused: battles_ranked has %d compressed chunks", compressedChunks)
	}

	var candidates int64
	if err = conn.QueryRow(ctx, `SELECT count(*) FROM public.battles_ranked
		WHERE direction='defense' AND looted_resources IS NOT NULL`).Scan(&candidates); err != nil {
		return err
	}
	fmt.Printf("dry_run=%t defense_rows=%d batch_size=%d compressed_chunks=0\n", !apply, candidates, batch)
	if !apply {
		return nil
	}

	var cleared int64
	for {
		var count int64
		err = conn.QueryRow(ctx, `WITH batch AS (
			SELECT player_tag,battle_time
			FROM public.battles_ranked
			WHERE direction='defense' AND looted_resources IS NOT NULL
			ORDER BY battle_time,player_tag
			LIMIT $1
			FOR UPDATE SKIP LOCKED
		), cleared AS (
			UPDATE public.battles_ranked battle
			SET looted_resources=NULL
			FROM batch
			WHERE (battle.player_tag,battle.battle_time)
			    = (batch.player_tag,batch.battle_time)
			RETURNING 1
		)
		SELECT count(*) FROM cleared`, batch).Scan(&count)
		if err != nil {
			return fmt.Errorf("cleanup stopped after %d committed rows: %w", cleared, err)
		}
		cleared += count
		fmt.Printf("cleared=%d remaining_at_start=%d\n", cleared, candidates-cleared)
		if count == 0 {
			break
		}
	}
	var remaining int64
	if err = conn.QueryRow(ctx, `SELECT count(*) FROM public.battles_ranked
		WHERE direction='defense' AND looted_resources IS NOT NULL`).Scan(&remaining); err != nil {
		return err
	}
	if remaining != 0 {
		return fmt.Errorf("cleanup incomplete: %d defense rows still contain loot", remaining)
	}
	fmt.Printf("cleanup complete: cleared=%d remaining=0\n", cleared)
	return nil
}
