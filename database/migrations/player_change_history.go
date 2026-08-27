//go:build ignore

package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
	"unicode"

	"github.com/ClashKingInc/DevKit/database/migrations/migrateutil"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"go.mongodb.org/mongo-driver/v2/bson"
	"go.mongodb.org/mongo-driver/v2/mongo"
	"go.mongodb.org/mongo-driver/v2/mongo/options"
)

const (
	playerHistoryTable                  = "player_change_history"
	playerHistoryMigrationKey           = "legacy_new_looper_player_history_v1"
	defaultPlayerHistoryWindows         = 40
	defaultSnapshotEqualThreshold       = 5
	playerHistorySourceDatabase         = "new_looper"
	playerHistorySourceCollection       = "player_history"
	changeTypeTroopLevel          int16 = 1
	changeTypeSuperTroopBoost     int16 = 2
	changeTypeHeroLevel           int16 = 3
	changeTypeSpellLevel          int16 = 4
	changeTypePetLevel            int16 = 5
	changeTypeEquipmentLevel      int16 = 6
	changeTypeTownHallLevel       int16 = 7
	changeTypeBestTrophies        int16 = 8
	changeTypeBestBuilder         int16 = 9
	changeTypeExpLevel            int16 = 10
	changeTypeWarPreference       int16 = 11
	changeTypeName                int16 = 12
)

type playerHistoryRow struct {
	eventTime     time.Time
	playerTag     string
	changeType    int16
	itemID        any
	townHallLevel any
	previous      string
	current       string
}

type staticItem struct {
	changeType int16
	itemID     int16
	superTroop bool
	village    string
}

type staticCatalog map[string]staticItem

type staticDataFile struct {
	Items []struct {
		ID         int64           `json:"_id"`
		Name       string          `json:"name"`
		Village    string          `json:"village"`
		SuperTroop json.RawMessage `json:"super_troop"`
	} `json:"items"`
}

type analyzedPlayerHistory struct {
	row        *playerHistoryRow
	reason     string
	legacyType string
	equalItem  bool
	superBoost bool
}

type playerHistoryGroup struct {
	key      string
	items    []analyzedPlayerHistory
	lastID   bson.ObjectID
	rawCount int64
}

type playerHistoryStats struct {
	scanned       int64
	written       int64
	rejected      map[string]int64
	unmappedTypes map[string]int64
}

type playerHistoryState struct {
	signature    string
	sourceID     string
	sampleWindow int
	windowDocs   int64
	totalDocs    int64
}

type playerHistoryRun struct {
	ctx                    context.Context
	cfg                    migrateutil.Config
	pool                   *pgxpool.Pool
	collection             *mongo.Collection
	catalog                staticCatalog
	state                  playerHistoryState
	stats                  playerHistoryStats
	rows                   [][]any
	sinceCheckpoint        int64
	lastCheckpointID       bson.ObjectID
	snapshotEqualThreshold int
}

type playerHistorySourceRange struct {
	index int
	from  bson.ObjectID
	to    bson.ObjectID
	limit int64
}

var excludedPlayerHistoryTypes = map[string]struct{}{
	"Games Champion": {}, "clanCapitalContributions": {}, "role": {}, "warStars": {}, "league": {},
}

func main() {
	migrateutil.Main("player_change_history", runPlayerChangeHistory)
}

