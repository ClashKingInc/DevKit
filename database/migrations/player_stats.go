//go:build ignore

package main

import (
	"context"
	"fmt"
	"sort"

	"clashking_devkit_database_migrations/migrateutil"
	"github.com/jackc/pgx/v5"
	"go.mongodb.org/mongo-driver/v2/bson"
)

type seasonStat struct {
	playerTag string
	season    string
	clanTag   string
	values    []any
}

func main() {
	migrateutil.Main("player_stats", runPlayerStats)
}

func runPlayerStats(ctx context.Context, cfg migrateutil.Config) error {
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
	cp, err := migrateutil.LoadCheckpoint(cfg, "player_stats")
	if err != nil {
		return err
	}
	currentRows := make([][]any, 0, cfg.BatchSize)
	seasonRows := map[string]seasonStat{}
	flush := func() error {
		if len(currentRows) == 0 && len(seasonRows) == 0 {
			return nil
		}
		err := flushPlayerStats(ctx, pool, currentRows, seasonRows)
		currentRows = currentRows[:0]
		seasonRows = map[string]seasonStat{}
		return err
	}
	seen, err := migrateutil.StreamByObjectID(ctx, cfg, cp, "player_stats_id", mongoClient.Database("new_looper").Collection("player_stats"), func(doc bson.M) (bool, error) {
		tag := migrateutil.String(doc["tag"])
		if tag == "" {
			return false, nil
		}
		lastOnline, _ := migrateutil.Time(doc["last_online"])
		var lastOnlineValue any
		if !lastOnline.IsZero() {
			lastOnlineValue = lastOnline
		}
		currentRows = append(currentRows, []any{
			tag,
			migrateutil.String(doc["clan_tag"]),
			migrateutil.String(doc["name"]),
			migrateutil.OptionalInt(doc["townhall"]),
			lastOnlineValue,
			migrateutil.RawJSON(doc["legends"]),
			migrateutil.RawJSON(doc["donations"]),
			migrateutil.RawJSON(doc["activity"]),
			migrateutil.RawJSON(doc),
		})
		addSeasonStats(tag, doc, seasonRows)
		return len(currentRows) >= cfg.BatchSize, nil
	}, flush)
	if err != nil {
		return err
	}
	fmt.Printf("player_stats: scanned_docs=%d\n", seen)
	return nil
}

func addSeasonStats(tag string, doc bson.M, rows map[string]seasonStat) {
	clanTag := migrateutil.String(doc["clan_tag"])
	name := migrateutil.String(doc["name"])
	townhall := migrateutil.OptionalInt(doc["townhall"])
	seasons := map[string]struct{}{}
	for _, field := range []string{"donations", "clan_games", "activity", "last_online_times", "capital_gold"} {
		for season := range migrateutil.Map(doc[field]) {
			seasons[season] = struct{}{}
		}
	}
	keys := make([]string, 0, len(seasons))
	for season := range seasons {
		keys = append(keys, season)
	}
	sort.Strings(keys)
	for _, season := range keys {
		donations := migrateutil.Map(doc["donations"])[season]
		donationsMap := migrateutil.Map(donations)
		donated := firstInt(donationsMap["donated"], donationsMap["donate"], donationsMap["donations"])
		received := firstInt(donationsMap["received"], donationsMap["donationsReceived"])
		capital := migrateutil.Map(doc["capital_gold"])[season]
		capitalMap := migrateutil.Map(capital)
		capitalDonos := firstInt(capitalMap["donated"], capitalMap["donate"])
		activity := migrateutil.Map(doc["activity"])[season]
		lastOnline, _ := migrateutil.Time(migrateutil.Map(doc["last_online_times"])[season])
		var lastOnlineValue any
		if !lastOnline.IsZero() {
			lastOnlineValue = lastOnline
		}
		key := tag + "\x00" + season + "\x00" + clanTag
		rows[key] = seasonStat{playerTag: tag, season: season, clanTag: clanTag, values: []any{
			tag,
			season,
			clanTag,
			donated,
			received,
			capitalDonos,
			migrateutil.Int(activity),
			lastOnlineValue,
			name,
			townhall,
			migrateutil.RawJSON(donations),
			migrateutil.RawJSON(migrateutil.Map(doc["clan_games"])[season]),
			migrateutil.RawJSON(activity),
			migrateutil.RawJSON(map[string]any{
				"legends":         migrateutil.Map(doc["legends"])[season],
				"capital_gold":    capital,
				"attack_wins":     migrateutil.Map(doc["attack_wins"])[season],
				"season_pass":     migrateutil.Map(doc["season_pass"])[season],
				"season_trophies": migrateutil.Map(doc["season_trophies"])[season],
			}),
		}}
	}
}

