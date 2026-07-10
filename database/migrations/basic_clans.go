//go:build ignore

package main

import (
	"context"
	"fmt"

	"clashking_devkit_database_migrations/migrateutil"
	"github.com/jackc/pgx/v5"
	"go.mongodb.org/mongo-driver/v2/bson"
)

type clanRow struct {
	values []any
}

func main() {
	migrateutil.Main("basic_clans", runBasicClans)
}

func runBasicClans(ctx context.Context, cfg migrateutil.Config) error {
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
	cp, err := migrateutil.LoadCheckpoint(cfg, "basic_clans")
	if err != nil {
		return err
	}

	clans := make([]clanRow, 0, cfg.BatchSize)
	flush := func() error {
		if len(clans) == 0 {
			return nil
		}
		if err := flushBasicClans(ctx, pool, clans); err != nil {
			return err
		}
		clans = clans[:0]
		return nil
	}

	projection := bson.D{
		{Key: "tag", Value: 1},
		{Key: "name", Value: 1},
		{Key: "description", Value: 1},
		{Key: "clanLevel", Value: 1},
		{Key: "level", Value: 1},
		{Key: "location", Value: 1},
		{Key: "warLeague", Value: 1},
		{Key: "capitalLeague", Value: 1},
		{Key: "isWarLogPublic", Value: 1},
		{Key: "publicWarLog", Value: 1},
		{Key: "warWins", Value: 1},
		{Key: "warWinStreak", Value: 1},
		{Key: "clanPoints", Value: 1},
		{Key: "members", Value: 1},
		{Key: "member_count", Value: 1},
		{Key: "badgeUrls", Value: 1},
		{Key: "badge_url", Value: 1},
	}
	seen, err := migrateutil.StreamByObjectIDProjected(
		ctx,
		cfg,
		cp,
		"clan_tags_id",
		mongoClient.Database("looper").Collection("clan_tags"),
		projection,
		func(doc bson.M) (bool, error) {
			tag := migrateutil.String(first(doc["tag"], doc["_id"]))
			if tag == "" {
				return false, nil
			}
			location := migrateutil.Map(doc["location"])
			warLeague := migrateutil.Map(doc["warLeague"])
			capitalLeague := migrateutil.Map(doc["capitalLeague"])
			badge := migrateutil.Map(doc["badgeUrls"])
			cwlID := firstInt(warLeague["id"], doc["warLeagueID"], doc["cwl_league_id"])
			if cwlID == 0 {
				cwlID = 48000000
			}
			clans = append(clans, clanRow{values: []any{
				tag,
				firstString(doc["name"], tag),
				migrateutil.String(doc["description"]),
				firstInt(doc["clanLevel"], doc["level"]),
				migrateutil.OptionalInt(location["id"]),
				cwlID,
				migrateutil.OptionalInt(first(capitalLeague["id"], doc["capitalLeagueID"])),
				firstBool(doc["isWarLogPublic"], doc["publicWarLog"]),
				migrateutil.Int(doc["warWins"]),
				migrateutil.Int(doc["warWinStreak"]),
				migrateutil.Int(doc["clanPoints"]),
				firstInt(doc["members"], doc["member_count"]),
				migrateutil.BadgeToken(doc["badge_url"], badge["large"], badge["medium"], badge["small"]),
				0,
				0,
				"[]",
			}})
			return len(clans) >= cfg.BatchSize, nil
		},
		flush,
	)
	if err != nil {
		return err
	}
	fmt.Printf("basic_clans: scanned_docs=%d\n", seen)
	return nil
}

func flushBasicClans(ctx context.Context, pool interface {
	Begin(context.Context) (pgx.Tx, error)
}, clans []clanRow) error {
	tx, err := pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, `
		CREATE TEMP TABLE _ck_basic_clan (
			tag text, name text, description text, clan_level int, location_id int,
			cwl_league_id int, capital_league_id int, public_war_log bool,
			war_wins int, war_win_streak int, clan_points int, member_count int,
			badge_token text, troops_donated int, troops_received int, members text
		) ON COMMIT DROP;
	`); err != nil {
		return err
	}
	rows := make([][]any, 0, len(clans))
	for _, row := range clans {
		rows = append(rows, row.values)
	}
	if _, err := tx.CopyFrom(ctx, pgx.Identifier{"_ck_basic_clan"}, []string{
		"tag", "name", "description", "clan_level", "location_id", "cwl_league_id",
		"capital_league_id", "public_war_log", "war_wins", "war_win_streak",
		"clan_points", "member_count", "badge_token", "troops_donated", "troops_received",
		"members",
	}, pgx.CopyFromRows(rows)); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `
		INSERT INTO basic_clan (
			tag, name, description, clan_level, location_id, cwl_league_id, capital_league_id,
			public_war_log, war_wins, war_win_streak, clan_points, member_count,
			badge_token, troops_donated, troops_received, members
		)
		SELECT tag, name, description, clan_level, location_id, cwl_league_id, capital_league_id,
			public_war_log, war_wins, war_win_streak, clan_points, member_count,
			badge_token, troops_donated, troops_received, members::jsonb
		FROM _ck_basic_clan
		WHERE tag <> '' AND name <> ''
		ON CONFLICT (tag) DO NOTHING
	`); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

func first(values ...any) any {
	for _, value := range values {
		if migrateutil.String(value) != "" {
			return value
		}
	}
	return nil
}

func firstString(values ...any) string {
	return migrateutil.String(first(values...))
}

func firstInt(values ...any) int {
	for _, value := range values {
		if out := migrateutil.Int(value); out != 0 {
			return out
		}
	}
	return 0
}

func firstBool(values ...any) bool {
	for _, value := range values {
		if out, ok := value.(bool); ok {
			return out
		}
		if migrateutil.String(value) != "" {
			return migrateutil.Bool(value)
		}
	}
	return false
}
