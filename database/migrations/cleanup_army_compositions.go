//go:build ignore

package main

import (
	"context"
	"fmt"
	"strconv"
	"time"

	"github.com/ClashKingInc/DevKit/database/migrations/migrateutil"
)

func main() { migrateutil.Main("cleanup_army_compositions", cleanupArmyCompositions) }

func cleanupSettings(env map[string]string) (bool, int, error) {
	apply := env["ARMY_COMPOSITION_CLEANUP_APPLY"] == "true"
	if apply && env["ARMY_COMPOSITION_WRITERS_PAUSED"] != "true" {
		return false, 0, fmt.Errorf("apply requires ARMY_COMPOSITION_WRITERS_PAUSED=true; stop battle ingestion and family closeouts first")
	}
	batch := 1000
	if raw := env["ARMY_COMPOSITION_CLEANUP_BATCH_SIZE"]; raw != "" {
		v, err := strconv.Atoi(raw)
		if err != nil || v < 1 || v > 5000 {
			return false, 0, fmt.Errorf("batch size must be 1..5000")
		}
		batch = v
	}
	return apply, batch, nil
}

func cleanupArmyCompositions(ctx context.Context, cfg migrateutil.Config) error {
	apply, batch, err := cleanupSettings(cfg.Env)
	if err != nil {
		return err
	}
	pool, err := migrateutil.TimescalePool(ctx, cfg)
	if err != nil {
		return err
	}
	defer pool.Close()
	conn, err := pool.Acquire(ctx)
	if err != nil {
		return err
	}
	defer conn.Release()
	if _, err = conn.Exec(ctx, "SET application_name='ck_composition_cleanup'; SET lock_timeout='5s'; SET statement_timeout='120s'"); err != nil {
		return err
	}
	var locked bool
	if err = conn.QueryRow(ctx, "SELECT pg_try_advisory_lock(719233812)").Scan(&locked); err != nil {
		return err
	}
	if !locked {
		return fmt.Errorf("another cleanup is running")
	}
	defer conn.Exec(context.Background(), "SELECT pg_advisory_unlock(719233812)")
	var constraints int
	if err = conn.QueryRow(ctx, `SELECT count(*) FROM pg_constraint WHERE conrelid='public.battles_ranked'::regclass AND confrelid='public.army_compositions'::regclass`).Scan(&constraints); err != nil {
		return err
	}
	if constraints != 0 {
		return fmt.Errorf("apply schema 012 first; battle-to-composition foreign keys still exist")
	}
	// Scan the raw battle history once, not once per delete batch.
	if _, err = conn.Exec(ctx, `CREATE TEMP TABLE cleanup_keep ON COMMIT PRESERVE ROWS AS
 SELECT army_hash FROM public.battles_ranked WHERE battle_mode='legend'
 UNION SELECT anchor_army_hash FROM public.army_families
 UNION SELECT army_hash FROM public.army_family_members`); err != nil {
		return err
	}
	if _, err = conn.Exec(ctx, `CREATE UNIQUE INDEX ON cleanup_keep(army_hash); ANALYZE cleanup_keep;
 CREATE TEMP TABLE cleanup_candidates ON COMMIT PRESERVE ROWS AS
 SELECT c.army_hash FROM public.army_compositions c WHERE NOT EXISTS(SELECT 1 FROM cleanup_keep k WHERE k.army_hash=c.army_hash);
 CREATE UNIQUE INDEX ON cleanup_candidates(army_hash); ANALYZE cleanup_candidates`); err != nil {
		return err
	}
	defer conn.Exec(context.Background(), "DROP TABLE IF EXISTS pg_temp.cleanup_candidates,pg_temp.cleanup_keep")
	var candidates, kept int64
	if err = conn.QueryRow(ctx, "SELECT (SELECT count(*) FROM cleanup_candidates),(SELECT count(*) FROM cleanup_keep)").Scan(&candidates, &kept); err != nil {
		return err
	}
	fmt.Printf("dry_run=%t candidate_compositions=%d protected_hashes=%d batch_size=%d\n", !apply, candidates, kept, batch)
	if !apply {
		return nil
	}
	var deleted int64
	remaining := candidates
	for {
		var n, processed int64
		// Each statement is its own atomic transaction. Family references are also
		// rechecked here and enforced by their retained foreign keys.
		err = conn.QueryRow(ctx, `WITH batch AS (SELECT army_hash FROM cleanup_candidates ORDER BY army_hash LIMIT $1),
   gone AS (DELETE FROM public.army_compositions c USING batch b WHERE c.army_hash=b.army_hash
    AND NOT EXISTS(SELECT 1 FROM public.army_families f WHERE f.anchor_army_hash=c.army_hash)
    AND NOT EXISTS(SELECT 1 FROM public.army_family_members m WHERE m.army_hash=c.army_hash) RETURNING c.army_hash),
   consumed AS (DELETE FROM cleanup_candidates c USING batch b WHERE c.army_hash=b.army_hash RETURNING c.army_hash)
   SELECT (SELECT count(*) FROM gone),(SELECT count(*) FROM consumed)`, batch).Scan(&n, &processed)
		if err != nil {
			return fmt.Errorf("cleanup stopped after %d committed deletes: %w", deleted, err)
		}
		deleted += n
		remaining -= processed
		fmt.Printf("deleted=%d remaining_candidates=%d\n", deleted, remaining)
		if remaining == 0 {
			break
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(100 * time.Millisecond):
		}
	}
	var missing int64
	if err = conn.QueryRow(ctx, `SELECT count(*) FROM cleanup_keep k WHERE NOT EXISTS(SELECT 1 FROM public.army_compositions c WHERE c.army_hash=k.army_hash)`).Scan(&missing); err != nil {
		return err
	}
	if missing != 0 {
		return fmt.Errorf("verification found %d protected hashes without compositions", missing)
	}
	fmt.Printf("cleanup complete: deleted=%d protected_hashes_missing=0\n", deleted)
	return nil
}
