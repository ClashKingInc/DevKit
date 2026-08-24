package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestTimescaleKeepsTwoConsolidatedMigrations(t *testing.T) {
	files, err := filepath.Glob("../timescale/*.sql")
	if err != nil {
		t.Fatal(err)
	}
	if len(files) != 2 || filepath.Base(files[0]) != "001_initial_stats.sql" || filepath.Base(files[1]) != "002_initial_settings.sql" {
		t.Fatalf("Timescale migrations = %v, want only 001_initial_stats.sql and 002_initial_settings.sql", files)
	}
}

func TestWarArchiveBaseline(t *testing.T) {
	raw, err := os.ReadFile("../timescale/001_initial_stats.sql")
	if err != nil {
		t.Fatal(err)
	}
	migration := strings.ToLower(string(raw))
	wars := strings.ToLower(baselineTableDDL(t, string(raw), "wars"))
	for _, required := range []string{
		"war_id uuid not null",
		"archive_pack_id bigint",
		"archive_offset bigint",
		"archive_compressed_bytes integer",
		"wars_archive_locator_check",
		"wars_battle_modifier_check",
		"'hardmode'::text",
		"'minusone'::text",
		"'minustwo'::text",
		"'minusthree'::text",
	} {
		if !strings.Contains(wars, required) {
			t.Errorf("wars baseline missing %q", required)
		}
	}
	for _, table := range []string{"war_archive_pending", "war_archive_packs", "player_war_history"} {
		baselineTableDDL(t, string(raw), table)
	}
	for _, required := range []string{
		"primary key (player_tag, period_start)",
		"player_war_history_quarter_check",
		"foreign key (archive_pack_id) references public.war_archive_packs(pack_id)",
	} {
		if !strings.Contains(migration, required) {
			t.Errorf("war archive baseline missing %q", required)
		}
	}
	for _, removed := range []string{
		"create table public.war_members",
		"create table public.war_attacks",
		"create table public.war_missed_attacks",
	} {
		if strings.Contains(migration, removed) {
			t.Errorf("war archive baseline retains removed table declaration %q", removed)
		}
	}
}
