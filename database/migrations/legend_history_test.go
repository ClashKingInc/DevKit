//go:build ignore

package main

import (
	"reflect"
	"strings"
	"testing"

	"go.mongodb.org/mongo-driver/v2/bson"
)

func TestLegendHistoryOneShotPlan(t *testing.T) {
	plan := legendHistoryOneShotPlan()
	if !reflect.DeepEqual(plan.ResetSQL, []string{`TRUNCATE TABLE public.legend_history`}) {
		t.Fatalf("reset SQL = %#v", plan.ResetSQL)
	}
	if len(plan.DropIndexes) != 4 || len(plan.CreateIndexes) != 2 {
		t.Fatalf("unexpected index lifecycle: drop=%#v create=%#v", plan.DropIndexes, plan.CreateIndexes)
	}
	created := strings.Join(plan.CreateIndexes, "\n")
	if strings.Contains(created, "player_season") ||
		!strings.Contains(created, "(season, rank)") ||
		!strings.Contains(created, "(clan_tag, season DESC)") {
		t.Fatalf("unexpected legend indexes: %s", created)
	}
}

func TestLegendRowFromDocument(t *testing.T) {
	row, ok := legendRowFromDocument(bson.M{
		"_id":         "mongo-only",
		"season":      "v2-2026-07-06T05:00:00Z",
		"tag":         "#PLAYER",
		"name":        "Example",
		"expLevel":    int32(186),
		"rank":        int32(12),
		"trophies":    int32(6123),
		"attackWins":  int32(300),
		"defenseWins": int32(4),
		"clan": bson.M{
			"tag":  "#CLAN",
			"name": "Clan",
			"badgeUrls": bson.M{
				"large": "https://api-assets.clashofclans.com/badges/512/legend-clan-token.png",
			},
		},
		"leagueTier": bson.M{
			"id":       int32(105000036),
			"name":     "Legend I",
			"iconUrls": bson.M{"small": "ignored"},
		},
	})
	if !ok {
		t.Fatal("expected valid legend row")
	}
	if row.season != "v2-2026-07-06T05:00:00Z" ||
		row.playerTag != "#PLAYER" ||
		row.playerName != "Example" ||
		row.expLevel != 186 ||
		row.rank != 12 ||
		row.trophies != 6123 ||
		row.attackWins != 300 ||
		row.defenseWins != 4 ||
		row.clanTag != "#CLAN" ||
		row.clanName != "Clan" ||
		row.clanBadgeToken != "legend-clan-token" ||
		row.leagueTierID != 105000036 {
		t.Fatalf("unexpected row: %#v", row)
	}
}

func TestLegendRowRejectsInvalidIdentity(t *testing.T) {
	for _, doc := range []bson.M{
		{"season": "", "tag": "#P", "name": "P", "rank": 1, "trophies": 1},
		{"season": "2026-01", "tag": "", "name": "P", "rank": 1, "trophies": 1},
		{"season": "2026-01", "tag": "#P", "name": "", "rank": 1, "trophies": 1},
		{"season": "2026-01", "tag": "#P", "name": "P", "rank": 0, "trophies": 1},
		{"season": "2026-01", "tag": "#P", "name": "P", "rank": 1, "trophies": -1},
		{
			"season": "2026-01", "tag": "#P", "name": "P", "rank": 1, "trophies": 1,
			"clan": bson.M{"tag": "#C", "name": "Clan"},
		},
	} {
		if _, ok := legendRowFromDocument(doc); ok {
			t.Fatalf("invalid document accepted: %#v", doc)
		}
	}
}