func runPlayerChangeHistory(ctx context.Context, cfg migrateutil.Config) error {
	catalog, catalogDir, err := loadPlayerHistoryCatalog(cfg)
	if err != nil {
		return err
	}
	mongoClient, err := migrateutil.StatsClient(ctx, cfg)
	if err != nil {
		return err
	}
	defer mongoClient.Disconnect(ctx)
	pool, err := migrateutil.TimescalePool(ctx, cfg)
	if err != nil {
		return err
	}
	defer pool.Close()

	sampleDocs := playerHistoryEnvInt64(cfg.Env, "PLAYER_CHANGE_HISTORY_SAMPLE_DOCS", 0)
	sampleWindows := playerHistoryEnvInt(cfg.Env, "PLAYER_CHANGE_HISTORY_SAMPLE_WINDOWS", defaultPlayerHistoryWindows)
	if sampleDocs < 0 || sampleWindows <= 0 {
		return errors.New("PLAYER_CHANGE_HISTORY_SAMPLE_DOCS must be non-negative and PLAYER_CHANGE_HISTORY_SAMPLE_WINDOWS must be positive")
	}
	signature := "full"
	if sampleDocs > 0 {
		if sampleDocs < int64(sampleWindows) {
			return errors.New("PLAYER_CHANGE_HISTORY_SAMPLE_DOCS must be at least PLAYER_CHANGE_HISTORY_SAMPLE_WINDOWS")
		}
		signature = fmt.Sprintf("sample:%d:%d", sampleDocs, sampleWindows)
	}
	run := &playerHistoryRun{
		ctx: ctx, cfg: cfg, pool: pool,
		collection:             mongoClient.Database(playerHistorySourceDatabase).Collection(playerHistorySourceCollection),
		catalog:                catalog,
		stats:                  playerHistoryStats{rejected: map[string]int64{}, unmappedTypes: map[string]int64{}},
		rows:                   make([][]any, 0, cfg.BatchSize),
		snapshotEqualThreshold: playerHistoryEnvInt(cfg.Env, "PLAYER_CHANGE_HISTORY_SNAPSHOT_EQUAL_THRESHOLD", defaultSnapshotEqualThreshold),
	}
	if run.snapshotEqualThreshold < 2 {
		return errors.New("PLAYER_CHANGE_HISTORY_SNAPSHOT_EQUAL_THRESHOLD must be at least 2")
	}
	if err := run.prepare(signature); err != nil {
		return err
	}
	fmt.Printf("player_change_history: mode=%s static_data=%s resume_docs=%d\n", signature, catalogDir, run.state.totalDocs)

	if sampleDocs > 0 {
		ranges, err := playerHistorySampleRanges(ctx, run.collection, sampleDocs, sampleWindows)
		if err != nil {
			return err
		}
		for _, sourceRange := range ranges {
			if sourceRange.index < run.state.sampleWindow {
				continue
			}
			if err := run.streamRange(sourceRange); err != nil {
				return err
			}
			if err := run.advanceSampleWindow(sourceRange.index + 1); err != nil {
				return err
			}
		}
	} else {
		if err := run.streamRange(playerHistorySourceRange{index: 0}); err != nil {
			return err
		}
	}
	if err := run.finish(); err != nil {
		return err
	}
	run.printSummary(signature)
	return nil
}

