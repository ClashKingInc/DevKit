package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"math/rand/v2"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"clashking_devkit_database_migrations/migrateutil"
	"clashking_devkit_database_migrations/wararchive"
	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/credentials"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/klauspost/compress/zstd"
	"go.mongodb.org/mongo-driver/v2/bson"
	"go.mongodb.org/mongo-driver/v2/mongo/options"
)

const (
	defaultTrainingWars = 20_000
	defaultArchiveWars  = 100_000
	defaultPackWars     = 10_000
	defaultVerifyWars   = 1_000
)

type config struct {
	mode         string
	envFile      string
	workDir      string
	dictionary   string
	manifest     string
	packDir      string
	trainCount   int
	warCount     int
	packSize     int
	verifyCount  int
	concurrency  int
	requestRate  int
	startPack    uint64
	objectPrefix string
}

func main() {
	var cfg config
	flag.StringVar(&cfg.mode, "mode", "all", "train, migrate, verify, or all")
	flag.StringVar(&cfg.envFile, "env", "", "optional second env file containing R2 settings")
	flag.StringVar(&cfg.workDir, "work-dir", ".war-archive-prototype", "temporary samples and report directory")
	flag.StringVar(&cfg.dictionary, "dictionary", "", "dictionary path (defaults beneath work-dir)")
	flag.StringVar(&cfg.manifest, "manifest", "", "locator manifest path (defaults beneath work-dir)")
	flag.StringVar(&cfg.packDir, "pack-dir", "", "local pack staging directory (defaults beneath work-dir)")
	flag.IntVar(&cfg.trainCount, "train-wars", defaultTrainingWars, "canonical wars used to train the dictionary")
	flag.IntVar(&cfg.warCount, "wars", defaultArchiveWars, "wars to archive")
	flag.IntVar(&cfg.packSize, "pack-wars", defaultPackWars, "wars per R2 pack")
	flag.IntVar(&cfg.verifyCount, "verify-wars", defaultVerifyWars, "random wars reconstructed from R2")
	flag.IntVar(&cfg.concurrency, "concurrency", 32, "parallel R2 range reads during verification")
	flag.IntVar(&cfg.requestRate, "requests-per-second", 0, "optional steady verification request rate")
	flag.Uint64Var(&cfg.startPack, "start-pack", 1, "first pack number")
	flag.StringVar(&cfg.objectPrefix, "object-prefix", "", "optional prefix before packs/")
	flag.Parse()

	if err := run(context.Background(), cfg); err != nil {
		fmt.Fprintln(os.Stderr, "wararchive-prototype:", err)
		os.Exit(1)
	}
}

func run(ctx context.Context, cfg config) error {
	if cfg.trainCount <= 0 || cfg.warCount <= 0 || cfg.packSize <= 0 || cfg.verifyCount <= 0 || cfg.concurrency <= 0 {
		return errors.New("all count and concurrency values must be positive")
	}
	if err := os.MkdirAll(cfg.workDir, 0o755); err != nil {
		return err
	}
	if cfg.dictionary == "" {
		cfg.dictionary = filepath.Join(cfg.workDir, "war-json.zdict")
	}
	if cfg.manifest == "" {
		cfg.manifest = filepath.Join(cfg.workDir, "manifest.jsonl")
	}
	if cfg.packDir == "" {
		cfg.packDir = filepath.Join(cfg.workDir, "packs")
	}
	base, env, err := loadConfig(cfg.envFile)
	if err != nil {
		return err
	}
	for _, pair := range os.Environ() {
		key, value, ok := strings.Cut(pair, "=")
		if ok {
			env[key] = value
		}
	}

	switch cfg.mode {
	case "train":
		return train(ctx, base, cfg)
	case "migrate":
		return migrate(ctx, base, cfg)
	case "upload":
		return upload(ctx, env, cfg)
	case "verify":
		return verify(ctx, env, cfg)
	case "verify-local":
		return verifyLocal(ctx, cfg)
	case "analyze-size":
		return analyzeSize(cfg)
	case "all":
		if err := train(ctx, base, cfg); err != nil {
			return err
		}
		if err := migrate(ctx, base, cfg); err != nil {
			return err
		}
		if err := upload(ctx, env, cfg); err != nil {
			return err
		}
		return verify(ctx, env, cfg)
	default:
		return fmt.Errorf("unknown mode %q", cfg.mode)
	}
}

