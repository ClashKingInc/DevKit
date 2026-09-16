package schema

import (
	"context"
	"os"
	"testing"

	"github.com/jackc/pgx/v5"
)

func TestCWLSeasonStatisticsRemoved(t *testing.T) {
	if os.Getenv("CLASHKING_DISPOSABLE_TIMESCALE") != "1" {
		t.Skip("requires disposable Timescale fixture")
	}
	if os.Getenv("CLASHKING_TIMESCALE_PROFILE") != "retained-api" {
		t.Skip("requires retained-api migration profile")
	}
	ctx := context.Background()
	conn, err := pgx.Connect(ctx, os.Getenv("TEST_DATABASE_URL"))
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close(ctx)
	var valid bool
	err = conn.QueryRow(ctx, `SELECT
 to_regclass('public.cwl_season_statistics') IS NULL
 AND to_regprocedure('public.reconcile_cwl_season_statistics(text[])') IS NULL
 AND to_regprocedure('public.cwl_town_halls_valid(jsonb)') IS NULL
 AND to_regclass('public.cwl_groups') IS NOT NULL
 AND to_regclass('public.cwl_group_clans') IS NOT NULL
 AND to_regclass('public.cwl_group_members') IS NOT NULL
 AND to_regclass('public.league_hitrate_stats') IS NOT NULL
 AND to_regclass('public.ranked_league_tier_stats') IS NOT NULL
 AND to_regclass('public.legend_daily_stats') IS NOT NULL`).Scan(&valid)
	if err != nil {
		t.Fatal(err)
	}
	if !valid {
		t.Fatal("CWL season-statistics objects remain or retained source/analytics tables are missing")
	}
}
