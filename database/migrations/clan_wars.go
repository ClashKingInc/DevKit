//go:build ignore

package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/ClashKingInc/DevKit/database/migrations/migrateutil"
	"github.com/ClashKingInc/DevKit/database/wararchive"
	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/credentials"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
	"go.mongodb.org/mongo-driver/v2/bson"
	"go.mongodb.org/mongo-driver/v2/mongo"
	"go.mongodb.org/mongo-driver/v2/mongo/options"
)

const (
	defaultWarArchivePackSize      = 10_000
	defaultWarArchivePackWorkers   = 24
	defaultWarArchiveUploadWorkers = 8
	defaultWarArchiveSQLWorkers    = 4
)

func main() {
	migrateutil.Main("clan_wars", runClanWars)
}

func runClanWars(ctx context.Context, cfg migrateutil.Config) error {
	clanTag := normalizeClanWarTag(cfg.Env["CLAN_WARS_CLAN_TAG"])
	cwlClanTag := normalizeClanWarTag(cfg.Env["CLAN_WARS_CWL_CLAN_TAG"])
	idRange, err := clanWarIDRangeFromEnv(cfg.Env)
	if err != nil {
		return err
	}
	if clanTag != "" && cwlClanTag != "" {
		return errors.New("CLAN_WARS_CLAN_TAG and CLAN_WARS_CWL_CLAN_TAG cannot both be set")
	}
	if envBool(cfg.Env, "CLAN_WARS_TRUNCATE") {
		return errors.New("CLAN_WARS_TRUNCATE is intentionally unsupported by the R2 archive migration")
	}
	prepareOnly := envBool(cfg.Env, "CLAN_WARS_PREPARE_ONLY")
	finalizeOnly := envBool(cfg.Env, "CLAN_WARS_FINALIZE_ONLY")
	if prepareOnly && finalizeOnly {
		return errors.New("CLAN_WARS_PREPARE_ONLY and CLAN_WARS_FINALIZE_ONLY cannot both be set")
	}
	pool, err := migrateutil.TimescalePool(ctx, cfg)
	if err != nil {
		return err
	}
	defer pool.Close()
	if prepareOnly {
		return dropClanWarSecondaryIndexes(ctx, pool)
	}
	if finalizeOnly {
		return recreateClanWarSecondaryIndexes(ctx, pool)
	}

	dictionaryPath := strings.TrimSpace(cfg.Env["WAR_ARCHIVE_DICTIONARY"])
	if dictionaryPath == "" {
		dictionaryPath = "../war-json.zdict"
	}
	dictionary, err := os.ReadFile(dictionaryPath)
	if err != nil {
		return fmt.Errorf("read archive dictionary %s: %w", dictionaryPath, err)
	}
	store, err := newWarArchiveStore(cfg.Env)
	if err != nil {
		return err
	}
	mongoClient, err := migrateutil.StatsClient(ctx, cfg)
	if err != nil {
		return err
	}
	defer mongoClient.Disconnect(ctx)
	cp, err := migrateutil.LoadCheckpoint(cfg, "clan_wars")
	if err != nil {
		return err
	}

	checkpointKey := clanWarCheckpointKey(clanTag)
	filter := clanWarFilterWithIDRange(clanTag, idRange)
	if cwlClanTag != "" {
		warTags, err := loadCWLBackfillWarTags(ctx, pool, cwlClanTag)
		if err != nil {
			return err
		}
		checkpointKey = "clan_war_cwl_2025_08_2026_07_id_" + strings.TrimPrefix(cwlClanTag, "#")
		filter = applyClanWarIDRange(cwlWarTagFilter(warTags), idRange)
	}
	if explicit := strings.TrimSpace(cfg.Env["CLAN_WARS_CHECKPOINT_KEY"]); explicit != "" {
		checkpointKey = explicit
	} else if idRange.configured() {
		checkpointKey = idRange.checkpointKey(checkpointKey)
	}
	packSize := envInt(cfg.Env, "WAR_ARCHIVE_PACK_WARS", defaultWarArchivePackSize)
	if packSize <= 0 {
		return errors.New("WAR_ARCHIVE_PACK_WARS must be positive")
	}
	packWorkers := envInt(cfg.Env, "WAR_ARCHIVE_PACK_WORKERS", defaultWarArchivePackWorkers)
	uploadWorkers := envInt(cfg.Env, "WAR_ARCHIVE_UPLOAD_WORKERS", minInt(defaultWarArchiveUploadWorkers, packWorkers))
	sqlWorkers := envInt(cfg.Env, "WAR_ARCHIVE_SQL_WORKERS", minInt(defaultWarArchiveSQLWorkers, packWorkers))
	if packWorkers <= 0 || uploadWorkers <= 0 || sqlWorkers <= 0 {
		return errors.New("WAR_ARCHIVE_PACK_WORKERS, WAR_ARCHIVE_UPLOAD_WORKERS, and WAR_ARCHIVE_SQL_WORKERS must be positive")
	}
	manageIndexes := clanTag == "" && cwlClanTag == "" && !envBool(cfg.Env, "CLAN_WARS_SKIP_INDEX_MANAGEMENT")
	if manageIndexes {
		if err := dropClanWarSecondaryIndexes(ctx, pool); err != nil {
			return err
		}
	}

	pipeline := newArchivePackPipeline(ctx, packWorkers, uploadWorkers, sqlWorkers, cp, checkpointKey,
		func(processCtx context.Context, batch []archiveWar, sqlGate, uploadGate chan struct{}) error {
			return flushArchivePack(processCtx, pool, store, dictionary, batch, sqlGate, uploadGate)
		})
	defer pipeline.Close()
	collection := mongoClient.Database("looper").Collection("clan_war")
	pending := make([]archiveWar, 0, packSize)
	flush := func(checkpoint string) error {
		batch := append([]archiveWar(nil), pending...)
		pending = pending[:0]
		return pipeline.Submit(batch, checkpoint)
	}

	fmt.Printf("clan_wars: pack_size=%d pack_workers=%d upload_workers=%d sql_workers=%d\n", packSize, packWorkers, uploadWorkers, sqlWorkers)
	seen, streamErr := streamClanWarDocs(ctx, cfg, cp, checkpointKey, collection, filter, clanWarProjection(), func(doc clanWarDoc) (bool, error) {
		war, ok := canonicalArchiveWar(doc)
		if !ok {
			return false, nil
		}
		pending = append(pending, war)
		return len(pending) >= packSize, nil
	}, flush)
	pipelineErr := pipeline.Close()
	if streamErr != nil {
		return streamErr
	}
	if pipelineErr != nil {
		return pipelineErr
	}
	if manageIndexes {
		if err := recreateClanWarSecondaryIndexes(ctx, pool); err != nil {
			return err
		}
	}
	fmt.Printf("clan_wars: scanned_docs=%d archive_pack_size=%d pack_workers=%d\n", seen, packSize, packWorkers)
	return nil
}

