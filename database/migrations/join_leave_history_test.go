//go:build ignore

package main

import (
	"reflect"
	"testing"

	"go.mongodb.org/mongo-driver/v2/bson"
)

func TestNormalizeJoinLeaveClanTag(t *testing.T) {
	for input, want := range map[string]string{
		"":          "",
		" vy2j0ll ": "#VY2J0LL",
		"#Vy2J0lL":  "#VY2J0LL",
	} {
		if got := normalizeJoinLeaveClanTag(input); got != want {
			t.Fatalf("normalizeJoinLeaveClanTag(%q) = %q, want %q", input, got, want)
		}
	}
}

func TestNormalizeJoinLeavePlayerTag(t *testing.T) {
	for input, want := range map[string]string{
		"":            "",
		" 2j8v28gv0 ": "#2J8V28GV0",
		"#2j8V28gV0":  "#2J8V28GV0",
	} {
		if got := normalizeJoinLeavePlayerTag(input); got != want {
			t.Fatalf("normalizeJoinLeavePlayerTag(%q) = %q, want %q", input, got, want)
		}
	}
}

func TestJoinLeaveHistoryFilter(t *testing.T) {
	tests := []struct {
		name      string
		clanTag   string
		playerTag string
		want      bson.D
	}{
		{name: "unfiltered", want: bson.D{}},
		{name: "clan", clanTag: "#VY2J0LL", want: bson.D{{Key: "clan", Value: "#VY2J0LL"}}},
		{name: "player", playerTag: "#2J8V28GV0", want: bson.D{{Key: "tag", Value: "#2J8V28GV0"}}},
		{name: "clan and player", clanTag: "#VY2J0LL", playerTag: "#2J8V28GV0", want: bson.D{
			{Key: "clan", Value: "#VY2J0LL"},
			{Key: "tag", Value: "#2J8V28GV0"},
		}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := joinLeaveHistoryFilter(test.clanTag, test.playerTag); !reflect.DeepEqual(got, test.want) {
				t.Fatalf("joinLeaveHistoryFilter() = %#v, want %#v", got, test.want)
			}
		})
	}
}
