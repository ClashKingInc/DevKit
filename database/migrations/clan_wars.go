//go:build ignore

package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/ClashKingInc/DevKit/database/migrations/migrateutil"
	"github.com/ClashKingInc/DevKit/database/wararchive"
	"github.com/ClashKingInc/DevKit/database/warhistory"
	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/credentials"
	"github.com/aws/aws-sdk-go-v2/service/s3"
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
	defaultWarArchiveDecodeWorkers = 4
	defaultWarHistoryWindowWars    = 5_000_000
	defaultWarHistoryShards        = 256
	defaultWarHistoryReadyWindows  = 2
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
	endTimeRange, err := clanWarEndTimeRangeFromEnv(cfg.Env)
	if err != nil {
		return err
	}
	if idRange.configured() && endTimeRange.configured() {
		return errors.New("Mongo _id and end-time ranges cannot be combined")
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
	if !envBool(cfg.Env, "WAR_ARCHIVE_SKIP_STARTUP_CLEANUP") {
		if err := cleanupBuildingMigrationPacks(ctx, pool, store); err != nil {
			return err
		}
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

	chronological := clanTag == "" && cwlClanTag == "" && !idRange.configured()
	checkpointKey := clanWarCheckpointKey(clanTag)
	filter := clanWarFilterWithIDRange(clanTag, idRange)
	if chronological {
		checkpointKey = endTimeRange.checkpointKey("clan_war_r2_end_time")
		filter = applyClanWarEndTimeRange(clanWarFilter(""), endTimeRange)
	}
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
	decodeWorkers := envInt(cfg.Env, "WAR_ARCHIVE_DECODE_WORKERS", defaultWarArchiveDecodeWorkers)
	sqlBatchWars := envInt(cfg.Env, "WAR_ARCHIVE_SQL_BATCH_WARS", 100_000)
	sqlBatchWait := time.Duration(envInt(cfg.Env, "WAR_ARCHIVE_SQL_BATCH_MAX_WAIT_SECONDS", 30)) * time.Second
	deferPlayerHistory := envBool(cfg.Env, "WAR_ARCHIVE_DEFER_PLAYER_HISTORY")
	if packWorkers <= 0 || uploadWorkers <= 0 || sqlWorkers <= 0 || decodeWorkers <= 0 {
		return errors.New("WAR_ARCHIVE_PACK_WORKERS, WAR_ARCHIVE_UPLOAD_WORKERS, WAR_ARCHIVE_SQL_WORKERS, and WAR_ARCHIVE_DECODE_WORKERS must be positive")
	}
	if sqlBatchWars <= 0 || sqlBatchWait <= 0 {
		return errors.New("WAR_ARCHIVE_SQL_BATCH_WARS and WAR_ARCHIVE_SQL_BATCH_MAX_WAIT_SECONDS must be positive")
	}
	manageIndexes := clanTag == "" && cwlClanTag == "" && !envBool(cfg.Env, "CLAN_WARS_SKIP_INDEX_MANAGEMENT")
	if manageIndexes {
		if err := dropClanWarSecondaryIndexes(ctx, pool); err != nil {
			return err
		}
	}
	var historyWriter *warhistory.Writer
	if deferPlayerHistory {
		historyRoot := strings.TrimSpace(cfg.Env["WAR_ARCHIVE_HISTORY_SHARD_DIR"])
		if historyRoot == "" {
			return errors.New("WAR_ARCHIVE_HISTORY_SHARD_DIR is required when WAR_ARCHIVE_DEFER_PLAYER_HISTORY=true")
		}
		historyRunID := firstNonEmptyString(cfg.Env["WAR_ARCHIVE_HISTORY_RUN_ID"], checkpointKey)
		historyWriter, err = warhistory.NewWriter(
			historyRoot,
			historyRunID,
			envInt(cfg.Env, "WAR_ARCHIVE_HISTORY_SHARDS", defaultWarHistoryShards),
			envInt(cfg.Env, "WAR_ARCHIVE_HISTORY_WINDOW_WARS", defaultWarHistoryWindowWars),
			envInt(cfg.Env, "WAR_ARCHIVE_HISTORY_MAX_READY_WINDOWS", defaultWarHistoryReadyWindows),
		)
		if err != nil {
			return fmt.Errorf("open player-history window writer: %w", err)
		}
		fmt.Printf("clan_wars: player_history_root=%s run_id=%s shards=%d window_wars=%d max_ready_windows=%d\n",
			historyRoot, warhistory.SafeRunID(historyRunID),
			envInt(cfg.Env, "WAR_ARCHIVE_HISTORY_SHARDS", defaultWarHistoryShards),
			envInt(cfg.Env, "WAR_ARCHIVE_HISTORY_WINDOW_WARS", defaultWarHistoryWindowWars),
			envInt(cfg.Env, "WAR_ARCHIVE_HISTORY_MAX_READY_WINDOWS", defaultWarHistoryReadyWindows))
		defer historyWriter.Close()
	}

	finalizer := newArchiveSQLBatcher(ctx, pool, sqlWorkers, sqlBatchWars, sqlBatchWait, deferPlayerHistory)
	pipeline := newArchivePackPipeline(ctx, packWorkers, uploadWorkers, sqlWorkers, cp, checkpointKey,
		func(processCtx context.Context, batch []archiveWar, batchCheckpointKey, batchCheckpoint string, sqlGate, uploadGate chan struct{}) error {
			return flushArchivePack(processCtx, pool, store, dictionary, finalizer, historyWriter, batchCheckpointKey, batchCheckpoint, batch, sqlGate, uploadGate)
		})
	defer func() {
		pipeline.Close()
		finalizer.Close()
	}()
	collection := mongoClient.Database("looper").Collection("clan_war")
	pending := make([]archiveWar, 0, packSize)
	flush := func(checkpoint string) error {
		batch := append([]archiveWar(nil), pending...)
		pending = pending[:0]
		return pipeline.Submit(batch, checkpoint)
	}

	fmt.Printf("clan_wars: pack_size=%d pack_workers=%d upload_workers=%d sql_workers=%d decode_workers=%d sql_batch_wars=%d sql_batch_wait=%s chronological=%t defer_player_history=%t\n", packSize, packWorkers, uploadWorkers, sqlWorkers, decodeWorkers, sqlBatchWars, sqlBatchWait, chronological, deferPlayerHistory)
	var seen int64
	var streamErr error
	if chronological {
		var pendingEndTime string
		seen, streamErr = streamClanWarDocsChronological(ctx, cfg, cp, checkpointKey, collection, filter, clanWarProjection(), decodeWorkers, func(doc clanWarDoc, sourceEndTime string) error {
			war, ok := canonicalArchiveWar(doc)
			if !ok {
				return nil
			}
			if len(pending) >= packSize && pendingEndTime != "" && sourceEndTime != pendingEndTime {
				if err := flush(pendingEndTime); err != nil {
					return err
				}
			}
			pending = append(pending, war)
			pendingEndTime = sourceEndTime
			return nil
		})
		if streamErr == nil && len(pending) > 0 {
			streamErr = flush(pendingEndTime)
		}
	} else {
		seen, streamErr = streamClanWarDocs(ctx, cfg, cp, checkpointKey, collection, filter, clanWarProjection(), func(doc clanWarDoc) (bool, error) {
			war, ok := canonicalArchiveWar(doc)
			if !ok {
				return false, nil
			}
			pending = append(pending, war)
			return len(pending) >= packSize, nil
		}, flush)
	}
	pipelineErr := pipeline.Close()
	finalizerErr := finalizer.Close()
	if streamErr != nil {
		return streamErr
	}
	if pipelineErr != nil {
		return pipelineErr
	}
	if finalizerErr != nil {
		return finalizerErr
	}
	if historyWriter != nil {
		if err := historyWriter.Close(); err != nil {
			return fmt.Errorf("seal final player-history window: %w", err)
		}
	}
	if manageIndexes {
		if err := recreateClanWarSecondaryIndexes(ctx, pool); err != nil {
			return err
		}
	}
	fmt.Printf("clan_wars: scanned_docs=%d archive_pack_size=%d pack_workers=%d\n", seen, packSize, packWorkers)
	return nil
}

type archivePackProcessor func(context.Context, []archiveWar, string, string, chan struct{}, chan struct{}) error

type archivePackFuture struct {
	checkpoint string
	sourceIDs  []string
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
	inFlight   map[string]struct{}
	futures    []archivePackFuture
	closeOnce  sync.Once
	closeErr   error
}

func newArchivePackPipeline(ctx context.Context, maxRunning, uploadWorkers, sqlWorkers int, cp *migrateutil.Checkpoint, cpKey string, process archivePackProcessor) *archivePackPipeline {
	pipelineCtx, cancel := context.WithCancel(ctx)
	return &archivePackPipeline{
		ctx: pipelineCtx, cancel: cancel, maxRunning: maxRunning,
		sqlGate: make(chan struct{}, sqlWorkers), uploadGate: make(chan struct{}, uploadWorkers),
		cp: cp, cpKey: cpKey, process: process, inFlight: make(map[string]struct{}, maxRunning*defaultWarArchivePackSize),
	}
}

func (p *archivePackPipeline) Submit(input []archiveWar, checkpoint string) error {
	if len(p.futures) >= p.maxRunning {
		if err := p.awaitOldest(true); err != nil {
			return err
		}
	}
	batch := make([]archiveWar, 0, len(input))
	ids := make([]string, 0, len(input))
	for _, value := range input {
		if _, exists := p.inFlight[value.SourceID]; exists {
			continue
		}
		p.inFlight[value.SourceID] = struct{}{}
		batch = append(batch, value)
		ids = append(ids, value.SourceID)
	}
	done := make(chan error, 1)
	p.futures = append(p.futures, archivePackFuture{checkpoint: checkpoint, sourceIDs: ids, done: done})
	go func() {
		if len(batch) == 0 {
			done <- nil
			return
		}
		done <- p.process(p.ctx, batch, p.cpKey, checkpoint, p.sqlGate, p.uploadGate)
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
	for _, id := range future.sourceIDs {
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
	ID       int32
	SourceID string
	WarType  string
	War      wararchive.War
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
	attacksPerMember := doc.Data.AttacksPerMember
	if attacksPerMember <= 0 {
		attacksPerMember = 1
	}
	clan, opponent := doc.Data.Clan, doc.Data.Opponent
	if clan.Tag > opponent.Tag {
		clan, opponent = opponent, clan
	}
	war := wararchive.War{
		WarTag: warTag, State: strings.ToLower(doc.Data.State),
		TeamSize: doc.Data.TeamSize, AttacksPerMember: attacksPerMember,
		PreparationStartTime: prepAt.UTC(), StartTime: startAt.UTC(), EndTime: endAt.UTC(),
		BattleModifier: wararchive.NormalizeBattleModifier(doc.Data.BattleModifier),
		Clan:           canonicalArchiveClan(clan), Opponent: canonicalArchiveClan(opponent),
	}
	return archiveWar{SourceID: doc.ID.Hex(), WarType: warType, War: war}, true
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
				DefenderTag: attack.DefenderTag, Stars: attack.Stars,
				DestructionPercentage: attack.DestructionPercentage,
				Duration:              attack.Duration, Order: attack.Order,
			})
		}
		members = append(members, wararchive.Member{
			Tag: member.Tag, Name: member.Name, TownhallLevel: member.TownhallLevel,
			MapPosition: member.MapPosition, Attacks: attacks,
		})
	}
	return wararchive.Clan{
		Tag: clan.Tag, Name: clan.Name,
		BadgeToken: migrateutil.BadgeToken(clan.BadgeURLs.Large, clan.BadgeURLs.Medium, clan.BadgeURLs.Small),
		ClanLevel:  clan.ClanLevel, Attacks: clan.Attacks, Stars: clan.Stars,
		DestructionPercentage: clan.DestructionPercentage, Members: members,
	}
}