func analyzeSize(local config) error {
	dict, err := os.ReadFile(local.dictionary)
	if err != nil {
		return err
	}
	rows, err := loadManifest(local.manifest)
	if err != nil {
		return err
	}
	if len(rows) > 10_000 {
		rows = rows[:10_000]
	}
	store := localStore{directory: local.packDir}
	type totals struct{ raw, level3, level6 int64 }
	results := map[string]*totals{"self_contained": {}, "derivable_removed": {}, "sql_header_details": {}}
	encoders := map[string][2]*zstd.Encoder{}
	for name := range results {
		level3, err := zstd.NewWriter(nil, zstd.WithEncoderDict(dict), zstd.WithEncoderLevel(zstd.EncoderLevelFromZstd(3)), zstd.WithEncoderConcurrency(1))
		if err != nil {
			return err
		}
		level6, err := zstd.NewWriter(nil, zstd.WithEncoderDict(dict), zstd.WithEncoderLevel(zstd.EncoderLevelFromZstd(6)), zstd.WithEncoderConcurrency(1))
		if err != nil {
			return err
		}
		encoders[name] = [2]*zstd.Encoder{level3, level6}
		defer level3.Close()
		defer level6.Close()
	}
	for index, row := range rows {
		frame, err := store.rangeGet(context.Background(), row.ObjectKey, row.Offset, row.CompressedBytes)
		if err != nil {
			return err
		}
		raw, err := wararchive.DecodeFrame(frame, dict)
		if err != nil {
			return err
		}
		variants, err := sizeVariants(raw)
		if err != nil {
			return err
		}
		for name, value := range variants {
			total := results[name]
			total.raw += int64(len(value))
			pair := encoders[name]
			total.level3 += int64(len(pair[0].EncodeAll(value, nil)))
			total.level6 += int64(len(pair[1].EncodeAll(value, nil)))
		}
		if (index+1)%1000 == 0 {
			fmt.Printf("size analysis wars=%d\n", index+1)
		}
	}
	report := make(map[string]any, len(results))
	for name, total := range results {
		report[name] = map[string]any{
			"raw_bytes": total.raw, "level3_bytes": total.level3, "level6_bytes": total.level6,
			"raw_mean": float64(total.raw) / float64(len(rows)), "level3_mean": float64(total.level3) / float64(len(rows)), "level6_mean": float64(total.level6) / float64(len(rows)),
		}
	}
	return writeReport(filepath.Join(local.workDir, "size-analysis-report.json"), report)
}

func sizeVariants(raw []byte) (map[string][]byte, error) {
	var full map[string]any
	if err := json.Unmarshal(raw, &full); err != nil {
		return nil, err
	}
	lean := cloneJSONMap(full)
	delete(lean, "warId")
	delete(lean, "state")
	delete(lean, "teamSize")
	for _, side := range []string{"clan", "opponent"} {
		if clan, ok := lean[side].(map[string]any); ok {
			delete(clan, "attacks")
			delete(clan, "stars")
			delete(clan, "destructionPercentage")
		}
	}
	details := map[string]any{}
	for _, side := range []string{"clan", "opponent"} {
		if clan, ok := full[side].(map[string]any); ok {
			details[side+"Members"] = clan["members"]
		}
	}
	leanJSON, err := json.Marshal(lean)
	if err != nil {
		return nil, err
	}
	detailsJSON, err := json.Marshal(details)
	if err != nil {
		return nil, err
	}
	return map[string][]byte{"self_contained": raw, "derivable_removed": leanJSON, "sql_header_details": detailsJSON}, nil
}