type archivePackProcessor func(context.Context, []archiveWar, chan struct{}, chan struct{}) error

type archivePackFuture struct {
	checkpoint string
	warIDs     []uuid.UUID
	done       chan error
}

// archivePackPipeline overlaps pack work while advancing the source checkpoint
// only after every preceding pack has completed successfully.
type archivePackPipeline struct {
	ctx        context.Context
	cancel     context.CancelFunc
	maxRunning int
	sqlGate    chan struct{}
	uploadGate chan struct{}
	cp         *migrateutil.Checkpoint
	cpKey      string
	process    archivePackProcessor
	inFlight   map[uuid.UUID]struct{}
	futures    []archivePackFuture
	closeOnce  sync.Once
	closeErr   error
}

func newArchivePackPipeline(ctx context.Context, maxRunning, uploadWorkers, sqlWorkers int, cp *migrateutil.Checkpoint, cpKey string, process archivePackProcessor) *archivePackPipeline {
	pipelineCtx, cancel := context.WithCancel(ctx)
	return &archivePackPipeline{
		ctx: pipelineCtx, cancel: cancel, maxRunning: maxRunning,
		sqlGate: make(chan struct{}, sqlWorkers), uploadGate: make(chan struct{}, uploadWorkers),
		cp: cp, cpKey: cpKey, process: process, inFlight: make(map[uuid.UUID]struct{}, maxRunning*defaultWarArchivePackSize),
	}
}

func (p *archivePackPipeline) Submit(input []archiveWar, checkpoint string) error {
	if len(p.futures) >= p.maxRunning {
		if err := p.awaitOldest(true); err != nil {
			return err
		}
	}
	batch := make([]archiveWar, 0, len(input))
	ids := make([]uuid.UUID, 0, len(input))
	for _, value := range input {
		if _, exists := p.inFlight[value.ID]; exists {
			continue
		}
		p.inFlight[value.ID] = struct{}{}
		batch = append(batch, value)
		ids = append(ids, value.ID)
	}
	done := make(chan error, 1)
	p.futures = append(p.futures, archivePackFuture{checkpoint: checkpoint, warIDs: ids, done: done})
	go func() {
		if len(batch) == 0 {
			done <- nil
			return
		}
		done <- p.process(p.ctx, batch, p.sqlGate, p.uploadGate)
	}()
	return nil
}

func (p *archivePackPipeline) awaitOldest(checkpoint bool) error {
	if len(p.futures) == 0 {
		return nil
	}
	future := p.futures[0]
	p.futures = p.futures[1:]
	err := <-future.done
	for _, id := range future.warIDs {
		delete(p.inFlight, id)
	}
	if err != nil {
		p.cancel()
		return err
	}
	if checkpoint && future.checkpoint != "" {
		if err := p.cp.Set(p.cpKey, future.checkpoint); err != nil {
			p.cancel()
			return err
		}
	}
	return nil
}

func (p *archivePackPipeline) Close() error {
	p.closeOnce.Do(func() {
		for len(p.futures) > 0 {
			if err := p.awaitOldest(p.closeErr == nil); err != nil && p.closeErr == nil {
				p.closeErr = err
			}
		}
		p.cancel()
	})
	return p.closeErr
}

type archiveWar struct {
	ID      uuid.UUID
	WarType string
	War     wararchive.War
}

