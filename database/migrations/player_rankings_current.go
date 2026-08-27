//go:build ignore

package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/ClashKingInc/DevKit/database/migrations/migrateutil"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"go.mongodb.org/mongo-driver/v2/bson"
	"go.mongodb.org/mongo-driver/v2/mongo"
)

const defaultPlayerRankingLocationsURL = "https://proxy.clashk.ing/v1/locations?limit=1000"

type playerRankingRow struct {
	playerTag   string
	rankingType string
	locationID  string
	rank        any
	points      any
}

type playerRankingLocations struct {
	byCode map[string]string
	byName map[string]string
}

type playerRankingLocation struct {
	ID          int    `json:"id"`
	Name        string `json:"name"`
	CountryCode string `json:"countryCode"`
	IsCountry   bool   `json:"isCountry"`
}

func main() {
	migrateutil.Main("player_rankings_current", runPlayerRankingsCurrent)
}

func runPlayerRankingsCurrent(ctx context.Context, cfg migrateutil.Config) error {
	locationsURL := strings.TrimSpace(cfg.Env["PLAYER_RANKINGS_LOCATIONS_URL"])
	if locationsURL == "" {
		locationsURL = defaultPlayerRankingLocationsURL
	}
	locations, err := loadPlayerRankingLocations(ctx, &http.Client{Timeout: 30 * time.Second}, locationsURL)
	if err != nil {
		return err
	}
	mongoClient, err := migrateutil.StatsClient(ctx, cfg)
	if err != nil {
		return err
	}
	defer mongoClient.Disconnect(ctx)
	collection := mongoClient.Database("new_looper").Collection("leaderboard_db")
	unresolvedSourceLocations, err := unresolvedPlayerRankingSourceLocations(ctx, collection, locations)
	if err != nil {
		return err
	}
	if len(unresolvedSourceLocations) != 0 {
		return fmt.Errorf("unresolved leaderboard countries: %s", strings.Join(unresolvedSourceLocations, ", "))
	}
	pool, err := migrateutil.TimescalePool(ctx, cfg)
	if err != nil {
		return err
	}
	defer pool.Close()
	if err := ensurePlayerRankingsCurrentSchema(ctx, pool); err != nil {
		return err
	}

	plan := playerRankingsCurrentOneShotPlan()
	if err := migrateutil.StartOneShot(ctx, pool, plan); err != nil {
		return err
	}
	rows := make([]playerRankingRow, 0, cfg.BatchSize)
	var writtenRows int64
	var unresolvedCountries int64
	unresolvedByCountry := map[string]int64{}
	flush := func() error {
		if len(rows) == 0 {
			return nil
		}
		written, err := flushPlayerRankingRows(ctx, pool, rows)
		if err != nil {
			return err
		}
		writtenRows += written
		rows = rows[:0]
		return nil
	}
	seen, err := migrateutil.StreamAllProjected(
		ctx,
		cfg,
		"player_rankings_current",
		collection,
		bson.D{
			{Key: "tag", Value: 1},
			{Key: "location_id", Value: 1},
			{Key: "locationId", Value: 1},
			{Key: "country_code", Value: 1},
			{Key: "country_name", Value: 1},
			{Key: "global_rank", Value: 1},
			{Key: "local_rank", Value: 1},
			{Key: "builder_global_rank", Value: 1},
			{Key: "builder_local_rank", Value: 1},
		},
		func(doc bson.M) (bool, error) {
			mapped, unresolved := playerRankingRowsFromDocument(doc, locations)
			if unresolved {
				unresolvedCountries++
				unresolvedByCountry[playerRankingCountryKey(doc)]++
			}
			rows = append(rows, mapped...)
			return len(rows) >= cfg.BatchSize, nil
		},
		flush,
	)
	if err != nil {
		return err
	}
	if err := migrateutil.FinishOneShot(ctx, pool, plan); err != nil {
		return err
	}
	fmt.Printf(
		"player_rankings_current: scanned_docs=%d rows=%d unresolved_countries=%d\n",
		seen,
		writtenRows,
		unresolvedCountries,
	)
	if unresolvedCountries > 0 {
		fmt.Printf("player_rankings_current: unresolved=%s\n", formatUnresolvedPlayerRankingCountries(unresolvedByCountry, 20))
	}
	return nil
}

func playerRankingsCurrentOneShotPlan() migrateutil.OneShotPlan {
	return migrateutil.OneShotPlan{
		ResetSQL: []string{`TRUNCATE TABLE public.player_rankings_current`},
		DropIndexes: []string{
			`DROP INDEX IF EXISTS public.idx_player_rankings_current_scope_rank`,
		},
		CreateIndexes: []string{
			`CREATE INDEX idx_player_rankings_current_scope_rank ON public.player_rankings_current (ranking_type, location_id, rank) WHERE rank IS NOT NULL`,
		},
	}
}

