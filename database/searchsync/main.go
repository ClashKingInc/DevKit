package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/jackc/pglogrepl"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

type entity struct{ name, table, projection, index string }
type item struct {
	Tag        string
	Generation int64
	Document   json.RawMessage
}
type service struct {
	db                            *pgx.Conn
	repl                          *pgconn.PgConn
	http                          *http.Client
	endpoint, key, user, password string
	batch                         int
	entities                      []entity
	slot, statePath               string
}
type handoffState struct {
	SystemID, Database, Slot, PlayerIndex, ClanIndex, Boundary string
	Complete                                                   bool
}

func required(k string) string {
	v := os.Getenv(k)
	if v == "" {
		log.Fatalf("%s is required", k)
	}
	return v
}
func main() {
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	if err := run(ctx); err != nil && ctx.Err() == nil {
		log.Fatal(err)
	}
}
func run(ctx context.Context) error {
	db, err := pgx.Connect(ctx, os.Getenv("DATABASE_URL"))
	if err != nil {
		return errors.New("database connection failed")
	}
	defer db.Close(context.Background())
	var locked bool
	if err = db.QueryRow(ctx, "SELECT pg_try_advisory_lock(73194209)").Scan(&locked); err != nil {
		return err
	}
	if !locked {
		return errors.New("another search sync owns this database")
	}
	var dbname, system string
	if err = db.QueryRow(ctx, "SELECT current_database(),system_identifier::text FROM pg_control_system()").Scan(&dbname, &system); err != nil {
		return err
	}
	if dbname != required("SEARCH_EXPECT_DATABASE") || system != required("SEARCH_EXPECT_SYSTEM_ID") {
		return errors.New("database identity mismatch")
	}
	cfg, err := pgconn.ParseConfig(os.Getenv("DATABASE_URL"))
	if err != nil {
		return errors.New("invalid database configuration")
	}
	cfg.RuntimeParams["replication"] = "database"
	repl, err := pgconn.ConnectConfig(ctx, cfg)
	if err != nil {
		return errors.New("replication connection failed")
	}
	defer repl.Close(context.Background())
	batch := 1000
	if x := os.Getenv("SEARCH_BATCH_SIZE"); x != "" {
		batch, err = strconv.Atoi(x)
		if err != nil || batch < 1 || batch > 5000 {
			return errors.New("batch size must be 1..5000")
		}
	}
	s := service{db: db, repl: repl, http: &http.Client{Timeout: 20 * time.Second}, endpoint: strings.TrimRight(required("ELASTICSEARCH_URL"), "/"), key: os.Getenv("ELASTICSEARCH_API_KEY"), user: os.Getenv("ELASTICSEARCH_USER"), password: os.Getenv("ELASTICSEARCH_PASSWORD"), batch: batch, slot: required("SEARCH_SLOT"), statePath: filepath.Join(required("SEARCH_STATE_DIR"), "handoff.json")}
	if id := os.Getenv("ELASTICSEARCH_API_KEY_ID"); id != "" {
		s.key = base64.StdEncoding.EncodeToString([]byte(id + ":" + s.key))
	}
	s.entities = []entity{{"player", "basic_player", "jsonb_build_object('tag',src.tag,'name',src.name,'league_id',src.league_id,'clan_tag',src.clan_tag,'townhall_level',src.townhall_level)", required("SEARCH_PLAYER_INDEX")}, {"clan", "basic_clan", "jsonb_build_object('tag',src.tag,'name',src.name,'clan_level',src.clan_level,'badge_token',src.badge_token,'location_id',src.location_id,'cwl_league_id',src.cwl_league_id,'member_count',src.member_count)", required("SEARCH_CLAN_INDEX")}}
	if !validIndex(s.slot) {
		return errors.New("invalid stream slot")
	}
	for _, e := range s.entities {
		if !validIndex(e.index) {
			return errors.New("invalid index")
		}
		_, status, err := s.request(ctx, "HEAD", "/"+e.index, nil)
		if err != nil || status != 200 {
			return errors.New("existing index is unavailable")
		}
	}
	publicationRows, err := db.Query(ctx, "SELECT tablename,attnames::text[] FROM pg_publication_tables WHERE pubname='clashking_search'")
	if err != nil {
		return err
	}
	published := map[string][]string{}
	for publicationRows.Next() {
		var table string
		var columns []string
		if err = publicationRows.Scan(&table, &columns); err != nil {
			publicationRows.Close()
			return err
		}
		published[table] = columns
	}
	publicationRows.Close()
	if err = publicationRows.Err(); err != nil {
		return err
	}
	if len(published) != 2 {
		return errors.New("search publication must contain exactly two tables")
	}
	for _, e := range s.entities {
		cols := published[e.table]
		wanted := []string{"tag", "name", "league_id", "clan_tag", "townhall_level"}
		if e.name == "clan" {
			wanted = []string{"tag", "name", "clan_level", "badge_token", "location_id", "cwl_league_id", "member_count"}
		}
		if len(cols) != len(wanted) {
			return errors.New("search publication column mismatch")
		}
		for _, name := range wanted {
			found := false
			for _, column := range cols {
				if name == column {
					found = true
				}
			}
			if !found {
				return errors.New("search publication column missing")
			}
		}
	}
	st := handoffState{SystemID: system, Database: dbname, Slot: s.slot, PlayerIndex: s.entities[0].index, ClanIndex: s.entities[1].index}
	data, readErr := os.ReadFile(s.statePath)
	if readErr == nil {
		var saved handoffState
		if json.Unmarshal(data, &saved) != nil {
			return errors.New("invalid handoff file")
		}
		if saved.SystemID != system || saved.Database != dbname || saved.Slot != s.slot || saved.PlayerIndex != st.PlayerIndex || saved.ClanIndex != st.ClanIndex {
			return errors.New("handoff identity mismatch")
		}
		st = saved
	} else if !errors.Is(readErr, os.ErrNotExist) {
		return readErr
	}
	var plugin, slotDB, confirmed string
	var active bool
	err = db.QueryRow(ctx, "SELECT plugin,database,confirmed_flush_lsn::text,active FROM pg_replication_slots WHERE slot_name=$1", s.slot).Scan(&plugin, &slotDB, &confirmed, &active)
	if errors.Is(err, pgx.ErrNoRows) {
		if readErr == nil {
			return errors.New("recorded stream slot is missing; refusing to skip changes")
		}
		r, err := pglogrepl.CreateReplicationSlot(ctx, repl, s.slot, "pgoutput", pglogrepl.CreateReplicationSlotOptions{Mode: pglogrepl.LogicalReplication, SnapshotAction: "NOEXPORT_SNAPSHOT"})
		if err != nil {
			return err
		}
		st.Boundary = r.ConsistentPoint
		confirmed = r.ConsistentPoint
	} else if err != nil {
		return err
	} else {
		if plugin != "pgoutput" || slotDB != dbname || active {
			return errors.New("stream slot mismatch or already active")
		}
		if st.Boundary == "" {
			st.Boundary = confirmed
		}
	}
	if readErr != nil {
		if err = s.save(st); err != nil {
			return err
		}
	}
	if !st.Complete {
		if err = s.bridge(ctx, st.Boundary); err != nil {
			return err
		}
		st.Complete = true
		if err = s.save(st); err != nil {
			return err
		}
	}
	start, err := pglogrepl.ParseLSN(confirmed)
	if err != nil {
		return err
	}
	log.Printf("stream ready slot=%s start=%s existing_indexes=true", s.slot, start)
	return s.stream(ctx, start)
}
func (s *service) save(st handoffState) error {
	if err := os.MkdirAll(filepath.Dir(s.statePath), 0700); err != nil {
		return err
	}
	data, _ := json.Marshal(st)
	f, err := os.OpenFile(s.statePath+".tmp", os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	if _, err = f.Write(data); err == nil {
		err = f.Sync()
	}
	closeErr := f.Close()
	if err != nil {
		return err
	}
	if closeErr != nil {
		return closeErr
	}
	if err = os.Rename(s.statePath+".tmp", s.statePath); err != nil {
		return err
	}
	dir, err := os.Open(filepath.Dir(s.statePath))
	if err != nil {
		return err
	}
	defer dir.Close()
	return dir.Sync()
}
func (s *service) bridge(ctx context.Context, boundary string) error {
	// Legacy slots retain the pre-handoff gap. Successful ES batches precede each
	// slot consume; no database queue or extra source write is introduced.
	for _, e := range []entity{s.entities[1], s.entities[0]} {
		slot := os.Getenv("SEARCH_" + strings.ToUpper(e.name) + "_OLD_SLOT")
		if slot == "" {
			return errors.New("both legacy slots are required for initial handoff")
		}
		if !validIndex(slot) {
			return errors.New("invalid legacy slot")
		}
		reader, err := pgx.Connect(ctx, os.Getenv("DATABASE_URL"))
		if err != nil {
			return err
		}
		err = s.bridgeEntity(ctx, reader, e, slot, boundary)
		reader.Close(context.Background())
		if err != nil {
			return err
		}
	}
	return nil
}
func (s *service) bridgeEntity(ctx context.Context, reader *pgx.Conn, e entity, slot, boundary string) error {
	for {
		begin := time.Now()
		rows, err := reader.Query(ctx, "SELECT lsn::text,CASE WHEN data LIKE $3 THEN data END FROM pg_logical_slot_peek_changes($1,$2::pg_lsn,5000,'skip-empty-xacts','1')", slot, boundary, "table public."+e.table+": %")
		if err != nil {
			return err
		}
		keys := map[string]struct{}{}
		last := ""
		records, ops := 0, 0
		flush := func() error {
			if len(keys) == 0 {
				return nil
			}
			tags := make([]string, 0, len(keys))
			for k := range keys {
				tags = append(tags, k)
			}
			rs, err := s.db.Query(ctx, "SELECT k.tag,CASE WHEN src.tag IS NULL THEN NULL ELSE "+e.projection+" END FROM unnest($1::text[]) k(tag) LEFT JOIN "+e.table+" src ON src.tag=k.tag", tags)
			if err != nil {
				return err
			}
			lsn, err := pglogrepl.ParseLSN(last)
			if err != nil {
				rs.Close()
				return err
			}
			items := make([]item, 0, len(tags))
			for rs.Next() {
				v := item{Generation: 1000000000000000000 + int64(lsn)}
				if err = rs.Scan(&v.Tag, &v.Document); err != nil {
					rs.Close()
					return err
				}
				items = append(items, v)
			}
			rs.Close()
			if err = rs.Err(); err != nil {
				return err
			}
			if err = s.bulk(ctx, e, items); err != nil {
				return err
			}
			ops += len(items)
			clear(keys)
			return nil
		}
		for rows.Next() {
			var data *string
			if err = rows.Scan(&last, &data); err != nil {
				rows.Close()
				return err
			}
			records++
			if data == nil {
				continue
			}
			tags, err := legacyTags(*data, e.table)
			if err != nil {
				rows.Close()
				return err
			}
			for _, tag := range tags {
				keys[tag] = struct{}{}
				if len(keys) >= s.batch {
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
		if last == "" {
			last = boundary
		}
		var consumed int64
		if err = s.db.QueryRow(ctx, "SELECT count(*) FROM pg_logical_slot_get_changes($1,$2::pg_lsn,NULL,'skip-empty-xacts','1')", slot, last).Scan(&consumed); err != nil {
			return err
		}
		log.Printf("bridge entity=%s records=%d indexed=%d consumed=%d elapsed_ms=%d", e.name, records, ops, consumed, time.Since(begin).Milliseconds())
		if records == 0 {
			return nil
		}
	}
}
