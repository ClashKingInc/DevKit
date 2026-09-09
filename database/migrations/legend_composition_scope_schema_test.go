package main

import (
	"os"
	"strings"
	"testing"
)

func TestLegendCompositionMigrationPreservesRawHistoryAndFamilyGuards(t *testing.T) {
	data, err := os.ReadFile("../timescale/012_legend_only_army_compositions.sql")
	if err != nil {
		t.Fatal(err)
	}
	up := strings.Split(string(data), "-- +goose Down")[0]
	for _, required := range []string{"DROP CONSTRAINT battles_ranked_army_hash_fkey", "DROP CONSTRAINT battles_ranked_share_code_hash_fkey", "BEFORE UPDATE ON public.army_compositions", "lock_timeout = '5s'"} {
		if !strings.Contains(up, required) {
			t.Fatalf("missing %s", required)
		}
	}
	for _, forbidden := range []string{"DELETE FROM", "TRUNCATE TABLE", "DROP TABLE", "DROP COLUMN", "ALTER TABLE public.army_families", "ALTER TABLE public.army_family_members", "DROP TRIGGER army_compositions_no_truncate"} {
		if strings.Contains(up, forbidden) {
			t.Fatalf("unexpected destructive operation: %s", forbidden)
		}
	}
}