func flushArchivePack(ctx context.Context, pool *pgxpool.Pool, store *warArchiveStore, dictionary []byte, finalizer *archiveSQLBatcher, historyWriter *warhistory.Writer, checkpointKey, checkpoint string, input []archiveWar, sqlGate, uploadGate chan struct{}) (returnErr error) {
	started := time.Now()
	if err := acquireArchiveGate(ctx, sqlGate); err != nil {
		return err
	}
	completedPackID, alreadyComplete, err := completedMigrationPack(ctx, pool, checkpointKey, checkpoint)
	if err != nil {
		releaseArchiveGate(sqlGate)
		return err
	}
	if alreadyComplete {
		wars := append([]archiveWar(nil), input...)
		if historyWriter != nil {
			if err := assignCompletedWarIDs(ctx, pool, completedPackID, wars); err != nil {
				releaseArchiveGate(sqlGate)
				return err
			}
			if err := historyWriter.Append(ctx, playerHistoryMappings(wars)); err != nil {
				releaseArchiveGate(sqlGate)
				return err
			}
		}
		releaseArchiveGate(sqlGate)
		fmt.Printf("clan_wars: reused completed checkpoint key=%s cursor=%s pack=%d\n", checkpointKey, checkpoint, completedPackID)
		return nil
	}
	wars := append([]archiveWar(nil), input...)
	if len(wars) == 0 {
		releaseArchiveGate(sqlGate)
		return nil
	}
	if err := assignWarIDs(ctx, pool, wars); err != nil {
		releaseArchiveGate(sqlGate)
		return err
	}
	packID, err := reserveMigrationPack(ctx, pool, checkpointKey, checkpoint)
	releaseArchiveGate(sqlGate)
	if err != nil {
		return err
	}
	objectKey := wararchive.ObjectKey(uint64(packID))
	completed := false
	defer func() {
		if completed {
			return
		}
		cleanupCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 2*time.Minute)
		defer cancel()
		if err := cleanupMigrationPack(cleanupCtx, pool, store, packID, objectKey); err != nil {
			fmt.Fprintf(os.Stderr, "clan_wars: cleanup warning pack=%d error=%v\n", packID, err)
		}
	}()
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
	finalizeStarted := time.Now()
	prepared := preparedArchivePack{
		packID: packID, wars: wars, locators: append([]wararchive.Locator(nil), builder.Locators()...),
		stats: stats, firstEnd: firstEnd, lastEnd: lastEnd,
	}
	if err := finalizer.Submit(ctx, prepared); err != nil {
		return err
	}
	completed = true
	if historyWriter != nil {
		if err := historyWriter.Append(ctx, playerHistoryMappings(wars)); err != nil {
			return fmt.Errorf("append player-history mappings for pack %d: %w", packID, err)
		}
	}
	finalizeDuration := time.Since(finalizeStarted)
	fmt.Printf("clan_wars: uploaded pack=%d wars=%d attacks=%d raw_bytes=%d compressed_bytes=%d build=%s upload=%s prime=%s finalize=%s total=%s\n",
		packID, len(wars), stats.TotalAttacks(), sumRawBytes(builder.Locators()), len(object), buildDuration, uploadDuration, primeDuration, finalizeDuration, time.Since(started))
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