func cloneJSONMap(source map[string]any) map[string]any {
	data, _ := json.Marshal(source)
	var clone map[string]any
	_ = json.Unmarshal(data, &clone)
	return clone
}

func loadConfig(envFile string) (migrateutil.Config, map[string]string, error) {
	if envFile == "" {
		cfg, err := migrateutil.LoadConfig()
		return cfg, cfg.Env, err
	}
	env, err := migrateutil.LoadEnv(envFile)
	if err != nil {
		return migrateutil.Config{}, nil, err
	}
	cfg := migrateutil.Config{
		Env:         env,
		StatsMongo:  strings.TrimSpace(env["STATS_MONGODB"]),
		StaticMongo: strings.TrimSpace(env["STATIC_MONGODB"]),
		BatchSize:   50000,
	}
	return cfg, env, nil
}

type mongoWar struct {
	ID      bson.ObjectID `bson:"_id"`
	Type    string        `bson:"type"`
	WarTag  string        `bson:"war_tag"`
	EndTime any           `bson:"endTime"`
	Data    mongoWarData  `bson:"data"`
}

type mongoWarData struct {
	Tag                  string    `bson:"tag"`
	WarTag               string    `bson:"warTag"`
	WarTagSnake          string    `bson:"war_tag"`
	Type                 string    `bson:"type"`
	Clan                 mongoClan `bson:"clan"`
	Opponent             mongoClan `bson:"opponent"`
	PreparationStartTime any       `bson:"preparationStartTime"`
	StartTime            any       `bson:"startTime"`
	EndTime              any       `bson:"endTime"`
	State                string    `bson:"state"`
	BattleModifier       string    `bson:"battleModifier"`
	TeamSize             int       `bson:"teamSize"`
	AttacksPerMember     int       `bson:"attacksPerMember"`
}

type mongoClan struct {
	Tag                   string        `bson:"tag"`
	Name                  string        `bson:"name"`
	BadgeURLs             mongoBadge    `bson:"badgeUrls"`
	ClanLevel             int           `bson:"clanLevel"`
	Attacks               int           `bson:"attacks"`
	Stars                 int           `bson:"stars"`
	DestructionPercentage float64       `bson:"destructionPercentage"`
	Members               []mongoMember `bson:"members"`
}

type mongoBadge struct{ Small, Medium, Large string }

type mongoMember struct {
	Tag           string        `bson:"tag"`
	Name          string        `bson:"name"`
	TownhallLevel int           `bson:"townhallLevel"`
	MapPosition   int           `bson:"mapPosition"`
	Attacks       []mongoAttack `bson:"attacks"`
}

type mongoAttack struct {
	AttackerTag           string `bson:"attackerTag"`
	DefenderTag           string `bson:"defenderTag"`
	Stars                 int    `bson:"stars"`
	DestructionPercentage int    `bson:"destructionPercentage"`
	Duration              int    `bson:"duration"`
	Order                 int    `bson:"order"`
}

func projection() bson.M {
	return bson.M{
		"type": 1, "war_tag": 1, "endTime": 1,
		"data.tag": 1, "data.warTag": 1, "data.war_tag": 1, "data.type": 1,
		"data.preparationStartTime": 1, "data.startTime": 1, "data.endTime": 1,
		"data.state": 1, "data.battleModifier": 1, "data.teamSize": 1, "data.attacksPerMember": 1,
		"data.clan": 1, "data.opponent": 1,
	}
}

