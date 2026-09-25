package main

import (
	"os"
	"strings"
	"testing"
)

func TestLegendDailyMetadataMigrationIsAdditive(t *testing.T) {
	raw, err := os.ReadFile("../timescale/030_legend_daily_metadata.sql")
	if err != nil {
		t.Fatal(err)
	}
	sql := string(raw)
	for _, expected := range []string{
		"'top_200','top_100'",
		"ADD COLUMN troop_stats jsonb NOT NULL DEFAULT '[]'::jsonb",
		"ADD COLUMN spell_stats jsonb NOT NULL DEFAULT '[]'::jsonb",
		"ADD COLUMN siege_stats jsonb NOT NULL DEFAULT '[]'::jsonb",
		"ADD COLUMN equipment_pair_stats jsonb NOT NULL DEFAULT '[]'::jsonb",
		"equipment_pair_usage_triples_within_attack_count",
	} {
		if !strings.Contains(sql, expected) {
			t.Fatalf("migration is missing %q", expected)
		}
	}
	petRaw, err := os.ReadFile("../timescale/031_legend_daily_pet_combos.sql")
	if err != nil {
		t.Fatal(err)
	}
	for _, expected := range []string{"ADD COLUMN pet_combo_stats jsonb NOT NULL DEFAULT '[]'::jsonb", "pet_combo_usage_triples_within_attack_count"} {
		if !strings.Contains(string(petRaw), expected) {
			t.Fatalf("migration 031 is missing %q", expected)
		}
	}
}
