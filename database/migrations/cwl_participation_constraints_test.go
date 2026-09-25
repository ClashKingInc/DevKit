package main

import (
	"context"
	"os"
	"testing"

	"github.com/jackc/pgx/v5"
)

func TestCWLParticipationTownHalls(t *testing.T) {
	if os.Getenv("CLASHKING_DISPOSABLE_TIMESCALE") != "1" || os.Getenv("TEST_DATABASE_URL") == "" {
		t.Skip("requires disposable authoritative Goose schema")
	}
	conn, err := pgx.Connect(t.Context(), os.Getenv("TEST_DATABASE_URL"))
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close(context.Background())
	for _, tc := range []struct {
		name, value string
		want        bool
	}{
		{"empty distribution", `[]`, true},
		{"ordered distribution", `[{"level":18,"count":4},{"level":17,"count":2}]`, true},
		{"null entry", `[null]`, false},
		{"string level", `[{"level":"17","count":2}]`, false},
		{"negative count", `[{"level":17,"count":-1}]`, false},
		{"duplicate level", `[{"level":17,"count":1},{"level":17,"count":2}]`, false},
		{"ascending levels", `[{"level":17,"count":1},{"level":18,"count":2}]`, false},
		{"unknown key", `[{"level":17,"count":1,"other":true}]`, false},
		{"out of range level", `[{"level":21,"count":1}]`, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var got bool
			if err := conn.QueryRow(t.Context(), "SELECT public.cwl_participation_town_halls_valid($1::jsonb)", tc.value).Scan(&got); err != nil {
				t.Fatal(err)
			}
			if got != tc.want {
				t.Fatalf("validator returned %v, want %v", got, tc.want)
			}
		})
	}
	for _, tc := range []struct {
		name, value string
		wantErr     bool
	}{
		{"valid row", `[{"level":18,"count":4}]`, false},
		{"malformed row", `[{"level":"18","count":4}]`, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			tx, err := conn.Begin(t.Context())
			if err != nil {
				t.Fatal(err)
			}
			defer tx.Rollback(context.Background())
			_, err = tx.Exec(t.Context(), `INSERT INTO public.cwl_participation
				(season,cwl_league_id,war_size,group_count,clan_count,registered_player_count,townhall_counts,finalized_wars,archived_wars)
				VALUES ('2026-09',48000001,15,1,1,1,$1::jsonb,0,0)`, tc.value)
			if (err != nil) != tc.wantErr {
				t.Fatalf("insert error = %v, want error = %v", err, tc.wantErr)
			}
		})
	}
}

func TestCWLParticipationHitRates(t *testing.T) {
	if os.Getenv("CLASHKING_DISPOSABLE_TIMESCALE") != "1" || os.Getenv("TEST_DATABASE_URL") == "" {
		t.Skip("requires disposable authoritative Goose schema")
	}
	conn, err := pgx.Connect(t.Context(), os.Getenv("TEST_DATABASE_URL"))
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close(context.Background())
	for _, tc := range []struct {
		name, value string
		want        bool
	}{
		{"empty observations", `[]`, true},
		{"descending observations", `[{"level":18,"attacks":4,"three_stars":2},{"level":17,"attacks":3,"three_stars":1}]`, true},
		{"null entry", `[null]`, false},
		{"missing fields", `[{}]`, false},
		{"string level", `[{"level":"18","attacks":1,"three_stars":0}]`, false},
		{"negative attempts", `[{"level":18,"attacks":-1,"three_stars":0}]`, false},
		{"triples over attempts", `[{"level":18,"attacks":1,"three_stars":2}]`, false},
		{"duplicate level", `[{"level":18,"attacks":1,"three_stars":0},{"level":18,"attacks":1,"three_stars":0}]`, false},
		{"ascending levels", `[{"level":17,"attacks":1,"three_stars":0},{"level":18,"attacks":1,"three_stars":0}]`, false},
		{"unknown key", `[{"level":18,"attacks":1,"three_stars":0,"other":true}]`, false},
		{"out of range level", `[{"level":21,"attacks":1,"three_stars":0}]`, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var got bool
			if err := conn.QueryRow(t.Context(), "SELECT public.cwl_participation_hitrates_valid($1::jsonb)", tc.value).Scan(&got); err != nil {
				t.Fatal(err)
			}
			if got != tc.want {
				t.Fatalf("validator returned %v, want %v", got, tc.want)
			}
		})
	}
	for _, tc := range []struct {
		name, value string
		wantErr     bool
	}{
		{"SQL null observations", "", false},
		{"valid row", `[{"level":18,"attacks":1,"three_stars":1}]`, false},
		{"malformed row", `[{}]`, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			tx, err := conn.Begin(t.Context())
			if err != nil {
				t.Fatal(err)
			}
			defer tx.Rollback(context.Background())
			var input any = tc.value
			if tc.name == "SQL null observations" {
				input = nil
			}
			_, err = tx.Exec(t.Context(), `INSERT INTO public.cwl_participation
				(season,cwl_league_id,war_size,group_count,clan_count,registered_player_count,townhall_counts,same_th_hitrates,finalized_wars,archived_wars)
				VALUES ('2026-09',48000001,15,1,1,1,'[]',$1::jsonb,0,0)`, input)
			if (err != nil) != tc.wantErr {
				t.Fatalf("insert error = %v, want error = %v", err, tc.wantErr)
			}
		})
	}
}
