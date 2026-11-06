package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"os"
	"strings"
	"time"

	"github.com/jackc/pglogrepl"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgproto3"
)

func (s *service) bridge(ctx context.Context, boundary string) error {
	// SQL peek/get restarts decoding at restart_lsn for every batch. A historical
	// transaction can pin that position far behind confirmed_flush_lsn, turning
	// small batches into repeated scans. Keep one continuous decoder per old slot.
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	result := make(chan error, len(s.entities))
	for _, e := range s.entities {
		go func(e entity) {
			err := s.bridgeStream(ctx, e, os.Getenv("SEARCH_"+strings.ToUpper(e.name)+"_OLD_SLOT"), boundary)
			result <- err
			if err != nil {
				cancel()
			}
		}(e)
	}
	var failure error
	for range s.entities {
		if err := <-result; err != nil && failure == nil {
			failure = err
		}
	}
	return failure
}

func (s *service) bridgeStream(ctx context.Context, e entity, slot, boundary string) error {
	if slot == "" || !validIndex(slot) {
		return errors.New("both valid legacy slots are required for handoff")
	}
	db, err := pgx.Connect(ctx, os.Getenv("DATABASE_URL"))
	if err != nil {
		return errors.New("legacy SQL connection failed")
	}
	defer db.Close(context.Background())
	var confirmed, plugin, dbname string
	var invalid *string
	if err = db.QueryRow(ctx, "SELECT confirmed_flush_lsn::text,plugin,database,invalidation_reason FROM pg_replication_slots WHERE slot_name=$1", slot).Scan(&confirmed, &plugin, &dbname, &invalid); err != nil {
		return err
	}
	if plugin != "test_decoding" || dbname != required("SEARCH_EXPECT_DATABASE") || invalid != nil {
		return errors.New("legacy slot unavailable or mismatched")
	}
	start, err := pglogrepl.ParseLSN(confirmed)
	if err != nil {
		return err
	}
	target, err := pglogrepl.ParseLSN(boundary)
	if err != nil {
		return err
	}
	if start >= target {
		return nil
	}
	cfg, err := pgconn.ParseConfig(os.Getenv("DATABASE_URL"))
	if err != nil {
		return err
	}
	cfg.RuntimeParams["replication"] = "database"
	conn, err := pgconn.ConnectConfig(ctx, cfg)
	if err != nil {
		return errors.New("legacy replication connection failed")
	}
	defer conn.Close(context.Background())
	if err = pglogrepl.StartReplication(ctx, conn, slot, start, pglogrepl.StartReplicationOptions{PluginArgs: []string{`"skip-empty-xacts" '1'`}}); err != nil {
		return err
	}
	pending := make(map[string]int64)
	complete, ack := start, start
	inTransaction := false
	var records, indexed int64
	lastProgress := time.Now()
	flush := func() error {
		if len(pending) > 0 {
			tags := make([]string, 0, len(pending))
			for tag := range pending {
				tags = append(tags, tag)
			}
			rows, err := db.Query(ctx, "SELECT k.tag,CASE WHEN src.tag IS NULL THEN NULL ELSE "+e.projection+" END FROM unnest($1::text[]) k(tag) LEFT JOIN "+e.table+" src ON src.tag=k.tag", tags)
			if err != nil {
				return err
			}
			items := make([]item, 0, len(tags))
			for rows.Next() {
				v := item{}
				if err = rows.Scan(&v.Tag, &v.Document); err != nil {
					rows.Close()
					return err
				}
				v.Generation = pending[v.Tag]
				items = append(items, v)
			}
			rows.Close()
			if err = rows.Err(); err != nil {
				return err
			}
			if err = s.bulk(ctx, e, items); err != nil {
				return err
			}
			indexed += int64(len(items))
			clear(pending)
		}
		// A committed transaction may be delivered in many bounded bulks. Do not
		// acknowledge its COMMIT until every bulk is durable. WALStart at COMMIT is
		// conservative: replaying that commit after a crash is safe and idempotent.
		ack = complete
		return pglogrepl.SendStandbyStatusUpdate(ctx, conn, pglogrepl.StandbyStatusUpdate{WALWritePosition: ack, WALFlushPosition: ack, WALApplyPosition: ack})
	}
	log.Printf("bridge stream entity=%s start=%s target=%s", e.name, start, target)
	for {
		readCtx, stop := context.WithTimeout(ctx, 250*time.Millisecond)
		message, readErr := conn.ReceiveMessage(readCtx)
		stop()
		if readErr != nil {
			if ctx.Err() != nil {
				return ctx.Err()
			}
			if !pgconn.Timeout(readErr) {
				return readErr
			}
			if err = flush(); err != nil {
				return err
			}
		} else {
			if pgErr, ok := message.(*pgproto3.ErrorResponse); ok {
				return fmt.Errorf("legacy replication server error: %s", pgErr.Code)
			}
			data, ok := message.(*pgproto3.CopyData)
			if !ok {
				continue
			}
			if len(data.Data) == 0 {
				return errors.New("empty legacy replication message")
			}
			switch data.Data[0] {
			case pglogrepl.PrimaryKeepaliveMessageByteID:
				keepalive, err := pglogrepl.ParsePrimaryKeepaliveMessage(data.Data[1:])
				if err != nil {
					return err
				}
				if !inTransaction && keepalive.ServerWALEnd > complete {
					complete = keepalive.ServerWALEnd
				}
				if keepalive.ReplyRequested {
					if err = flush(); err != nil {
						return err
					}
				}
			case pglogrepl.XLogDataByteID:
				xlog, err := pglogrepl.ParseXLogData(data.Data[1:])
				if err != nil {
					return err
				}
				line := string(xlog.WALData)
				records++
				switch {
				case strings.HasPrefix(line, "BEGIN "):
					if inTransaction {
						return errors.New("nested legacy transaction")
					}
					inTransaction = true
				case strings.HasPrefix(line, "COMMIT "):
					if !inTransaction {
						return errors.New("legacy commit without begin")
					}
					inTransaction = false
					complete = xlog.WALStart
				case strings.HasPrefix(line, "table public."+e.table+": "):
					if !inTransaction {
						return errors.New("legacy row outside transaction")
					}
					tags, err := legacyTags(line, e.table)
					if err != nil {
						return err
					}
					for _, tag := range tags {
						pending[tag] = 1000000000000000000 + int64(xlog.WALStart)
					}
				}
			}
		}
		if len(pending) >= s.batch || time.Since(lastProgress) >= time.Second || !inTransaction && complete >= target {
			if err = flush(); err != nil {
				return err
			}
			log.Printf("bridge stream entity=%s records=%d indexed=%d pending=%d ack=%s target=%s", e.name, records, indexed, len(pending), ack, target)
			lastProgress = time.Now()
		}
		if !inTransaction && ack >= target {
			return nil
		}
	}
}