func assignWarIDs(ctx context.Context, pool *pgxpool.Pool, wars []archiveWar) error {
	rows, err := pool.Query(ctx, `SELECT nextval('public.war_id_seq')::integer FROM generate_series(1, $1)`, len(wars))
	if err != nil {
		return err
	}
	defer rows.Close()
	index := 0
	for rows.Next() {
		if index >= len(wars) {
			return errors.New("war ID sequence returned too many values")
		}
		if err := rows.Scan(&wars[index].ID); err != nil {
			return err
		}
		wars[index].War.ID = wars[index].ID
		index++
	}
	if err := rows.Err(); err != nil {
		return err
	}
	if index != len(wars) {
		return fmt.Errorf("war ID sequence returned %d values, want %d", index, len(wars))
	}
	return nil
}

func completedMigrationPack(ctx context.Context, pool *pgxpool.Pool, checkpointKey, checkpoint string) (int64, bool, error) {
	var packID int64
	err := pool.QueryRow(ctx, `
		SELECT pack_id
		FROM war_archive_packs
		WHERE source = 'migration' AND status = 'uploaded'
		  AND checkpoint_key = $1 AND source_checkpoint = $2
	`, checkpointKey, checkpoint).Scan(&packID)
	if errors.Is(err, pgx.ErrNoRows) {
		return 0, false, nil
	}
	return packID, err == nil, err
}

