package main

import (
	"os"
	"strings"
	"testing"
)

func TestPlayerRankingsCurrentAllowsRetainedLocationWithoutPlacement(t *testing.T) {
	raw, err := os.ReadFile("../timescale/001_initial_stats.sql")
	if err != nil {
		t.Fatal(err)
	}
	ddl := strings.ToLower(baselineTableDDL(t, string(raw), "player_rankings_current"))
	for _, required := range []string{
		"location_id text not null",
		"rank integer",
		"points integer",
		"rank is null",
		"points is null",
		"rank is not null",
		"points is null",
	} {
		if !strings.Contains(ddl, required) {
			t.Errorf("player_rankings_current baseline missing %q", required)
		}
	}
	if strings.Contains(ddl, "points is not null") {
		t.Error("player ranking still requires legacy documents to invent points")
	}
}
