package main

import (
	"context"
	"os"
	"testing"

	"github.com/jackc/pgx/v5"
)

func TestDailyAnalyticsUsageConstraints(t *testing.T) {
	if os.Getenv("CLASHKING_DISPOSABLE_TIMESCALE") != "1" || os.Getenv("TEST_DATABASE_URL") == "" {
		t.Skip("requires disposable authoritative Goose schema")
	}
	conn, err := pgx.Connect(t.Context(), os.Getenv("TEST_DATABASE_URL"))
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close(context.Background())
	for _, tc := range []struct {
		name, function, value string
		want                  bool
	}{
		{"valid pet combinations", "pet_combo_usage_triples_within_attack_count", `[{"petIds":[1,2],"uses":2,"triples":1},{"petIds":[2,3],"uses":3,"triples":2}]`, true},
		{"duplicate pet combination", "pet_combo_usage_triples_within_attack_count", `[{"petIds":[1,2],"uses":2,"triples":1},{"petIds":[1,2],"uses":2,"triples":1}]`, false},
		{"unordered pet combinations", "pet_combo_usage_triples_within_attack_count", `[{"petIds":[2,3],"uses":1,"triples":0},{"petIds":[1,2],"uses":1,"triples":0}]`, false},
		{"overcounted pet combinations", "pet_combo_usage_triples_within_attack_count", `[{"petIds":[1],"uses":3,"triples":0},{"petIds":[2],"uses":3,"triples":0}]`, false},
		{"valid siege usage", "army_setup_siege_usage_within_attack_count", `[{"id":1,"attacks":2},{"id":2,"attacks":3}]`, true},
		{"malformed siege usage", "army_setup_siege_usage_within_attack_count", `[{"id":1,"attacks":"2"}]`, false},
		{"duplicate siege ID", "army_setup_siege_usage_within_attack_count", `[{"id":1,"attacks":2},{"id":1,"attacks":1}]`, false},
		{"unordered siege IDs", "army_setup_siege_usage_within_attack_count", `[{"id":2,"attacks":1},{"id":1,"attacks":1}]`, false},
		{"overcounted siege usage", "army_setup_siege_usage_within_attack_count", `[{"id":1,"attacks":3},{"id":2,"attacks":3}]`, false},
		{"valid Legend siege usage", "legend_siege_usage_within_attack_count", `[{"id":1,"uses":2,"triples":1},{"id":2,"uses":3,"triples":0}]`, true},
		{"overcounted Legend siege usage", "legend_siege_usage_within_attack_count", `[{"id":1,"uses":3,"triples":0},{"id":2,"uses":3,"triples":0}]`, false},
		{"valid equipment pairs for multiple heroes", "equipment_pair_usage_triples_within_attack_count", `[{"heroId":1,"equipmentIds":[1,2],"uses":3,"triples":0},{"heroId":1,"equipmentIds":[1,3],"uses":2,"triples":0},{"heroId":2,"equipmentIds":[1,2],"uses":5,"triples":0}]`, true},
		{"overcounted equipment pairs for one hero", "equipment_pair_usage_triples_within_attack_count", `[{"heroId":1,"equipmentIds":[1,2],"uses":3,"triples":0},{"heroId":1,"equipmentIds":[1,3],"uses":3,"triples":0}]`, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var got bool
			query := "SELECT public." + tc.function + "($1::jsonb, 5::bigint)"
			if err := conn.QueryRow(t.Context(), query, tc.value).Scan(&got); err != nil {
				t.Fatal(err)
			}
			if got != tc.want {
				t.Fatalf("validator returned %v, want %v", got, tc.want)
			}
		})
	}
}
