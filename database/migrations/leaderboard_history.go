//go:build ignore

package main

import (
	"context"
	"fmt"
	"strconv"
	"strings"
	"time"

	"clashking_devkit_database_migrations/migrateutil"
	"github.com/jackc/pgx/v5"
	"go.mongodb.org/mongo-driver/v2/bson"
)

const (
	leaderboardHistoryPlayerHomeTable        = "leaderboard_history_player_home"
	leaderboardHistoryPlayerBuilderBaseTable = "leaderboard_history_player_builder_base"
	leaderboardHistoryClanHomeTable          = "leaderboard_history_clan_home"
	leaderboardHistoryClanBuilderBaseTable   = "leaderboard_history_clan_builder_base"
	leaderboardHistoryClanCapitalTable       = "leaderboard_history_clan_capital"
)

type leaderboardHistorySource struct {
	collection              string
	table                   string
	tuesdaySnapshotAsMonday bool
}

var leaderboardHistorySources = []leaderboardHistorySource{
	{collection: "player_trophies", table: leaderboardHistoryPlayerHomeTable},
	{collection: "player_versus_trophies", table: leaderboardHistoryPlayerBuilderBaseTable},
	{collection: "clan_trophies", table: leaderboardHistoryClanHomeTable},
	{collection: "clan_versus_trophies", table: leaderboardHistoryClanBuilderBaseTable},
	{
		collection:              "capital",
		table:                   leaderboardHistoryClanCapitalTable,
		tuesdaySnapshotAsMonday: true,
	},
}

type leaderboardHistoryRow struct {
	locationID string
	date       time.Time
	tag        string
	name       string
	rank       int
	previous   any

	expLevel              int
	trophies              int
	attackWins            int
	defenseWins           int
	builderBaseTrophies   int
	builderBaseBattleWins any
	leagueID              any

	clanTag        any
	clanName       any
	clanBadgeToken any
	clanLevel      int
	clanPoints     int
	members        int
	clanLocationID any
}

func main() {
	migrateutil.Main("leaderboard_history", runLeaderboardHistory)
}

func runLeaderboardHistory(ctx context.Context, cfg migrateutil.Config) error {
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

	plan := leaderboardHistoryOneShotPlan()
	if err := migrateutil.StartOneShot(ctx, pool, plan); err != nil {
		return err
	}

	var scannedDocs int64
	var writtenRows int64
	for _, source := range leaderboardHistorySources {
		rows := make(map[string]leaderboardHistoryRow, cfg.BatchSize)
		flush := func() error {
			if len(rows) == 0 {
				return nil
			}
			written, err := flushLeaderboardHistoryRows(ctx, pool, source, rows)
			if err != nil {
				return err
			}
			writtenRows += written
			rows = make(map[string]leaderboardHistoryRow, cfg.BatchSize)
			return nil
		}
		seen, err := migrateutil.StreamAllProjected(
			ctx,
			cfg,
			source.collection,
			mongoClient.Database("ranking_history").Collection(source.collection),
			bson.D{
				{Key: "location", Value: 1},
				{Key: "date", Value: 1},
				{Key: "data.items", Value: 1},
			},
			func(doc bson.M) (bool, error) {
				for _, row := range leaderboardRowsFromDocument(source, doc) {
					rows[leaderboardHistoryRowKey(row)] = row
				}
				return len(rows) >= cfg.BatchSize, nil
			},
			flush,
		)
		if err != nil {
			return err
		}
		scannedDocs += seen
		fmt.Printf("ranking_history.%s: scanned_docs=%d\n", source.collection, seen)
	}

	if err := migrateutil.FinishOneShot(ctx, pool, plan); err != nil {
		return err
	}
	fmt.Printf("leaderboard histories: scanned_docs=%d rows=%d\n", scannedDocs, writtenRows)
	return nil
}

