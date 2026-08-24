//go:build ignore

package main

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/ClashKingInc/DevKit/database/migrations/migrateutil"
	"github.com/jackc/pgx/v5"
	"go.mongodb.org/mongo-driver/v2/bson"
)

const cwlUnrankedLeagueID = 48000000

var cwlLeagueIDsByName = map[string]int{
	"Unranked":            cwlUnrankedLeagueID,
	"Bronze League III":   48000001,
	"Bronze League II":    48000002,
	"Bronze League I":     48000003,
	"Silver League III":   48000004,
	"Silver League II":    48000005,
	"Silver League I":     48000006,
	"Gold League III":     48000007,
	"Gold League II":      48000008,
	"Gold League I":       48000009,
	"Crystal League III":  48000010,
	"Crystal League II":   48000011,
	"Crystal League I":    48000012,
	"Master League III":   48000013,
	"Master League II":    48000014,
	"Master League I":     48000015,
	"Champion League III": 48000016,
	"Champion League II":  48000017,
	"Champion League I":   48000018,
	"Titan League III":    48000019,
	"Titan League II":     48000020,
	"Titan League I":      48000021,
	"Legend League":       48000022,
}

type cwlLeagueHistoryRow struct {
	clanTag string
	seasons map[string]int
}

func main() {
	migrateutil.Main("cwl_league_history", runCWLLeagueHistory)
}

func runCWLLeagueHistory(ctx context.Context, cfg migrateutil.Config) error {
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

	if _, err := pool.Exec(ctx, `TRUNCATE TABLE public.cwl_league_history`); err != nil {
		return err
	}
	rows := make(map[string]cwlLeagueHistoryRow, cfg.BatchSize)
	var writtenRows int64
	flush := func() error {
		if len(rows) == 0 {
			return nil
		}
		written, err := flushCWLLeagueHistoryRows(ctx, pool, rows)
		if err != nil {
			return err
		}
		writtenRows += written
		rows = make(map[string]cwlLeagueHistoryRow, cfg.BatchSize)
		return nil
	}
	seen, err := migrateutil.StreamAllProjected(
		ctx,
		cfg,
		"cwl_league_history",
		mongoClient.Database("ranking_history").Collection("league_history"),
		bson.D{
			{Key: "_id", Value: 0},
			{Key: "tag", Value: 1},
			{Key: "changes.clanWarLeague", Value: 1},
		},
		func(doc bson.M) (bool, error) {
			row, ok, err := cwlLeagueHistoryFromDocument(doc)
			if err != nil {
				return false, err
			}
			if ok {
				if existing, exists := rows[row.clanTag]; exists {
					for season, leagueID := range row.seasons {
						existing.seasons[season] = leagueID
					}
					rows[row.clanTag] = existing
				} else {
					rows[row.clanTag] = row
				}
			}
			return len(rows) >= cfg.BatchSize, nil
		},
		flush,
	)
	if err != nil {
		return err
	}
	fmt.Printf("cwl league history: scanned_docs=%d clan_rows=%d\n", seen, writtenRows)
	return nil
}

func cwlLeagueHistoryFromDocument(doc bson.M) (cwlLeagueHistoryRow, bool, error) {
	clanTag := migrateutil.String(doc["tag"])
	history := migrateutil.Map(migrateutil.Map(doc["changes"])["clanWarLeague"])
	if clanTag == "" || len(history) == 0 {
		return cwlLeagueHistoryRow{}, false, nil
	}
	seasons := make(map[string]int, len(history))
	for recordedSeason, rawChange := range history {
		playedSeason, ok := shiftedCWLSeason(recordedSeason)
		if !ok {
			continue
		}
		leagueName := migrateutil.String(migrateutil.Map(rawChange)["league"])
		leagueID, ok := cwlLeagueIDsByName[leagueName]
		if !ok {
			return cwlLeagueHistoryRow{}, false, fmt.Errorf("unknown CWL league %q for clan %s season %s", leagueName, clanTag, recordedSeason)
		}
		seasons[playedSeason] = leagueID
	}
	if len(seasons) == 0 {
		return cwlLeagueHistoryRow{}, false, nil
	}
	return cwlLeagueHistoryRow{clanTag: clanTag, seasons: seasons}, true, nil
}

func shiftedCWLSeason(value string) (string, bool) {
	season, err := time.Parse("2006-01", value)
	if err != nil {
		return "", false
	}
	return season.AddDate(0, 1, 0).Format("2006-01"), true
}

func flushCWLLeagueHistoryRows(ctx context.Context, pool interface {
	Begin(context.Context) (pgx.Tx, error)
}, rows map[string]cwlLeagueHistoryRow) (int64, error) {
	tx, err := pool.Begin(ctx)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, `
		CREATE TEMP TABLE _ck_cwl_league_history (
			clan_tag text,
			seasons text
		) ON COMMIT DROP
	`); err != nil {
		return 0, err
	}
	copyRows := make([][]any, 0, len(rows))
	for _, row := range rows {
		encoded, err := json.Marshal(row.seasons)
		if err != nil {
			return 0, err
		}
		copyRows = append(copyRows, []any{row.clanTag, string(encoded)})
	}
	if _, err := tx.CopyFrom(ctx, pgx.Identifier{"_ck_cwl_league_history"}, []string{"clan_tag", "seasons"}, pgx.CopyFromRows(copyRows)); err != nil {
		return 0, err
	}
	command, err := tx.Exec(ctx, `
		INSERT INTO public.cwl_league_history (clan_tag, seasons)
		SELECT clan_tag, seasons::jsonb
		FROM _ck_cwl_league_history
		ON CONFLICT (clan_tag) DO UPDATE
		SET seasons = public.cwl_league_history.seasons || EXCLUDED.seasons
	`)
	if err != nil {
		return 0, err
	}
	if err := tx.Commit(ctx); err != nil {
		return 0, err
	}
	return command.RowsAffected(), nil
}