func assignCompletedWarIDs(ctx context.Context, pool *pgxpool.Pool, packID int64, wars []archiveWar) error {
	rows, err := pool.Query(ctx, `
		SELECT war_id, clan_tag, opponent_tag, prep_time
		FROM wars
		WHERE archive_pack_id = $1
	`, packID)
	if err != nil {
		return err
	}
	defer rows.Close()
	ids := make(map[string]int32, len(wars))
	for rows.Next() {
		var warID int32
		var clanTag, opponentTag string
		var preparationTime time.Time
		if err := rows.Scan(&warID, &clanTag, &opponentTag, &preparationTime); err != nil {
			return err
		}
		ids[completedWarIdentity(clanTag, opponentTag, preparationTime)] = warID
	}
	if err := rows.Err(); err != nil {
		return err
	}
	for index := range wars {
		identity := completedWarIdentity(wars[index].War.Clan.Tag, wars[index].War.Opponent.Tag, wars[index].War.PreparationStartTime)
		warID, exists := ids[identity]
		if !exists {
			return fmt.Errorf("completed archive pack %d has no SQL war matching %s", packID, identity)
		}
		wars[index].ID = warID
		wars[index].War.ID = warID
	}
	return nil
}

func completedWarIdentity(clanTag, opponentTag string, preparationTime time.Time) string {
	if clanTag > opponentTag {
		clanTag, opponentTag = opponentTag, clanTag
	}
	return clanTag + "\x00" + opponentTag + "\x00" + preparationTime.UTC().Format(time.RFC3339Nano)
}

func reserveMigrationPack(ctx context.Context, pool *pgxpool.Pool, checkpointKey, checkpoint string) (int64, error) {
	var packID int64
	err := pool.QueryRow(ctx, `
		INSERT INTO war_archive_packs (source, status, checkpoint_key, source_checkpoint)
		VALUES ('migration', 'building', $1, $2)
		RETURNING pack_id
	`, checkpointKey, checkpoint).Scan(&packID)
	return packID, err
}

