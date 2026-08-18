//go:build ignore

package main

import (
	"reflect"
	"strings"
	"testing"
	"time"

	"go.mongodb.org/mongo-driver/v2/bson"
)

func TestLeaderboardHistorySourcesUseFiveTypedTables(t *testing.T) {
	got := map[string]string{}
	for _, source := range leaderboardHistorySources {
		got[source.collection] = source.table
	}
	want := map[string]string{
		"player_trophies":        leaderboardHistoryPlayerHomeTable,
		"player_versus_trophies": leaderboardHistoryPlayerBuilderBaseTable,
		"clan_trophies":          leaderboardHistoryClanHomeTable,
		"clan_versus_trophies":   leaderboardHistoryClanBuilderBaseTable,
		"capital":                leaderboardHistoryClanCapitalTable,
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("sources = %#v, want %#v", got, want)
	}
	for _, forbidden := range []string{"legends", "league_history", "player_leaderboard", "clan_leaderboard"} {
		if _, exists := got[forbidden]; exists {
			t.Fatalf("incompatible collection %q must not be imported", forbidden)
		}
	}
}

func TestLeaderboardHistoryOneShotPlanUsesAllFiveTables(t *testing.T) {
	plan := leaderboardHistoryOneShotPlan()
	if len(plan.ResetSQL) != 5 || len(plan.DropIndexes) != 10 || len(plan.CreateIndexes) != 5 {
		t.Fatalf(
			"unexpected one-shot lifecycle: reset=%#v drop=%d create=%d",
			plan.ResetSQL,
			len(plan.DropIndexes),
			len(plan.CreateIndexes),
		)
	}
	for _, statement := range append(append([]string{}, plan.ResetSQL...), plan.CreateIndexes...) {
		if statement == "" ||
			!containsAny(statement, "leaderboard_history_") ||
			containsAny(statement, "jsonb", " data", " kind") {
			t.Fatalf("one-shot plan retains generic/JSON history storage: %q", statement)
		}
	}
	created := strings.Join(plan.CreateIndexes, "\n")
	if strings.Contains(created, "location_rank") || strings.Contains(created, "date DESC") {
		t.Fatalf("leaderboard import recreates unnecessary indexes: %s", created)
	}
}

func TestPlayerTrophyHistoryUsesLeagueTierBeforeLegacyLeague(t *testing.T) {
	doc := leaderboardDocument("2026-07-29", bson.M{
		"tag":          "#PLAYER",
		"name":         "Example",
		"rank":         int32(7),
		"previousRank": int32(8),
		"expLevel":     int32(200),
		"trophies":     int32(6001),
		"attackWins":   int32(300),
		"defenseWins":  int32(20),
		"league":       bson.M{"id": int32(29000022), "name": "Legend League"},
		"leagueTier":   bson.M{"id": int32(105000036), "name": "Legend I"},
		"clan": bson.M{
			"tag":  "#CLAN",
			"name": "Clan",
			"badgeUrls": bson.M{
				"small": "https://api-assets.clashofclans.com/badges/70/player-clan-token.png",
			},
		},
	})
	rows := leaderboardRowsFromDocument(
		leaderboardHistorySource{collection: "player_trophies", table: leaderboardHistoryPlayerHomeTable},
		doc,
	)
	if len(rows) != 1 {
		t.Fatalf("rows = %d, want 1", len(rows))
	}
	row := rows[0]
	if row.leagueID != 105000036 ||
		row.trophies != 6001 ||
		row.attackWins != 300 ||
		row.defenseWins != 20 ||
		row.clanBadgeToken != "player-clan-token" {
		t.Fatalf("unexpected typed player row: %#v", row)
	}

	delete(docItem(doc), "leagueTier")
	rows = leaderboardRowsFromDocument(
		leaderboardHistorySource{collection: "player_trophies", table: leaderboardHistoryPlayerHomeTable},
		doc,
	)
	if len(rows) != 1 || rows[0].leagueID != 29000022 {
		t.Fatalf("legacy league fallback was not preserved: %#v", rows)
	}
}

func TestPlayerBuilderBaseHistorySupportsLegacyAndCurrentFields(t *testing.T) {
	doc := leaderboardDocument("2026-07-29", bson.M{
		"tag":              "#PLAYER",
		"name":             "Example",
		"rank":             int32(2),
		"previousRank":     int32(3),
		"expLevel":         int32(150),
		"versusTrophies":   int32(5000),
		"versusBattleWins": int32(100),
	})
	source := leaderboardHistorySource{
		collection: "player_versus_trophies",
		table:      leaderboardHistoryPlayerBuilderBaseTable,
	}
	rows := leaderboardRowsFromDocument(source, doc)
	if len(rows) != 1 ||
		rows[0].builderBaseTrophies != 5000 ||
		rows[0].builderBaseBattleWins != 100 ||
		rows[0].leagueID != nil {
		t.Fatalf("legacy Builder Base row = %#v", rows)
	}

	item := docItem(doc)
	delete(item, "versusTrophies")
	delete(item, "versusBattleWins")
	item["builderBaseTrophies"] = int32(7000)
	item["builderBaseLeague"] = bson.M{"id": int32(44000041), "name": "Diamond I"}
	rows = leaderboardRowsFromDocument(source, doc)
	if len(rows) != 1 ||
		rows[0].builderBaseTrophies != 7000 ||
		rows[0].builderBaseBattleWins != nil ||
		rows[0].leagueID != 44000041 {
		t.Fatalf("current Builder Base row = %#v", rows)
	}
}

