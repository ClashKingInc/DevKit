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
		err := s.snapshot(ctx, st)
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
		for {
			began := time.Now()
			items, err := s.snapshotBatch(ctx, db, e, snap.Cursor[e.name])
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
			if err = s.save(*st); err != nil {
				return err
			}
			log.Printf("snapshot entity=%s rows=%d batch_ms=%d rate_limit=%d", e.name, snap.Rows[e.name], time.Since(began).Milliseconds(), rate)
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

func (s *service) snapshotBatch(ctx context.Context, db *pgx.Conn, e entity, cursor string) ([]item, error) {
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
		return nil, errors.New("snapshot batch expired; re-read current source")
	}
	if len(items) > 0 {
		if err = s.bulk(ctx, e, items); err != nil {
			return nil, err
		}
	}
	return items, nil
}
