package migrateutil

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"go.mongodb.org/mongo-driver/v2/bson"
	"go.mongodb.org/mongo-driver/v2/mongo"
	"go.mongodb.org/mongo-driver/v2/mongo/options"
)

const defaultBatchSize = 50000

type Config struct {
	Root         string
	Env          map[string]string
	StatsMongo   string
	StaticMongo  string
	TimescaleURL string
	BatchSize    int
	LimitDocs    int64
}

type Checkpoint struct {
	path   string
	script string
	state  map[string]any
	data   map[string]string
}

type Progress struct {
	label      string
	total      int64
	start      time.Time
	lastRender time.Time
}

func Main(script string, fn func(context.Context, Config) error) {
	ctx := context.Background()
	cfg, err := LoadConfig()
	if err == nil {
		err = fn(ctx, cfg)
	}
	if err != nil {
		fmt.Fprintf(os.Stderr, "%s: %v\n", script, err)
		os.Exit(1)
	}
}

func LoadConfig() (Config, error) {
	root, err := repoRoot()
	if err != nil {
		return Config{}, err
	}
	env, err := LoadEnv(filepath.Join(root, ".env"))
	if err != nil {
		return Config{}, err
	}
	for _, pair := range os.Environ() {
		key, value, ok := strings.Cut(pair, "=")
		if ok && key != "" {
			env[key] = value
		}
	}
	cfg := Config{
		Root:         root,
		Env:          env,
		StatsMongo:   firstNonEmpty(env["STATS_MONGODB"], env["STATS_MONGODB_URI"]),
		StaticMongo:  firstNonEmpty(env["STATIC_MONGODB"], env["STATIC_MONGODB_URI"]),
		TimescaleURL: firstNonEmpty(env["TIMESCALE_URL"], env["DATABASE_URL"]),
		BatchSize:    envInt(env, "MIGRATION_BATCH_SIZE", defaultBatchSize),
		LimitDocs:    envInt64(env, "MIGRATION_LIMIT_DOCS", 0),
	}
	if cfg.BatchSize <= 0 {
		cfg.BatchSize = defaultBatchSize
	}
	return cfg, nil
}

func LoadEnv(path string) (map[string]string, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("open %s: %w", path, err)
	}
	defer file.Close()
	values := map[string]string{}
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") || !strings.Contains(line, "=") {
			continue
		}
		key, value, _ := strings.Cut(line, "=")
		key = strings.TrimSpace(key)
		value = strings.Trim(strings.TrimSpace(value), `"'`)
		values[key] = value
	}
	return values, scanner.Err()
}

func StatsClient(ctx context.Context, cfg Config) (*mongo.Client, error) {
	if cfg.StatsMongo == "" {
		return nil, errors.New("missing STATS_MONGODB in .env")
	}
	return mongo.Connect(options.Client().ApplyURI(cfg.StatsMongo).SetCompressors([]string{"snappy"}))
}

func StaticClient(ctx context.Context, cfg Config) (*mongo.Client, error) {
	if cfg.StaticMongo == "" {
		return nil, errors.New("missing STATIC_MONGODB in .env")
	}
	return mongo.Connect(options.Client().ApplyURI(cfg.StaticMongo))
}

func TimescalePool(ctx context.Context, cfg Config) (*pgxpool.Pool, error) {
	if cfg.TimescaleURL == "" {
		return nil, errors.New("missing TIMESCALE_URL in .env")
	}
	poolCfg, err := pgxpool.ParseConfig(cfg.TimescaleURL)
	if err != nil {
		return nil, err
	}
	poolCfg.MaxConns = 8
	return pgxpool.NewWithConfig(ctx, poolCfg)
}