func leaderboardHistoryOneShotPlan() migrateutil.OneShotPlan {
	return migrateutil.OneShotPlan{
		ResetSQL: []string{
			`TRUNCATE TABLE public.leaderboard_history_player_home`,
			`TRUNCATE TABLE public.leaderboard_history_player_builder_base`,
			`TRUNCATE TABLE public.leaderboard_history_clan_home`,
			`TRUNCATE TABLE public.leaderboard_history_clan_builder_base`,
			`TRUNCATE TABLE public.leaderboard_history_clan_capital`,
		},
		DropIndexes: []string{
			`DROP INDEX IF EXISTS public.idx_leaderboard_history_player_home_location_rank`,
			`DROP INDEX IF EXISTS public.idx_leaderboard_history_player_home_player`,
			`DROP INDEX IF EXISTS public.idx_leaderboard_history_player_builder_base_location_rank`,
			`DROP INDEX IF EXISTS public.idx_leaderboard_history_player_builder_base_player`,
			`DROP INDEX IF EXISTS public.idx_leaderboard_history_clan_home_location_rank`,
			`DROP INDEX IF EXISTS public.idx_leaderboard_history_clan_home_clan`,
			`DROP INDEX IF EXISTS public.idx_leaderboard_history_clan_builder_base_location_rank`,
			`DROP INDEX IF EXISTS public.idx_leaderboard_history_clan_builder_base_clan`,
			`DROP INDEX IF EXISTS public.idx_leaderboard_history_clan_capital_location_rank`,
			`DROP INDEX IF EXISTS public.idx_leaderboard_history_clan_capital_clan`,
		},
		CreateIndexes: []string{
			`CREATE INDEX idx_leaderboard_history_player_home_location_rank ON public.leaderboard_history_player_home (location_id, date DESC, rank)`,
			`CREATE INDEX idx_leaderboard_history_player_home_player ON public.leaderboard_history_player_home (player_tag, date DESC)`,
			`CREATE INDEX idx_leaderboard_history_player_builder_base_location_rank ON public.leaderboard_history_player_builder_base (location_id, date DESC, rank)`,
			`CREATE INDEX idx_leaderboard_history_player_builder_base_player ON public.leaderboard_history_player_builder_base (player_tag, date DESC)`,
			`CREATE INDEX idx_leaderboard_history_clan_home_location_rank ON public.leaderboard_history_clan_home (location_id, date DESC, rank)`,
			`CREATE INDEX idx_leaderboard_history_clan_home_clan ON public.leaderboard_history_clan_home (clan_tag, date DESC)`,
			`CREATE INDEX idx_leaderboard_history_clan_builder_base_location_rank ON public.leaderboard_history_clan_builder_base (location_id, date DESC, rank)`,
			`CREATE INDEX idx_leaderboard_history_clan_builder_base_clan ON public.leaderboard_history_clan_builder_base (clan_tag, date DESC)`,
			`CREATE INDEX idx_leaderboard_history_clan_capital_location_rank ON public.leaderboard_history_clan_capital (location_id, date DESC, rank)`,
			`CREATE INDEX idx_leaderboard_history_clan_capital_clan ON public.leaderboard_history_clan_capital (clan_tag, date DESC)`,
		},
	}
}

func leaderboardRowsFromDocument(source leaderboardHistorySource, doc bson.M) []leaderboardHistoryRow {
	locationID, ok := normalizeLeaderboardLocation(doc["location"])
	if !ok {
		return nil
	}
	date, ok := normalizeLeaderboardDate(doc["date"])
	if !ok {
		return nil
	}
	if source.tuesdaySnapshotAsMonday {
		if date.Weekday() != time.Tuesday {
			return nil
		}
		date = date.AddDate(0, 0, -1)
	}
	items := migrateutil.Slice(migrateutil.Map(doc["data"])["items"])
	rows := make([]leaderboardHistoryRow, 0, len(items))
	for _, raw := range items {
		item := migrateutil.Map(raw)
		row, ok := typedLeaderboardHistoryRow(source, locationID, date, item)
		if ok {
			rows = append(rows, row)
		}
	}
	return rows
}