func flushPlayerStats(ctx context.Context, pool interface {
	Begin(context.Context) (pgx.Tx, error)
}, current [][]any, seasons map[string]seasonStat) error {
	tx, err := pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, `
		CREATE TEMP TABLE _ck_player_current_stats (
			player_tag text, clan_tag text, name text, townhall_level int, last_online_at timestamptz,
			legends text, donations text, activity text, data text
		) ON COMMIT DROP;
		CREATE TEMP TABLE _ck_player_season_stats (
			player_tag text, season text, clan_tag text, donated int, received int, capital_gold_donos int,
			activity_score int, last_online_at timestamptz, name text, townhall_level int,
			donations text, clan_games text, activity text, data text
		) ON COMMIT DROP;
	`); err != nil {
		return err
	}
	if len(current) > 0 {
		if _, err := tx.CopyFrom(ctx, pgx.Identifier{"_ck_player_current_stats"}, []string{
			"player_tag", "clan_tag", "name", "townhall_level", "last_online_at", "legends", "donations", "activity", "data",
		}, pgx.CopyFromRows(current)); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `
			INSERT INTO player_current_stats (
				player_tag, clan_tag, name, townhall_level, last_online_at, legends, donations, activity, data
			)
			SELECT player_tag, NULLIF(clan_tag, ''), name, townhall_level, last_online_at,
				legends::jsonb, donations::jsonb, activity::jsonb, data::jsonb
			FROM _ck_player_current_stats
			WHERE player_tag <> ''
			ON CONFLICT (player_tag) DO UPDATE SET
				clan_tag = EXCLUDED.clan_tag,
				name = EXCLUDED.name,
				townhall_level = EXCLUDED.townhall_level,
				last_online_at = EXCLUDED.last_online_at,
				legends = EXCLUDED.legends,
				donations = EXCLUDED.donations,
				activity = EXCLUDED.activity,
				data = EXCLUDED.data,
				updated_at = now()
		`); err != nil {
			return err
		}
	}
	if len(seasons) > 0 {
		rows := make([][]any, 0, len(seasons))
		for _, row := range seasons {
			rows = append(rows, row.values)
		}
		if _, err := tx.CopyFrom(ctx, pgx.Identifier{"_ck_player_season_stats"}, []string{
			"player_tag", "season", "clan_tag", "donated", "received", "capital_gold_donos",
			"activity_score", "last_online_at", "name", "townhall_level", "donations", "clan_games", "activity", "data",
		}, pgx.CopyFromRows(rows)); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `
			INSERT INTO player_season_stats (
				player_tag, season, clan_tag, donated, received, capital_gold_donos,
				activity_score, last_online_at, name, townhall_level, donations, clan_games, activity, data
			)
			SELECT player_tag, season, clan_tag, donated, received, capital_gold_donos,
				activity_score, last_online_at, name, townhall_level,
				donations::jsonb, clan_games::jsonb, activity::jsonb, data::jsonb
			FROM _ck_player_season_stats
			WHERE player_tag <> '' AND season <> ''
			ON CONFLICT (player_tag, season, clan_tag) DO UPDATE SET
				donated = EXCLUDED.donated,
				received = EXCLUDED.received,
				capital_gold_donos = EXCLUDED.capital_gold_donos,
				activity_score = EXCLUDED.activity_score,
				last_online_at = EXCLUDED.last_online_at,
				name = EXCLUDED.name,
				townhall_level = EXCLUDED.townhall_level,
				donations = EXCLUDED.donations,
				clan_games = EXCLUDED.clan_games,
				activity = EXCLUDED.activity,
				data = EXCLUDED.data,
				updated_at = now()
		`); err != nil {
			return err
		}
	}
	return tx.Commit(ctx)
}

func firstInt(values ...any) int {
	for _, value := range values {
		if out := migrateutil.Int(value); out != 0 {
			return out
		}
	}
	return 0
}