func ensurePlayerRankingsCurrentSchema(ctx context.Context, pool *pgxpool.Pool) error {
	tx, err := pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, `
		ALTER TABLE public.player_rankings_current
			DROP CONSTRAINT IF EXISTS player_rankings_current_placement_check;
		ALTER TABLE public.player_rankings_current
			ADD CONSTRAINT player_rankings_current_placement_check CHECK (
				(rank IS NULL AND points IS NULL)
				OR (rank IS NOT NULL AND rank > 0 AND (points IS NULL OR points >= 0))
			)
	`); err != nil {
		return fmt.Errorf("align player rankings placement constraint: %w", err)
	}
	return tx.Commit(ctx)
}

func playerRankingRowsFromDocument(doc bson.M, locations playerRankingLocations) ([]playerRankingRow, bool) {
	playerTag := strings.TrimSpace(migrateutil.String(doc["tag"]))
	if playerTag == "" {
		return nil, false
	}
	locationID := directPlayerRankingLocationID(doc)
	unresolved := false
	if locationID == "" {
		countryCode := normalizePlayerRankingCountryCode(migrateutil.String(doc["country_code"]))
		countryName := normalizePlayerRankingCountryName(migrateutil.String(doc["country_name"]))
		locationID = locations.byCode[countryCode]
		if locationID == "" {
			locationID = locations.byName[countryName]
		}
		unresolved = (countryCode != "" || countryName != "") && locationID == ""
	}

	homeGlobal := positivePlayerRanking(doc["global_rank"])
	homeLocal := positivePlayerRanking(doc["local_rank"])
	builderGlobal := positivePlayerRanking(doc["builder_global_rank"])
	builderLocal := positivePlayerRanking(doc["builder_local_rank"])
	rows := make([]playerRankingRow, 0, 4)
	if homeGlobal != nil {
		rows = append(rows, playerRankingRow{playerTag: playerTag, rankingType: "home", locationID: "global", rank: homeGlobal})
	}
	// leaderboard_db intentionally retains the last known country after local_rank
	// is reset. Keep that durable location as a nullable Home Village placement.
	if locationID != "" {
		rows = append(rows, playerRankingRow{playerTag: playerTag, rankingType: "home", locationID: locationID, rank: homeLocal})
	}
	if builderGlobal != nil {
		rows = append(rows, playerRankingRow{playerTag: playerTag, rankingType: "builder_base", locationID: "global", rank: builderGlobal})
	}
	if builderLocal != nil && locationID != "" {
		rows = append(rows, playerRankingRow{playerTag: playerTag, rankingType: "builder_base", locationID: locationID, rank: builderLocal})
	}
	return rows, unresolved
}

func directPlayerRankingLocationID(doc bson.M) string {
	for _, value := range []any{doc["location_id"], doc["locationId"]} {
		raw := strings.TrimSpace(migrateutil.String(value))
		parsed, err := strconv.ParseInt(raw, 10, 64)
		if err == nil && parsed > 0 {
			return strconv.FormatInt(parsed, 10)
		}
	}
	return ""
}

func positivePlayerRanking(value any) any {
	rank := migrateutil.Int(value)
	if rank <= 0 {
		return nil
	}
	return rank
}

func normalizePlayerRankingCountryCode(value string) string {
	return strings.ToUpper(strings.TrimSpace(value))
}

func normalizePlayerRankingCountryName(value string) string {
	return strings.ToLower(strings.Join(strings.Fields(value), " "))
}

func playerRankingCountryKey(doc bson.M) string {
	code := normalizePlayerRankingCountryCode(migrateutil.String(doc["country_code"]))
	name := strings.TrimSpace(migrateutil.String(doc["country_name"]))
	return code + ":" + name
}

func formatUnresolvedPlayerRankingCountries(counts map[string]int64, limit int) string {
	type entry struct {
		key   string
		count int64
	}
	entries := make([]entry, 0, len(counts))
	for key, count := range counts {
		entries = append(entries, entry{key: key, count: count})
	}
	sort.Slice(entries, func(i, j int) bool {
		if entries[i].count != entries[j].count {
			return entries[i].count > entries[j].count
		}
		return entries[i].key < entries[j].key
	})
	if limit > 0 && len(entries) > limit {
		entries = entries[:limit]
	}
	parts := make([]string, 0, len(entries))
	for _, value := range entries {
		parts = append(parts, fmt.Sprintf("%s=%d", value.key, value.count))
	}
	return strings.Join(parts, ",")
}

