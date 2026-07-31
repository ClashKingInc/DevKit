//go:build ignore

package main

import (
	"reflect"
	"strings"
	"testing"

	"go.mongodb.org/mongo-driver/v2/bson"
)

func TestUniqueRosterMembersKeepsFirstTagInSourceOrder(t *testing.T) {
	first := bson.M{"tag": "#AAA", "name": "first"}
	duplicate := bson.M{"tag": "#AAA", "name": "duplicate"}
	second := bson.M{"tag": "#BBB", "name": "second"}

	got := uniqueRosterMembers([]any{
		first,
		bson.M{"tag": ""},
		duplicate,
		second,
	})

	want := []bson.M{first, second}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("uniqueRosterMembers() = %#v, want %#v", got, want)
	}
}

func TestUniqueRosterStringsRemovesBlankAndDuplicateValues(t *testing.T) {
	got := uniqueRosterStrings([]any{"alpha", "", "alpha", "beta", "beta"})
	want := []string{"alpha", "beta"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("uniqueRosterStrings() = %#v, want %#v", got, want)
	}
}

func TestRosterIndexesUseOnlyNormalizedRosterColumns(t *testing.T) {
	for _, statement := range rosterOneShotPlan().CreateIndexes {
		if strings.Contains(statement, "rosters_members_gin") ||
			strings.Contains(statement, "USING gin (members)") {
			t.Fatalf("stale JSONB members index remains in one-shot plan: %s", statement)
		}
	}
}
