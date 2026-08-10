package main

import (
	"os"
	"strings"
	"testing"
)

func TestAutoboardsBaselineContract(t *testing.T) {
	raw, err := os.ReadFile("../timescale/002_initial_settings.sql")
	if err != nil {
		t.Fatal(err)
	}
	up := strings.SplitN(string(raw), "-- +goose Down", 2)[0]
	autoboards := baselineTableDDL(t, up, "autoboards")
	targets := baselineTableDDL(t, up, "autoboard_targets")
	contract := autoboards + targets + up

	required := []string{
		"CREATE TABLE public.autoboards (",
		"board_type text NOT NULL",
		"target_scope text NOT NULL",
		"delivery_mode text NOT NULL",
		"webhook_id text NOT NULL",
		"thread_id text",
		"message_id text",
		"interval_minutes integer",
		"schedule_kind text",
		"schedule_time time without time zone",
		"schedule_weekdays smallint[]",
		"schedule_day_of_month smallint",
		"next_run_at timestamp with time zone",
		"last_run_at timestamp with time zone",
		"CREATE TABLE public.autoboard_targets (",
		"\"position\" integer NOT NULL",
		"target text NOT NULL",
		"PRIMARY KEY (autoboard_id, target)",
		"UNIQUE (autoboard_id, \"position\")",
		"delivery_mode = 'refresh'",
		"delivery_mode = 'send'",
		"schedule_kind = 'daily'",
		"schedule_kind = 'weekdays'",
		"schedule_kind = 'day_of_month'",
		"CREATE INDEX idx_autoboards_refresh_due",
		"CREATE INDEX idx_autoboards_send_due",
	}
	for _, fragment := range required {
		if !strings.Contains(contract, fragment) {
			t.Errorf("autoboard baseline contract missing %q", fragment)
		}
	}

	forbidden := []string{
		"data jsonb",
		"button_id",
		"locale",
		"channel_id",
		" tag text",
	}
	for _, fragment := range forbidden {
		if strings.Contains(autoboards+targets, fragment) {
			t.Errorf("autoboard baseline contract contains retired %q", fragment)
		}
	}
}

func baselineTableDDL(t *testing.T, migration, table string) string {
	t.Helper()
	start := strings.Index(migration, "CREATE TABLE public."+table+" (")
	if start < 0 {
		t.Fatalf("baseline is missing table %s", table)
	}
	end := strings.Index(migration[start:], "\n);\n")
	if end < 0 {
		t.Fatalf("baseline table %s has no closing delimiter", table)
	}
	return migration[start : start+end+4]
}

func TestBotSettingsImporterDoesNotBackfillLegacyAutoboards(t *testing.T) {
	raw, err := os.ReadFile("bot_server_settings.go")
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(raw), `Collection("autoboards")`) {
		t.Fatal("legacy Mongo autoboards must not be imported into the clean-break schema")
	}
}