func loadPlayerRankingLocations(ctx context.Context, client *http.Client, endpoint string) (playerRankingLocations, error) {
	if client == nil {
		client = http.DefaultClient
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return playerRankingLocations{}, err
	}
	response, err := client.Do(request)
	if err != nil {
		return playerRankingLocations{}, fmt.Errorf("fetch Clash locations: %w", err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return playerRankingLocations{}, fmt.Errorf("fetch Clash locations: HTTP %d", response.StatusCode)
	}
	var payload struct {
		Items []playerRankingLocation `json:"items"`
	}
	if err := json.NewDecoder(response.Body).Decode(&payload); err != nil {
		return playerRankingLocations{}, fmt.Errorf("decode Clash locations: %w", err)
	}
	locations := playerRankingLocations{byCode: map[string]string{}, byName: map[string]string{}}
	for _, location := range payload.Items {
		if location.ID <= 0 || !location.IsCountry {
			continue
		}
		id := strconv.Itoa(location.ID)
		if code := normalizePlayerRankingCountryCode(location.CountryCode); code != "" {
			locations.byCode[code] = id
		}
		if name := normalizePlayerRankingCountryName(location.Name); name != "" {
			locations.byName[name] = id
		}
	}
	// Afghanistan was a valid legacy leaderboard location but is absent from
	// the current locations list. Its Clash location ID remains stable.
	locations.byCode["AF"] = "32000007"
	locations.byName["afghanistan"] = "32000007"
	if len(locations.byCode) == 0 || len(locations.byName) == 0 {
		return playerRankingLocations{}, errors.New("Clash locations response contains no countries")
	}
	return locations, nil
}

func unresolvedPlayerRankingSourceLocations(
	ctx context.Context,
	collection *mongo.Collection,
	locations playerRankingLocations,
) ([]string, error) {
	cursor, err := collection.Aggregate(ctx, mongo.Pipeline{
		{{Key: "$group", Value: bson.D{{Key: "_id", Value: bson.D{
			{Key: "code", Value: "$country_code"},
			{Key: "name", Value: "$country_name"},
		}}}}},
	})
	if err != nil {
		return nil, err
	}
	defer cursor.Close(ctx)
	var unresolved []string
	for cursor.Next(ctx) {
		var value struct {
			ID struct {
				Code string `bson:"code"`
				Name string `bson:"name"`
			} `bson:"_id"`
		}
		if err := cursor.Decode(&value); err != nil {
			return nil, err
		}
		code := normalizePlayerRankingCountryCode(value.ID.Code)
		name := normalizePlayerRankingCountryName(value.ID.Name)
		if code == "" && name == "" {
			continue
		}
		if locations.byCode[code] == "" && locations.byName[name] == "" {
			unresolved = append(unresolved, code+":"+value.ID.Name)
		}
	}
	if err := cursor.Err(); err != nil {
		return nil, err
	}
	sort.Strings(unresolved)
	return unresolved, nil
}

func flushPlayerRankingRows(ctx context.Context, pool interface {
	Begin(context.Context) (pgx.Tx, error)
}, rows []playerRankingRow) (int64, error) {
	if len(rows) == 0 {
		return 0, nil
	}
	tx, err := pool.Begin(ctx)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, `
		CREATE TEMP TABLE _ck_player_rankings_current (
			player_tag text,
			ranking_type text,
			location_id text,
			rank integer,
			points integer
		) ON COMMIT DROP
	`); err != nil {
		return 0, err
	}
	if _, err := tx.CopyFrom(
		ctx,
		pgx.Identifier{"_ck_player_rankings_current"},
		[]string{"player_tag", "ranking_type", "location_id", "rank", "points"},
		pgx.CopyFromSlice(len(rows), func(index int) ([]any, error) {
			row := rows[index]
			return []any{row.playerTag, row.rankingType, row.locationID, row.rank, row.points}, nil
		}),
	); err != nil {
		return 0, err
	}
	result, err := tx.Exec(ctx, `
		INSERT INTO player_rankings_current (player_tag, ranking_type, location_id, rank, points)
		SELECT player_tag, ranking_type, location_id, rank, points
		FROM _ck_player_rankings_current
		ON CONFLICT (player_tag, ranking_type, location_id) DO UPDATE SET
			rank = EXCLUDED.rank,
			points = EXCLUDED.points
	`)
	if err != nil {
		return 0, err
	}
	if err := tx.Commit(ctx); err != nil {
		return 0, err
	}
	return result.RowsAffected(), nil
}

func sortedPlayerRankingRows(rows []playerRankingRow) []playerRankingRow {
	sort.Slice(rows, func(i, j int) bool {
		if rows[i].playerTag != rows[j].playerTag {
			return rows[i].playerTag < rows[j].playerTag
		}
		if rows[i].rankingType != rows[j].rankingType {
			return rows[i].rankingType < rows[j].rankingType
		}
		return rows[i].locationID < rows[j].locationID
	})
	return rows
}