func cleanupBuildingMigrationPacks(ctx context.Context, pool *pgxpool.Pool, store *warArchiveStore) error {
	rows, err := pool.Query(ctx, `
		SELECT pack_id
		FROM war_archive_packs
		WHERE source = 'migration' AND status = 'building'
		ORDER BY pack_id
	`)
	if err != nil {
		return err
	}
	var packIDs []int64
	for rows.Next() {
		var packID int64
		if err := rows.Scan(&packID); err != nil {
			rows.Close()
			return err
		}
		packIDs = append(packIDs, packID)
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return err
	}
	rows.Close()
	for _, packID := range packIDs {
		if err := cleanupMigrationPack(ctx, pool, store, packID, wararchive.ObjectKey(uint64(packID))); err != nil {
			return err
		}
		fmt.Printf("clan_wars: removed incomplete pack=%d\n", packID)
	}
	return nil
}

func cleanupMigrationPack(ctx context.Context, pool *pgxpool.Pool, store *warArchiveStore, packID int64, objectKey string) error {
	if err := store.delete(ctx, objectKey); err != nil {
		return fmt.Errorf("delete incomplete archive object %s: %w", objectKey, err)
	}
	_, err := pool.Exec(ctx, `
		DELETE FROM war_archive_packs
		WHERE pack_id = $1 AND source = 'migration' AND status = 'building'
	`, packID)
	return err
}

type warStageRow struct {
	value   archiveWar
	locator wararchive.Locator
}

type preparedArchivePack struct {
	packID   int64
	wars     []archiveWar
	locators []wararchive.Locator
	stats    wararchive.PackStats
	firstEnd time.Time
	lastEnd  time.Time
}

type archiveFinalizeRequest struct {
	pack preparedArchivePack
	done chan error
}

type archiveSQLBatcher struct {
	ctx                context.Context
	pool               *pgxpool.Pool
	workers            int
	maxWars            int
	maxDelay           time.Duration
	deferPlayerHistory bool
	input              chan archiveFinalizeRequest
	done               chan struct{}
	closeOnce          sync.Once
	mu                 sync.Mutex
	err                error
}

func newArchiveSQLBatcher(ctx context.Context, pool *pgxpool.Pool, workers, maxWars int, maxDelay time.Duration, deferPlayerHistory bool) *archiveSQLBatcher {
	batcher := &archiveSQLBatcher{
		ctx: ctx, pool: pool, workers: workers, maxWars: maxWars, maxDelay: maxDelay, deferPlayerHistory: deferPlayerHistory,
		input: make(chan archiveFinalizeRequest), done: make(chan struct{}),
	}
	go batcher.run()
	return batcher
}

func (b *archiveSQLBatcher) Submit(ctx context.Context, pack preparedArchivePack) error {
	request := archiveFinalizeRequest{pack: pack, done: make(chan error, 1)}
	select {
	case b.input <- request:
	case <-ctx.Done():
		return ctx.Err()
	case <-b.done:
		return b.result()
	}
	select {
	case err := <-request.done:
		return err
	case <-ctx.Done():
		return ctx.Err()
	}
}

func (b *archiveSQLBatcher) Close() error {
	b.closeOnce.Do(func() { close(b.input) })
	<-b.done
	return b.result()
}

func (b *archiveSQLBatcher) result() error {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.err
}

func (b *archiveSQLBatcher) setError(err error) {
	b.mu.Lock()
	if b.err == nil {
		b.err = err
	}
	b.mu.Unlock()
}

func (b *archiveSQLBatcher) run() {
	defer close(b.done)
	type finalizeBatch struct {
		requests []archiveFinalizeRequest
		warCount int
	}
	jobs := make(chan finalizeBatch)
	var workers sync.WaitGroup
	for range b.workers {
		workers.Add(1)
		go func() {
			defer workers.Done()
			for job := range jobs {
				packs := make([]preparedArchivePack, len(job.requests))
				for index := range job.requests {
					packs[index] = job.requests[index].pack
				}
				started := time.Now()
				err := b.result()
				if err == nil {
					err = finalizeArchivePacks(b.ctx, b.pool, packs, b.deferPlayerHistory)
					if err != nil {
						b.setError(err)
					}
				}
				fmt.Printf("clan_wars: finalized sql_batch packs=%d wars=%d duration=%s error=%v\n", len(packs), job.warCount, time.Since(started), err)
				for _, request := range job.requests {
					request.done <- err
				}
			}
		}()
	}
	timer := time.NewTimer(b.maxDelay)
	if !timer.Stop() {
		<-timer.C
	}
	var pending []archiveFinalizeRequest
	warCount := 0
	flush := func() {
		if len(pending) == 0 {
			return
		}
		requests := append([]archiveFinalizeRequest(nil), pending...)
		jobs <- finalizeBatch{requests: requests, warCount: warCount}
		pending = pending[:0]
		warCount = 0
	}
	for {
		select {
		case request, ok := <-b.input:
			if !ok {
				flush()
				close(jobs)
				workers.Wait()
				return
			}
			if err := b.result(); err != nil {
				request.done <- err
				continue
			}
			pending = append(pending, request)
			warCount += len(request.pack.wars)
			if len(pending) == 1 {
				timer.Reset(b.maxDelay)
			}
			if warCount >= b.maxWars {
				if !timer.Stop() {
					select {
					case <-timer.C:
					default:
					}
				}
				flush()
			}
		case <-timer.C:
			flush()
		case <-b.ctx.Done():
			b.setError(b.ctx.Err())
			flush()
			close(jobs)
			workers.Wait()
			return
		}
	}
}