func canonical(doc mongoWar) (wararchive.War, bool) {
	prep, prepOK := migrateutil.Time(doc.Data.PreparationStartTime)
	end, endOK := migrateutil.Time(first(doc.Data.EndTime, doc.EndTime))
	if !prepOK || !endOK || doc.Data.Clan.Tag == "" || doc.Data.Opponent.Tag == "" || !finished(doc.Data.State) {
		return wararchive.War{}, false
	}
	start, startOK := migrateutil.Time(doc.Data.StartTime)
	var startPtr *time.Time
	if startOK {
		startPtr = &start
	}
	warTag := firstString(doc.Data.Tag, doc.Data.WarTag, doc.Data.WarTagSnake, doc.WarTag)
	warType := firstString(doc.Type, doc.Data.Type)
	if warType == "" {
		if warTag != "" {
			warType = "cwl"
		} else {
			warType = "random"
		}
	}
	attacksPerMember := doc.Data.AttacksPerMember
	if attacksPerMember <= 0 {
		attacksPerMember = 1
	}
	war := wararchive.War{
		ID:     wararchive.DeterministicV7(doc.Data.Clan.Tag, doc.Data.Opponent.Tag, prep, warTag),
		WarTag: warTag, Type: strings.ToLower(warType), State: strings.ToLower(doc.Data.State),
		TeamSize: doc.Data.TeamSize, AttacksPerMember: attacksPerMember,
		PreparationStartTime: prep.UTC(), StartTime: startPtr, EndTime: end.UTC(),
		BattleModifier: normalizeModifier(doc.Data.BattleModifier),
		Clan:           canonicalClan(doc.Data.Clan), Opponent: canonicalClan(doc.Data.Opponent),
	}
	return war, true
}

func canonicalClan(clan mongoClan) wararchive.Clan {
	members := make([]wararchive.Member, 0, len(clan.Members))
	for _, member := range clan.Members {
		if member.Tag == "" {
			continue
		}
		attacks := make([]wararchive.Attack, 0, len(member.Attacks))
		for _, attack := range member.Attacks {
			if attack.DefenderTag == "" {
				continue
			}
			attacks = append(attacks, wararchive.Attack{DefenderTag: attack.DefenderTag, Stars: attack.Stars, DestructionPercentage: attack.DestructionPercentage, Duration: attack.Duration, Order: attack.Order})
		}
		members = append(members, wararchive.Member{Tag: member.Tag, Name: member.Name, TownhallLevel: member.TownhallLevel, MapPosition: member.MapPosition, Attacks: attacks})
	}
	return wararchive.Clan{Tag: clan.Tag, Name: clan.Name, BadgeToken: migrateutil.BadgeToken(clan.BadgeURLs.Large, clan.BadgeURLs.Medium, clan.BadgeURLs.Small), ClanLevel: clan.ClanLevel, Attacks: clan.Attacks, Stars: clan.Stars, DestructionPercentage: clan.DestructionPercentage, Members: members}
}

func train(ctx context.Context, cfg migrateutil.Config, local config) error {
	samples := filepath.Join(local.workDir, "training")
	if err := os.RemoveAll(samples); err != nil {
		return err
	}
	if err := os.MkdirAll(samples, 0o755); err != nil {
		return err
	}
	defer os.RemoveAll(samples)
	count, rawBytes, err := streamCanonical(ctx, cfg, 0, local.trainCount, func(index int, war wararchive.War) error {
		raw, err := wararchive.Marshal(war)
		if err != nil {
			return err
		}
		return os.WriteFile(filepath.Join(samples, fmt.Sprintf("%06d.json", index)), raw, 0o644)
	})
	if err != nil {
		return err
	}
	if count != local.trainCount {
		return fmt.Errorf("only found %d of %d training wars", count, local.trainCount)
	}
	if err := os.Remove(local.dictionary); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	cmd := exec.CommandContext(ctx, "zstd", "--train-fastcover", "-r", samples, "-o", local.dictionary, "--maxdict=32768")
	cmd.Stdout, cmd.Stderr = os.Stdout, os.Stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("train dictionary: %w", err)
	}
	info, err := os.Stat(local.dictionary)
	if err != nil {
		return err
	}
	fmt.Printf("dictionary trained samples=%d sample_bytes=%d dictionary_bytes=%d path=%s\n", count, rawBytes, info.Size(), local.dictionary)
	return nil
}