func typedLeaderboardHistoryRow(
	source leaderboardHistorySource,
	locationID string,
	date time.Time,
	item bson.M,
) (leaderboardHistoryRow, bool) {
	tag := migrateutil.String(item["tag"])
	name := migrateutil.String(item["name"])
	rank := migrateutil.Int(item["rank"])
	if item == nil || tag == "" || name == "" || rank <= 0 {
		return leaderboardHistoryRow{}, false
	}
	row := leaderboardHistoryRow{
		locationID: locationID,
		date:       date,
		tag:        tag,
		name:       name,
		rank:       rank,
		previous:   optionalLeaderboardInt(item["previousRank"]),
	}
	switch source.table {
	case leaderboardHistoryPlayerHomeTable:
		row.expLevel = migrateutil.Int(item["expLevel"])
		row.trophies = migrateutil.Int(item["trophies"])
		row.attackWins = migrateutil.Int(item["attackWins"])
		row.defenseWins = migrateutil.Int(item["defenseWins"])
		row.clanTag, row.clanName, row.clanBadgeToken = leaderboardPlayerClan(item["clan"])
		row.leagueID = firstPositiveLeaderboardInt(
			migrateutil.Map(item["leagueTier"])["id"],
			migrateutil.Map(item["league"])["id"],
		)
		if row.expLevel < 0 || row.trophies < 0 || row.attackWins < 0 || row.defenseWins < 0 {
			return leaderboardHistoryRow{}, false
		}
	case leaderboardHistoryPlayerBuilderBaseTable:
		row.expLevel = migrateutil.Int(item["expLevel"])
		row.builderBaseTrophies = firstLeaderboardInt(
			item["builderBaseTrophies"],
			item["versusTrophies"],
		)
		row.builderBaseBattleWins = firstOptionalLeaderboardInt(
			item["builderBaseBattleWins"],
			item["versusBattleWins"],
		)
		row.clanTag, row.clanName, row.clanBadgeToken = leaderboardPlayerClan(item["clan"])
		row.leagueID = firstPositiveLeaderboardInt(
			migrateutil.Map(item["builderBaseLeague"])["id"],
		)
		if row.expLevel < 0 || row.builderBaseTrophies < 0 {
			return leaderboardHistoryRow{}, false
		}
	case leaderboardHistoryClanHomeTable:
		if !populateLeaderboardClanRow(&row, item) {
			return leaderboardHistoryRow{}, false
		}
		row.clanPoints = migrateutil.Int(item["clanPoints"])
		if row.clanPoints < 0 {
			return leaderboardHistoryRow{}, false
		}
	case leaderboardHistoryClanBuilderBaseTable:
		if !populateLeaderboardClanRow(&row, item) {
			return leaderboardHistoryRow{}, false
		}
		row.clanPoints = firstLeaderboardInt(
			item["clanBuilderBasePoints"],
			item["clanVersusPoints"],
		)
		if row.clanPoints < 0 {
			return leaderboardHistoryRow{}, false
		}
	case leaderboardHistoryClanCapitalTable:
		if !populateLeaderboardClanRow(&row, item) {
			return leaderboardHistoryRow{}, false
		}
		row.clanPoints = migrateutil.Int(item["clanCapitalPoints"])
		if row.clanPoints < 0 {
			return leaderboardHistoryRow{}, false
		}
	default:
		return leaderboardHistoryRow{}, false
	}
	return row, true
}

func populateLeaderboardClanRow(row *leaderboardHistoryRow, item bson.M) bool {
	badgeURLs := migrateutil.Map(item["badgeUrls"])
	badgeToken := migrateutil.BadgeToken(
		item["badgeToken"],
		badgeURLs["medium"],
		badgeURLs["small"],
		badgeURLs["large"],
	)
	row.clanLevel = migrateutil.Int(item["clanLevel"])
	row.members = migrateutil.Int(item["members"])
	row.clanLocationID = firstPositiveLeaderboardInt(migrateutil.Map(item["location"])["id"])
	row.clanBadgeToken = badgeToken
	return badgeToken != "" &&
		row.clanLevel > 0 &&
		row.members >= 0 &&
		row.members <= 50
}

func leaderboardPlayerClan(value any) (any, any, any) {
	clan := migrateutil.Map(value)
	tag := migrateutil.String(clan["tag"])
	name := migrateutil.String(clan["name"])
	badgeURLs := migrateutil.Map(clan["badgeUrls"])
	badgeToken := migrateutil.BadgeToken(
		clan["badgeToken"],
		badgeURLs["medium"],
		badgeURLs["small"],
		badgeURLs["large"],
	)
	if tag == "" || name == "" || badgeToken == "" {
		return nil, nil, nil
	}
	return tag, name, badgeToken
}

