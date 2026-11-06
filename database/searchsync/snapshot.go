package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"os"
	"strconv"
	"time"

	"github.com/jackc/pglogrepl"
	"github.com/jackc/pgx/v5"
)

var errSnapshotExpired = errors.New("snapshot batch expired; re-read current source")

type snapshotTiming struct{ Read, Write time.Duration }

type snapshotState struct {
	Cursor map[string]string
	Done   map[string]bool
	Rows   map[string]int64
}

// Full resync writes only fresh indexes. Snapshot version 1 cannot replace a
// newer streamed value. WAL consumption runs concurrently, so Tracking never
// has to stop and the snapshot does not pin the stream's acknowledgement.
func (s *service) fullResync(ctx context.Context, st *handoffState, start pglogrepl.LSN) error {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	if st.Snapshot == nil {
		st.Snapshot = &snapshotState{Cursor: map[string]string{}, Done: map[string]bool{}, Rows: map[string]int64{}}
		if err := s.save(*st); err != nil {
			return err
		}
	}
	result := make(chan error, 2)
	go func() {
		err := s.snapshotWithRetry(ctx, st)
		result <- err
		if err != nil {
			cancel()
		}
	}()
	go func() { err := s.stream(ctx, start); result <- err; cancel() }()
	var failure error
	for range 2 {
		if err := <-result; err != nil && failure == nil {
			failure = err
		}
	}
	return failure
}

// A bounded snapshot read may time out under foreground database load. Retry
// from the last successful in-memory cursor with a new SQL connection; the live
// WAL consumer must keep acknowledging instead of losing its cache and session.
func (s *service) snapshotWithRetry(ctx context.Context, st *handoffState) error {
	for {
		err := s.snapshot(ctx, st)
		if ctx.Err() != nil {
			return ctx.Err()
		}
		if !errors.Is(err, context.DeadlineExceeded) && !errors.Is(err, errSnapshotExpired) {
			return err
		}
		log.Print("snapshot batch timed out; retrying current cursor while WAL stream continues")
		timer := time.NewTimer(2 * time.Second)
		select {
		case <-ctx.Done():
			timer.Stop()
			return ctx.Err()
		case <-timer.C:
		}
	}
}

func (s *service) snapshot(ctx context.Context, st *handoffState) error {
	db, err := pgx.Connect(ctx, os.Getenv("DATABASE_URL"))
	if err != nil {
		return errors.New("snapshot database connection failed")
	}
	defer db.Close(context.Background())
	rate := 25000
	if v := os.Getenv("SEARCH_SNAPSHOT_RATE"); v != "" {
		rate, err = strconv.Atoi(v)
		if err != nil || rate < 100 || rate > 100000 {
			return errors.New("snapshot rate must be 100..100000 documents/second")
		}
	}
	snap := st.Snapshot
	for _, e := range s.entities {
		if snap.Done[e.name] {
			continue
		}
		lastSaved := time.Time{}
		rowsSinceSave := int64(0)
		for {
			began := time.Now()
			timing := snapshotTiming{}
			items, err := s.snapshotBatch(ctx, db, e, snap.Cursor[e.name], &timing)
			if err != nil {
				return err
			}
			if len(items) == 0 {
				snap.Done[e.name] = true
				if err = s.save(*st); err != nil {
					return err
				}
				log.Printf("snapshot complete entity=%s rows=%d", e.name, snap.Rows[e.name])
				break
			}

			snap.Cursor[e.name] = items[len(items)-1].Tag
			snap.Rows[e.name] += int64(len(items))
			rowsSinceSave += int64(len(items))
			// Snapshot writes are idempotent and always older than streamed WAL.
			// Persist progress in bounded intervals instead of forcing a filesystem
			// journal commit for every bulk. A crash replays only the recent tail.
			checkpointTime := time.Duration(0)
			if time.Since(lastSaved) >= 5*time.Second || rowsSinceSave >= 100000 {
				checkpointStart := time.Now()
				if err = s.save(*st); err != nil {
					return err
				}
				checkpointTime = time.Since(checkpointStart)
				lastSaved = time.Now()
				rowsSinceSave = 0
			}
			log.Printf("snapshot entity=%s rows=%d batch_ms=%d read_ms=%d bulk_ms=%d checkpoint_ms=%d rate_limit=%d", e.name, snap.Rows[e.name], time.Since(began).Milliseconds(), timing.Read.Milliseconds(), timing.Write.Milliseconds(), checkpointTime.Milliseconds(), rate)
			wait := time.Duration(float64(time.Second)*float64(len(items))/float64(rate)) - time.Since(began)
			if wait > 0 {
				timer := time.NewTimer(wait)
				select {
				case <-ctx.Done():
					timer.Stop()
					return ctx.Err()
				case <-timer.C:
				}
			}
		}
	}
	log.Printf("snapshot all complete; live WAL stream continues")
	return nil
}

func (s *service) validateFreshIndexes(ctx context.Context) error {
	for _, e := range s.entities {
		data, status, err := s.request(ctx, "GET", "/"+e.index+"/_count", nil)
		if err != nil {
			return err
		}
		if status != 200 {
			return fmt.Errorf("fresh index count HTTP %d", status)
		}
		var count struct {
			Count int64 `json:"count"`
		}
		if err = json.Unmarshal(data, &count); err != nil {
			return err
		}
		if count.Count != 0 {
			return errors.New("full resync requires fresh empty indexes on initialization")
		}
	}
	return nil
}

func (s *service) snapshotBatch(ctx context.Context, db *pgx.Conn, e entity, cursor string, timing *snapshotTiming) ([]item, error) {
	began := time.Now()
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	rows, err := db.Query(ctx, "SELECT src.tag,"+e.projection+" FROM "+e.table+" src WHERE src.tag>$1 ORDER BY src.tag LIMIT $2", cursor, s.batch)
	if err != nil {
		return nil, err
	}
	items := make([]item, 0, s.batch)
	for rows.Next() {
		v := item{Generation: 1}
		if err = rows.Scan(&v.Tag, &v.Document); err != nil {
			rows.Close()
			return nil, err
		}
		items = append(items, v)
	}
	rows.Close()
	if err = rows.Err(); err != nil {
		return nil, err
	}
	// Never resume an old row batch after an unbounded process suspension. Delete
	// tombstones have finite retention; the next process must re-read current SQL.
	if time.Since(began) >= 30*time.Second {
		return nil, errSnapshotExpired
	}
	timing.Read = time.Since(began)
	if len(items) > 0 {
		writeStart := time.Now()
		if err = s.bulk(ctx, e, items); err != nil {
			return nil, err
		}
		timing.Write = time.Since(writeStart)
	}
	return items, nil
}
