// historycounts initializes exact continuous-count buckets in bounded batches.
// It writes only derived aggregates and one existing scheduled-job checkpoint
// per completed batch. Source history is never changed.
package main

import (
	"context"
	"flag"
	"fmt"
	"github.com/jackc/pgx/v5"
	"os"
	"strconv"
	"time"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
func run() error {
	apply := flag.Bool("apply", false, "refresh derived buckets and save completed batch progress")
	expectedDB := flag.String("expected-database", "", "required database identity")
	expectedSystem := flag.String("expected-system", "", "required PostgreSQL system identifier")
	throughArg := flag.String("through", "", "exclusive UTC day boundary YYYY-MM-DD")
	batches := flag.Int("max-batches", 1, "maximum seven-day batches in this invocation")
	minSafe := flag.Int64("minimum-safe-wal-gib", 32, "minimum remaining safe WAL space for each valid logical slot")
	flag.Parse()
	through, err := time.Parse("2006-01-02", *throughArg)
	if err != nil {
		return fmt.Errorf("explicit --through UTC date required")
	}
	if through.After(time.Now().UTC().Truncate(24*time.Hour)) || *batches < 1 || *batches > 1000 || *minSafe < 1 {
		return fmt.Errorf("invalid date or batch/headroom bounds")
	}
	ctx := context.Background()
	db, err := pgx.Connect(ctx, os.Getenv("DATABASE_URL"))
	if err != nil {
		return fmt.Errorf("database connection failed")
	}
	defer db.Close(ctx)
	var name, system string
	if err = db.QueryRow(ctx, "SELECT current_database(),system_identifier::text FROM pg_control_system()").Scan(&name, &system); err != nil {
		return err
	}
	if name != *expectedDB || system != *expectedSystem {
		return fmt.Errorf("database identity mismatch; provide exact expected database and system identifier")
	}
	if _, err = db.Exec(ctx, "SET statement_timeout='20min'; SET lock_timeout='5s'; SET max_parallel_workers_per_gather=1; SET work_mem='64MB'"); err != nil {
		return err
	}
	var locked bool
	if err = db.QueryRow(ctx, "SELECT pg_try_advisory_lock(73194201)").Scan(&locked); err != nil {
		return err
	}
	if !locked {
		return fmt.Errorf("snapshot maintenance is active; retry later")
	}
	defer db.Exec(context.Background(), "SELECT pg_advisory_unlock(73194201)")
	used := 0
	for _, spec := range [][2]string{{"join_leave_history", "stats_join_leave_daily_counts"}, {"wars", "stats_war_daily_counts"}} {
		job := "count_history_bootstrap_" + spec[0]
		var earliest *time.Time
		if err = db.QueryRow(ctx, "SELECT min(range_start) FROM timescaledb_information.chunks WHERE hypertable_schema='public' AND hypertable_name=$1", spec[0]).Scan(&earliest); err != nil {
			return err
		}
		cursor := through
		if earliest != nil {
			cursor = earliest.UTC().Truncate(24 * time.Hour)
		}
		var saved string
		var complete *time.Time
		err = db.QueryRow(ctx, "SELECT last_tag,completed_at FROM tracking_scheduled_jobs WHERE job=$1 AND period=$2", job, through).Scan(&saved, &complete)
		if err != nil && err != pgx.ErrNoRows {
			return err
		}
		if err == nil {
			if complete != nil {
				fmt.Printf("already_complete source=%s through=%s\n", spec[0], *throughArg)
				continue
			}
			if saved != "" {
				cursor, err = time.Parse("2006-01-02", saved)
				if err != nil {
					return fmt.Errorf("invalid saved batch cursor")
				}
			}
		}
		fmt.Printf("plan source=%s next=%s through=%s apply=%t\n", spec[0], cursor.Format("2006-01-02"), *throughArg, *apply)
		if !*apply {
			continue
		}
		if !cursor.Before(through) {
			_, err = db.Exec(ctx, "INSERT INTO tracking_scheduled_jobs(job,period,last_tag,completed_at) VALUES($1,$2,$3,clock_timestamp()) ON CONFLICT(job,period) DO UPDATE SET last_tag=EXCLUDED.last_tag,completed_at=EXCLUDED.completed_at", job, through, *throughArg)
			if err != nil {
				return err
			}
			continue
		}
		for cursor.Before(through) && used < *batches {
			var unsafe int
			if err = db.QueryRow(ctx, "SELECT count(*) FROM pg_replication_slots WHERE slot_type='logical' AND invalidation_reason IS NULL AND safe_wal_size IS NOT NULL AND safe_wal_size<$1", *minSafe*1024*1024*1024).Scan(&unsafe); err != nil {
				return err
			}
			if unsafe > 0 {
				return fmt.Errorf("WAL headroom below " + strconv.FormatInt(*minSafe, 10) + " GiB; no new batch started")
			}
			end := cursor.AddDate(0, 0, 7)
			if end.After(through) {
				end = through
			}
			started := time.Now()
			// CALL commits before the cursor. A crash between these operations repeats
			// a safe refresh; it never skips an unmaterialized history interval.
			_, err = db.Exec(ctx, "CALL refresh_continuous_aggregate($1::regclass,$2::timestamptz,$3::timestamptz)", spec[1], cursor, end)
			if err != nil {
				return err
			}
			_, err = db.Exec(ctx, "INSERT INTO tracking_scheduled_jobs(job,period,last_tag,completed_at) VALUES($1,$2,$3,CASE WHEN $4 THEN clock_timestamp() END) ON CONFLICT(job,period) DO UPDATE SET last_tag=EXCLUDED.last_tag,completed_at=EXCLUDED.completed_at", job, through, end.Format("2006-01-02"), end.Equal(through))
			if err != nil {
				return err
			}
			fmt.Printf("refreshed source=%s from=%s through=%s duration_ms=%d complete=%t\n", spec[0], cursor.Format("2006-01-02"), end.Format("2006-01-02"), time.Since(started).Milliseconds(), end.Equal(through))
			cursor = end
			used++
		}
	}
	return nil
}