func optionalLeaderboardInt(value any) any {
	if value == nil {
		return nil
	}
	return migrateutil.Int(value)
}

func firstPositiveLeaderboardInt(values ...any) any {
	for _, value := range values {
		if parsed := migrateutil.Int(value); parsed > 0 {
			return parsed
		}
	}
	return nil
}

func firstOptionalLeaderboardInt(values ...any) any {
	for _, value := range values {
		if value != nil {
			parsed := migrateutil.Int(value)
			if parsed >= 0 {
				return parsed
			}
		}
	}
	return nil
}

func firstLeaderboardInt(values ...any) int {
	for _, value := range values {
		if value != nil {
			return migrateutil.Int(value)
		}
	}
	return 0
}

func normalizeLeaderboardLocation(value any) (string, bool) {
	raw := migrateutil.String(value)
	if strings.EqualFold(raw, "global") {
		return "global", true
	}
	locationID, err := strconv.ParseInt(raw, 10, 64)
	if err != nil || locationID <= 0 {
		return "", false
	}
	return strconv.FormatInt(locationID, 10), true
}

func normalizeLeaderboardDate(value any) (time.Time, bool) {
	parsed, ok := migrateutil.Time(value)
	if !ok {
		return time.Time{}, false
	}
	year, month, day := parsed.UTC().Date()
	return time.Date(year, month, day, 0, 0, 0, 0, time.UTC), true
}

func leaderboardHistoryRowKey(row leaderboardHistoryRow) string {
	return fmt.Sprintf(
		"%s\x00%s\x00%s",
		row.locationID,
		row.date.Format("2006-01-02"),
		row.tag,
	)
}

func flushLeaderboardHistoryRows(ctx context.Context, pool interface {
	Begin(context.Context) (pgx.Tx, error)
}, source leaderboardHistorySource, rows map[string]leaderboardHistoryRow) (int64, error) {
	columns, copyRows, updates, err := leaderboardHistoryCopyRows(source.table, rows)
	if err != nil {
		return 0, err
	}
	tx, err := pool.Begin(ctx)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback(ctx)
	target := pgx.Identifier{"public", source.table}.Sanitize()
	temp := pgx.Identifier{"_ck_leaderboard_history"}.Sanitize()
	if _, err := tx.Exec(ctx, fmt.Sprintf(
		"CREATE TEMP TABLE %s (LIKE %s INCLUDING DEFAULTS) ON COMMIT DROP",
		temp,
		target,
	)); err != nil {
		return 0, err
	}
	if _, err := tx.CopyFrom(
		ctx,
		pgx.Identifier{"_ck_leaderboard_history"},
		columns,
		pgx.CopyFromRows(copyRows),
	); err != nil {
		return 0, err
	}
	columnSQL := strings.Join(columns, ", ")
	if _, err := tx.Exec(ctx, fmt.Sprintf(`
		INSERT INTO %s (%s)
		SELECT %s FROM %s
		ON CONFLICT (location_id, date, %s) DO UPDATE SET %s
	`, target, columnSQL, columnSQL, temp, leaderboardHistoryIdentityColumn(source.table), updates)); err != nil {
		return 0, err
	}
	if err := tx.Commit(ctx); err != nil {
		return 0, err
	}
	return int64(len(rows)), nil
}