func migrate(ctx context.Context, mongoCfg migrateutil.Config, local config) error {
	dict, err := os.ReadFile(local.dictionary)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(local.packDir, 0o755); err != nil {
		return err
	}
	manifest, err := os.Create(local.manifest)
	if err != nil {
		return err
	}
	defer manifest.Close()
	writer := bufio.NewWriterSize(manifest, 1<<20)
	defer writer.Flush()
	var builder *wararchive.PackBuilder
	packID := local.startPack
	var packBytes int64
	var compressedBytes int64
	var rawBytes int64
	var uploadedPacks int
	stats := wararchive.NewPackStats()
	started := time.Now()
	flush := func() error {
		if builder == nil || builder.Len() == 0 {
			return nil
		}
		key := prefixedKey(local.objectPrefix, wararchive.ObjectKey(packID))
		payload := bytes.Clone(builder.Bytes())
		packPath := filepath.Join(local.packDir, filepath.Base(key))
		if err := os.WriteFile(packPath, payload, 0o644); err != nil {
			return err
		}
		for _, locator := range builder.Locators() {
			line := manifestRow{Locator: locator, ObjectKey: key}
			if err := json.NewEncoder(writer).Encode(line); err != nil {
				return err
			}
		}
		if err := writer.Flush(); err != nil {
			return err
		}
		packBytes += int64(len(payload))
		uploadedPacks++
		fmt.Printf("built pack=%d wars=%d bytes=%d total_packs=%d\n", packID, builder.Len(), len(payload), uploadedPacks)
		builder.Close()
		builder = nil
		packID++
		return nil
	}
	count, _, err := streamCanonical(ctx, mongoCfg, local.trainCount, local.warCount, func(_ int, war wararchive.War) error {
		if builder == nil {
			builder, err = wararchive.NewPackBuilder(packID, dict)
			if err != nil {
				return err
			}
		}
		locator, err := builder.Add(war.ID, war)
		if err != nil {
			return err
		}
		rawBytes += int64(locator.RawBytes)
		compressedBytes += int64(locator.CompressedBytes)
		stats.Add(war)
		if builder.Len() == local.packSize {
			return flush()
		}
		return nil
	})
	if err != nil {
		return err
	}
	if err := flush(); err != nil {
		return err
	}
	if count != local.warCount {
		return fmt.Errorf("only found %d of %d archive wars", count, local.warCount)
	}
	report := map[string]any{"wars": count, "packs": uploadedPacks, "raw_bytes": rawBytes, "compressed_bytes": compressedBytes, "pack_bytes": packBytes, "ratio": float64(compressedBytes) / float64(rawBytes), "elapsed_seconds": time.Since(started).Seconds(), "pack_stats": stats}
	return writeReport(filepath.Join(local.workDir, "migration-report.json"), report)
}

func upload(ctx context.Context, env map[string]string, local config) error {
	rows, err := loadManifest(local.manifest)
	if err != nil {
		return err
	}
	store, err := newR2(env, local.objectPrefix)
	if err != nil {
		return err
	}
	seen := make(map[uint64]string)
	for _, row := range rows {
		seen[row.PackID] = row.ObjectKey
	}
	packIDs := make([]uint64, 0, len(seen))
	for id := range seen {
		packIDs = append(packIDs, id)
	}
	sort.Slice(packIDs, func(i, j int) bool { return packIDs[i] < packIDs[j] })
	for index, id := range packIDs {
		payload, err := os.ReadFile(filepath.Join(local.packDir, filepath.Base(seen[id])))
		if err != nil {
			return err
		}
		if err := store.put(ctx, seen[id], payload); err != nil {
			return fmt.Errorf("upload pack %d: %w", id, err)
		}
		fmt.Printf("uploaded pack=%d bytes=%d progress=%d/%d\n", id, len(payload), index+1, len(packIDs))
	}
	return nil
}