func LoadCheckpoint(cfg Config, script string) (*Checkpoint, error) {
	path := filepath.Join(cfg.Root, "migration_state.json")
	cp := &Checkpoint{
		path:   path,
		script: script,
		state:  map[string]any{},
		data:   map[string]string{},
	}

	payload, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return loadLegacyCheckpoint(cfg, cp)
	}
	if err != nil {
		return nil, err
	}
	if len(bytes.TrimSpace(payload)) != 0 {
		if err := json.Unmarshal(payload, &cp.state); err != nil {
			return nil, err
		}
	}
	if raw := cp.state[script]; raw != nil {
		data, err := checkpointDataFromJSONValue(script, raw)
		if err != nil {
			return nil, err
		}
		cp.data = data
		return cp, nil
	}
	return loadLegacyCheckpoint(cfg, cp)
}

func (c *Checkpoint) Get(key string) string {
	return c.data[key]
}

func (c *Checkpoint) Set(key, value string) error {
	c.data[key] = value
	c.state[c.script] = c.jsonValue()
	payload, err := json.MarshalIndent(c.state, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(c.path, append(payload, '\n'), 0o600)
}

func (c *Checkpoint) Clear() error {
	c.data = map[string]string{}
	delete(c.state, c.script)
	if len(c.state) == 0 {
		if err := os.Remove(c.path); err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
		return nil
	}
	payload, err := json.MarshalIndent(c.state, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(c.path, append(payload, '\n'), 0o600)
}

func loadLegacyCheckpoint(cfg Config, cp *Checkpoint) (*Checkpoint, error) {
	path := filepath.Join(cfg.Root, ".migration_state", cp.script+".json")
	payload, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return cp, nil
	}
	if err != nil {
		return nil, err
	}
	if len(bytes.TrimSpace(payload)) == 0 {
		return cp, nil
	}
	if err := json.Unmarshal(payload, &cp.data); err != nil {
		return nil, err
	}
	cp.state[cp.script] = cp.jsonValue()
	return cp, nil
}

func (c *Checkpoint) jsonValue() any {
	if key := singleValueCheckpointKey(c.script); key != "" && len(c.data) == 1 {
		if value, ok := c.data[key]; ok {
			return value
		}
	}
	out := make(map[string]string, len(c.data))
	for key, value := range c.data {
		out[key] = value
	}
	return out
}

func checkpointDataFromJSONValue(script string, value any) (map[string]string, error) {
	switch typed := value.(type) {
	case string:
		key := singleValueCheckpointKey(script)
		if key == "" {
			return nil, fmt.Errorf("checkpoint %s is a string but has no single-value key", script)
		}
		return map[string]string{key: typed}, nil
	case map[string]any:
		out := make(map[string]string, len(typed))
		for key, raw := range typed {
			value, ok := raw.(string)
			if !ok {
				return nil, fmt.Errorf("checkpoint %s.%s is %T, want string", script, key, raw)
			}
			out[key] = value
		}
		return out, nil
	default:
		return nil, fmt.Errorf("checkpoint %s is %T, want string or object", script, value)
	}
}

func singleValueCheckpointKey(script string) string {
	switch script {
	case "basic_clans":
		return "clan_tags_id"
	case "clan_change_history":
		return "all_clans_changes_id"
	case "clan_records":
		return "all_clans_records_id"
	case "clan_wars":
		return "clan_war_id"
	case "cwl_groups":
		return "cwl_group_id"
	case "join_leave_history":
		return "join_leave_id"
	case "legend_history_snapshots":
		return "legend_history_id"
	case "player_history_events":
		return "player_history_id"
	case "player_online_events":
		return "last_online_id"
	case "player_stats":
		return "player_stats_id"
	default:
		return ""
	}
}

func StreamByObjectID(
	ctx context.Context,
	cfg Config,
	cp *Checkpoint,
	cpKey string,
	collection *mongo.Collection,
	handle func(bson.M) (bool, error),
	flush func() error,
) (int64, error) {
	return StreamByObjectIDProjected(ctx, cfg, cp, cpKey, collection, nil, handle, flush)
}

func StreamByObjectIDProjected(
	ctx context.Context,
	cfg Config,
	cp *Checkpoint,
	cpKey string,
	collection *mongo.Collection,
	projection any,
	handle func(bson.M) (bool, error),
	flush func() error,
) (int64, error) {
	var filter any = bson.D{}
	if raw := cp.Get(cpKey); raw != "" {
		id, err := bson.ObjectIDFromHex(raw)
		if err != nil {
			return 0, fmt.Errorf("bad checkpoint %s=%q: %w", cpKey, raw, err)
		}
		filter = bson.D{{Key: "_id", Value: bson.D{{Key: "$gt", Value: id}}}}
	}
	opts := options.Find().
		SetSort(bson.D{{Key: "_id", Value: 1}}).
		SetBatchSize(int32(min(cfg.BatchSize, 10000))).
		SetNoCursorTimeout(true)
	if projection != nil {
		opts.SetProjection(projection)
	}
	cursor, err := collection.Find(ctx, filter, opts)
	if err != nil {
		return 0, err
	}
	defer cursor.Close(ctx)

	progress := NewProgress(ctx, cfg, collection, cpKey, filter)
	var seen int64
	var checkpointID string
	defer func() {
		progress.Done(seen)
	}()
	for cursor.Next(ctx) {
		var doc bson.M
		if err := cursor.Decode(&doc); err != nil {
			return seen, err
		}
		ready, err := handle(doc)
		if err != nil {
			return seen, err
		}
		seen++
		if id, ok := doc["_id"].(bson.ObjectID); ok {
			checkpointID = id.Hex()
		}
		if ready {
			if err := flush(); err != nil {
				return seen, err
			}
			if checkpointID != "" {
				if err := cp.Set(cpKey, checkpointID); err != nil {
					return seen, err
				}
				checkpointID = ""
			}
		}
		progress.Tick(seen)
		if cfg.LimitDocs > 0 && seen >= cfg.LimitDocs {
			break
		}
	}
	if err := cursor.Err(); err != nil {
		return seen, err
	}
	if checkpointID != "" {
		if err := flush(); err != nil {
			return seen, err
		}
		if err := cp.Set(cpKey, checkpointID); err != nil {
			return seen, err
		}
	}
	return seen, nil
}

func NewProgress(ctx context.Context, cfg Config, collection *mongo.Collection, label string, filter any) *Progress {
	total := cfg.LimitDocs
	if total <= 0 {
		countCtx, cancel := context.WithTimeout(ctx, 3*time.Second)
		defer cancel()
		count, err := collection.CountDocuments(countCtx, filter)
		if err == nil {
			total = count
		}
	}
	progress := &Progress{
		label: label,
		total: total,
		start: time.Now(),
	}
	progress.render(0, true)
	return progress
}

func (p *Progress) Tick(seen int64) {
	if seen == 0 {
		return
	}
	now := time.Now()
	if seen%1000 != 0 && now.Sub(p.lastRender) < 2*time.Second {
		return
	}
	p.render(seen, false)
}

func (p *Progress) Done(seen int64) {
	p.render(seen, false)
	fmt.Fprintln(os.Stderr)
}

func (p *Progress) render(seen int64, force bool) {
	now := time.Now()
	if !force && now.Sub(p.lastRender) < 200*time.Millisecond {
		return
	}
	p.lastRender = now
	elapsed := now.Sub(p.start).Seconds()
	rate := float64(0)
	if elapsed > 0 {
		rate = float64(seen) / elapsed
	}
	if p.total > 0 {
		percent := float64(seen) / float64(p.total)
		if percent > 1 {
			percent = 1
		}
		width := 28
		filled := int(percent * float64(width))
		bar := strings.Repeat("=", filled) + strings.Repeat(" ", width-filled)
		fmt.Fprintf(os.Stderr, "\r%-28s [%s] %6.2f%% %12d/%-12d %9.0f docs/s", p.label, bar, percent*100, seen, p.total, rate)
		return
	}
	fmt.Fprintf(os.Stderr, "\r%-28s scanned=%12d %9.0f docs/s", p.label, seen, rate)
}

func RawJSON(value any) string {
	payload, err := bson.MarshalExtJSON(value, false, false)
	if err != nil {
		payload, _ = json.Marshal(value)
	}
	if len(payload) == 0 {
		return "{}"
	}
	return string(payload)
}

func Map(value any) bson.M {
	switch typed := value.(type) {
	case bson.M:
		return typed
	case map[string]any:
		return bson.M(typed)
	case bson.D:
		out := bson.M{}
		for _, item := range typed {
			out[item.Key] = item.Value
		}
		return out
	default:
		return nil
	}
}

func Slice(value any) []any {
	switch typed := value.(type) {
	case bson.A:
		return []any(typed)
	case []any:
		return typed
	default:
		return nil
	}
}

func String(value any) string {
	if value == nil {
		return ""
	}
	return strings.TrimSpace(fmt.Sprint(value))
}

func Int(value any) int {
	switch typed := value.(type) {
	case int:
		return typed
	case int32:
		return int(typed)
	case int64:
		return int(typed)
	case float64:
		return int(typed)
	case string:
		out, _ := strconv.Atoi(strings.TrimSpace(typed))
		return out
	default:
		return 0
	}
}

func Bool(value any) bool {
	switch typed := value.(type) {
	case bool:
		return typed
	case string:
		return strings.EqualFold(typed, "true")
	default:
		return false
	}
}

func OptionalInt(value any) any {
	if value == nil {
		return nil
	}
	if out := Int(value); out != 0 {
		return out
	}
	return nil
}

func Time(value any) (time.Time, bool) {
	switch typed := value.(type) {
	case time.Time:
		return typed.UTC(), true
	case bson.DateTime:
		return typed.Time().UTC(), true
	case int:
		return time.Unix(int64(typed), 0).UTC(), true
	case int32:
		return time.Unix(int64(typed), 0).UTC(), true
	case int64:
		if typed > 1_000_000_000_000 {
			return time.UnixMilli(typed).UTC(), true
		}
		return time.Unix(typed, 0).UTC(), true
	case float64:
		return time.Unix(int64(typed), 0).UTC(), true
	case string:
		raw := strings.TrimSpace(typed)
		for _, layout := range []string{
			"20060102T150405.000Z",
			"20060102T150405Z",
			time.RFC3339Nano,
			time.RFC3339,
			"2006-01-02",
		} {
			if out, err := time.Parse(layout, raw); err == nil {
				return out.UTC(), true
			}
		}
	}
	return time.Time{}, false
}

func SeasonFromDate(value time.Time) string {
	return value.UTC().Format("2006-01")
}

func BadgeToken(values ...any) string {
	for _, value := range values {
		raw := String(value)
		if raw == "" {
			continue
		}
		raw = strings.TrimSpace(raw)
		raw = strings.TrimSuffix(raw, ".png")
		if idx := strings.LastIndex(raw, "/"); idx >= 0 {
			raw = raw[idx+1:]
		}
		if raw != "" {
			return raw
		}
	}
	return ""
}

func repoRoot() (string, error) {
	wd, err := os.Getwd()
	if err != nil {
		return "", err
	}
	for {
		if _, err := os.Stat(filepath.Join(wd, "timescale", "001_initial.sql")); err == nil {
			return wd, nil
		}
		if _, err := os.Stat(filepath.Join(wd, "..", "timescale", "001_initial.sql")); err == nil {
			return filepath.Clean(filepath.Join(wd, "..")), nil
		}
		parent := filepath.Dir(wd)
		if parent == wd {
			return "", errors.New("could not locate ClashKing database root")
		}
		wd = parent
	}
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return strings.TrimSpace(value)
		}
	}
	return ""
}

func envInt(env map[string]string, key string, fallback int) int {
	if raw := strings.TrimSpace(env[key]); raw != "" {
		if out, err := strconv.Atoi(raw); err == nil {
			return out
		}
	}
	return fallback
}

func envInt64(env map[string]string, key string, fallback int64) int64 {
	if raw := strings.TrimSpace(env[key]); raw != "" {
		if out, err := strconv.ParseInt(raw, 10, 64); err == nil {
			return out
		}
	}
	return fallback
}
