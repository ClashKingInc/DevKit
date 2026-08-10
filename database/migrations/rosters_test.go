//go:build ignore

package main

import (
	"os"
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

func TestRosterSortConfigurationUsesStableColumnIDs(t *testing.T) {
	got := rosterSortConfigurationJSON([]any{
		"Townhall Level",
		"Name (Z-A)",
		"hitrate_desc",
		"Recently Added",
		"War Opt Status",
		"Not A Roster Column",
	})
	want := `[{"columnId":"townhall","direction":"desc"},{"columnId":"name","direction":"desc"},{"columnId":"hitrate","direction":"desc"},{"columnId":"added_at","direction":"desc"},{"columnId":"war_pref","direction":"asc"}]`
	if got != want {
		t.Fatalf("rosterSortConfigurationJSON() = %s, want %s", got, want)
	}
}

func TestRosterLegacyNumericSortLabelsDefaultToDescending(t *testing.T) {
	for label, wantColumn := range map[string]string{
		"Townhall Level": "townhall",
		"Heroes":         "hero_lvs",
		"30 Day Hitrate": "hitrate",
		"Trophies":       "trophies",
	} {
		columnID, direction, ok := rosterSortField(label)
		if !ok || columnID != wantColumn || direction != "desc" {
			t.Errorf("rosterSortField(%q) = (%q, %q, %t), want (%q, desc, true)", label, columnID, direction, ok, wantColumn)
		}
	}
}

func TestRosterImporterUsesLegacyHeroLevelSum(t *testing.T) {
	source, err := os.ReadFile("rosters.go")
	if err != nil {
		t.Fatal(err)
	}
	text := string(source)
	if !strings.Contains(text, `migrateutil.Int(member["hero_lvs"])`) {
		t.Fatal("roster importer does not read the legacy hero_lvs scalar")
	}
	if strings.Contains(text, `member["heroes"]`) {
		t.Fatal("roster importer still expects a heroes array that legacy rosters never stored")
	}
}

func TestRosterColumnIDsNormalizesEveryObservedLegacyLabel(t *testing.T) {
	got := rosterColumnIDs([]any{
		"30 Day Hitrate",
		"Clan Tag",
		"Current Clan",
		"Discord",
		"Heroes",
		"Name",
		"Player Tag",
		"Townhall Level",
		"Trophies",
		"War Opt Status",
		"name",
		"Not A Roster Column",
	})
	want := []string{
		"hitrate",
		"current_clan_tag",
		"current_clan",
		"discord",
		"hero_lvs",
		"name",
		"tag",
		"townhall",
		"trophies",
		"war_pref",
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("rosterColumnIDs() = %#v, want %#v", got, want)
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

func TestRosterImporterOmitsRetiredSignupAndSubstituteSchema(t *testing.T) {
	source, err := os.ReadFile("rosters.go")
	if err != nil {
		t.Fatal(err)
	}
	text := string(source)
	for _, retired := range []string{
		"roster_signup_categories",
		"roster_allowed_signup_categories",
		"roster_group_allowed_signup_categories",
		"default_signup_category",
		"substitute",
		"signup_group",
		"roster_display_columns",
		"roster_sort_fields",
		"roster_size",
		"townhall_restriction",
	} {
		if strings.Contains(text, retired) {
			t.Fatalf("retired roster importer projection remains: %s", retired)
		}
	}
}

func TestRosterImporterDoesNotPersistMongoRosterIdentity(t *testing.T) {
	source, err := os.ReadFile("rosters.go")
	if err != nil {
		t.Fatal(err)
	}
	text := string(source)
	for _, persistedLegacyShape := range []string{
		"id, custom_id, server_id",
		"ON CONFLICT (custom_id)",
		"WHERE custom_id =",
	} {
		if strings.Contains(text, persistedLegacyShape) {
			t.Fatalf("Mongo roster identity is still persisted: %s", persistedLegacyShape)
		}
	}
}