func finalizeArchivePacks(ctx context.Context, pool *pgxpool.Pool, packs []preparedArchivePack, deferPlayerHistory bool) error {
	if len(packs) == 0 {
		return nil
	}
	tx, err := pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, `SET LOCAL work_mem = '512MB'`); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `CREATE TEMP TABLE war_archive_stage (LIKE wars INCLUDING DEFAULTS) ON COMMIT DROP`); err != nil {
		return err
	}
	var rows []warStageRow
	var allWars []archiveWar
	for _, pack := range packs {
		if len(pack.wars) != len(pack.locators) {
			return fmt.Errorf("archive pack %d war and locator counts differ", pack.packID)
		}
		allWars = append(allWars, pack.wars...)
		for index := range pack.wars {
			rows = append(rows, warStageRow{value: pack.wars[index], locator: pack.locators[index]})
		}
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
			war.Clan.DestructionPercentage, war.Opponent.DestructionPercentage, int64(row.locator.PackID), row.locator.Offset,
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
	if !deferPlayerHistory {
		if err := upsertPlayerWarHistory(ctx, tx, allWars); err != nil {
			return err
		}
	}
	for _, pack := range packs {
		statsJSON, err := json.Marshal(pack.stats)
		if err != nil {
			return err
		}
		result, err := tx.Exec(ctx, `
			UPDATE war_archive_packs
			SET status = 'uploaded', war_count = $2, attack_count = $3, raw_bytes = $4,
				compressed_bytes = $5, first_end_time = $6, last_end_time = $7,
				stats = $8, uploaded_at = now()
			WHERE pack_id = $1 AND source = 'migration' AND status = 'building'
		`, pack.packID, len(pack.wars), pack.stats.TotalAttacks(), sumRawBytes(pack.locators), sumCompressedBytes(pack.locators), pack.firstEnd, pack.lastEnd, statsJSON)
		if err != nil {
			return err
		}
		if result.RowsAffected() != 1 {
			return fmt.Errorf("finalized %d rows for migration pack %d, expected 1", result.RowsAffected(), pack.packID)
		}
	}
	return tx.Commit(ctx)
}

func upsertPlayerWarHistory(ctx context.Context, tx pgx.Tx, wars []archiveWar) error {
	rows := aggregatePlayerWarHistory(wars)
	if len(rows) == 0 {
		return nil
	}
	if _, err := tx.Exec(ctx, `CREATE TEMP TABLE player_war_history_stage (player_tag text, war_ids integer[]) ON COMMIT DROP`); err != nil {
		return err
	}
	_, err := tx.CopyFrom(ctx, pgx.Identifier{"player_war_history_stage"}, []string{"player_tag", "war_ids"}, pgx.CopyFromSlice(len(rows), func(index int) ([]any, error) {
		row := rows[index]
		return []any{row.playerTag, row.warIDs}, nil
	}))
	if err != nil {
		return err
	}
	_, err = tx.Exec(ctx, `
		INSERT INTO player_war_history (player_tag, war_ids)
		SELECT player_tag, war_ids
		FROM player_war_history_stage
		ORDER BY player_tag
		ON CONFLICT (player_tag) DO UPDATE SET
			war_ids = player_war_history.war_ids || EXCLUDED.war_ids
	`)
	return err
}

type playerWarHistoryRow struct {
	playerTag string
	warIDs    []int32
}

func playerHistoryMappings(wars []archiveWar) []warhistory.WarMappings {
	mappings := make([]warhistory.WarMappings, 0, len(wars))
	for _, war := range wars {
		playerTags := make([]string, 0, len(war.War.Clan.Members)+len(war.War.Opponent.Members))
		for _, members := range [][]wararchive.Member{war.War.Clan.Members, war.War.Opponent.Members} {
			for _, member := range members {
				if member.Tag == "" {
					continue
				}
				playerTags = append(playerTags, member.Tag)
			}
		}
		mappings = append(mappings, warhistory.WarMappings{WarID: war.ID, PlayerTags: playerTags})
	}
	return mappings
}