type manifestRow struct {
	wararchive.Locator
	ObjectKey string `json:"object_key"`
}

func verify(ctx context.Context, env map[string]string, local config) error {
	store, err := newR2(env, local.objectPrefix)
	if err != nil {
		return err
	}
	return verifyWithStore(ctx, store, local, "verification-report.json")
}

func verifyLocal(ctx context.Context, local config) error {
	return verifyWithStore(ctx, localStore{directory: local.packDir}, local, "local-verification-report.json")
}

type rangeStore interface {
	rangeGet(context.Context, string, int64, int) ([]byte, error)
}

func verifyWithStore(ctx context.Context, store rangeStore, local config, reportName string) error {
	dict, err := os.ReadFile(local.dictionary)
	if err != nil {
		return err
	}
	rows, err := loadManifest(local.manifest)
	if err != nil {
		return err
	}
	if len(rows) < local.verifyCount {
		return fmt.Errorf("manifest has %d rows, need %d", len(rows), local.verifyCount)
	}
	rand.Shuffle(len(rows), func(i, j int) { rows[i], rows[j] = rows[j], rows[i] })
	rows = rows[:local.verifyCount]
	type result struct {
		latency         time.Duration
		compressed, raw int
		err             error
	}
	jobs := make(chan manifestRow)
	results := make(chan result, len(rows))
	var peakInFlight atomic.Int64
	var inFlight atomic.Int64
	var wg sync.WaitGroup
	for range local.concurrency {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for row := range jobs {
				current := inFlight.Add(1)
				for current > peakInFlight.Load() && !peakInFlight.CompareAndSwap(peakInFlight.Load(), current) {
				}
				started := time.Now()
				frame, err := store.rangeGet(ctx, row.ObjectKey, row.Offset, row.CompressedBytes)
				if err == nil {
					var raw []byte
					raw, err = wararchive.DecodeFrame(frame, dict)
					if err == nil {
						war, decodeErr := wararchive.Unmarshal(raw)
						if decodeErr != nil {
							err = decodeErr
						} else if wararchive.DeterministicV7(war.Clan.Tag, war.Opponent.Tag, war.PreparationStartTime, war.WarTag) != row.WarID {
							err = errors.New("war id mismatch")
						} else {
							err = validateReconstruction(war)
						}
					}
				}
				results <- result{latency: time.Since(started), compressed: len(frame), raw: row.RawBytes, err: err}
				inFlight.Add(-1)
			}
		}()
	}
	go func() {
		var ticker *time.Ticker
		if local.requestRate > 0 {
			ticker = time.NewTicker(time.Second / time.Duration(local.requestRate))
			defer ticker.Stop()
		}
		for index, row := range rows {
			if ticker != nil && index > 0 {
				select {
				case <-ctx.Done():
					close(jobs)
					return
				case <-ticker.C:
				}
			}
			jobs <- row
		}
		close(jobs)
		wg.Wait()
		close(results)
	}()
	latencies := make([]time.Duration, 0, len(rows))
	compressed := make([]int, 0, len(rows))
	raw := make([]int, 0, len(rows))
	failures := 0
	started := time.Now()
	for result := range results {
		if result.err != nil {
			failures++
			fmt.Fprintln(os.Stderr, "verify:", result.err)
			continue
		}
		latencies = append(latencies, result.latency)
		compressed = append(compressed, result.compressed)
		raw = append(raw, result.raw)
	}
	sort.Slice(latencies, func(i, j int) bool { return latencies[i] < latencies[j] })
	sort.Ints(compressed)
	sort.Ints(raw)
	report := map[string]any{
		"sampled": len(rows), "successes": len(latencies), "failures": failures,
		"concurrency": local.concurrency, "requests_per_second": local.requestRate, "peak_in_flight": peakInFlight.Load(), "wall_seconds": time.Since(started).Seconds(),
		"latency_ms": metricDuration(latencies), "compressed_bytes": metricInt(compressed), "raw_bytes": metricInt(raw),
	}
	if err := writeReport(filepath.Join(local.workDir, reportName), report); err != nil {
		return err
	}
	if failures != 0 {
		return fmt.Errorf("%d of %d reconstructions failed", failures, len(rows))
	}
	return nil
}