func canonicalArchiveWar(doc clanWarDoc) (archiveWar, bool) {
	clanTag := doc.Data.Clan.Tag
	opponentTag := doc.Data.Opponent.Tag
	prepAt, prepOK := migrateutil.Time(doc.Data.PreparationStartTime)
	startAt, startOK := migrateutil.Time(doc.Data.StartTime)
	endAt, endOK := migrateutil.Time(firstWar(doc.Data.EndTime, doc.EndTime))
	if clanTag == "" || opponentTag == "" || !prepOK || !startOK || !endOK || !isFinishedWar(doc.Data.State) {
		return archiveWar{}, false
	}
	warTag := firstNonEmptyString(doc.Data.Tag, doc.Data.WarTag, doc.Data.WarTagSnake, doc.WarTag)
	warType := strings.ToLower(firstNonEmptyString(doc.Type, doc.Data.Type))
	if warType == "" {
		if warTag != "" {
			warType = "cwl"
		} else {
			warType = "random"
		}
	}
	attacksPerMember := migrateutil.Int(doc.Data.AttacksPerMember)
	if attacksPerMember <= 0 {
		attacksPerMember = 1
	}
	id := wararchive.DeterministicV7(clanTag, opponentTag, prepAt, warTag)
	clan, opponent := doc.Data.Clan, doc.Data.Opponent
	if clan.Tag > opponent.Tag {
		clan, opponent = opponent, clan
	}
	war := wararchive.War{
		ID: id, WarTag: warTag, State: strings.ToLower(doc.Data.State),
		TeamSize: migrateutil.Int(doc.Data.TeamSize), AttacksPerMember: attacksPerMember,
		PreparationStartTime: prepAt.UTC(), StartTime: startAt.UTC(), EndTime: endAt.UTC(),
		BattleModifier: wararchive.NormalizeBattleModifier(doc.Data.BattleModifier),
		Clan:           canonicalArchiveClan(clan), Opponent: canonicalArchiveClan(opponent),
	}
	return archiveWar{ID: id, WarType: warType, War: war}, true
}

func canonicalArchiveClan(clan warClanDoc) wararchive.Clan {
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
			attacks = append(attacks, wararchive.Attack{
				DefenderTag: attack.DefenderTag, Stars: migrateutil.Int(attack.Stars),
				DestructionPercentage: migrateutil.Int(attack.DestructionPercentage),
				Duration:              migrateutil.Int(attack.Duration), Order: migrateutil.Int(attack.Order),
			})
		}
		members = append(members, wararchive.Member{
			Tag: member.Tag, Name: member.Name, TownhallLevel: migrateutil.Int(member.TownhallLevel),
			MapPosition: migrateutil.Int(member.MapPosition), Attacks: attacks,
		})
	}
	return wararchive.Clan{
		Tag: clan.Tag, Name: clan.Name,
		BadgeToken: migrateutil.BadgeToken(clan.BadgeURLs.Large, clan.BadgeURLs.Medium, clan.BadgeURLs.Small),
		ClanLevel:  migrateutil.Int(clan.ClanLevel), Attacks: migrateutil.Int(clan.Attacks), Stars: migrateutil.Int(clan.Stars),
		DestructionPercentage: warFloat(clan.DestructionPercentage), Members: members,
	}
}

func flushArchivePack(ctx context.Context, pool *pgxpool.Pool, store *warArchiveStore, dictionary []byte, input []archiveWar, sqlGate, uploadGate chan struct{}) error {
	started := time.Now()
	if err := acquireArchiveGate(ctx, sqlGate); err != nil {
		return err
	}
	wars, err := excludeStoredWars(ctx, pool, input)
	if err != nil || len(wars) == 0 {
		releaseArchiveGate(sqlGate)
		return err
	}
	packID, err := reserveMigrationPack(ctx, pool)
	releaseArchiveGate(sqlGate)
	if err != nil {
		return err
	}
	buildStarted := time.Now()
	builder, err := wararchive.NewPackBuilder(uint64(packID), dictionary)
	if err != nil {
		return err
	}
	defer builder.Close()
	stats := wararchive.NewPackStats()
	firstEnd, lastEnd := wars[0].War.EndTime, wars[0].War.EndTime
	for _, value := range wars {
		if _, err := builder.Add(value.ID, value.War); err != nil {
			return err
		}
		stats.Add(value.WarType, value.War)
		if value.War.EndTime.Before(firstEnd) {
			firstEnd = value.War.EndTime
		}
		if value.War.EndTime.After(lastEnd) {
			lastEnd = value.War.EndTime
		}
	}
	object := bytes.Clone(builder.Bytes())
	buildDuration := time.Since(buildStarted)
	if err := acquireArchiveGate(ctx, uploadGate); err != nil {
		return err
	}
	uploadStarted := time.Now()
	objectKey := wararchive.ObjectKey(uint64(packID))
	if err := store.put(ctx, objectKey, object); err != nil {
		releaseArchiveGate(uploadGate)
		return fmt.Errorf("upload archive pack %d: %w", packID, err)
	}
	uploadDuration := time.Since(uploadStarted)
	primeStarted := time.Now()
	if err := store.prime(ctx, objectKey); err != nil {
		fmt.Printf("clan_wars: cache prime warning pack=%d error=%v\n", packID, err)
	}
	primeDuration := time.Since(primeStarted)
	releaseArchiveGate(uploadGate)
	if err := acquireArchiveGate(ctx, sqlGate); err != nil {
		return err
	}
	finalizeStarted := time.Now()
	if err := finalizeArchivePack(ctx, pool, packID, wars, builder.Locators(), stats, firstEnd, lastEnd); err != nil {
		releaseArchiveGate(sqlGate)
		return err
	}
	finalizeDuration := time.Since(finalizeStarted)
	releaseArchiveGate(sqlGate)
	fmt.Printf("clan_wars: uploaded pack=%d wars=%d attacks=%d raw_bytes=%d compressed_bytes=%d build=%s upload=%s prime=%s finalize=%s total=%s\n",
		packID, len(wars), stats.Attacks.Total, sumRawBytes(builder.Locators()), len(object), buildDuration, uploadDuration, primeDuration, finalizeDuration, time.Since(started))
	return nil
}

