//go:build ignore

package main

import (
	"context"
	"fmt"

	"clashking_devkit_database_migrations/migrateutil"
	"github.com/jackc/pgx/v5"
	"go.mongodb.org/mongo-driver/v2/bson"
)

type legendHistoryRow struct {
	season         string
	playerTag      string
	playerName     string
	expLevel       int
	trophies       int
	attackWins     int
	defenseWins    int
	rank           int
	clanTag        any
	clanName       any
	clanBadgeToken any
	leagueTierID   any
}

func main() {
	migrateutil.Main("legend_history", runLegendHistory)
}

func runLegendHistory(ctx context.Context, cfg migrateutil.Config) error {
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

	plan := legendHistoryOneShotPlan()
	if err := migrateutil.StartOneShot(ctx, pool, plan); err != nil {
		return err
	}

	rows := make(map[string]legendHistoryRow, cfg.BatchSize)
	var writtenRows int64
	flush := func() error {
		if len(rows) == 0 {
			return nil
		}
		written, err := flushLegendHistoryRows(ctx, pool, rows)
		if err != nil {
			return err
		}
		writtenRows += written
		rows = make(map[string]legendHistoryRow, cfg.BatchSize)
		return nil
	}
	seen, err := migrateutil.StreamAllProjected(
		ctx,
		cfg,
		"legend_history",
		mongoClient.Database("looper").Collection("legend_history"),
		bson.D{{Key: "_id", Value: 0}},
		func(doc bson.M) (bool, error) {
			row, ok := legendRowFromDocument(doc)
			if ok {
				rows[legendHistoryRowKey(row)] = row
			}
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
	fmt.Printf("legend_history: scanned_docs=%d rows=%d\n", seen, writtenRows)
	return nil
}

func legendHistoryOneShotPlan() migrateutil.OneShotPlan {
	return migrateutil.OneShotPlan{
		ResetSQL: []string{`TRUNCATE TABLE public.legend_history`},
		DropIndexes: []string{
			`DROP INDEX IF EXISTS public.idx_legend_history_season_rank`,
			`DROP INDEX IF EXISTS public.idx_legend_history_player_season`,
			`DROP INDEX IF EXISTS public.idx_legend_history_clan_rank`,
		},
		CreateIndexes: []string{
			`CREATE INDEX idx_legend_history_season_rank ON public.legend_history (season, rank)`,
			`CREATE INDEX idx_legend_history_player_season ON public.legend_history (player_tag, season DESC)`,
			`CREATE INDEX idx_legend_history_clan_rank ON public.legend_history (clan_tag, rank, season DESC) WHERE clan_tag IS NOT NULL`,
		},
	}
}

func legendRowFromDocument(doc bson.M) (legendHistoryRow, bool) {
	season := migrateutil.String(doc["season"])
	playerTag := migrateutil.String(doc["tag"])
	playerName := migrateutil.String(doc["name"])
	expLevel := migrateutil.Int(doc["expLevel"])
	attackWins := migrateutil.Int(doc["attackWins"])
	defenseWins := migrateutil.Int(doc["defenseWins"])
	rank := migrateutil.Int(doc["rank"])
	trophies := migrateutil.Int(doc["trophies"])
	if season == "" ||
		playerTag == "" ||
		playerName == "" ||
		expLevel < 0 ||
		attackWins < 0 ||
		defenseWins < 0 ||
		rank <= 0 ||
		trophies < 0 {
		return legendHistoryRow{}, false
	}

	var clanTag any
	var clanName any
	var clanBadgeToken any
	if clan := migrateutil.Map(doc["clan"]); clan != nil {
		tag := migrateutil.String(clan["tag"])
		name := migrateutil.String(clan["name"])
		badgeURLs := migrateutil.Map(clan["badgeUrls"])
		badgeToken := migrateutil.BadgeToken(
			clan["badgeToken"],
			badgeURLs["large"],
			badgeURLs["medium"],
			badgeURLs["small"],
		)
		if tag == "" || name == "" || badgeToken == "" {
			return legendHistoryRow{}, false
		}
		clanTag = tag
		clanName = name
		clanBadgeToken = badgeToken
	}
	leagueTierID := migrateutil.OptionalInt(migrateutil.Map(doc["leagueTier"])["id"])
	return legendHistoryRow{
		season:         season,
		playerTag:      playerTag,
		playerName:     playerName,
		expLevel:       expLevel,
		trophies:       trophies,
		attackWins:     attackWins,
		defenseWins:    defenseWins,
		rank:           rank,
		clanTag:        clanTag,
		clanName:       clanName,
		clanBadgeToken: clanBadgeToken,
		leagueTierID:   leagueTierID,
	}, true
}

func legendHistoryRowKey(row legendHistoryRow) string {
	return row.season + "\x00" + row.playerTag
}

func flushLegendHistoryRows(ctx context.Context, pool interface {
	Begin(context.Context) (pgx.Tx, error)
}, rows map[string]legendHistoryRow) (int64, error) {
	tx, err := pool.Begin(ctx)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, `
		CREATE TEMP TABLE _ck_legend_history (
			season text,
			player_tag text,
			player_name text,
			exp_level integer,
			trophies integer,
			attack_wins integer,
			defense_wins integer,
			rank integer,
			clan_tag text,
			clan_name text,
			clan_badge_token text,
			league_tier_id integer
		) ON COMMIT DROP
	`); err != nil {
		return 0, err
	}
	copyRows := make([][]any, 0, len(rows))
	for _, row := range rows {
		copyRows = append(copyRows, []any{
			row.season,
			row.playerTag,
			row.playerName,
			row.expLevel,
			row.trophies,
			row.attackWins,
			row.defenseWins,
			row.rank,
			row.clanTag,
			row.clanName,
			row.clanBadgeToken,
			row.leagueTierID,
		})
	}
	if _, err := tx.CopyFrom(
		ctx,
		pgx.Identifier{"_ck_legend_history"},
		[]string{
			"season",
			"player_tag",
			"player_name",
			"exp_level",
			"trophies",
			"attack_wins",
			"defense_wins",
			"rank",
			"clan_tag",
			"clan_name",
			"clan_badge_token",
			"league_tier_id",
		},
		pgx.CopyFromRows(copyRows),
	); err != nil {
		return 0, err
	}
	if _, err := tx.Exec(ctx, `
		INSERT INTO public.legend_history (
			season, player_tag, player_name, exp_level, trophies,
			attack_wins, defense_wins, rank, clan_tag, clan_name,
			clan_badge_token, league_tier_id
		)
		SELECT season, player_tag, player_name, exp_level, trophies,
			attack_wins, defense_wins, rank, clan_tag, clan_name,
			clan_badge_token, league_tier_id
		FROM _ck_legend_history
		ON CONFLICT (season, player_tag) DO UPDATE SET
			player_name = EXCLUDED.player_name,
			exp_level = EXCLUDED.exp_level,
			rank = EXCLUDED.rank,
			trophies = EXCLUDED.trophies,
			attack_wins = EXCLUDED.attack_wins,
			defense_wins = EXCLUDED.defense_wins,
			clan_tag = EXCLUDED.clan_tag,
			clan_name = EXCLUDED.clan_name,
			clan_badge_token = EXCLUDED.clan_badge_token,
			league_tier_id = EXCLUDED.league_tier_id
	`); err != nil {
		return 0, err
	}
	if err := tx.Commit(ctx); err != nil {
		return 0, err
	}
	return int64(len(rows)), nil
}