func (r *playerHistoryRun) prepare(signature string) error {
	if _, err := r.pool.Exec(r.ctx, `
		CREATE TABLE IF NOT EXISTS public._migration_player_change_history_state (
			migration_key text PRIMARY KEY,
			signature text NOT NULL,
			source_id text,
			sample_window integer NOT NULL DEFAULT 0,
			window_docs bigint NOT NULL DEFAULT 0,
			total_docs bigint NOT NULL DEFAULT 0,
			updated_at timestamptz NOT NULL DEFAULT now()
		)
	`); err != nil {
		return fmt.Errorf("create migration state table: %w", err)
	}
	err := r.pool.QueryRow(r.ctx, `
		SELECT signature, COALESCE(source_id, ''), sample_window, window_docs, total_docs
		FROM public._migration_player_change_history_state WHERE migration_key = $1
	`, playerHistoryMigrationKey).Scan(&r.state.signature, &r.state.sourceID, &r.state.sampleWindow, &r.state.windowDocs, &r.state.totalDocs)
	if err == nil {
		if r.state.signature != signature {
			return fmt.Errorf("unfinished player history migration uses %q, requested %q", r.state.signature, signature)
		}
		return nil
	}
	if !errors.Is(err, pgx.ErrNoRows) {
		return fmt.Errorf("load migration state: %w", err)
	}
	tx, err := r.pool.Begin(r.ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(r.ctx)
	for _, statement := range []string{
		`DROP INDEX IF EXISTS public.idx_player_change_history_player_time`,
		`DROP INDEX IF EXISTS public.idx_player_change_history_player_type_time`,
		`DROP INDEX IF EXISTS public.idx_player_change_history_type_time`,
		`DROP INDEX IF EXISTS public.player_change_history_event_time_idx`,
		`TRUNCATE TABLE public.player_change_history`,
	} {
		if _, err := tx.Exec(r.ctx, statement); err != nil {
			return fmt.Errorf("prepare player history target: %w", err)
		}
	}
	if _, err := tx.Exec(r.ctx, `
		INSERT INTO public._migration_player_change_history_state (migration_key, signature)
		VALUES ($1, $2)
	`, playerHistoryMigrationKey, signature); err != nil {
		return err
	}
	r.state = playerHistoryState{signature: signature}
	return tx.Commit(r.ctx)
}

func (r *playerHistoryRun) streamRange(sourceRange playerHistorySourceRange) error {
	filter := bson.D{}
	if !sourceRange.from.IsZero() || !sourceRange.to.IsZero() || r.state.sourceID != "" {
		idFilter := bson.D{}
		if r.state.sourceID != "" && sourceRange.index == r.state.sampleWindow {
			checkpoint, err := bson.ObjectIDFromHex(r.state.sourceID)
			if err != nil {
				return fmt.Errorf("invalid stored source id %q: %w", r.state.sourceID, err)
			}
			idFilter = append(idFilter, bson.E{Key: "$gt", Value: checkpoint})
		} else if !sourceRange.from.IsZero() {
			idFilter = append(idFilter, bson.E{Key: "$gte", Value: sourceRange.from})
		}
		if !sourceRange.to.IsZero() {
			idFilter = append(idFilter, bson.E{Key: "$lt", Value: sourceRange.to})
		}
		filter = bson.D{{Key: "_id", Value: idFilter}}
	}
	remaining := sourceRange.limit
	if remaining > 0 && sourceRange.index == r.state.sampleWindow {
		remaining -= r.state.windowDocs
		if remaining <= 0 {
			return nil
		}
	}
	opts := options.Find().SetSort(bson.D{{Key: "_id", Value: 1}}).
		SetBatchSize(int32(min(r.cfg.BatchSize, 10000))).
		SetProjection(playerHistoryProjection())
	if remaining > 0 {
		opts.SetLimit(remaining)
	}
	cursor, err := r.collection.Find(r.ctx, filter, opts)
	if err != nil {
		return err
	}
	defer cursor.Close(r.ctx)

	var group playerHistoryGroup
	var rangeDocs int64
	for cursor.Next(r.ctx) {
		var doc bson.M
		if err := cursor.Decode(&doc); err != nil {
			return err
		}
		id, ok := doc["_id"].(bson.ObjectID)
		if !ok {
			r.stats.scanned++
			r.stats.rejected["invalid_source_id"]++
			continue
		}
		analyzed := analyzePlayerHistory(doc, r.catalog)
		key := playerHistoryGroupKey(doc)
		if len(group.items) > 0 && key != group.key {
			r.finalizeGroup(&group)
			if err := r.maybeCheckpoint(sourceRange.index, false); err != nil {
				return err
			}
			group = playerHistoryGroup{}
		}
		if len(group.items) == 0 {
			group.key = key
		}
		group.items = append(group.items, analyzed)
		group.lastID = id
		group.rawCount++
		rangeDocs++
	}
	if err := cursor.Err(); err != nil {
		return err
	}
	if len(group.items) > 0 {
		r.finalizeGroup(&group)
	}
	if err := r.maybeCheckpoint(sourceRange.index, true); err != nil {
		return err
	}
	fmt.Printf("player_change_history: source_window=%d scanned=%d\n", sourceRange.index, rangeDocs)
	return nil
}

func (r *playerHistoryRun) finalizeGroup(group *playerHistoryGroup) {
	equalItems := 0
	for _, item := range group.items {
		if item.equalItem {
			equalItems++
		}
	}
	broadSnapshot := equalItems >= r.snapshotEqualThreshold
	seenRows := map[string]struct{}{}
	for _, item := range group.items {
		r.stats.scanned++
		if item.row == nil {
			r.reject(item)
			continue
		}
		if item.superBoost && broadSnapshot {
			r.stats.rejected["snapshot_cluster"]++
			continue
		}
		key := fmt.Sprintf("%d:%v:%s:%s", item.row.changeType, item.row.itemID, item.row.previous, item.row.current)
		if _, exists := seenRows[key]; exists {
			r.stats.rejected["duplicate_in_poll"]++
			continue
		}
		seenRows[key] = struct{}{}
		r.rows = append(r.rows, []any{
			item.row.eventTime, item.row.playerTag, item.row.changeType, item.row.itemID,
			item.row.townHallLevel, item.row.previous, item.row.current,
		})
	}
	r.sinceCheckpoint += group.rawCount
	r.lastCheckpointID = group.lastID
}

func (r *playerHistoryRun) reject(item analyzedPlayerHistory) {
	if item.reason == "unmapped_type" {
		r.stats.unmappedTypes[item.legacyType]++
	}
	if item.reason == "" {
		item.reason = "invalid"
	}
	r.stats.rejected[item.reason]++
}

func (r *playerHistoryRun) maybeCheckpoint(sampleWindow int, force bool) error {
	if r.sinceCheckpoint == 0 || (!force && r.sinceCheckpoint < int64(r.cfg.BatchSize)) {
		return nil
	}
	tx, err := r.pool.Begin(r.ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(r.ctx)
	if len(r.rows) > 0 {
		_, err = tx.CopyFrom(r.ctx, pgx.Identifier{playerHistoryTable}, []string{
			"event_time", "player_tag", "change_type", "item_id", "townhall_level", "previous_value", "current_value",
		}, pgx.CopyFromRows(r.rows))
		if err != nil {
			return fmt.Errorf("copy player change rows: %w", err)
		}
	}
	windowDocs := r.state.windowDocs + r.sinceCheckpoint
	totalDocs := r.state.totalDocs + r.sinceCheckpoint
	if _, err := tx.Exec(r.ctx, `
		UPDATE public._migration_player_change_history_state
		SET source_id = $2, sample_window = $3, window_docs = $4, total_docs = $5, updated_at = now()
		WHERE migration_key = $1
	`, playerHistoryMigrationKey, r.lastCheckpointID.Hex(), sampleWindow, windowDocs, totalDocs); err != nil {
		return err
	}
	if err := tx.Commit(r.ctx); err != nil {
		return err
	}
	r.stats.written += int64(len(r.rows))
	r.state.sourceID = r.lastCheckpointID.Hex()
	r.state.sampleWindow = sampleWindow
	r.state.windowDocs = windowDocs
	r.state.totalDocs = totalDocs
	r.rows = r.rows[:0]
	r.sinceCheckpoint = 0
	fmt.Printf("player_change_history: checkpoint source_id=%s total_docs=%d run_scanned=%d run_written=%d\n",
		r.state.sourceID, r.state.totalDocs, r.stats.scanned, r.stats.written)
	return nil
}

func (r *playerHistoryRun) advanceSampleWindow(next int) error {
	if _, err := r.pool.Exec(r.ctx, `
		UPDATE public._migration_player_change_history_state
		SET source_id = NULL, sample_window = $2, window_docs = 0, updated_at = now()
		WHERE migration_key = $1
	`, playerHistoryMigrationKey, next); err != nil {
		return err
	}
	r.state.sourceID = ""
	r.state.sampleWindow = next
	r.state.windowDocs = 0
	return nil
}

func (r *playerHistoryRun) finish() error {
	for _, statement := range []string{
		`CREATE INDEX IF NOT EXISTS idx_player_change_history_player_time ON public.player_change_history (player_tag, event_time DESC)`,
		`CREATE INDEX IF NOT EXISTS idx_player_change_history_player_type_time ON public.player_change_history (player_tag, change_type, event_time DESC)`,
	} {
		if _, err := r.pool.Exec(r.ctx, statement); err != nil {
			return fmt.Errorf("finalize player history indexes: %w", err)
		}
	}
	if _, err := r.pool.Exec(r.ctx, `DELETE FROM public._migration_player_change_history_state WHERE migration_key = $1`, playerHistoryMigrationKey); err != nil {
		return err
	}
	return nil
}

func (r *playerHistoryRun) printSummary(signature string) {
	fmt.Printf("player_change_history: complete mode=%s scanned=%d written=%d rejected=%d\n",
		signature, r.stats.scanned, r.stats.written, r.stats.scanned-r.stats.written)
	printPlayerHistoryCounts("rejection", r.stats.rejected)
	printPlayerHistoryCounts("unmapped_type", r.stats.unmappedTypes)
}

func printPlayerHistoryCounts(label string, values map[string]int64) {
	keys := make([]string, 0, len(values))
	for key := range values {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	for _, key := range keys {
		fmt.Printf("player_change_history: %s=%q count=%d\n", label, key, values[key])
	}
}

func analyzePlayerHistory(doc bson.M, catalog staticCatalog) analyzedPlayerHistory {
	legacyType := migrateutil.String(doc["type"])
	result := analyzedPlayerHistory{legacyType: legacyType}
	eventTime, ok := migrateutil.Time(doc["time"])
	if !ok {
		result.reason = "invalid_time"
		return result
	}
	tag := normalizePlayerHistoryTag(migrateutil.String(doc["tag"]))
	if tag == "" {
		result.reason = "invalid_tag"
		return result
	}
	townHall := playerHistoryTownHall(doc["th"])
	if _, excluded := excludedPlayerHistoryTypes[legacyType]; excluded {
		result.reason = "excluded_type"
		return result
	}
	base := playerHistoryRow{eventTime: eventTime, playerTag: tag, townHallLevel: townHall}

	switch legacyType {
	case "name":
		previous, previousOK := playerHistoryText(doc, "p_value")
		current, currentOK := playerHistoryText(doc, "value")
		if !previousOK || !currentOK {
			result.reason = "missing_value"
			return result
		}
		if previous == current {
			result.reason = "equal_value"
			return result
		}
		base.changeType, base.previous, base.current = changeTypeName, previous, current
		result.row = &base
		return result
	case "warPreference":
		previousRaw, previousExists := doc["p_value"]
		currentRaw, currentExists := doc["value"]
		if !previousExists || previousRaw == nil || !currentExists || currentRaw == nil {
			result.reason = "missing_value"
			return result
		}
		previous, previousOK := playerHistoryWarPreference(previousRaw)
		current, currentOK := playerHistoryWarPreference(currentRaw)
		if !previousOK || !currentOK {
			result.reason = "invalid_war_preference"
			return result
		}
		if previous == current {
			result.reason = "equal_value"
			return result
		}
		base.changeType, base.previous, base.current = changeTypeWarPreference, previous, current
		result.row = &base
		return result
	}

	if scalarType := playerHistoryScalarType(legacyType); scalarType != 0 {
		previous, previousNumber, previousOK := playerHistoryNumber(doc, "p_value")
		current, currentNumber, currentOK := playerHistoryNumber(doc, "value")
		if !previousOK || !currentOK {
			result.reason = "missing_value"
			return result
		}
		if currentNumber == previousNumber {
			result.reason = "equal_value"
			return result
		}
		if currentNumber < previousNumber {
			result.reason = "decrease"
			return result
		}
		base.changeType, base.previous, base.current = scalarType, previous, current
		result.row = &base
		return result
	}

	item, ok := catalog[normalizePlayerHistoryName(legacyType)]
	if !ok {
		result.reason = "unmapped_type"
		return result
	}
	previous, previousNumber, previousOK := playerHistoryNumber(doc, "p_value")
	current, currentNumber, currentOK := playerHistoryNumber(doc, "value")
	if !previousOK || !currentOK {
		result.reason = "missing_value"
		return result
	}
	result.equalItem = previousNumber == currentNumber
	if item.superTroop {
		if previousNumber != currentNumber || currentNumber <= 0 {
			result.reason = "super_troop_non_boost"
			return result
		}
		base.changeType, base.itemID, base.previous, base.current = changeTypeSuperTroopBoost, item.itemID, "0", "1"
		result.row, result.superBoost = &base, true
		return result
	}
	if previousNumber == currentNumber {
		result.reason = "equal_value"
		return result
	}
	if currentNumber < previousNumber {
		result.reason = "decrease"
		return result
	}
	base.changeType, base.itemID, base.previous, base.current = item.changeType, item.itemID, previous, current
	result.row = &base
	return result
}

func playerHistoryScalarType(value string) int16 {
	switch value {
	case "townHallLevel", "townhall", "townHall":
		return changeTypeTownHallLevel
	case "bestTrophies":
		return changeTypeBestTrophies
	case "bestBuilderBaseTrophies", "bestVersusTrophies":
		return changeTypeBestBuilder
	case "expLevel":
		return changeTypeExpLevel
	default:
		return 0
	}
}

func playerHistoryProjection() bson.D {
	return bson.D{{Key: "_id", Value: 1}, {Key: "tag", Value: 1}, {Key: "time", Value: 1},
		{Key: "type", Value: 1}, {Key: "value", Value: 1}, {Key: "p_value", Value: 1}, {Key: "th", Value: 1}}
}

func playerHistoryGroupKey(doc bson.M) string {
	eventTime, _ := migrateutil.Time(doc["time"])
	return normalizePlayerHistoryTag(migrateutil.String(doc["tag"])) + ":" + strconv.FormatInt(eventTime.Unix(), 10)
}

func normalizePlayerHistoryTag(value string) string {
	value = strings.ToUpper(strings.TrimSpace(value))
	for {
		switch {
		case strings.HasPrefix(value, "#"):
			value = strings.TrimPrefix(value, "#")
		case strings.HasPrefix(value, "%23"):
			value = strings.TrimPrefix(value, "%23")
		default:
			if value == "" {
				return ""
			}
			return "#" + value
		}
	}
}

func playerHistoryTownHall(value any) any {
	_, number, ok := playerHistoryCanonicalNumber(value)
	if !ok || number <= 0 || number > math.MaxInt16 {
		return nil
	}
	return int16(number)
}

func playerHistoryNumber(doc bson.M, key string) (string, int64, bool) {
	value, exists := doc[key]
	if !exists || value == nil {
		return "", 0, false
	}
	return playerHistoryCanonicalNumber(value)
}

func playerHistoryCanonicalNumber(value any) (string, int64, bool) {
	var number int64
	switch typed := value.(type) {
	case int:
		number = int64(typed)
	case int32:
		number = int64(typed)
	case int64:
		number = typed
	case float64:
		if math.Trunc(typed) != typed || typed > math.MaxInt64 || typed < math.MinInt64 {
			return "", 0, false
		}
		number = int64(typed)
	case string:
		parsed, err := strconv.ParseInt(strings.TrimSpace(typed), 10, 64)
		if err != nil {
			return "", 0, false
		}
		number = parsed
	default:
		return "", 0, false
	}
	return strconv.FormatInt(number, 10), number, true
}

func playerHistoryText(doc bson.M, key string) (string, bool) {
	value, exists := doc[key]
	if !exists || value == nil {
		return "", false
	}
	text := strings.TrimSpace(fmt.Sprint(value))
	return text, text != ""
}

func playerHistoryWarPreference(value any) (string, bool) {
	switch strings.ToLower(strings.TrimSpace(fmt.Sprint(value))) {
	case "out", "0", "false":
		return "0", true
	case "in", "1", "true":
		return "1", true
	default:
		return "", false
	}
}

func loadPlayerHistoryCatalog(cfg migrateutil.Config) (staticCatalog, string, error) {
	dir, err := playerHistoryStaticDataDir(cfg)
	if err != nil {
		return nil, "", err
	}
	catalog := staticCatalog{}
	files := []struct {
		name       string
		base       int64
		changeType int16
	}{
		{"troops.json", 4_000_000, changeTypeTroopLevel},
		{"spells.json", 26_000_000, changeTypeSpellLevel},
		{"heroes.json", 28_000_000, changeTypeHeroLevel},
		{"pets.json", 73_000_000, changeTypePetLevel},
		{"equipment.json", 90_000_000, changeTypeEquipmentLevel},
	}
	for _, file := range files {
		payload, err := os.ReadFile(filepath.Join(dir, file.name))
		if err != nil {
			return nil, "", fmt.Errorf("read static data %s: %w", file.name, err)
		}
		var data staticDataFile
		if err := json.Unmarshal(payload, &data); err != nil {
			return nil, "", fmt.Errorf("decode static data %s: %w", file.name, err)
		}
		for _, raw := range data.Items {
			relativeID := raw.ID - file.base
			if relativeID < 0 || relativeID > math.MaxInt16 || strings.TrimSpace(raw.Name) == "" {
				continue
			}
			item := staticItem{
				changeType: file.changeType, itemID: int16(relativeID), village: raw.Village,
				superTroop: len(raw.SuperTroop) > 0 && string(raw.SuperTroop) != "null",
			}
			key := normalizePlayerHistoryName(raw.Name)
			existing, exists := catalog[key]
			if !exists || (item.village == "home" && existing.village != "home") {
				catalog[key] = item
			}
		}
	}
	aliases := map[string]staticItem{
		"Baby Dragon (Builder Base)": {changeType: changeTypeTroopLevel, itemID: 41, village: "builderBase"},
		"Power PEKKA":                {changeType: changeTypeTroopLevel, itemID: 36, village: "builderBase"},
		"Super PEKKA":                {changeType: changeTypeTroopLevel, itemID: 36, village: "builderBase"},
		"Overgrowth":                 {changeType: changeTypeSpellLevel, itemID: 70, village: "home"},
	}
	for name, item := range aliases {
		catalog[normalizePlayerHistoryName(name)] = item
	}
	return catalog, dir, nil
}

func playerHistoryStaticDataDir(cfg migrateutil.Config) (string, error) {
	candidates := []string{strings.TrimSpace(cfg.Env["PLAYER_CHANGE_HISTORY_STATIC_DATA_DIR"])}
	repositoryRoot := filepath.Dir(cfg.Root)
	candidates = append(candidates,
		filepath.Join(filepath.Dir(repositoryRoot), "clashking-assets", "assets", "static_data"),
		"/root/clashking/clashking-assets/assets/static_data",
	)
	for _, candidate := range candidates {
		if candidate == "" {
			continue
		}
		if info, err := os.Stat(filepath.Join(candidate, "troops.json")); err == nil && !info.IsDir() {
			return filepath.Clean(candidate), nil
		}
	}
	return "", errors.New("static data not found; set PLAYER_CHANGE_HISTORY_STATIC_DATA_DIR to the ClashKing assets/static_data directory")
}

func normalizePlayerHistoryName(value string) string {
	var out strings.Builder
	for _, char := range strings.ToLower(strings.TrimSpace(value)) {
		if unicode.IsLetter(char) || unicode.IsDigit(char) {
			out.WriteRune(char)
		}
	}
	return out.String()
}

func playerHistorySampleRanges(ctx context.Context, collection *mongo.Collection, total int64, windows int) ([]playerHistorySourceRange, error) {
	var first, last struct {
		ID bson.ObjectID `bson:"_id"`
	}
	if err := collection.FindOne(ctx, bson.D{}, options.FindOne().SetSort(bson.D{{Key: "_id", Value: 1}}).SetProjection(bson.D{{Key: "_id", Value: 1}})).Decode(&first); err != nil {
		return nil, fmt.Errorf("find first player history id: %w", err)
	}
	if err := collection.FindOne(ctx, bson.D{}, options.FindOne().SetSort(bson.D{{Key: "_id", Value: -1}}).SetProjection(bson.D{{Key: "_id", Value: 1}})).Decode(&last); err != nil {
		return nil, fmt.Errorf("find last player history id: %w", err)
	}
	start, end := first.ID.Timestamp().Unix(), last.ID.Timestamp().Unix()+1
	if end <= start {
		return nil, errors.New("invalid player history ObjectID time range")
	}
	ranges := make([]playerHistorySourceRange, 0, windows)
	baseLimit, remainder := total/int64(windows), total%int64(windows)
	for index := 0; index < windows; index++ {
		fromUnix := start + (end-start)*int64(index)/int64(windows)
		toUnix := start + (end-start)*int64(index+1)/int64(windows)
		limit := baseLimit
		if int64(index) < remainder {
			limit++
		}
		ranges = append(ranges, playerHistorySourceRange{
			index: index, from: bson.NewObjectIDFromTimestamp(time.Unix(fromUnix, 0)),
			to: bson.NewObjectIDFromTimestamp(time.Unix(toUnix, 0)), limit: limit,
		})
	}
	return ranges, nil
}

func playerHistoryEnvInt(env map[string]string, key string, fallback int) int {
	if raw := strings.TrimSpace(env[key]); raw != "" {
		if value, err := strconv.Atoi(raw); err == nil {
			return value
		}
	}
	return fallback
}

func playerHistoryEnvInt64(env map[string]string, key string, fallback int64) int64 {
	if raw := strings.TrimSpace(env[key]); raw != "" {
		if value, err := strconv.ParseInt(raw, 10, 64); err == nil {
			return value
		}
	}
	return fallback
}