type localStore struct{ directory string }

func (s localStore) rangeGet(_ context.Context, key string, offset int64, length int) ([]byte, error) {
	file, err := os.Open(filepath.Join(s.directory, filepath.Base(key)))
	if err != nil {
		return nil, err
	}
	defer file.Close()
	data := make([]byte, length)
	_, err = file.ReadAt(data, offset)
	return data, err
}

func validateReconstruction(war wararchive.War) error {
	if war.Clan.Tag == "" || war.Opponent.Tag == "" || war.EndTime.IsZero() {
		return errors.New("missing required reconstructed war fields")
	}
	for _, clan := range []wararchive.Clan{war.Clan, war.Opponent} {
		for _, member := range clan.Members {
			if member.Tag == "" {
				return errors.New("member without tag")
			}
			for _, attack := range member.Attacks {
				if attack.DefenderTag == "" {
					return errors.New("attack without defender")
				}
				// The original attackerTag is exactly recoverable from the parent.
				attackerTag := member.Tag
				if attackerTag == "" {
					return errors.New("could not reconstruct attacker tag")
				}
			}
		}
	}
	return nil
}

type r2Store struct {
	client         *s3.Client
	bucket, prefix string
}

func newR2(env map[string]string, prefix string) (*r2Store, error) {
	endpoint := firstString(env["R2_ENDPOINT"], env["R2_ENDPOINT_URL"])
	bucket := firstString(env["R2_WARS_BUCKET"], env["R2_BUCKET"])
	access := env["R2_ACCESS_KEY_ID"]
	secret := env["R2_SECRET_ACCESS_KEY"]
	if endpoint == "" || bucket == "" || access == "" || secret == "" {
		return nil, errors.New("R2_ENDPOINT, R2_WARS_BUCKET/R2_BUCKET, R2_ACCESS_KEY_ID, and R2_SECRET_ACCESS_KEY are required")
	}
	awsCfg := aws.Config{Region: "auto", Credentials: credentials.NewStaticCredentialsProvider(access, secret, "")}
	client := s3.NewFromConfig(awsCfg, func(options *s3.Options) { options.BaseEndpoint = aws.String(endpoint); options.UsePathStyle = true })
	return &r2Store{client: client, bucket: bucket, prefix: strings.Trim(prefix, "/")}, nil
}

func (s *r2Store) key(key string) string {
	return prefixedKey(s.prefix, key)
}

func prefixedKey(prefix, key string) string {
	prefix = strings.Trim(prefix, "/")
	if prefix == "" {
		return key
	}
	return prefix + "/" + key
}
func (s *r2Store) put(ctx context.Context, key string, data []byte) error {
	_, err := s.client.PutObject(ctx, &s3.PutObjectInput{Bucket: aws.String(s.bucket), Key: aws.String(key), Body: bytes.NewReader(data), ContentType: aws.String("application/zstd")})
	return err
}
func (s *r2Store) rangeGet(ctx context.Context, key string, offset int64, length int) ([]byte, error) {
	rangeHeader := fmt.Sprintf("bytes=%d-%d", offset, offset+int64(length)-1)
	output, err := s.client.GetObject(ctx, &s3.GetObjectInput{Bucket: aws.String(s.bucket), Key: aws.String(key), Range: aws.String(rangeHeader)})
	if err != nil {
		return nil, err
	}
	defer output.Body.Close()
	return io.ReadAll(io.LimitReader(output.Body, int64(length)+1))
}

