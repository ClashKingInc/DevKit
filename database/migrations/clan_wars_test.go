//go:build ignore

package main

import (
	"context"
	"reflect"
	"testing"
	"time"

	"github.com/ClashKingInc/DevKit/database/migrations/migrateutil"
	"github.com/ClashKingInc/DevKit/database/wararchive"
	"github.com/google/uuid"
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
	if got := clanWarCheckpointKey(""); got != "clan_war_r2_id" {
		t.Fatalf("unfiltered checkpoint key = %q", got)
	}
	if got := clanWarCheckpointKey("#VY2J0LL"); got != "clan_war_r2_id_VY2J0LL" {
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

func TestClanWarFilterAppliesObjectIDRange(t *testing.T) {
	from, _ := bson.ObjectIDFromHex("000000000000000000000001")
	before, _ := bson.ObjectIDFromHex("000000000000000000000010")
	idRange := clanWarIDRange{from: &from, before: &before}
	want := bson.D{{Key: "_id", Value: bson.D{
		{Key: "$gte", Value: from},
		{Key: "$lt", Value: before},
	}}}
	if got := clanWarFilterWithIDRange("", idRange); !reflect.DeepEqual(got, want) {
		t.Fatalf("clanWarFilterWithIDRange() = %#v, want %#v", got, want)
	}
	wantCheckpoint := "clan_war_r2_id_from_" + from.Hex() + "_before_" + before.Hex()
	if got := idRange.checkpointKey(clanWarCheckpointKey("")); got != wantCheckpoint {
		t.Fatalf("range checkpoint key = %q, want %q", got, wantCheckpoint)
	}
}

func TestClanWarIDRangeValidation(t *testing.T) {
	id := "000000000000000000000010"
	if _, err := clanWarIDRangeFromEnv(map[string]string{
		"CLAN_WARS_ID_AFTER": id,
		"CLAN_WARS_ID_FROM":  id,
	}); err == nil {
		t.Fatal("expected conflicting lower bounds to fail")
	}
	if _, err := clanWarIDRangeFromEnv(map[string]string{
		"CLAN_WARS_ID_FROM":   id,
		"CLAN_WARS_ID_BEFORE": id,
	}); err == nil {
		t.Fatal("expected an empty ObjectID range to fail")
	}
}

func TestClanWarLegacyNumericStringsDecode(t *testing.T) {
	payload, err := bson.Marshal(bson.D{{Key: "data", Value: bson.D{
		{Key: "teamSize", Value: "15"},
		{Key: "attacksPerMember", Value: "2"},
		{Key: "clan", Value: bson.D{
			{Key: "clanLevel", Value: "20"},
			{Key: "destructionPercentage", Value: "97.25"},
			{Key: "members", Value: bson.A{bson.D{
				{Key: "tag", Value: "#PLAYER"},
				{Key: "townhallLevel", Value: "18"},
				{Key: "mapPosition", Value: "1"},
			}}},
		}},
	}}})
	if err != nil {
		t.Fatal(err)
	}
	doc, err := decodeClanWarDoc(payload)
	if err != nil {
		t.Fatalf("decode legacy numeric strings: %v", err)
	}
	clan := canonicalArchiveClan(doc.Data.Clan)
	if migrateutil.Int(doc.Data.TeamSize) != 15 || migrateutil.Int(doc.Data.AttacksPerMember) != 2 {
		t.Fatalf("unexpected war numerics: size=%v attacks=%v", doc.Data.TeamSize, doc.Data.AttacksPerMember)
	}
	if clan.ClanLevel != 20 || clan.DestructionPercentage != 97.25 || clan.Members[0].TownhallLevel != 18 {
		t.Fatalf("unexpected canonical clan: %+v", clan)
	}
}

func TestDecodeClanWarDocRejectsMalformedNestedArrays(t *testing.T) {
	payload, err := bson.Marshal(bson.D{{Key: "data", Value: bson.D{
		{Key: "clan", Value: bson.D{{Key: "members", Value: "not-an-array"}}},
	}}})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := decodeClanWarDoc(payload); err == nil {
		t.Fatal("expected malformed members to fail typed decoding")
	}
}

func TestClanWarNullBattleModifierBecomesNone(t *testing.T) {
	payload, err := bson.Marshal(bson.D{{Key: "data", Value: bson.D{
		{Key: "battleModifier", Value: nil},
	}}})
	if err != nil {
		t.Fatal(err)
	}
	doc, err := decodeClanWarDoc(payload)
	if err != nil {
		t.Fatal(err)
	}
	if got := wararchive.NormalizeBattleModifier(doc.Data.BattleModifier); got != wararchive.BattleModifierNone {
		t.Fatalf("null battle modifier normalized to %q, want none", got)
	}
}

func TestCanonicalArchiveWarRequiresStartTime(t *testing.T) {
	doc := clanWarDoc{Data: clanWarData{
		Clan:                 warClanDoc{Tag: "#AAA"},
		Opponent:             warClanDoc{Tag: "#BBB"},
		PreparationStartTime: time.Unix(1, 0),
		EndTime:              time.Unix(3, 0),
		State:                "warended",
	}}
	if _, ok := canonicalArchiveWar(doc); ok {
		t.Fatal("finished war without startTime was accepted")
	}
	doc.Data.StartTime = time.Unix(2, 0)
	war, ok := canonicalArchiveWar(doc)
	if !ok || !war.War.StartTime.Equal(time.Unix(2, 0).UTC()) {
		t.Fatalf("valid startTime was not preserved: %#v", war)
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

func TestArchivePackPipelineCheckpointsCompletedPacksInSourceOrder(t *testing.T) {
	cp, err := migrateutil.LoadCheckpoint(migrateutil.Config{Root: t.TempDir() + "/migrations"}, "clan_wars")
	if err != nil {
		t.Fatal(err)
	}
	firstID, secondID := uuid.New(), uuid.New()
	firstStarted := make(chan struct{})
	secondFinished := make(chan struct{})
	releaseFirst := make(chan struct{})
	processor := func(_ context.Context, wars []archiveWar, _, _ chan struct{}) error {
		switch wars[0].ID {
		case firstID:
			close(firstStarted)
			<-releaseFirst
		case secondID:
			close(secondFinished)
		}
		return nil
	}
	pipeline := newArchivePackPipeline(context.Background(), 2, 1, 1, cp, "ordered", processor)
	if err := pipeline.Submit([]archiveWar{{ID: firstID}}, "first"); err != nil {
		t.Fatal(err)
	}
	if err := pipeline.Submit([]archiveWar{{ID: secondID}}, "second"); err != nil {
		t.Fatal(err)
	}
	<-firstStarted
	<-secondFinished
	closed := make(chan error, 1)
	go func() { closed <- pipeline.Close() }()
	select {
	case err := <-closed:
		t.Fatalf("pipeline closed before the first pack completed: %v", err)
	case <-time.After(20 * time.Millisecond):
	}
	close(releaseFirst)
	if err := <-closed; err != nil {
		t.Fatal(err)
	}
	if got := cp.Get("ordered"); got != "second" {
		t.Fatalf("checkpoint = %q, want second", got)
	}
}
