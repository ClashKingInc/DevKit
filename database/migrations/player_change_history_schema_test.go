package main

import (
	"os"
	"strings"
	"testing"
)

func TestPlayerChangeHistoryBaselineIsCompactAndNormalized(t *testing.T) {
	raw, err := os.ReadFile("../timescale/001_initial_stats.sql")
	if err != nil {
		t.Fatal(err)
	}
	migration := strings.ToLower(string(raw))
	ddl := strings.ToLower(baselineTableDDL(t, string(raw), "player_change_history"))
	for _, required := range []string{
		"event_time timestamp with time zone not null",
		"player_tag text not null",
		"change_type smallint not null",
		"item_id smallint",
		"townhall_level smallint",
		"previous_value text not null",
		"current_value text not null",
		"change_type >= 1",
		"change_type <= 12",
	} {
		if !strings.Contains(ddl, required) {
			t.Errorf("player_change_history baseline missing %q", required)
		}
	}
	for _, removed := range []string{"clan_tag", "jsonb", "change_type text", "default 0"} {
		if strings.Contains(ddl, removed) {
			t.Errorf("player_change_history retains %q", removed)
		}
	}
	if !strings.Contains(migration, "'player_change_history',\n    'event_time',\n    chunk_time_interval => interval '3 months'") {
		t.Error("player_change_history is not configured with three-month Timescale chunks")
	}
	if !strings.Contains(migration, "idx_player_change_history_player_type_time") ||
		strings.Contains(migration, "create index idx_player_change_history_type_time") ||
		strings.Contains(migration, "create index player_change_history_event_time_idx") {
		t.Error("player_change_history has the wrong secondary indexes")
	}
	if strings.Contains(migration, "add_compression_policy(\n    'player_change_history'") ||
		strings.Contains(migration, "alter table public.player_change_history set (\n    timescaledb.compress") {
		t.Error("player_change_history must remain a plain hypertable without compression/Hypercore configuration")
	}
}