func TestClanHistoriesUseOnlyTypedColumns(t *testing.T) {
	for _, test := range []struct {
		source leaderboardHistorySource
		field  string
		value  int32
	}{
		{
			source: leaderboardHistorySource{collection: "clan_trophies", table: leaderboardHistoryClanHomeTable},
			field:  "clanPoints",
			value:  123456,
		},
		{
			source: leaderboardHistorySource{collection: "clan_versus_trophies", table: leaderboardHistoryClanBuilderBaseTable},
			field:  "clanBuilderBasePoints",
			value:  65432,
		},
		{
			source: leaderboardHistorySource{collection: "capital", table: leaderboardHistoryClanCapitalTable},
			field:  "clanCapitalPoints",
			value:  6200,
		},
	} {
		item := bson.M{
			"tag":          "#CLAN",
			"name":         "Example",
			"rank":         int32(1),
			"previousRank": int32(-1),
			"clanLevel":    int32(20),
			"members":      int32(49),
			"location":     bson.M{"id": int32(32000006), "name": "Canada"},
			"badgeUrls": bson.M{
				"medium": "https://api-assets.clashofclans.com/badges/200/clan-token.png",
			},
			test.field: test.value,
		}
		date := "2026-07-29"
		if test.source.tuesdaySnapshotAsMonday {
			date = "2026-07-28"
		}
		rows := leaderboardRowsFromDocument(test.source, leaderboardDocument(date, item))
		if len(rows) != 1 {
			t.Fatalf("%s rows = %d, want 1", test.source.table, len(rows))
		}
		row := rows[0]
		if row.clanPoints != int(test.value) ||
			row.clanBadgeToken != "clan-token" ||
			row.clanLocationID != 32000006 ||
			row.previous != -1 {
			t.Fatalf("%s typed row = %#v", test.source.table, row)
		}
	}
}

func TestCapitalHistoryKeepsTuesdayAndRecordsPreviousMonday(t *testing.T) {
	source := leaderboardHistorySource{
		collection:              "capital",
		table:                   leaderboardHistoryClanCapitalTable,
		tuesdaySnapshotAsMonday: true,
	}
	item := bson.M{
		"tag": "#CLAN", "name": "Example", "rank": int32(1),
		"clanCapitalPoints": int32(3000), "clanLevel": int32(10), "members": int32(40),
		"badgeUrls": bson.M{
			"medium": "https://api-assets.clashofclans.com/badges/200/capital-token.png",
		},
	}
	rows := leaderboardRowsFromDocument(source, leaderboardDocument("2026-07-28", item))
	if len(rows) != 1 {
		t.Fatalf("Tuesday rows = %d, want 1", len(rows))
	}
	wantDate := time.Date(2026, 7, 27, 0, 0, 0, 0, time.UTC)
	if rows[0].date != wantDate {
		t.Fatalf("stored date = %s, want previous Monday %s", rows[0].date, wantDate)
	}

	if rows := leaderboardRowsFromDocument(source, leaderboardDocument("2026-07-29", item)); len(rows) != 0 {
		t.Fatalf("non-Tuesday capital snapshot produced %d rows", len(rows))
	}
}

func TestLeaderboardHistoryCopyColumnsContainNoJSON(t *testing.T) {
	for _, table := range []string{
		leaderboardHistoryPlayerHomeTable,
		leaderboardHistoryPlayerBuilderBaseTable,
		leaderboardHistoryClanHomeTable,
		leaderboardHistoryClanBuilderBaseTable,
		leaderboardHistoryClanCapitalTable,
	} {
		columns, _, _, err := leaderboardHistoryCopyRows(table, map[string]leaderboardHistoryRow{})
		if err != nil {
			t.Fatal(err)
		}
		for _, column := range columns {
			if column == "data" || column == "jsonb" || column == "kind" {
				t.Fatalf("%s retained generic column %q", table, column)
			}
		}
	}
}

func TestNormalizeLeaderboardLocation(t *testing.T) {
	for _, test := range []struct {
		input any
		want  string
		ok    bool
	}{
		{input: "global", want: "global", ok: true},
		{input: "GLOBAL", want: "global", ok: true},
		{input: int32(32000006), want: "32000006", ok: true},
		{input: "0", ok: false},
		{input: "United States", ok: false},
	} {
		got, ok := normalizeLeaderboardLocation(test.input)
		if got != test.want || ok != test.ok {
			t.Fatalf("normalizeLeaderboardLocation(%v) = %q,%v; want %q,%v", test.input, got, ok, test.want, test.ok)
		}
	}
}

func leaderboardDocument(date string, item bson.M) bson.M {
	return bson.M{
		"location": "32000006",
		"date":     date,
		"data":     bson.M{"items": bson.A{item}},
	}
}

func docItem(doc bson.M) bson.M {
	return doc["data"].(bson.M)["items"].(bson.A)[0].(bson.M)
}

func containsAny(value string, needles ...string) bool {
	for _, needle := range needles {
		if needle != "" && len(value) >= len(needle) {
			for index := 0; index+len(needle) <= len(value); index++ {
				if value[index:index+len(needle)] == needle {
					return true
				}
			}
		}
	}
	return false
}
