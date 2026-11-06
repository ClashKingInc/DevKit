package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"os"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

// bridge transfers the still-unacknowledged old logical history into the durable
// queue. No Elasticsearch write occurs until both fixed capture boundaries are
// bridged, so current-state coalescing cannot race the new consumer's ACKs.
func (s *service) bridge(ctx context.Context) error {
	writer, err := pgx.Connect(ctx, os.Getenv("DATABASE_URL"))
	if err != nil {
		return errors.New("bridge database connection failed")
	}
	defer writer.Close(context.Background())
	// Process the older slot first so the tightest retention horizon advances
	// before spending time on the newer slot's overlapping history.
	ordered := append([]entity(nil), s.entities...)
	if len(ordered) == 2 {
		var clanFirst bool
		err = s.db.QueryRow(ctx, "SELECT coalesce((SELECT restart_lsn FROM pg_replication_slots WHERE slot_name=$1)<(SELECT restart_lsn FROM pg_replication_slots WHERE slot_name=$2),false)", required("SEARCH_CLAN_SLOT"), required("SEARCH_PLAYER_SLOT")).Scan(&clanFirst)
		if err != nil {
			return err
		}
		if clanFirst {
			ordered[0], ordered[1] = ordered[1], ordered[0]
		}
	}
	for _, e := range ordered {
		slot := required("SEARCH_" + strings.ToUpper(e.name) + "_SLOT")
		if !validIndex(slot) {
			return errors.New("invalid old slot name")
		}
		_, err = s.db.Exec(ctx, "INSERT INTO search_sync_bridge(entity,slot_name,through_lsn) SELECT $1,$2,started_lsn FROM search_sync_capture ON CONFLICT(entity) DO NOTHING", e.name, slot)
		if err != nil {
			return err
		}
		var boundSlot, boundary string
		var done bool
		if err = s.db.QueryRow(ctx, "SELECT slot_name,through_lsn::text,completed FROM search_sync_bridge WHERE entity=$1", e.name).Scan(&boundSlot, &boundary, &done); err != nil {
			return err
		}
		if boundSlot != slot {
			return errors.New("old slot differs from persisted bridge")
		}
		if done {
			continue
		}
		var plugin, dbname, status string
		var active bool
		if err = s.db.QueryRow(ctx, "SELECT plugin,database,coalesce(wal_status,''),active FROM pg_replication_slots WHERE slot_name=$1", slot).Scan(&plugin, &dbname, &status, &active); err != nil {
			return fmt.Errorf("old slot unavailable: %s", slot)
		}
		if plugin != "test_decoding" || dbname != required("SEARCH_EXPECT_DATABASE") || active || status == "lost" {
			return errors.New("old slot is incompatible, active, or invalidated")
		}
		// Each peek returns complete committed transactions, even when a transaction
		// exceeds the requested row count. Stream its rows and flush key sets through
		// the second connection, so memory remains bounded by one 1000-key set.
		// Suppress unrelated row payloads before network transfer, but retain
		// every LSN (including logical messages) so an empty filtered payload
		// never masquerades as completion of the full capture boundary.
		for {
			began := time.Now()
			rows, err := s.db.Query(ctx, "SELECT lsn::text,CASE WHEN data LIKE $3 THEN data END FROM pg_logical_slot_peek_changes($1,$2::pg_lsn,5000,'skip-empty-xacts','1')", slot, boundary, "table public."+e.table+": %")
			if err != nil {
				return err
			}
			keys := make(map[string]struct{}, 1000)
			lastLSN := ""
			records := 0
			queued := int64(0)
			flush := func() error {
				if len(keys) == 0 {
					return nil
				}
				tags := make([]string, 0, len(keys))
				for tag := range keys {
					tags = append(tags, tag)
				}
				// A newer trigger payload wins. If its source transaction has not committed,
				// ON CONFLICT waits for it, then preserves that newer queued state.
				result, err := writer.Exec(ctx, "INSERT INTO search_sync_pending(entity,tag,document) SELECT $1,k.tag,CASE WHEN src.tag IS NULL THEN NULL ELSE "+strings.ReplaceAll(e.projection, ",tag,", ",src.tag,")+" END FROM unnest($2::text[]) k(tag) LEFT JOIN "+e.table+" src ON src.tag=k.tag ON CONFLICT(entity,tag) DO NOTHING", e.name, tags)
				if err != nil {
					return err
				}
				queued += result.RowsAffected()
				clear(keys)
				return nil
			}
			for rows.Next() {
				var lsn string
				var data *string
				if err = rows.Scan(&lsn, &data); err != nil {
					rows.Close()
					return err
				}
				lastLSN = lsn
				records++
				if data == nil {
					continue
				}
				tags, parseErr := legacyTags(*data, e.table)
				if parseErr != nil {
					rows.Close()
					return parseErr
				}
				for _, tag := range tags {
					keys[tag] = struct{}{}
					if len(keys) >= 1000 {
						if err = flush(); err != nil {
							rows.Close()
							return err
						}
					}
				}
			}
			rows.Close()
			if err = rows.Err(); err != nil {
				return err
			}
			if err = flush(); err != nil {
				return err
			}
			consumeThrough := lastLSN
			if consumeThrough == "" {
				consumeThrough = boundary
			}
			// Durable queue rows precede slot consumption. On any failure above, the
			// slot remains unchanged and a restart safely coalesces the same identities.
			var consumed int64
			if err = s.db.QueryRow(ctx, "SELECT count(*) FROM pg_logical_slot_get_changes($1,$2::pg_lsn,NULL,'skip-empty-xacts','1')", slot, consumeThrough).Scan(&consumed); err != nil {
				return err
			}
			log.Printf("bridge entity=%s records=%d queued=%d consumed=%d elapsed_ms=%d", e.name, records, queued, consumed, time.Since(began).Milliseconds())
			if records == 0 {
				_, err = s.db.Exec(ctx, "UPDATE search_sync_bridge SET completed=true,updated_at=clock_timestamp() WHERE entity=$1", e.name)
				if err != nil {
					return err
				}
				break
			}
		}
	}
	return nil
}

