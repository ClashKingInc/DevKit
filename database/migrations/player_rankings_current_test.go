//go:build ignore

package main

import (
	"context"
	"io"
	"net/http"
	"reflect"
	"strings"
	"testing"

	"go.mongodb.org/mongo-driver/v2/bson"
)

type playerRankingRoundTripFunc func(*http.Request) (*http.Response, error)

func (function playerRankingRoundTripFunc) RoundTrip(request *http.Request) (*http.Response, error) {
	return function(request)
}

func TestPlayerRankingRowsRetainLocationWithoutPlacement(t *testing.T) {
	locations := playerRankingLocations{
		byCode: map[string]string{"US": "32000006"},
		byName: map[string]string{"united states": "32000006"},
	}
	rows, unresolved := playerRankingRowsFromDocument(bson.M{
		"tag": "#PLAYER", "country_code": "us", "country_name": "United States",
		"global_rank": int32(12), "local_rank": nil,
	}, locations)
	rows = sortedPlayerRankingRows(rows)
	if unresolved {
		t.Fatal("known country was unresolved")
	}
	want := []playerRankingRow{
		{playerTag: "#PLAYER", rankingType: "home", locationID: "32000006"},
		{playerTag: "#PLAYER", rankingType: "home", locationID: "global", rank: 12},
	}
	if !reflect.DeepEqual(rows, want) {
		t.Fatalf("rows = %#v, want %#v", rows, want)
	}
}

func TestPlayerRankingRowsMapBuilderPlacementsAndSharedLocation(t *testing.T) {
	locations := playerRankingLocations{
		byCode: map[string]string{"CA": "32000006"},
		byName: map[string]string{"canada": "32000006"},
	}
	rows, unresolved := playerRankingRowsFromDocument(bson.M{
		"tag": "#PLAYER", "country_name": "Canada",
		"builder_global_rank": int64(41), "builder_local_rank": int32(7),
	}, locations)
	rows = sortedPlayerRankingRows(rows)
	if unresolved {
		t.Fatal("known country was unresolved")
	}
	want := []playerRankingRow{
		{playerTag: "#PLAYER", rankingType: "builder_base", locationID: "32000006", rank: 7},
		{playerTag: "#PLAYER", rankingType: "builder_base", locationID: "global", rank: 41},
		{playerTag: "#PLAYER", rankingType: "home", locationID: "32000006"},
	}
	if !reflect.DeepEqual(rows, want) {
		t.Fatalf("rows = %#v, want %#v", rows, want)
	}
}

func TestPlayerRankingRowsPreferStoredNumericLocation(t *testing.T) {
	rows, unresolved := playerRankingRowsFromDocument(bson.M{
		"tag": "#PLAYER", "location_id": int32(32000087),
		"country_code": "ZZ", "local_rank": int32(9),
	}, playerRankingLocations{byCode: map[string]string{}, byName: map[string]string{}})
	if unresolved || len(rows) != 1 || rows[0].locationID != "32000087" || rows[0].rank != 9 {
		t.Fatalf("rows=%#v unresolved=%v", rows, unresolved)
	}
}

func TestPlayerRankingRowsReportUnknownCountry(t *testing.T) {
	rows, unresolved := playerRankingRowsFromDocument(bson.M{
		"tag": "#PLAYER", "country_code": "ZZ", "global_rank": int32(3),
	}, playerRankingLocations{byCode: map[string]string{}, byName: map[string]string{}})
	if !unresolved || len(rows) != 1 || rows[0].locationID != "global" {
		t.Fatalf("rows=%#v unresolved=%v", rows, unresolved)
	}
}

func TestLoadPlayerRankingLocations(t *testing.T) {
	client := &http.Client{Transport: playerRankingRoundTripFunc(func(request *http.Request) (*http.Response, error) {
		if request.Method != http.MethodGet {
			t.Fatalf("method = %s", request.Method)
		}
		return &http.Response{
			StatusCode: http.StatusOK,
			Body: io.NopCloser(strings.NewReader(`{"items":[
			{"id":32000006,"name":"Canada","countryCode":"CA","isCountry":true},
			{"id":32000000,"name":"Europe","isCountry":false}
		]}`)),
		}, nil
	})}
	locations, err := loadPlayerRankingLocations(context.Background(), client, "https://locations.example")
	if err != nil {
		t.Fatal(err)
	}
	if locations.byCode["CA"] != "32000006" || locations.byName["canada"] != "32000006" ||
		locations.byCode["AF"] != "32000007" || len(locations.byCode) != 2 {
		t.Fatalf("locations = %#v", locations)
	}
}

func TestPlayerRankingsCurrentOneShotPlanOwnsOnlyCurrentPlayers(t *testing.T) {
	plan := playerRankingsCurrentOneShotPlan()
	joined := strings.Join(append(append([]string{}, plan.ResetSQL...), append(plan.DropIndexes, plan.CreateIndexes...)...), "\n")
	if !strings.Contains(joined, "player_rankings_current") {
		t.Fatal("one-shot plan does not own player_rankings_current")
	}
	for _, forbidden := range []string{"clan_rankings_current", "leaderboard_history_"} {
		if strings.Contains(joined, forbidden) {
			t.Fatalf("one-shot plan mutates %s", forbidden)
		}
	}
}
