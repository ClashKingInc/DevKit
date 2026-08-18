//go:build ignore

package main

import (
	"reflect"
	"testing"

	"go.mongodb.org/mongo-driver/v2/bson"
)

func TestNormalizeClanWarTag(t *testing.T) {
	for input, want := range map[string]string{
		"":          "",
		" vy2j0ll ": "#VY2J0LL",
		"#Vy2J0lL":  "#VY2J0LL",
	} {
		if got := normalizeClanWarTag(input); got != want {
			t.Fatalf("normalizeClanWarTag(%q) = %q, want %q", input, got, want)
		}
	}
}

func TestClanWarCheckpointKeyIsScoped(t *testing.T) {
	if got := clanWarCheckpointKey(""); got != "clan_war_id" {
		t.Fatalf("unfiltered checkpoint key = %q", got)
	}
	if got := clanWarCheckpointKey("#VY2J0LL"); got != "clan_war_id_VY2J0LL" {
		t.Fatalf("filtered checkpoint key = %q", got)
	}
}

func TestClanWarFilterMatchesEitherSide(t *testing.T) {
	want := bson.D{{Key: "$or", Value: bson.A{
		bson.D{{Key: "data.clan.tag", Value: "#VY2J0LL"}},
		bson.D{{Key: "data.opponent.tag", Value: "#VY2J0LL"}},
	}}}
	if got := clanWarFilter("#VY2J0LL"); !reflect.DeepEqual(got, want) {
		t.Fatalf("clanWarFilter() = %#v, want %#v", got, want)
	}
}

func TestClanWarFilterGlobalScanUsesValidBSON(t *testing.T) {
	want := bson.D{{Key: "_id", Value: bson.D{{Key: "$exists", Value: true}}}}
	if got := clanWarFilter(""); !reflect.DeepEqual(got, want) {
		t.Fatalf("global clanWarFilter() = %#v, want %#v", got, want)
	}
}

func TestCWLWarTagFilterUsesIndexedOfficialTag(t *testing.T) {
	want := bson.D{{Key: "data.tag", Value: bson.D{{Key: "$in", Value: []string{"#WAR1", "#WAR2"}}}}}
	if got := cwlWarTagFilter([]string{"#WAR1", "#WAR2"}); !reflect.DeepEqual(got, want) {
		t.Fatalf("cwlWarTagFilter() = %#v, want %#v", got, want)
	}
}

func TestDecodeCWLBackfillWarTags(t *testing.T) {
	tests := []struct {
		name string
		raw  string
		want []string
	}{
		{name: "official", raw: `[{"warTags":["#WAR1","#WAR2"]},{"warTags":["#WAR3"]}]`, want: []string{"#WAR1", "#WAR2", "#WAR3"}},
		{name: "nested", raw: `[["#WAR1"],["#WAR2","#WAR3"]]`, want: []string{"#WAR1", "#WAR2", "#WAR3"}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := decodeCWLBackfillWarTags([]byte(test.raw)); !reflect.DeepEqual(got, test.want) {
				t.Fatalf("decodeCWLBackfillWarTags() = %#v, want %#v", got, test.want)
			}
		})
	}
}