func acquireArchiveGate(ctx context.Context, gate chan struct{}) error {
	select {
	case gate <- struct{}{}:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

func releaseArchiveGate(gate chan struct{}) { <-gate }

func excludeStoredWars(ctx context.Context, pool *pgxpool.Pool, input []archiveWar) ([]archiveWar, error) {
	unique := make(map[uuid.UUID]archiveWar, len(input))
	ids := make([]uuid.UUID, 0, len(input))
	for _, value := range input {
		if _, exists := unique[value.ID]; exists {
			continue
		}
		unique[value.ID] = value
		ids = append(ids, value.ID)
	}
	rows, err := pool.Query(ctx, `SELECT DISTINCT war_id FROM wars WHERE war_id = ANY($1::uuid[])`, ids)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var id uuid.UUID
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		delete(unique, id)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	result := make([]archiveWar, 0, len(unique))
	for _, id := range ids {
		if value, exists := unique[id]; exists {
			result = append(result, value)
		}
	}
	return result, nil
}

func reserveMigrationPack(ctx context.Context, pool *pgxpool.Pool) (int64, error) {
	var packID int64
	err := pool.QueryRow(ctx, `
		INSERT INTO war_archive_packs (source, status)
		VALUES ('migration', 'building')
		RETURNING pack_id
	`).Scan(&packID)
	return packID, err
}

type warStageRow struct {
	value   archiveWar
	locator wararchive.Locator
}

func finalizeArchivePack(ctx context.Context, pool *pgxpool.Pool, packID int64, wars []archiveWar, locators []wararchive.Locator, stats wararchive.PackStats, firstEnd, lastEnd time.Time) error {
	if len(wars) != len(locators) {
		return errors.New("archive war and locator counts differ")
	}
	tx, err := pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, `CREATE TEMP TABLE war_archive_stage (LIKE wars INCLUDING DEFAULTS) ON COMMIT DROP`); err != nil {
		return err
	}
	rows := make([]warStageRow, len(wars))
	for index := range wars {
		rows[index] = warStageRow{value: wars[index], locator: locators[index]}
	}
	columns := []string{
		"war_id", "clan_tag", "opponent_tag", "prep_time", "start_time", "end_time", "size", "attacks_per_member",
		"war_type", "state", "battle_modifier", "war_tag", "clan_name", "opponent_name", "clan_badge_token",
		"opponent_badge_token", "clan_level", "opponent_clan_level", "clan_attacks", "opponent_attacks", "clan_stars",
		"opponent_stars", "clan_destruction_percentage", "opponent_destruction_percentage", "archive_pack_id",
		"archive_offset", "archive_compressed_bytes",
	}
	if _, err := tx.CopyFrom(ctx, pgx.Identifier{"war_archive_stage"}, columns, pgx.CopyFromSlice(len(rows), func(index int) ([]any, error) {
		row := rows[index]
		war := row.value.War
		return []any{
			row.value.ID, war.Clan.Tag, war.Opponent.Tag, war.PreparationStartTime, war.StartTime, war.EndTime,
			war.TeamSize, war.AttacksPerMember, row.value.WarType, war.State, war.BattleModifier, nullString(war.WarTag),
			war.Clan.Name, war.Opponent.Name, war.Clan.BadgeToken, war.Opponent.BadgeToken, war.Clan.ClanLevel,
			war.Opponent.ClanLevel, war.Clan.Attacks, war.Opponent.Attacks, war.Clan.Stars, war.Opponent.Stars,
			war.Clan.DestructionPercentage, war.Opponent.DestructionPercentage, packID, row.locator.Offset,
			row.locator.CompressedBytes,
		}, nil
	})); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `
		INSERT INTO wars (`+strings.Join(columns, ", ")+`)
		SELECT `+strings.Join(columns, ", ")+` FROM war_archive_stage
		ON CONFLICT (war_id, end_time) DO UPDATE SET
			archive_pack_id = EXCLUDED.archive_pack_id,
			archive_offset = EXCLUDED.archive_offset,
			archive_compressed_bytes = EXCLUDED.archive_compressed_bytes
	`); err != nil {
		return err
	}
	if err := upsertPlayerWarHistory(ctx, tx, wars); err != nil {
		return err
	}
	statsJSON, err := json.Marshal(stats)
	if err != nil {
		return err
	}
	result, err := tx.Exec(ctx, `
		UPDATE war_archive_packs
		SET status = 'uploaded', war_count = $2, attack_count = $3, raw_bytes = $4,
			compressed_bytes = $5, first_end_time = $6, last_end_time = $7,
			stats = $8, uploaded_at = now()
		WHERE pack_id = $1 AND source = 'migration' AND status = 'building'
	`, packID, len(wars), stats.Attacks.Total, sumRawBytes(locators), sumCompressedBytes(locators), firstEnd, lastEnd, statsJSON)
	if err != nil {
		return err
	}
	if result.RowsAffected() != 1 {
		return fmt.Errorf("finalized %d migration pack rows, expected 1", result.RowsAffected())
	}
	return tx.Commit(ctx)
}