func aggregatePlayerWarHistory(wars []archiveWar) []playerWarHistoryRow {
	grouped := make(map[string][]int32)
	for _, war := range wars {
		seen := make(map[string]struct{}, len(war.War.Clan.Members)+len(war.War.Opponent.Members))
		for _, members := range [][]wararchive.Member{war.War.Clan.Members, war.War.Opponent.Members} {
			for _, member := range members {
				if member.Tag == "" {
					continue
				}
				if _, exists := seen[member.Tag]; exists {
					continue
				}
				seen[member.Tag] = struct{}{}
				grouped[member.Tag] = append(grouped[member.Tag], war.ID)
			}
		}
	}
	rows := make([]playerWarHistoryRow, 0, len(grouped))
	for playerTag, warIDs := range grouped {
		sort.Slice(warIDs, func(i, j int) bool { return warIDs[i] < warIDs[j] })
		rows = append(rows, playerWarHistoryRow{playerTag: playerTag, warIDs: warIDs})
	}
	sort.Slice(rows, func(i, j int) bool {
		return rows[i].playerTag < rows[j].playerTag
	})
	return rows
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

func (s *warArchiveStore) delete(ctx context.Context, key string) error {
	_, err := s.client.DeleteObject(ctx, &s3.DeleteObjectInput{
		Bucket: aws.String(s.bucket), Key: aws.String(key),
	})
	return err
}

func (s *warArchiveStore) prime(ctx context.Context, key string) error {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, s.publicOrigin+"/"+key, nil)
	if err != nil {
		return err
	}
	request.Header.Set("Range", "bytes=0-0")
	response, err := s.httpClient.Do(request)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusPartialContent {
		return fmt.Errorf("cache prime returned HTTP %d", response.StatusCode)
	}
	bytesRead, err := io.Copy(io.Discard, response.Body)
	if err != nil {
		return fmt.Errorf("read cache-prime byte: %w", err)
	}
	if bytesRead != 1 {
		return fmt.Errorf("cache prime returned %d bytes, want 1", bytesRead)
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

type clanWarEndTimeRange struct {
	from   string
	before string
}

func clanWarEndTimeRangeFromEnv(env map[string]string) (clanWarEndTimeRange, error) {
	parse := func(key string) (string, error) {
		raw := strings.TrimSpace(env[key])
		if raw == "" {
			return "", nil
		}
		value, ok := migrateutil.Time(raw)
		if !ok {
			return "", fmt.Errorf("invalid %s=%q", key, raw)
		}
		return value.UTC().Format("20060102T150405.000Z"), nil
	}
	from, err := parse("CLAN_WARS_END_TIME_FROM")
	if err != nil {
		return clanWarEndTimeRange{}, err
	}
	before, err := parse("CLAN_WARS_END_TIME_BEFORE")
	if err != nil {
		return clanWarEndTimeRange{}, err
	}
	if from != "" && before != "" && from >= before {
		return clanWarEndTimeRange{}, errors.New("CLAN_WARS_END_TIME_BEFORE must be later than CLAN_WARS_END_TIME_FROM")
	}
	return clanWarEndTimeRange{from: from, before: before}, nil
}

func (r clanWarEndTimeRange) configured() bool { return r.from != "" || r.before != "" }

func (r clanWarEndTimeRange) checkpointKey(base string) string {
	from := "start"
	if r.from != "" {
		from = strings.TrimSuffix(strings.TrimSuffix(r.from, ".000Z"), "Z")
	}
	before := "end"
	if r.before != "" {
		before = strings.TrimSuffix(strings.TrimSuffix(r.before, ".000Z"), "Z")
	}
	return base + "_from_" + from + "_before_" + before
}

func applyClanWarEndTimeRange(base bson.D, value clanWarEndTimeRange) bson.D {
	conditions := bson.D{}
	if value.from != "" {
		conditions = append(conditions, bson.E{Key: "$gte", Value: value.from})
	}
	if value.before != "" {
		conditions = append(conditions, bson.E{Key: "$lt", Value: value.before})
	}
	if len(conditions) == 0 {
		conditions = append(conditions, bson.E{Key: "$type", Value: "string"})
	}
	return append(base, bson.E{Key: "data.endTime", Value: conditions})
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
	TeamSize             int        `bson:"teamSize"`
	AttacksPerMember     int        `bson:"attacksPerMember"`
}

type warClanDoc struct {
	Tag                   string         `bson:"tag"`
	Name                  string         `bson:"name"`
	BadgeURLs             badgeURLsDoc   `bson:"badgeUrls"`
	ClanLevel             int            `bson:"clanLevel"`
	Attacks               int            `bson:"attacks"`
	Stars                 int            `bson:"stars"`
	DestructionPercentage float64        `bson:"destructionPercentage"`
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
	TownhallLevel int            `bson:"townhallLevel"`
	MapPosition   int            `bson:"mapPosition"`
	Attacks       []warAttackDoc `bson:"attacks"`
}

type warAttackDoc struct {
	DefenderTag           string `bson:"defenderTag"`
	Stars                 int    `bson:"stars"`
	DestructionPercentage int    `bson:"destructionPercentage"`
	Duration              int    `bson:"duration"`
	Order                 int    `bson:"order"`
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

type chronologicalRawWar struct {
	raw     bson.Raw
	endTime string
	id      string
}

type chronologicalDecodedWar struct {
	doc clanWarDoc
	err error
}

func streamClanWarDocsChronological(ctx context.Context, cfg migrateutil.Config, cp *migrateutil.Checkpoint, cpKey string, collection *mongo.Collection, baseFilter bson.D, projection any, decodeWorkers int, handle func(clanWarDoc, string) error) (int64, error) {
	filter := append(bson.D(nil), baseFilter...)
	if checkpoint := strings.TrimSpace(cp.Get(cpKey)); checkpoint != "" {
		filter = bson.D{{Key: "$and", Value: bson.A{
			filter,
			bson.D{{Key: "data.endTime", Value: bson.D{{Key: "$gt", Value: checkpoint}}}},
		}}}
	}
	opts := options.Find().
		SetSort(bson.D{{Key: "data.endTime", Value: 1}}).
		SetHint("data.endTime_-1").
		SetBatchSize(int32(minInt(cfg.BatchSize, 10_000))).
		SetProjection(projection)
	cursor, err := collection.Find(ctx, filter, opts)
	if err != nil {
		return 0, err
	}
	defer cursor.Close(ctx)
	progress := migrateutil.NewProgress(ctx, cfg, collection, cpKey, filter)
	var seen int64
	defer func() { progress.Done(seen) }()
	var malformed int64
	var lastEndTime string
	decodeBatchSize := max(256, decodeWorkers*256)
	batch := make([]chronologicalRawWar, 0, decodeBatchSize)
	processBatch := func() error {
		decoded := make([]chronologicalDecodedWar, len(batch))
		jobs := make(chan int)
		var workers sync.WaitGroup
		for range min(decodeWorkers, len(batch)) {
			workers.Add(1)
			go func() {
				defer workers.Done()
				for index := range jobs {
					decoded[index].err = bson.Unmarshal(batch[index].raw, &decoded[index].doc)
				}
			}()
		}
		for index := range batch {
			jobs <- index
		}
		close(jobs)
		workers.Wait()
		for index, result := range decoded {
			seen++
			if result.err != nil {
				malformed++
				if malformed <= 20 || malformed%1000 == 0 {
					fmt.Fprintf(os.Stderr, "clan_wars: skipping malformed Mongo document _id=%s error=%v\n", batch[index].id, result.err)
				}
			} else if err := handle(result.doc, batch[index].endTime); err != nil {
				return err
			}
			progress.Tick(seen)
		}
		batch = batch[:0]
		return nil
	}
	stoppedAtLimit := false
	for cursor.Next(ctx) {
		raw := cursor.Current
		sourceEndTime, ok := raw.Lookup("data", "endTime").StringValueOK()
		if !ok || strings.TrimSpace(sourceEndTime) == "" {
			malformed++
			if malformed <= 20 || malformed%1000 == 0 {
				id := "unknown"
				if docID, hasObjectID := raw.Lookup("_id").ObjectIDOK(); hasObjectID {
					id = docID.Hex()
				}
				fmt.Fprintf(os.Stderr, "clan_wars: skipping Mongo document without indexed data.endTime _id=%s\n", id)
			}
			continue
		}
		if cfg.LimitDocs > 0 && seen+int64(len(batch)) >= cfg.LimitDocs && lastEndTime != "" && sourceEndTime != lastEndTime {
			stoppedAtLimit = true
			break
		}
		lastEndTime = sourceEndTime
		id := "unknown"
		if docID, hasObjectID := raw.Lookup("_id").ObjectIDOK(); hasObjectID {
			id = docID.Hex()
		}
		batch = append(batch, chronologicalRawWar{raw: bytes.Clone(raw), endTime: sourceEndTime, id: id})
		if len(batch) >= decodeBatchSize {
			if err := processBatch(); err != nil {
				return seen, err
			}
		}
	}
	if err := processBatch(); err != nil {
		return seen, err
	}
	if !stoppedAtLimit {
		if err := cursor.Err(); err != nil {
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
