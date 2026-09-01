package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestTimescaleMigrationsAreExplicitlyNumbered(t *testing.T) {
	files, err := filepath.Glob("../timescale/*.sql")
	if err != nil {
		t.Fatal(err)
	}
	want := []string{
		"001_initial_stats.sql",
		"002_initial_settings.sql",
		"003_tracking_observability.sql",
		"004_developer_link_grants.sql",
	}
	if len(files) != len(want) {
		t.Fatalf("Timescale migrations = %v, want %v", files, want)
	}
	for index := range want {
		if filepath.Base(files[index]) != want[index] {
			t.Fatalf("Timescale migrations = %v, want %v", files, want)
		}
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
		"war_id integer default nextval('public.war_id_seq'::regclass) not null",
		"start_time timestamp with time zone not null",
		"archive_pack_id bigint",
		"archive_offset bigint",
		"archive_compressed_bytes integer",
		"wars_archive_locator_check",
		"archive_offset is not null",
		"archive_compressed_bytes is not null",
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
	playerHistory := strings.ToLower(baselineTableDDL(t, string(raw), "player_war_history"))
	if !strings.Contains(playerHistory, "war_ids integer[]") {
		t.Error("player_war_history does not use compact integer war IDs")
	}
	for _, table := range []string{"war_archive_pending", "war_schedule"} {
		ddl := strings.ToLower(baselineTableDDL(t, string(raw), table))
		if !strings.Contains(ddl, "war_id integer") {
			t.Errorf("%s does not use the shared integer war ID", table)
		}
	}
	packs := strings.ToLower(baselineTableDDL(t, string(raw), "war_archive_packs"))
	for _, required := range []string{"checkpoint_key text", "source_checkpoint text"} {
		if !strings.Contains(packs, required) {
			t.Errorf("war_archive_packs baseline missing %q", required)
		}
	}
	if !strings.Contains(migration, "idx_war_archive_packs_migration_checkpoint") {
		t.Error("war archive migration checkpoints are not uniquely indexed")
	}
	if !strings.Contains(migration, "create sequence public.war_id_seq as integer") ||
		!strings.Contains(migration, "alter sequence public.war_id_seq owned by public.wars.war_id") {
		t.Error("war ID sequence is missing or is not owned by wars.war_id")
	}
	if strings.Contains(playerHistory, "updated_at") {
		t.Error("player_war_history retains unused updated_at column")
	}
	if !strings.Contains(migration, "primary key (player_tag)") {
		t.Error("player war history does not use player_tag as its sole primary key")
	}
	if strings.Contains(playerHistory, "period_start") {
		t.Error("player_war_history retains period_start")
	}
	if strings.Contains(migration, "foreign key (archive_pack_id) references public.war_archive_packs(pack_id)") {
		t.Error("wars archive locator retains the high-contention pack foreign key")
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