type historyStageRow struct {
	playerTag   string
	periodStart time.Time
	warID       uuid.UUID
}

func upsertPlayerWarHistory(ctx context.Context, tx pgx.Tx, wars []archiveWar) error {
	rows := make([]historyStageRow, 0, len(wars)*50)
	seen := make(map[string]struct{}, len(wars)*50)
	for _, value := range wars {
		period := quarterStart(value.War.EndTime)
		for _, clan := range []wararchive.Clan{value.War.Clan, value.War.Opponent} {
			for _, member := range clan.Members {
				key := member.Tag + "\x00" + value.ID.String()
				if member.Tag == "" {
					continue
				}
				if _, exists := seen[key]; exists {
					continue
				}
				seen[key] = struct{}{}
				rows = append(rows, historyStageRow{playerTag: member.Tag, periodStart: period, warID: value.ID})
			}
		}
	}
	if len(rows) == 0 {
		return nil
	}
	if _, err := tx.Exec(ctx, `CREATE TEMP TABLE player_war_history_stage (player_tag text, period_start date, war_id uuid) ON COMMIT DROP`); err != nil {
		return err
	}
	if _, err := tx.CopyFrom(ctx, pgx.Identifier{"player_war_history_stage"}, []string{"player_tag", "period_start", "war_id"}, pgx.CopyFromSlice(len(rows), func(index int) ([]any, error) {
		row := rows[index]
		return []any{row.playerTag, row.periodStart, row.warID}, nil
	})); err != nil {
		return err
	}
	_, err := tx.Exec(ctx, `
		INSERT INTO player_war_history (player_tag, period_start, war_ids)
		SELECT player_tag, period_start, array_agg(DISTINCT war_id ORDER BY war_id)
		FROM player_war_history_stage
		GROUP BY player_tag, period_start
		ON CONFLICT (player_tag, period_start) DO UPDATE SET
			war_ids = ARRAY(
				SELECT DISTINCT id
				FROM unnest(player_war_history.war_ids || EXCLUDED.war_ids) AS id
				ORDER BY id
			),
			updated_at = now()
	`)
	return err
}

func quarterStart(value time.Time) time.Time {
	value = value.UTC()
	month := time.Month(((int(value.Month()) - 1) / 3 * 3) + 1)
	return time.Date(value.Year(), month, 1, 0, 0, 0, 0, time.UTC)
}

func sumRawBytes(rows []wararchive.Locator) int64 {
	var total int64
	for _, row := range rows {
		total += int64(row.RawBytes)
	}
	return total
}

func sumCompressedBytes(rows []wararchive.Locator) int64 {
	var total int64
	for _, row := range rows {
		total += int64(row.CompressedBytes)
	}
	return total
}

type warArchiveStore struct {
	client       *s3.Client
	bucket       string
	publicOrigin string
	httpClient   *http.Client
}

func newWarArchiveStore(env map[string]string) (*warArchiveStore, error) {
	endpoint := firstNonEmptyString(env["WAR_ARCHIVE_S3_ENDPOINT"], env["R2_ENDPOINT"], env["R2_ENDPOINT_URL"])
	if endpoint == "" && strings.TrimSpace(env["R2_ACCOUNT_ID"]) != "" {
		endpoint = "https://" + strings.TrimSpace(env["R2_ACCOUNT_ID"]) + ".r2.cloudflarestorage.com"
	}
	bucket := firstNonEmptyString(env["WAR_ARCHIVE_BUCKET"], env["R2_WARS_BUCKET"], "clashking-wars")
	publicOrigin := strings.TrimRight(firstNonEmptyString(env["WAR_ARCHIVE_ORIGIN"], "https://wars.clashk.ing"), "/")
	access := strings.TrimSpace(env["R2_ACCESS_KEY_ID"])
	secret := strings.TrimSpace(env["R2_SECRET_ACCESS_KEY"])
	if endpoint == "" || bucket == "" || access == "" || secret == "" {
		return nil, errors.New("R2 endpoint/account, archive bucket, R2_ACCESS_KEY_ID, and R2_SECRET_ACCESS_KEY are required")
	}
	awsConfig := aws.Config{
		Region: "auto", Credentials: credentials.NewStaticCredentialsProvider(access, secret, ""),
		HTTPClient: &http.Client{Timeout: 2 * time.Minute},
	}
	client := s3.NewFromConfig(awsConfig, func(options *s3.Options) {
		options.BaseEndpoint = aws.String(endpoint)
		options.UsePathStyle = true
	})
	return &warArchiveStore{client: client, bucket: bucket, publicOrigin: publicOrigin, httpClient: &http.Client{Timeout: 2 * time.Minute}}, nil
}

