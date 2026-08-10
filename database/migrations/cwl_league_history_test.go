//go:build ignore

package main

import (
	"testing"

	"go.mongodb.org/mongo-driver/v2/bson"
)

func TestCWLLeagueHistoryShiftsRecordedMonthAndStoresIDs(t *testing.T) {
	row, ok, err := cwlLeagueHistoryFromDocument(bson.M{
		"tag": "#2RRVPUJCY",
		"changes": bson.M{"clanWarLeague": bson.M{
			"2025-07": bson.M{"league": "Master League I"},
			"2025-08": bson.M{"league": "Champion League III"},
		}},
	})
	if err != nil {
		t.Fatal(err)
	}
	if !ok || row.clanTag != "#2RRVPUJCY" {
		t.Fatalf("unexpected row: %#v ok=%v", row, ok)
	}
	if row.seasons["2025-08"] != 48000015 || row.seasons["2025-09"] != 48000016 {
		t.Fatalf("shifted seasons = %#v", row.seasons)
	}
}

func TestCWLLeagueHistoryMapsUnranked(t *testing.T) {
	row, ok, err := cwlLeagueHistoryFromDocument(bson.M{
		"tag": "#CLAN",
		"changes": bson.M{"clanWarLeague": bson.M{
			"2025-08": bson.M{"league": "Unranked"},
		}},
	})
	if err != nil || !ok || row.seasons["2025-09"] != cwlUnrankedLeagueID {
		t.Fatalf("row=%#v ok=%v err=%v", row, ok, err)
	}
}

func TestCWLLeagueHistoryRejectsUnknownLeague(t *testing.T) {
	_, _, err := cwlLeagueHistoryFromDocument(bson.M{
		"tag": "#CLAN",
		"changes": bson.M{"clanWarLeague": bson.M{
			"2025-08": bson.M{"league": "Future League"},
		}},
	})
	if err == nil {
		t.Fatal("expected unknown league error")
	}
}

func TestShiftedCWLSeasonRejectsInvalidMonth(t *testing.T) {
	if _, ok := shiftedCWLSeason("2025-13"); ok {
		t.Fatal("invalid month accepted")
	}
}