func streamCanonical(ctx context.Context, cfg migrateutil.Config, skip, count int, handle func(int, wararchive.War) error) (int, int64, error) {
	client, err := migrateutil.StatsClient(ctx, cfg)
	if err != nil {
		return 0, 0, err
	}
	defer client.Disconnect(ctx)
	collection := client.Database("looper").Collection("clan_war")
	opts := options.Find().SetSort(bson.D{{Key: "_id", Value: -1}}).SetProjection(projection()).SetBatchSize(5000)
	filter := bson.D{{Key: "data.state", Value: bson.D{{Key: "$in", Value: bson.A{"warEnded", "ended"}}}}}
	cursor, err := collection.Find(ctx, filter, opts)
	if err != nil {
		return 0, 0, err
	}
	defer cursor.Close(ctx)
	accepted, skipped := 0, 0
	var rawBytes int64
	seen := make(map[[16]byte]struct{}, skip+count)
	for cursor.Next(ctx) {
		var doc mongoWar
		if err := cursor.Decode(&doc); err != nil {
			return accepted, rawBytes, err
		}
		war, ok := canonical(doc)
		if !ok {
			continue
		}
		if _, duplicate := seen[war.ID]; duplicate {
			continue
		}
		seen[war.ID] = struct{}{}
		if skipped < skip {
			skipped++
			continue
		}
		raw, err := wararchive.Marshal(war)
		if err != nil {
			return accepted, rawBytes, err
		}
		rawBytes += int64(len(raw))
		if err := handle(accepted, war); err != nil {
			return accepted, rawBytes, err
		}
		accepted++
		if accepted%10000 == 0 {
			fmt.Printf("canonicalized wars=%d\n", accepted)
		}
		if accepted >= count {
			break
		}
	}
	return accepted, rawBytes, cursor.Err()
}

func loadManifest(path string) ([]manifestRow, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	rows := make([]manifestRow, 0, defaultArchiveWars)
	scanner := bufio.NewScanner(file)
	scanner.Buffer(make([]byte, 64<<10), 1<<20)
	for scanner.Scan() {
		var row manifestRow
		if err := json.Unmarshal(scanner.Bytes(), &row); err != nil {
			return nil, err
		}
		rows = append(rows, row)
	}
	return rows, scanner.Err()
}

func writeReport(path string, value any) error {
	data, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return err
	}
	if err := os.WriteFile(path, append(data, '\n'), 0o644); err != nil {
		return err
	}
	fmt.Println(string(data))
	return nil
}

func metricDuration(values []time.Duration) map[string]float64 {
	if len(values) == 0 {
		return map[string]float64{}
	}
	return map[string]float64{"min": float64(values[0]) / float64(time.Millisecond), "p50": float64(values[len(values)/2]) / float64(time.Millisecond), "p95": float64(values[len(values)*95/100]) / float64(time.Millisecond), "p99": float64(values[len(values)*99/100]) / float64(time.Millisecond), "max": float64(values[len(values)-1]) / float64(time.Millisecond)}
}
func metricInt(values []int) map[string]float64 {
	if len(values) == 0 {
		return map[string]float64{}
	}
	var sum int64
	for _, value := range values {
		sum += int64(value)
	}
	return map[string]float64{"min": float64(values[0]), "p50": float64(values[len(values)/2]), "p95": float64(values[len(values)*95/100]), "p99": float64(values[len(values)*99/100]), "max": float64(values[len(values)-1]), "mean": float64(sum) / float64(len(values))}
}

func first(values ...any) any {
	for _, value := range values {
		if value != nil {
			return value
		}
	}
	return nil
}
func firstString(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return strings.TrimSpace(value)
		}
	}
	return ""
}
func finished(state string) bool {
	state = strings.ToLower(strings.TrimSpace(state))
	return state == "warended" || state == "ended"
}
func normalizeModifier(value string) string {
	value = strings.ToLower(strings.TrimSpace(value))
	if value == "" {
		return "none"
	}
	return value
}