func (s *warArchiveStore) put(ctx context.Context, key string, payload []byte) error {
	_, err := s.client.PutObject(ctx, &s3.PutObjectInput{
		Bucket: aws.String(s.bucket), Key: aws.String(key), Body: bytes.NewReader(payload),
		ContentType: aws.String("application/octet-stream"), CacheControl: aws.String("public, max-age=31536000, immutable"),
	})
	return err
}

func (s *warArchiveStore) prime(ctx context.Context, key string) error {
	request, err := http.NewRequestWithContext(ctx, http.MethodHead, s.publicOrigin+"/"+key, nil)
	if err != nil {
		return err
	}
	response, err := s.httpClient.Do(request)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return fmt.Errorf("cache prime returned HTTP %d", response.StatusCode)
	}
	if status := strings.ToUpper(strings.TrimSpace(response.Header.Get("CF-Cache-Status"))); status == "BYPASS" || status == "DYNAMIC" {
		return fmt.Errorf("cache prime was not eligible for caching: %s", status)
	}
	return nil
}

type clanWarIndexDB interface {
	Exec(context.Context, string, ...any) (pgconn.CommandTag, error)
}

func dropClanWarSecondaryIndexes(ctx context.Context, db clanWarIndexDB) error {
	started := time.Now()
	fmt.Fprint(os.Stderr, "clan_wars: dropping secondary indexes ...")
	_, err := db.Exec(ctx, `
		DROP INDEX IF EXISTS public.idx_wars_clan_end_time;
		DROP INDEX IF EXISTS public.idx_wars_opponent_end_time;
		DROP INDEX IF EXISTS public.idx_wars_war_tag;
	`)
	if err != nil {
		fmt.Fprintln(os.Stderr)
		return err
	}
	fmt.Fprintf(os.Stderr, " done in %s\n", time.Since(started).Round(time.Millisecond))
	return nil
}

func recreateClanWarSecondaryIndexes(ctx context.Context, db clanWarIndexDB) error {
	statements := []struct {
		name string
		sql  string
	}{
		{name: "idx_wars_clan_end_time", sql: `CREATE INDEX IF NOT EXISTS idx_wars_clan_end_time ON public.wars USING btree (clan_tag, end_time DESC)`},
		{name: "idx_wars_opponent_end_time", sql: `CREATE INDEX IF NOT EXISTS idx_wars_opponent_end_time ON public.wars USING btree (opponent_tag, end_time DESC)`},
		{name: "idx_wars_war_tag", sql: `CREATE INDEX IF NOT EXISTS idx_wars_war_tag ON public.wars USING btree (war_tag) WHERE (war_tag IS NOT NULL)`},
	}
	for _, statement := range statements {
		started := time.Now()
		fmt.Fprintf(os.Stderr, "clan_wars: creating %s ...", statement.name)
		if _, err := db.Exec(ctx, statement.sql); err != nil {
			fmt.Fprintln(os.Stderr)
			return fmt.Errorf("create %s: %w", statement.name, err)
		}
		fmt.Fprintf(os.Stderr, " done in %s\n", time.Since(started).Round(time.Millisecond))
	}
	return nil
}

func normalizeClanWarTag(value string) string {
	value = strings.ToUpper(strings.TrimSpace(value))
	if value != "" && !strings.HasPrefix(value, "#") {
		value = "#" + value
	}
	return value
}

func clanWarCheckpointKey(clanTag string) string {
	if clanTag == "" {
		return "clan_war_r2_id"
	}
	return "clan_war_r2_id_" + strings.TrimPrefix(clanTag, "#")
}

type clanWarIDRange struct {
	after  *bson.ObjectID
	from   *bson.ObjectID
	before *bson.ObjectID
}

func clanWarIDRangeFromEnv(env map[string]string) (clanWarIDRange, error) {
	parse := func(key string) (*bson.ObjectID, error) {
		raw := strings.TrimSpace(env[key])
		if raw == "" {
			return nil, nil
		}
		id, err := bson.ObjectIDFromHex(raw)
		if err != nil {
			return nil, fmt.Errorf("invalid %s=%q: %w", key, raw, err)
		}
		return &id, nil
	}
	after, err := parse("CLAN_WARS_ID_AFTER")
	if err != nil {
		return clanWarIDRange{}, err
	}
	from, err := parse("CLAN_WARS_ID_FROM")
	if err != nil {
		return clanWarIDRange{}, err
	}
	before, err := parse("CLAN_WARS_ID_BEFORE")
	if err != nil {
		return clanWarIDRange{}, err
	}
	if after != nil && from != nil {
		return clanWarIDRange{}, errors.New("CLAN_WARS_ID_AFTER and CLAN_WARS_ID_FROM cannot both be set")
	}
	lower := after
	if lower == nil {
		lower = from
	}
	if lower != nil && before != nil && bytes.Compare(lower[:], before[:]) >= 0 {
		return clanWarIDRange{}, errors.New("the CLAN_WARS_ID_BEFORE bound must be greater than the lower ObjectID bound")
	}
	return clanWarIDRange{after: after, from: from, before: before}, nil
}

