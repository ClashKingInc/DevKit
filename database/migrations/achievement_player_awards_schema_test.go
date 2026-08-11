package main

import (
	"os"
	"strings"
	"testing"
)

func TestAchievementPlayerAwardsSchema(t *testing.T) {
	t.Parallel()

	contents, err := os.ReadFile("../timescale/002_initial_settings.sql")
	if err != nil {
		t.Fatalf("read settings baseline: %v", err)
	}

	sql := strings.ToLower(string(contents))
	table := strings.ToLower(baselineTableDDL(t, string(contents), "achievement_player_awards"))
	for _, fragment := range []string{
		"achievement_id text not null",
		"player_tag text not null",
		"occurrence_key text default 'lifetime'::text not null",
		"earned_at timestamp with time zone default now() not null",
		"achievement_player_awards_achievement_id_check",
		"achievement_player_awards_occurrence_key_check",
	} {
		if !strings.Contains(table, fragment) {
			t.Errorf("achievement awards table is missing %q", fragment)
		}
	}

	for _, fragment := range []string{
		"primary key (achievement_id, player_tag, occurrence_key)",
		"references public.player_links(tag)",
		"on delete cascade",
		"idx_achievement_player_awards_player_tag",
	} {
		if !strings.Contains(sql, fragment) {
			t.Errorf("settings baseline is missing %q", fragment)
		}
	}

	for _, excluded := range []string{"source", "observed_value", "legend_league_battles"} {
		if strings.Contains(table, excluded) {
			t.Errorf("achievement awards table unexpectedly contains %q", excluded)
		}
	}
}