func leaderboardHistoryCopyRows(
	table string,
	rows map[string]leaderboardHistoryRow,
) ([]string, [][]any, string, error) {
	var columns []string
	var updates string
	switch table {
	case leaderboardHistoryPlayerHomeTable:
		columns = []string{
			"location_id", "date", "player_tag", "player_name", "exp_level",
			"trophies", "attack_wins", "defense_wins", "rank", "previous_rank",
			"clan_tag", "clan_name", "clan_badge_token", "league_id",
		}
		updates = `
			player_name = EXCLUDED.player_name,
			exp_level = EXCLUDED.exp_level,
			trophies = EXCLUDED.trophies,
			attack_wins = EXCLUDED.attack_wins,
			defense_wins = EXCLUDED.defense_wins,
			rank = EXCLUDED.rank,
			previous_rank = EXCLUDED.previous_rank,
			clan_tag = EXCLUDED.clan_tag,
			clan_name = EXCLUDED.clan_name,
			clan_badge_token = EXCLUDED.clan_badge_token,
			league_id = EXCLUDED.league_id`
	case leaderboardHistoryPlayerBuilderBaseTable:
		columns = []string{
			"location_id", "date", "player_tag", "player_name", "exp_level",
			"builder_base_trophies", "builder_base_battle_wins", "rank", "previous_rank",
			"clan_tag", "clan_name", "clan_badge_token", "league_id",
		}
		updates = `
			player_name = EXCLUDED.player_name,
			exp_level = EXCLUDED.exp_level,
			builder_base_trophies = EXCLUDED.builder_base_trophies,
			builder_base_battle_wins = EXCLUDED.builder_base_battle_wins,
			rank = EXCLUDED.rank,
			previous_rank = EXCLUDED.previous_rank,
			clan_tag = EXCLUDED.clan_tag,
			clan_name = EXCLUDED.clan_name,
			clan_badge_token = EXCLUDED.clan_badge_token,
			league_id = EXCLUDED.league_id`
	case leaderboardHistoryClanHomeTable:
		columns = clanLeaderboardHistoryColumns("clan_points")
		updates = clanLeaderboardHistoryUpdates("clan_points")
	case leaderboardHistoryClanBuilderBaseTable:
		columns = clanLeaderboardHistoryColumns("builder_base_points")
		updates = clanLeaderboardHistoryUpdates("builder_base_points")
	case leaderboardHistoryClanCapitalTable:
		columns = clanLeaderboardHistoryColumns("capital_points")
		updates = clanLeaderboardHistoryUpdates("capital_points")
	default:
		return nil, nil, "", fmt.Errorf("unsupported leaderboard history table %q", table)
	}
	copyRows := make([][]any, 0, len(rows))
	for _, row := range rows {
		switch table {
		case leaderboardHistoryPlayerHomeTable:
			copyRows = append(copyRows, []any{
				row.locationID, row.date, row.tag, row.name, row.expLevel,
				row.trophies, row.attackWins, row.defenseWins, row.rank, row.previous,
				row.clanTag, row.clanName, row.clanBadgeToken, row.leagueID,
			})
		case leaderboardHistoryPlayerBuilderBaseTable:
			copyRows = append(copyRows, []any{
				row.locationID, row.date, row.tag, row.name, row.expLevel,
				row.builderBaseTrophies, row.builderBaseBattleWins, row.rank, row.previous,
				row.clanTag, row.clanName, row.clanBadgeToken, row.leagueID,
			})
		default:
			copyRows = append(copyRows, []any{
				row.locationID, row.date, row.tag, row.name, row.clanBadgeToken,
				row.clanLevel, row.clanPoints, row.members, row.clanLocationID,
				row.rank, row.previous,
			})
		}
	}
	return columns, copyRows, updates, nil
}

func clanLeaderboardHistoryColumns(pointsColumn string) []string {
	return []string{
		"location_id", "date", "clan_tag", "clan_name", "clan_badge_token",
		"clan_level", pointsColumn, "members", "clan_location_id", "rank", "previous_rank",
	}
}

func clanLeaderboardHistoryUpdates(pointsColumn string) string {
	return fmt.Sprintf(`
		clan_name = EXCLUDED.clan_name,
		clan_badge_token = EXCLUDED.clan_badge_token,
		clan_level = EXCLUDED.clan_level,
		%s = EXCLUDED.%s,
		members = EXCLUDED.members,
		clan_location_id = EXCLUDED.clan_location_id,
		rank = EXCLUDED.rank,
		previous_rank = EXCLUDED.previous_rank
	`, pointsColumn, pointsColumn)
}

func leaderboardHistoryIdentityColumn(table string) string {
	if table == leaderboardHistoryPlayerHomeTable || table == leaderboardHistoryPlayerBuilderBaseTable {
		return "player_tag"
	}
	return "clan_tag"
}