func (r clanWarIDRange) configured() bool {
	return r.after != nil || r.from != nil || r.before != nil
}

func (r clanWarIDRange) checkpointKey(base string) string {
	lower := "start"
	if r.after != nil {
		lower = "after_" + r.after.Hex()
	} else if r.from != nil {
		lower = "from_" + r.from.Hex()
	}
	upper := "end"
	if r.before != nil {
		upper = "before_" + r.before.Hex()
	}
	return base + "_" + lower + "_" + upper
}

func clanWarFilterWithIDRange(clanTag string, idRange clanWarIDRange) bson.D {
	return applyClanWarIDRange(clanWarFilter(clanTag), idRange)
}

func applyClanWarIDRange(base bson.D, idRange clanWarIDRange) bson.D {
	if !idRange.configured() {
		return base
	}
	conditions := bson.D{}
	if idRange.after != nil {
		conditions = append(conditions, bson.E{Key: "$gt", Value: *idRange.after})
	} else if idRange.from != nil {
		conditions = append(conditions, bson.E{Key: "$gte", Value: *idRange.from})
	}
	if idRange.before != nil {
		conditions = append(conditions, bson.E{Key: "$lt", Value: *idRange.before})
	}
	if len(base) == 1 && base[0].Key == "_id" {
		return bson.D{{Key: "_id", Value: conditions}}
	}
	return append(base, bson.E{Key: "_id", Value: conditions})
}

func clanWarFilter(clanTag string) bson.D {
	if clanTag == "" {
		return bson.D{{Key: "_id", Value: bson.D{{Key: "$exists", Value: true}}}}
	}
	return bson.D{{Key: "$or", Value: bson.A{
		bson.D{{Key: "data.clan.tag", Value: clanTag}},
		bson.D{{Key: "data.opponent.tag", Value: clanTag}},
	}}}
}

func cwlWarTagFilter(warTags []string) bson.D {
	return bson.D{{Key: "data.tag", Value: bson.D{{Key: "$in", Value: warTags}}}}
}

