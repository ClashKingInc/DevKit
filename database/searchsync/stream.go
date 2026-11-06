package main

import (
	"container/list"
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
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgproto3"
)

type cacheEntry struct{ key, value string }
type documentCache struct {
	values map[string]*list.Element
	order  *list.List
	limit  int
}

func (c *documentCache) equal(k, v string) bool {
	e := c.values[k]
	if e == nil {
		return false
	}
	c.order.MoveToFront(e)
	return e.Value.(cacheEntry).value == v
}
func (c *documentCache) put(k, v string) {
	if e := c.values[k]; e != nil {
		e.Value = cacheEntry{k, v}
		c.order.MoveToFront(e)
		return
	}
	c.values[k] = c.order.PushFront(cacheEntry{k, v})
	if c.order.Len() > c.limit {
		e := c.order.Back()
		delete(c.values, e.Value.(cacheEntry).key)
		c.order.Remove(e)
	}
}

type pendingItem struct {
	entity int
	item   item
}

func (s *service) stream(ctx context.Context, start pglogrepl.LSN) error {
	if err := pglogrepl.StartReplication(ctx, s.repl, s.slot, start, pglogrepl.StartReplicationOptions{PluginArgs: []string{"proto_version '1'", "publication_names 'clashking_search'"}}); err != nil {
		return err
	}
	cacheLimit := 100000
	if value := os.Getenv("SEARCH_CACHE_ENTRIES"); value != "" {
		n, err := strconv.Atoi(value)
		if err != nil || n < 1 || n > 1000000 {
			return errors.New("cache entries must be 1..1000000")
		}
		cacheLimit = n
	}
	cache := documentCache{values: map[string]*list.Element{}, order: list.New(), limit: cacheLimit}
	pending := map[string]pendingItem{}
	relations := map[uint32]*pglogrepl.RelationMessage{}
	complete, ack := start, start
	var transaction pglogrepl.LSN
	inTransaction := false
	received, indexed, skipped := int64(0), int64(0), int64(0)
	lastProgress, lastData := time.Now(), time.Now()
	flush := func() error {
		for e, definition := range s.entities {
			batch := make([]item, 0, len(pending))
			for _, p := range pending {
				if p.entity == e {
					batch = append(batch, p.item)
				}
			}
			if len(batch) == 0 {
				continue
			}
			if err := s.bulk(ctx, definition, batch); err != nil {
				return err
			}
			for _, v := range batch {
				key := definition.name + ":" + v.Tag
				cache.put(key, string(v.Document))
				delete(pending, key)
			}
			indexed += int64(len(batch))
		}
		// Only complete transactions are acknowledged. Mid-transaction flushes keep
		// memory bounded but remain replayable until their COMMIT has been received.
		ack = complete
		return pglogrepl.SendStandbyStatusUpdate(ctx, s.repl, pglogrepl.StandbyStatusUpdate{WALWritePosition: ack, WALFlushPosition: ack, WALApplyPosition: ack})
	}
	enqueue := func(e int, v item) {
		received++
		k := s.entities[e].name + ":" + v.Tag
		if _, exists := pending[k]; !exists && cache.equal(k, string(v.Document)) {
			skipped++
			return
		}
		pending[k] = pendingItem{e, v}
	}
	for {
		deadline := time.Now().Add(250 * time.Millisecond)
		readCtx, cancel := context.WithDeadline(ctx, deadline)
		message, err := s.repl.ReceiveMessage(readCtx)
		cancel()
		if err != nil {
			if ctx.Err() != nil {
				return ctx.Err()
			}
			if !pgconn.Timeout(err) {
				return err
			}
			if err = flush(); err != nil {
				return err
			}
			if os.Getenv("SEARCH_RUN_UNTIL_IDLE") == "1" && !inTransaction && time.Since(lastData) > time.Second {
				return nil
			}
		} else {
			if pgError, ok := message.(*pgproto3.ErrorResponse); ok {
				return fmt.Errorf("replication server error: %s", pgError.Code)
			}
			data, ok := message.(*pgproto3.CopyData)
			if !ok {
				continue
			}
			if len(data.Data) == 0 {
				return errors.New("empty replication message")
			}
			switch data.Data[0] {
			case pglogrepl.PrimaryKeepaliveMessageByteID:
				keepalive, err := pglogrepl.ParsePrimaryKeepaliveMessage(data.Data[1:])
				if err != nil {
					return err
				}
				// A logical walsender keepalive carries its processed/sent position. Never
				// use XLogData.ServerWALEnd (the current WAL tip) as an ACK. Do not advance
				// through a keepalive while an emitted transaction is incomplete.
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
				logical, err := pglogrepl.Parse(xlog.WALData)
				if err != nil {
					return err
				}
				lastData = time.Now()
				switch m := logical.(type) {
				case *pglogrepl.RelationMessage:
					if m.Namespace != "public" {
						return errors.New("unexpected replicated schema")
					}
					if _, err = s.entityFor(m); err != nil {
						return err
					}
					relations[m.RelationID] = m
				case *pglogrepl.BeginMessage:
					if inTransaction {
						return errors.New("nested nonstreaming transaction")
					}
					inTransaction = true
					transaction = m.FinalLSN
				case *pglogrepl.CommitMessage:
					if !inTransaction {
						return errors.New("commit without begin")
					}
					inTransaction = false
					complete = m.TransactionEndLSN
				case *pglogrepl.InsertMessage:
					r := relations[m.RelationID]
					e, err := s.entityFor(r)
					if err != nil {
						return err
					}
					v, err := s.document(ctx, r, m.Tuple, e, transaction)
					if err != nil {
						return err
					}
					enqueue(e, v)
				case *pglogrepl.UpdateMessage:
					r := relations[m.RelationID]
					e, err := s.entityFor(r)
					if err != nil {
						return err
					}
					v, err := s.document(ctx, r, m.NewTuple, e, transaction)
					if err != nil {
						return err
					}
					if m.OldTuple != nil {
						tag, err := tupleTag(r, m.OldTuple)
						if err != nil {
							return err
						}
						if tag != v.Tag {
							enqueue(e, item{Tag: tag, Generation: v.Generation})
						}
					}
					enqueue(e, v)
				case *pglogrepl.DeleteMessage:
					r := relations[m.RelationID]
					e, err := s.entityFor(r)
					if err != nil {
						return err
					}
					tag, err := tupleTag(r, m.OldTuple)
					if err != nil {
						return err
					}
					enqueue(e, item{Tag: tag, Generation: 1000000000000000000 + int64(transaction)})
				case *pglogrepl.TruncateMessage:
					return errors.New("source TRUNCATE requires explicit search reconciliation; ACK withheld")
				case *pglogrepl.TypeMessage, *pglogrepl.OriginMessage:
				default:
					return fmt.Errorf("unsupported replication message %T", logical)
				}
				if len(pending) >= s.batch {
					if err = flush(); err != nil {
						return err
					}
				}
			default:
				return errors.New("unsupported replication frame")
			}
		}
		if time.Since(lastProgress) >= time.Second {
			if err = flush(); err != nil {
				return err
			}
			log.Printf("stream received=%d indexed=%d cache_skipped=%d pending=%d cache_entries=%d ack=%s", received, indexed, skipped, len(pending), cache.order.Len(), ack)
			lastProgress = time.Now()
		}
	}
}
func (s *service) entityFor(r *pglogrepl.RelationMessage) (int, error) {
	if r == nil {
		return 0, errors.New("missing relation metadata")
	}
	for i, e := range s.entities {
		if r.RelationName == e.table {
			wanted := map[string]bool{"tag": true, "name": true}
			if e.name == "player" {
				for _, k := range []string{"league_id", "clan_tag", "townhall_level"} {
					wanted[k] = true
				}
			} else {
				for _, k := range []string{"clan_level", "badge_token", "location_id", "cwl_league_id", "member_count"} {
					wanted[k] = true
				}
			}
			if len(r.Columns) != len(wanted) {
				return 0, errors.New("publication column contract differs")
			}
			for _, c := range r.Columns {
				if !wanted[c.Name] {
					return 0, errors.New("unexpected publication column")
				}
			}
			return i, nil
		}
	}
	return 0, errors.New("unexpected replicated table")
}
func tupleTag(r *pglogrepl.RelationMessage, t *pglogrepl.TupleData) (string, error) {
	if r == nil || t == nil || len(t.Columns) != len(r.Columns) {
		return "", errors.New("tuple column mismatch")
	}
	for i, c := range r.Columns {
		if c.Name == "tag" && t.Columns[i].DataType == 't' {
			return string(t.Columns[i].Data), nil
		}
	}
	return "", errors.New("tuple key is missing")
}
func (s *service) document(ctx context.Context, r *pglogrepl.RelationMessage, t *pglogrepl.TupleData, e int, lsn pglogrepl.LSN) (item, error) {
	tag, err := tupleTag(r, t)
	if err != nil {
		return item{}, err
	}
	v := item{Tag: tag, Generation: 1000000000000000000 + int64(lsn)}
	values := map[string]any{}
	toast := false
	for i, c := range r.Columns {
		column := t.Columns[i]
		switch column.DataType {
		case 'n':
			values[c.Name] = nil
		case 'u':
			toast = true
		case 't':
			switch c.Name {
			case "tag", "name", "clan_tag", "badge_token":
				values[c.Name] = string(column.Data)
			default:
				n, err := strconv.ParseInt(string(column.Data), 10, 64)
				if err != nil {
					return item{}, err
				}
				values[c.Name] = n
			}
		default:
			return item{}, errors.New("unsupported tuple encoding")
		}
	}
	if toast {
		// A cold/evicted cache cannot invent an omitted TOAST value. Fetch only this
		// current canonical document; subsequent ordered WAL still reaches the latest
		// state. This rare fallback is a read, never a new source/queue write.
		e := s.entities[e]
		err = s.db.QueryRow(ctx, "SELECT "+e.projection+" FROM "+e.table+" src WHERE tag=$1", tag).Scan(&v.Document)
		if errors.Is(err, pgx.ErrNoRows) {
			return v, nil
		}
		return v, err
	}
	v.Document, err = json.Marshal(values)
	return v, err
}
