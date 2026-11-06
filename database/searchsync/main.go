// Command searchsync synchronizes only the canonical player/clan search fields.
package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5"
)

type entity struct{ name, table, projection, index string }
type item struct {
	Tag        string
	Generation int64
	Document   json.RawMessage
}
type state struct {
	Cursor string
	Done   bool
}
type service struct {
	db                            *pgx.Conn
	http                          *http.Client
	endpoint, key, user, password string
	batch                         int
	entities                      []entity
}
type schemaEntry struct {
	Nodes struct {
		Table string `json:"table"`
	} `json:"nodes"`
	Setting json.RawMessage `json:"setting"`
	Mapping json.RawMessage `json:"mapping"`
}

func required(key string) string {
	v := os.Getenv(key)
	if v == "" {
		log.Fatalf("%s is required", key)
	}
	return v
}
func main() {
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	if err := run(ctx); err != nil && ctx.Err() == nil && !errors.Is(err, context.Canceled) {
		log.Fatal(err)
	}
}
func run(ctx context.Context) error {
	db, err := pgx.Connect(ctx, os.Getenv("DATABASE_URL"))
	if err != nil {
		return fmt.Errorf("database connection failed")
	}
	defer db.Close(context.Background())
	// One connection owns the advisory lock and every acknowledgement. A broken
	// connection ends this process; it cannot reconnect while an old bulk is live.
	var locked bool
	if err = db.QueryRow(ctx, "SELECT pg_try_advisory_lock(73194209)").Scan(&locked); err != nil {
		return err
	}
	if !locked {
		return errors.New("another search sync owns the database lock")
	}
	var dbname string
	if err = db.QueryRow(ctx, "SELECT current_database()").Scan(&dbname); err != nil {
		return err
	}
	if dbname != required("SEARCH_EXPECT_DATABASE") {
		return errors.New("database identity mismatch")
	}
	var system string
	if err = db.QueryRow(ctx, "SELECT system_identifier::text FROM pg_control_system()").Scan(&system); err != nil {
		return err
	}
	if system != required("SEARCH_EXPECT_SYSTEM_ID") {
		return errors.New("database system identity mismatch")
	}
	batch := 1000
	if v := os.Getenv("SEARCH_BATCH_SIZE"); v != "" {
		batch, err = strconv.Atoi(v)
		if err != nil || batch < 1 || batch > 5000 {
			return errors.New("SEARCH_BATCH_SIZE must be 1..5000")
		}
	}
	endpoint := strings.TrimRight(required("ELASTICSEARCH_URL"), "/")
	u, err := url.Parse(endpoint)
	if err != nil || u.Host == "" || u.User != nil || (u.Scheme != "http" && u.Scheme != "https") {
		return errors.New("invalid Elasticsearch URL")
	}
	s := service{db: db, http: &http.Client{Timeout: 20 * time.Second}, endpoint: endpoint, key: os.Getenv("ELASTICSEARCH_API_KEY"), user: os.Getenv("ELASTICSEARCH_USER"), password: os.Getenv("ELASTICSEARCH_PASSWORD"), batch: batch}
	if id := os.Getenv("ELASTICSEARCH_API_KEY_ID"); id != "" {
		s.key = base64.StdEncoding.EncodeToString([]byte(id + ":" + required("ELASTICSEARCH_API_KEY")))
	}
	s.entities = []entity{
		{"player", "basic_player", "jsonb_build_object('tag',tag,'name',name,'league_id',league_id,'clan_tag',clan_tag,'townhall_level',townhall_level)", required("SEARCH_PLAYER_INDEX")},
		{"clan", "basic_clan", "jsonb_build_object('tag',tag,'name',name,'clan_level',clan_level,'badge_token',badge_token,'location_id',location_id,'cwl_league_id',cwl_league_id,'member_count',member_count)", required("SEARCH_CLAN_INDEX")},
	}
	if os.Getenv("SEARCH_MODE") == "handoff" {
		if err = s.bridge(ctx); err != nil {
			return err
		}
	}
	for _, e := range s.entities {
		if !validIndex(e.index) {
			return errors.New("invalid target index name")
		}
		if err = s.initialize(ctx, e); err != nil {
			return err
		}
	}
	// Complete both snapshots before queue drain. Version 1 snapshots cannot
	// overwrite a newer queued generation, even after an interrupted deployment.
	for {
		complete := true
		for _, e := range s.entities {
			st, err := s.state(ctx, e)
			if err != nil {
				return err
			}
			if st.Done {
				continue
			}
			complete = false
			start := time.Now()
			n, err := s.snapshot(ctx, e, st)
			if err != nil {
				return fmt.Errorf("snapshot %s: %w", e.name, err)
			}
			log.Printf("snapshot entity=%s rows=%d elapsed_ms=%d", e.name, n, time.Since(start).Milliseconds())
		}
		if complete {
			break
		}
	}
	for {
		total := 0
		for _, e := range s.entities {
			start := time.Now()
			n, err := s.drain(ctx, e)
			if err != nil {
				return fmt.Errorf("queue %s: %w", e.name, err)
			}
			total += n
			if n > 0 {
				log.Printf("queue entity=%s processed=%d elapsed_ms=%d", e.name, n, time.Since(start).Milliseconds())
			}
		}
		if os.Getenv("SEARCH_RUN_ONCE") == "1" && total == 0 {
			return nil
		}
		if total == 0 {
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-time.After(200 * time.Millisecond):
			}
		}
	}
}
func validIndex(v string) bool {
	if len(v) < 1 || len(v) > 200 {
		return false
	}
	for _, r := range v {
		if !(r >= 'a' && r <= 'z' || r >= '0' && r <= '9' || r == '_' || r == '-') {
			return false
		}
	}
	return true
}
func (s *service) request(ctx context.Context, method, path string, body []byte) ([]byte, int, error) {
	req, err := http.NewRequestWithContext(ctx, method, s.endpoint+path, bytes.NewReader(body))
	if err != nil {
		return nil, 0, err
	}
	req.Header.Set("Content-Type", "application/json")
	if s.key != "" {
		req.Header.Set("Authorization", "ApiKey "+s.key)
	} else if s.user != "" {
		req.SetBasicAuth(s.user, s.password)
	}
	res, err := s.http.Do(req)
	if err != nil {
		return nil, 0, errors.New("Elasticsearch request failed")
	}
	defer res.Body.Close()
	data, err := io.ReadAll(io.LimitReader(res.Body, 16<<20))
	if err != nil {
		return nil, res.StatusCode, err
	}
	return data, res.StatusCode, nil
}
func (s *service) state(ctx context.Context, e entity) (state, error) {
	var st state
	var index string
	err := s.db.QueryRow(ctx, "SELECT index_name,cursor_tag,snapshot_done FROM search_sync_state WHERE entity=$1", e.name).Scan(&index, &st.Cursor, &st.Done)
	if err == nil && index != e.index {
		err = errors.New("target differs from persisted index; explicit rebuild required")
	}
	return st, err
}
func (s *service) initialize(ctx context.Context, e entity) error {
	_, err := s.state(ctx, e)
	if err == nil {
		_, status, requestErr := s.request(ctx, "HEAD", "/"+e.index, nil)
		if requestErr != nil || status != 200 {
			return errors.New("persisted target index is unavailable; refusing automatic recreation")
		}
		return nil
	}
	if !errors.Is(err, pgx.ErrNoRows) {
		return err
	}
	// An unbound existing index is never adopted: it could contain stale documents
	// that a forward snapshot cannot delete. Creation and DB registration are
	// recoverable with an empty-index check after a crash between the two steps.
	data, err := os.ReadFile(required("SEARCH_SCHEMA_FILE"))
	if err != nil {
		return err
	}
	var schema []schemaEntry
	if err = json.Unmarshal(data, &schema); err != nil {
		return err
	}
	var body []byte
	for _, entry := range schema {
		if entry.Nodes.Table == e.table {
			body, err = json.Marshal(map[string]json.RawMessage{"settings": entry.Setting, "mappings": entry.Mapping})
		}
	}
	if len(body) == 0 || err != nil {
		return errors.New("canonical search mapping missing")
	}
	var created []byte
	var status int
	if os.Getenv("SEARCH_ALLOW_INDEX_CREATE") == "1" {
		created, status, err = s.request(ctx, "PUT", "/"+e.index, body)
	} else {
		_, status, err = s.request(ctx, "HEAD", "/"+e.index, nil)
		if err != nil || status != 200 {
			return errors.New("target index must be precreated with canonical mappings")
		}
		created = []byte(`{"error":{"type":"resource_already_exists_exception"}}`)
		status = 400
	}
	if err != nil {
		return err
	}
	if status != 200 {
		var failure struct {
			Error struct {
				Type string `json:"type"`
			} `json:"error"`
		}
		if status != 400 || json.Unmarshal(created, &failure) != nil || failure.Error.Type != "resource_already_exists_exception" {
			return fmt.Errorf("index creation failed (HTTP %d)", status)
		}
		data, status, err = s.request(ctx, "GET", "/"+e.index+"/_count", nil)
		if err != nil || status != 200 {
			return fmt.Errorf("cannot initialize %s index (HTTP %d)", e.name, status)
		}
		var count struct {
			Count int64 `json:"count"`
		}
		if json.Unmarshal(data, &count) != nil {
			return errors.New("invalid index count")
		}
		if count.Count != 0 && os.Getenv("SEARCH_MODE") != "handoff" {
			return errors.New("unbound target index is not empty")
		}
	}
	data, status, err = s.request(ctx, "GET", "/"+e.index+"/_mapping", nil)
	if err != nil || status != 200 {
		return errors.New("cannot validate target mapping")
	}
	var actual map[string]struct {
		Mappings map[string]any `json:"mappings"`
	}
	var desired struct {
		Mappings map[string]any `json:"mappings"`
	}
	if json.Unmarshal(data, &actual) != nil || json.Unmarshal(body, &desired) != nil {
		return errors.New("invalid target mapping")
	}
	a := actual[e.index].Mappings
	if a["dynamic"] != "strict" {
		return errors.New("target mapping must be strict")
	}
	expectedProperties, _ := json.Marshal(desired.Mappings["properties"])
	actualProperties, _ := json.Marshal(a["properties"])
	if !bytes.Equal(expectedProperties, actualProperties) {
		return errors.New("target mapping differs from canonical fields")
	}
	_, err = s.db.Exec(ctx, "INSERT INTO search_sync_state(entity,index_name,snapshot_done) VALUES($1,$2,$3)", e.name, e.index, os.Getenv("SEARCH_MODE") == "handoff")
	return err
}
func (s *service) snapshot(ctx context.Context, e entity, st state) (int, error) {
	rows, err := s.db.Query(ctx, "SELECT tag,"+e.projection+" FROM "+e.table+" WHERE tag>$1 ORDER BY tag LIMIT $2", st.Cursor, s.batch)
	if err != nil {
		return 0, err
	}
	items := make([]item, 0, s.batch)
	for rows.Next() {
		v := item{Generation: 1}
		if err = rows.Scan(&v.Tag, &v.Document); err != nil {
			rows.Close()
			return 0, err
		}
		items = append(items, v)
	}
	rows.Close()
	if err = rows.Err(); err != nil {
		return 0, err
	}
	if len(items) == 0 {
		_, err = s.db.Exec(ctx, "UPDATE search_sync_state SET snapshot_done=true,updated_at=clock_timestamp() WHERE entity=$1", e.name)
		return 0, err
	}
	if err = s.bulk(ctx, e, items); err != nil {
		return 0, err
	}
	_, err = s.db.Exec(ctx, "UPDATE search_sync_state SET cursor_tag=$2,updated_at=clock_timestamp() WHERE entity=$1", e.name, items[len(items)-1].Tag)
	return len(items), err
}
func (s *service) drain(ctx context.Context, e entity) (int, error) {
	rows, err := s.db.Query(ctx, "SELECT tag,generation,document FROM search_sync_pending WHERE entity=$1 ORDER BY queued_at,tag LIMIT $2", e.name, s.batch)
	if err != nil {
		return 0, err
	}
	items := make([]item, 0, s.batch)
	for rows.Next() {
		var v item
		if err = rows.Scan(&v.Tag, &v.Generation, &v.Document); err != nil {
			rows.Close()
			return 0, err
		}
		items = append(items, v)
	}
	rows.Close()
	if err = rows.Err(); err != nil {
		return 0, err
	}
	if len(items) == 0 {
		return 0, nil
	}
	if err = s.bulk(ctx, e, items); err != nil {
		return 0, err
	}
	tags := make([]string, len(items))
	versions := make([]int64, len(items))
	for i, v := range items {
		tags[i] = v.Tag
		versions[i] = v.Generation
	}
	// A concurrent source update replaces the generation. Never remove that newer
	// payload merely because the preceding Elasticsearch bulk succeeded.
	_, err = s.db.Exec(ctx, "DELETE FROM search_sync_pending q USING unnest($2::text[],$3::bigint[]) AS done(tag,generation) WHERE q.entity=$1 AND q.tag=done.tag AND q.generation=done.generation", e.name, tags, versions)
	return len(items), err
}
func (s *service) bulk(ctx context.Context, e entity, items []item) error {
	var body bytes.Buffer
	enc := json.NewEncoder(&body)
	for _, v := range items {
		op := "index"
		if len(v.Document) == 0 || string(v.Document) == "null" {
			op = "delete"
		}
		if err := enc.Encode(map[string]any{op: map[string]any{"_index": e.index, "_id": v.Tag, "version": v.Generation, "version_type": "external_gte"}}); err != nil {
			return err
		}
		if op == "index" {
			body.Write(v.Document)
			body.WriteByte('\n')
		}
	}
	data, status, err := s.request(ctx, "POST", "/_bulk", body.Bytes())
	if err != nil {
		return err
	}
	if status != 200 {
		return fmt.Errorf("bulk HTTP %d; queue retained", status)
	}
	var response struct {
		Items []map[string]struct {
			Status int `json:"status"`
			Error  *struct {
				Type string `json:"type"`
			} `json:"error"`
		} `json:"items"`
	}
	if err = json.Unmarshal(data, &response); err != nil {
		return err
	}
	if len(response.Items) != len(items) {
		return errors.New("bulk result length mismatch; queue retained")
	}
	for _, r := range response.Items {
		if len(r) != 1 {
			return errors.New("invalid bulk item")
		}
		for op, v := range r {
			if v.Status >= 200 && v.Status < 300 {
				continue
			}
			if op == "delete" && v.Status == 404 && v.Error == nil {
				continue
			}
			if v.Status == 409 && v.Error != nil && v.Error.Type == "version_conflict_engine_exception" {
				continue
			}
			return fmt.Errorf("bulk item HTTP %d; queue retained", v.Status)
		}
	}
	return nil
}