func loadCWLBackfillWarTags(ctx context.Context, pool interface {
	Query(context.Context, string, ...any) (pgx.Rows, error)
}, clanTag string) ([]string, error) {
	rows, err := pool.Query(ctx, `
		SELECT groups.rounds
		FROM cwl_groups AS groups
		JOIN cwl_group_clans AS clans ON clans.cwl_id = groups.cwl_id
		WHERE clans.clan_tag = $1
		  AND left(groups.season, 7) >= '2025-08'
		  AND left(groups.season, 7) < '2026-08'
	`, clanTag)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	seen := map[string]struct{}{}
	var result []string
	for rows.Next() {
		var raw []byte
		if err := rows.Scan(&raw); err != nil {
			return nil, err
		}
		for _, tag := range decodeCWLBackfillWarTags(raw) {
			if tag == "" || tag == "#0" {
				continue
			}
			if _, exists := seen[tag]; exists {
				continue
			}
			seen[tag] = struct{}{}
			result = append(result, tag)
		}
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	if len(result) == 0 {
		return nil, fmt.Errorf("no August 2025 through July 2026 CWL war tags found for %s", clanTag)
	}
	sort.Strings(result)
	return result, nil
}

func decodeCWLBackfillWarTags(raw []byte) []string {
	var official []struct {
		WarTags []string `json:"warTags"`
	}
	if json.Unmarshal(raw, &official) == nil {
		var result []string
		for _, round := range official {
			result = append(result, round.WarTags...)
		}
		return result
	}
	var nested [][]string
	if json.Unmarshal(raw, &nested) == nil {
		var result []string
		for _, round := range nested {
			result = append(result, round...)
		}
		return result
	}
	return nil
}

type clanWarDoc struct {
	ID      bson.ObjectID `bson:"_id"`
	Type    string        `bson:"type"`
	WarTag  string        `bson:"war_tag"`
	EndTime any           `bson:"endTime"`
	Data    clanWarData   `bson:"data"`
}

type clanWarData struct {
	Tag                  string     `bson:"tag"`
	WarTag               string     `bson:"warTag"`
	WarTagSnake          string     `bson:"war_tag"`
	Type                 string     `bson:"type"`
	Clan                 warClanDoc `bson:"clan"`
	Opponent             warClanDoc `bson:"opponent"`
	PreparationStartTime any        `bson:"preparationStartTime"`
	StartTime            any        `bson:"startTime"`
	EndTime              any        `bson:"endTime"`
	State                string     `bson:"state"`
	BattleModifier       string     `bson:"battleModifier"`
	TeamSize             any        `bson:"teamSize"`
	AttacksPerMember     any        `bson:"attacksPerMember"`
}

type warClanDoc struct {
	Tag                   string         `bson:"tag"`
	Name                  string         `bson:"name"`
	BadgeURLs             badgeURLsDoc   `bson:"badgeUrls"`
	ClanLevel             any            `bson:"clanLevel"`
	Attacks               any            `bson:"attacks"`
	Stars                 any            `bson:"stars"`
	DestructionPercentage any            `bson:"destructionPercentage"`
	Members               []warMemberDoc `bson:"members"`
}

type badgeURLsDoc struct {
	Small  string `bson:"small"`
	Medium string `bson:"medium"`
	Large  string `bson:"large"`
}

type warMemberDoc struct {
	Tag           string         `bson:"tag"`
	Name          string         `bson:"name"`
	TownhallLevel any            `bson:"townhallLevel"`
	MapPosition   any            `bson:"mapPosition"`
	Attacks       []warAttackDoc `bson:"attacks"`
}

type warAttackDoc struct {
	DefenderTag           string `bson:"defenderTag"`
	Stars                 any    `bson:"stars"`
	DestructionPercentage any    `bson:"destructionPercentage"`
	Duration              any    `bson:"duration"`
	Order                 any    `bson:"order"`
}

func decodeClanWarDoc(raw bson.Raw) (clanWarDoc, error) {
	var doc clanWarDoc
	err := bson.Unmarshal(raw, &doc)
	return doc, err
}

func clanWarProjection() bson.M {
	return bson.M{
		"data.clan": 1, "data.opponent": 1, "data.preparationStartTime": 1, "data.startTime": 1,
		"data.endTime": 1, "data.state": 1, "data.battleModifier": 1, "data.teamSize": 1,
		"data.attacksPerMember": 1, "data.tag": 1, "data.warTag": 1, "data.war_tag": 1,
		"data.type": 1, "type": 1, "war_tag": 1, "endTime": 1,
	}
}

func streamClanWarDocs(ctx context.Context, cfg migrateutil.Config, cp *migrateutil.Checkpoint, cpKey string, collection *mongo.Collection, baseFilter bson.D, projection any, handle func(clanWarDoc) (bool, error), flush func(string) error) (int64, error) {
	filter := append(bson.D(nil), baseFilter...)
	if raw := cp.Get(cpKey); raw != "" {
		id, err := bson.ObjectIDFromHex(raw)
		if err != nil {
			return 0, fmt.Errorf("bad checkpoint %s=%q: %w", cpKey, raw, err)
		}
		filter = bson.D{{Key: "$and", Value: bson.A{
			filter,
			bson.D{{Key: "_id", Value: bson.D{{Key: "$gt", Value: id}}}},
		}}}
	}
	opts := options.Find().SetSort(bson.D{{Key: "_id", Value: 1}}).SetBatchSize(int32(minInt(cfg.BatchSize, 10_000))).SetProjection(projection)
	cursor, err := collection.Find(ctx, filter, opts)
	if err != nil {
		return 0, err
	}
	defer cursor.Close(ctx)
	progress := migrateutil.NewProgress(ctx, cfg, collection, cpKey, filter)
	var seen int64
	defer func() { progress.Done(seen) }()
	var checkpoint string
	var malformed int64
	for cursor.Next(ctx) {
		seen++
		raw := cursor.Current
		docID, hasObjectID := raw.Lookup("_id").ObjectIDOK()
		if hasObjectID {
			checkpoint = docID.Hex()
		}
		doc, decodeErr := decodeClanWarDoc(raw)
		ready := false
		if decodeErr != nil {
			malformed++
			if malformed <= 20 || malformed%1000 == 0 {
				id := "unknown"
				if hasObjectID {
					id = docID.Hex()
				}
				fmt.Fprintf(os.Stderr, "clan_wars: skipping malformed Mongo document _id=%s error=%v\n", id, decodeErr)
			}
		} else {
			var err error
			ready, err = handle(doc)
			if err != nil {
				return seen, err
			}
		}
		if ready {
			if err := flush(checkpoint); err != nil {
				return seen, err
			}
			checkpoint = ""
		}
		progress.Tick(seen)
		if cfg.LimitDocs > 0 && seen >= cfg.LimitDocs {
			break
		}
	}
	if err := cursor.Err(); err != nil {
		return seen, err
	}
	if checkpoint != "" {
		if err := flush(checkpoint); err != nil {
			return seen, err
		}
	}
	if malformed > 0 {
		fmt.Fprintf(os.Stderr, "clan_wars: skipped_malformed_docs=%d\n", malformed)
	}
	return seen, nil
}

func isFinishedWar(value string) bool {
	value = strings.ToLower(strings.TrimSpace(value))
	return value == "warended" || value == "ended"
}

func firstWar(values ...any) any {
	for _, value := range values {
		if value != nil {
			return value
		}
	}
	return nil
}

func firstNonEmptyString(values ...string) string {
	for _, value := range values {
		if value = strings.TrimSpace(value); value != "" {
			return value
		}
	}
	return ""
}

func warFloat(value any) float64 {
	out, _ := strconv.ParseFloat(migrateutil.String(value), 64)
	return out
}

func nullString(value string) any {
	if strings.TrimSpace(value) == "" {
		return nil
	}
	return value
}

func minInt(left, right int) int {
	if left < right {
		return left
	}
	return right
}

func envInt(env map[string]string, key string, fallback int) int {
	value := strings.TrimSpace(env[key])
	if value == "" {
		return fallback
	}
	parsed, err := strconv.Atoi(value)
	if err != nil {
		return fallback
	}
	return parsed
}

func envBool(env map[string]string, key string) bool {
	value, _ := strconv.ParseBool(strings.TrimSpace(env[key]))
	return value
}
