package migrateutil

import (
	"bufio"
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/golang/snappy"
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
	R2Endpoint   string
	R2AccessKey  string
	R2SecretKey  string
	R2Bucket     string
	BatchSize    int
	LimitDocs    int64
}

type Checkpoint struct {
	path string
	data map[string]string
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
		R2Endpoint:   env["R2_ENDPOINT"],
		R2AccessKey:  env["R2_ACCESS_KEY_ID"],
		R2SecretKey:  env["R2_SECRET_ACCESS_KEY"],
		R2Bucket:     env["R2_BUCKET"],
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
	dir := filepath.Join(cfg.Root, ".migration_state")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, err
	}
	cp := &Checkpoint{
		path: filepath.Join(dir, script+".json"),
		data: map[string]string{},
	}
	payload, err := os.ReadFile(cp.path)
	if errors.Is(err, os.ErrNotExist) {
		return cp, nil
	}
	if err != nil {
		return nil, err
	}
	if len(bytes.TrimSpace(payload)) == 0 {
		return cp, nil
	}
	return cp, json.Unmarshal(payload, &cp.data)
}

func (c *Checkpoint) Get(key string) string {
	return c.data[key]
}

func (c *Checkpoint) Set(key, value string) error {
	c.data[key] = value
	payload, err := json.MarshalIndent(c.data, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(c.path, append(payload, '\n'), 0o600)
}

func (c *Checkpoint) Clear() error {
	c.data = map[string]string{}
	if err := os.Remove(c.path); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	return nil
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

func R2FromConfig(cfg Config) (*R2ObjectStore, error) {
	if cfg.R2Endpoint == "" || cfg.R2AccessKey == "" || cfg.R2SecretKey == "" || cfg.R2Bucket == "" {
		return nil, errors.New("missing R2_ENDPOINT/R2_ACCESS_KEY_ID/R2_SECRET_ACCESS_KEY/R2_BUCKET in .env")
	}
	endpoint, err := url.Parse(strings.TrimRight(cfg.R2Endpoint, "/"))
	if err != nil {
		return nil, err
	}
	return &R2ObjectStore{
		endpoint:        endpoint,
		accessKeyID:     cfg.R2AccessKey,
		secretAccessKey: cfg.R2SecretKey,
		bucket:          strings.Trim(cfg.R2Bucket, "/"),
		client:          newR2HTTPClient(),
		now:             time.Now,
		limiter:         newRequestRateLimiter(envInt(cfg.Env, "R2_REQUESTS_PER_SECOND", 100)),
	}, nil
}

func Snappy(payload []byte) []byte {
	return snappy.Encode(nil, payload)
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

type R2ObjectStore struct {
	endpoint        *url.URL
	accessKeyID     string
	secretAccessKey string
	bucket          string
	client          *http.Client
	now             func() time.Time
	limiter         *requestRateLimiter
}

func (s *R2ObjectStore) PutObject(ctx context.Context, key string, payload []byte, contentType string) error {
	if err := s.limiter.Wait(ctx); err != nil {
		return err
	}
	key = strings.TrimLeft(key, "/")
	target := *s.endpoint
	target.Path = "/" + s.bucket + "/" + key
	req, err := http.NewRequestWithContext(ctx, http.MethodPut, target.String(), bytes.NewReader(payload))
	if err != nil {
		return err
	}
	if contentType == "" {
		contentType = "application/octet-stream"
	}
	req.Header.Set("Content-Type", contentType)
	req.Header.Set("Content-Length", fmt.Sprintf("%d", len(payload)))
	if err := s.sign(req, payload); err != nil {
		return err
	}
	resp, err := s.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 200 && resp.StatusCode < 300 {
		return nil
	}
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
	return fmt.Errorf("r2 put %s failed: status=%d body=%s", key, resp.StatusCode, strings.TrimSpace(string(body)))
}

func newR2HTTPClient() *http.Client {
	return &http.Client{
		Transport: &http.Transport{
			Proxy:                 http.ProxyFromEnvironment,
			MaxIdleConns:          300,
			MaxIdleConnsPerHost:   300,
			MaxConnsPerHost:       300,
			IdleConnTimeout:       90 * time.Second,
			TLSHandshakeTimeout:   10 * time.Second,
			ExpectContinueTimeout: 1 * time.Second,
		},
		Timeout: 30 * time.Second,
	}
}

type requestRateLimiter struct {
	mu       sync.Mutex
	interval time.Duration
	next     time.Time
}

func newRequestRateLimiter(requestsPerSecond int) *requestRateLimiter {
	if requestsPerSecond <= 0 {
		requestsPerSecond = 100
	}
	return &requestRateLimiter{interval: time.Second / time.Duration(requestsPerSecond)}
}

func (l *requestRateLimiter) Wait(ctx context.Context) error {
	now := time.Now()
	l.mu.Lock()
	if l.next.Before(now) {
		l.next = now
	}
	waitUntil := l.next
	l.next = l.next.Add(l.interval)
	l.mu.Unlock()
	wait := time.Until(waitUntil)
	if wait <= 0 {
		return nil
	}
	timer := time.NewTimer(wait)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}

func (s *R2ObjectStore) sign(req *http.Request, payload []byte) error {
	now := s.now().UTC()
	amzDate := now.Format("20060102T150405Z")
	dateStamp := now.Format("20060102")
	payloadHash := sha256Hex(payload)
	req.Header.Set("Host", req.URL.Host)
	req.Header.Set("X-Amz-Date", amzDate)
	req.Header.Set("X-Amz-Content-Sha256", payloadHash)
	signedHeaders := canonicalSignedHeaders(req.Header)
	canonicalRequest := strings.Join([]string{
		req.Method,
		req.URL.EscapedPath(),
		req.URL.RawQuery,
		canonicalHeaders(req.Header, signedHeaders),
		strings.Join(signedHeaders, ";"),
		payloadHash,
	}, "\n")
	scope := dateStamp + "/auto/s3/aws4_request"
	stringToSign := strings.Join([]string{
		"AWS4-HMAC-SHA256",
		amzDate,
		scope,
		sha256Hex([]byte(canonicalRequest)),
	}, "\n")
	signature := hex.EncodeToString(hmacSHA256(signingKey(s.secretAccessKey, dateStamp), []byte(stringToSign)))
	req.Header.Set("Authorization", fmt.Sprintf(
		"AWS4-HMAC-SHA256 Credential=%s/%s, SignedHeaders=%s, Signature=%s",
		s.accessKeyID,
		scope,
		strings.Join(signedHeaders, ";"),
		signature,
	))
	return nil
}

func canonicalSignedHeaders(headers http.Header) []string {
	out := make([]string, 0, len(headers))
	for key := range headers {
		out = append(out, strings.ToLower(key))
	}
	sort.Strings(out)
	return out
}

func canonicalHeaders(headers http.Header, signed []string) string {
	var b strings.Builder
	for _, key := range signed {
		values := headers.Values(key)
		if len(values) == 0 {
			values = headers.Values(http.CanonicalHeaderKey(key))
		}
		for i := range values {
			values[i] = strings.Join(strings.Fields(values[i]), " ")
		}
		sort.Strings(values)
		b.WriteString(key)
		b.WriteByte(':')
		b.WriteString(strings.Join(values, ","))
		b.WriteByte('\n')
	}
	return b.String()
}

func signingKey(secret, dateStamp string) []byte {
	dateKey := hmacSHA256([]byte("AWS4"+secret), []byte(dateStamp))
	regionKey := hmacSHA256(dateKey, []byte("auto"))
	serviceKey := hmacSHA256(regionKey, []byte("s3"))
	return hmacSHA256(serviceKey, []byte("aws4_request"))
}

func hmacSHA256(key, data []byte) []byte {
	mac := hmac.New(sha256.New, key)
	mac.Write(data)
	return mac.Sum(nil)
}

func sha256Hex(data []byte) string {
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
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
