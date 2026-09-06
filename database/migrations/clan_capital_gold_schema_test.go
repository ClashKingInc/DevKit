package main

import (
	"os"
	"strings"
	"testing"
)

func TestClanCapitalGoldMigrationStoresAndRanksTotal(t *testing.T) {
	raw, err := os.ReadFile("../timescale/009_clan_capital_gold.sql")
	if err != nil {
		t.Fatal(err)
	}
	migration := strings.ToLower(string(raw))
	for _, required := range []string{
		"add column capital_gold_total bigint default 0 not null",
		"order by capital_gold_total desc, tag",
		"as capital_gold_rank",
		"partition by location_id order by capital_gold_total desc, tag",
		"as location_capital_gold_rank",
		"idx_clan_leaderboards_capital_gold_rank",
		"idx_clan_leaderboards_location_capital_gold_rank",
	} {
		if !strings.Contains(migration, required) {
			t.Errorf("clan capital gold migration missing %q", required)
		}
	}

	if got := strings.Count(migration, "refresh materialized view public.clan_leaderboards"); got != 2 {
		t.Errorf("clan capital gold migration refresh count = %d, want 2", got)
	}
}
