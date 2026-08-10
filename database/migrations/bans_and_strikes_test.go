//go:build ignore

package main

import (
	"os"
	"reflect"
	"strings"
	"testing"
	"time"

	"go.mongodb.org/mongo-driver/v2/bson"
)

func TestBansAndStrikesOneShotPlan(t *testing.T) {
	plan := bansAndStrikesOneShotPlan()
	if !reflect.DeepEqual(plan.ResetSQL, []string{`TRUNCATE TABLE public.server_bans, public.strikes`}) {
		t.Fatalf("reset SQL = %#v", plan.ResetSQL)
	}
	if len(plan.DropIndexes) != 3 || len(plan.CreateIndexes) != 3 {
		t.Fatalf("unexpected index lifecycle: drop=%#v create=%#v", plan.DropIndexes, plan.CreateIndexes)
	}
}

func TestTypedModerationBaseline(t *testing.T) {
	payload, err := os.ReadFile("../timescale/002_initial_settings.sql")
	if err != nil {
		t.Fatal(err)
	}
	up, _, found := strings.Cut(string(payload), "-- +goose Down")
	if !found {
		t.Fatal("settings baseline is missing a Goose down section")
	}
	for _, table := range []string{"server_bans", "strikes"} {
		definition := moderationTableDDL(t, up, table)
		if !strings.Contains(definition, "image text") {
			t.Errorf("%s baseline is missing typed image evidence", table)
		}
		if strings.Contains(definition, "data jsonb") {
			t.Errorf("%s baseline retains the retired data column", table)
		}
	}
}

func moderationTableDDL(t *testing.T, migration, table string) string {
	t.Helper()
	start := strings.Index(migration, "CREATE TABLE public."+table+" (")
	if start < 0 {
		t.Fatalf("settings baseline is missing table %s", table)
	}
	end := strings.Index(migration[start:], "\n);\n")
	if end < 0 {
		t.Fatalf("settings baseline table %s has no closing delimiter", table)
	}
	return migration[start : start+end+4]
}

func TestBanRowFromLegacyDocument(t *testing.T) {
	row, ok := banRowFromDocument(bson.M{
		"_id":           bson.NewObjectID(),
		"VillageTag":    "2abc",
		"DateCreated":   "2026-07-02 03:04:05",
		"Notes":         "Repeated hopping",
		"server":        int64(12345),
		"added_by":      int64(67890),
		"rollover_date": int64(1784000000),
		"image":         "https://example.com/ban-evidence.png",
		"name":          "Player",
		"edited_by": bson.A{bson.M{
			"user": int64(42),
			"previous": bson.M{
				"reason":        "Old reason",
				"rollover_days": nil,
			},
		}},
	})
	if !ok {
		t.Fatal("expected valid ban row")
	}
	if row.serverID != "12345" || row.playerTag != "#2ABC" || row.name != "Player" ||
		row.reason != "Repeated hopping" || row.addedBy != "67890" ||
		row.image != "https://example.com/ban-evidence.png" ||
		!row.createdAt.Equal(time.Date(2026, 7, 2, 3, 4, 5, 0, time.UTC)) {
		t.Fatalf("unexpected row: %#v", row)
	}
}

func TestStrikeRowFromLegacyDocument(t *testing.T) {
	row, ok := strikeRowFromDocument(bson.M{
		"strike_id":     "abcde",
		"tag":           "#player",
		"date_created":  "2026-07-02 03:04:05",
		"reason":        "Missed attacks",
		"server":        int64(12345),
		"added_by":      int64(67890),
		"strike_weight": int32(2),
		"rollover_date": int64(1784000000),
		"image":         "https://example.com/evidence.png",
	})
	if !ok {
		t.Fatal("expected valid strike row")
	}
	rollover, ok := row.rolloverDate.(time.Time)
	if !ok {
		t.Fatalf("rollover type = %T", row.rolloverDate)
	}
	if row.id != "ABCDE" || row.serverID != "12345" || row.playerTag != "#PLAYER" ||
		row.weight != 2 || row.image != "https://example.com/evidence.png" ||
		!row.createdAt.Equal(time.Date(2026, 7, 2, 3, 4, 5, 0, time.UTC)) ||
		!rollover.Equal(time.Unix(1784000000, 0).UTC()) {
		t.Fatalf("unexpected row: %#v", row)
	}
}

func TestModerationRowsRejectMissingIdentity(t *testing.T) {
	validDate := "2026-07-02 03:04:05"
	for _, doc := range []bson.M{
		{"VillageTag": "#P", "DateCreated": validDate},
		{"server": 1, "DateCreated": validDate},
		{"server": 1, "VillageTag": "#P"},
	} {
		if _, ok := banRowFromDocument(doc); ok {
			t.Fatalf("invalid ban accepted: %#v", doc)
		}
	}
	for _, doc := range []bson.M{
		{"server": 1, "tag": "#P", "date_created": validDate},
		{"strike_id": "ABCDE", "tag": "#P", "date_created": validDate},
		{"strike_id": "ABCDE", "server": 1, "date_created": validDate},
		{"strike_id": "ABCDE", "server": 1, "tag": "#P"},
	} {
		if _, ok := strikeRowFromDocument(doc); ok {
			t.Fatalf("invalid strike accepted: %#v", doc)
		}
	}
}

func TestStrikeWeightDefaultsToOne(t *testing.T) {
	for _, weight := range []any{nil, 0, -1, int64(1344445667899)} {
		row, ok := strikeRowFromDocument(bson.M{
			"strike_id":     "ABCDE",
			"tag":           "#P",
			"server":        1,
			"date_created":  "2026-07-02 03:04:05",
			"strike_weight": weight,
		})
		if !ok || row.weight != 1 {
			t.Fatalf("source weight=%v row=%#v ok=%v", weight, row, ok)
		}
	}
}