// legacyTags reads only the actual typed tag columns in test_decoding output.
// Quoted values are skipped as units: text containing 'tag[...]' is never
// mistaken for an identity. PK updates can contain old-key and new-tuple tags.
func legacyTags(data, table string) ([]string, error) {
	prefix := "table public." + table + ": "
	if !strings.HasPrefix(data, prefix) {
		return nil, nil
	}
	rest := strings.TrimPrefix(data, prefix)
	colon := strings.IndexByte(rest, ':')
	if colon < 0 {
		return nil, errors.New("malformed legacy operation")
	}
	op := rest[:colon]
	rest = rest[colon+1:]
	if op != "INSERT" && op != "UPDATE" && op != "DELETE" {
		return nil, fmt.Errorf("unsupported legacy source operation %s", op)
	}
	var tags []string
	for len(strings.TrimSpace(rest)) > 0 {
		rest = strings.TrimSpace(rest)
		if strings.HasPrefix(rest, "old-key:") {
			rest = rest[len("old-key:"):]
			continue
		}
		if strings.HasPrefix(rest, "new-tuple:") {
			rest = rest[len("new-tuple:"):]
			continue
		}
		bracket := strings.IndexByte(rest, '[')
		if bracket < 1 {
			return nil, errors.New("malformed legacy column")
		}
		name := rest[:bracket]
		end := strings.Index(rest[bracket:], "]:")
		if end < 0 {
			return nil, errors.New("malformed legacy type")
		}
		rest = rest[bracket+end+2:]
		value := ""
		if strings.HasPrefix(rest, "'") {
			rest = rest[1:]
			var b strings.Builder
			closed := false
			for len(rest) > 0 {
				if rest[0] == '\'' {
					if len(rest) > 1 && rest[1] == '\'' {
						b.WriteByte('\'')
						rest = rest[2:]
						continue
					}
					rest = rest[1:]
					closed = true
					break
				}
				b.WriteByte(rest[0])
				rest = rest[1:]
			}
			if !closed {
				return nil, errors.New("unterminated legacy value")
			}
			value = b.String()
		} else {
			end := strings.IndexByte(rest, ' ')
			if end < 0 {
				value = rest
				rest = ""
			} else {
				value = rest[:end]
				rest = rest[end:]
			}
		}
		if name == "tag" {
			if value == "" || value == "null" {
				return nil, errors.New("legacy tag missing")
			}
			tags = append(tags, value)
		}
	}
	if len(tags) == 0 {
		return nil, errors.New("legacy source change lacks tag")
	}
	return tags, nil
}
