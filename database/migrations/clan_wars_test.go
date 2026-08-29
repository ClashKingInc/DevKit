//go:build ignore

package main

import (
	"context"
	"io"
	"net/http"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/ClashKingInc/DevKit/database/migrations/migrateutil"
	"github.com/ClashKingInc/DevKit/database/wararchive"
	"go.mongodb.org/mongo-driver/v2/bson"
)

type roundTripFunc func(*http.Request) (*http.Response, error)

func (function roundTripFunc) RoundTrip(request *http.Request) (*http.Response, error) {
	return function(request)
}

func TestWarArchiveCachePrimeUsesOneByteRangeGET(t *testing.T) {
	client := &http.Client{Transport: roundTripFunc(func(request *http.Request) (*http.Response, error) {
		if request.Method != http.MethodGet {
			t.Errorf("method = %s, want GET", request.Method)
		}
		if got := request.Header.Get("Range"); got != "bytes=0-0" {
			t.Errorf("Range = %q, want bytes=0-0", got)
		}
		return &http.Response{
			StatusCode: http.StatusPartialContent,
			Header: http.Header{
				"CF-Cache-Status": {"MISS"},
				"Content-Range":   {"bytes 0-0/1024"},
			},
			Body: io.NopCloser(strings.NewReader("x")),
		}, nil
	})}

	store := &warArchiveStore{publicOrigin: "https://wars.example", httpClient: client}
	if err := store.prime(context.Background(), "packs/000001.pack"); err != nil {
		t.Fatal(err)
	}
}

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

func TestClanWarEndTimeRangeUsesSortableClashTimestamps(t *testing.T) {
	value, err := clanWarEndTimeRangeFromEnv(map[string]string{
		"CLAN_WARS_END_TIME_FROM":   "2026-06-01T00:00:00Z",
		"CLAN_WARS_END_TIME_BEFORE": "20260701T000000.000Z",
	})
	if err != nil {
		t.Fatal(err)
	}
	if value.from != "20260601T000000.000Z" || value.before != "20260701T000000.000Z" {
		t.Fatalf("unexpected normalized range: %+v", value)
	}
	want := bson.D{
		{Key: "_id", Value: bson.D{{Key: "$exists", Value: true}}},
		{Key: "data.endTime", Value: bson.D{
			{Key: "$gte", Value: "20260601T000000.000Z"},
			{Key: "$lt", Value: "20260701T000000.000Z"},
		}},
	}
	if got := applyClanWarEndTimeRange(clanWarFilter(""), value); !reflect.DeepEqual(got, want) {
		t.Fatalf("end-time filter = %#v, want %#v", got, want)
	}
	if got := value.checkpointKey("wars"); got != "wars_from_20260601T000000_before_20260701T000000" {
		t.Fatalf("checkpoint key = %q", got)
	}
}

func TestClanWarEndTimeRangeRejectsEmptyOrReversedRange(t *testing.T) {
	if _, err := clanWarEndTimeRangeFromEnv(map[string]string{
		"CLAN_WARS_END_TIME_FROM":   "2026-07-01",
		"CLAN_WARS_END_TIME_BEFORE": "2026-06-01",
	}); err == nil {
		t.Fatal("expected reversed end-time range to fail")
	}
}

func TestClanWarNumericBSONTypesDecode(t *testing.T) {
	payload, err := bson.Marshal(bson.D{{Key: "data", Value: bson.D{
		{Key: "teamSize", Value: int32(15)},
		{Key: "attacksPerMember", Value: int64(2)},
		{Key: "clan", Value: bson.D{
			{Key: "clanLevel", Value: int64(20)},
			{Key: "destructionPercentage", Value: 97.25},
			{Key: "members", Value: bson.A{bson.D{
				{Key: "tag", Value: "#PLAYER"},
				{Key: "townhallLevel", Value: int32(18)},
				{Key: "mapPosition", Value: int64(1)},
			}}},
		}},
	}}})
	if err != nil {
		t.Fatal(err)
	}
	doc, err := decodeClanWarDoc(payload)
	if err != nil {
		t.Fatalf("decode BSON numerics: %v", err)
	}
	clan := canonicalArchiveClan(doc.Data.Clan)
	if doc.Data.TeamSize != 15 || doc.Data.AttacksPerMember != 2 {
		t.Fatalf("unexpected war numerics: size=%v attacks=%v", doc.Data.TeamSize, doc.Data.AttacksPerMember)
	}
	if clan.ClanLevel != 20 || clan.DestructionPercentage != 97.25 || clan.Members[0].TownhallLevel != 18 {
		t.Fatalf("unexpected canonical clan: %+v", clan)
	}
}

func TestClanWarNumericStringsAreMalformed(t *testing.T) {
	payload, err := bson.Marshal(bson.D{{Key: "data", Value: bson.D{{Key: "teamSize", Value: "15"}}}})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := decodeClanWarDoc(payload); err == nil {
		t.Fatal("numeric string decoded into typed war document")
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
	firstID, secondID := "first-source", "second-source"
	firstStarted := make(chan struct{})
	secondFinished := make(chan struct{})
	releaseFirst := make(chan struct{})
	processor := func(_ context.Context, wars []archiveWar, _, _ string, _, _ chan struct{}) error {
		switch wars[0].SourceID {
		case firstID:
			close(firstStarted)
			<-releaseFirst
		case secondID:
			close(secondFinished)
		}
		return nil
	}
	pipeline := newArchivePackPipeline(context.Background(), 2, 1, 1, cp, "ordered", processor)
	if err := pipeline.Submit([]archiveWar{{SourceID: firstID}}, "first"); err != nil {
		t.Fatal(err)
	}
	if err := pipeline.Submit([]archiveWar{{SourceID: secondID}}, "second"); err != nil {
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

func TestAggregatePlayerWarHistoryGroupsPlayersAndDeduplicatesSides(t *testing.T) {
	endTime := time.Date(2026, 6, 15, 12, 0, 0, 0, time.UTC)
	rows := aggregatePlayerWarHistory([]archiveWar{
		{
			ID: 42,
			War: wararchive.War{
				EndTime:  endTime,
				Clan:     wararchive.Clan{Members: []wararchive.Member{{Tag: "#A"}, {Tag: "#B"}}},
				Opponent: wararchive.Clan{Members: []wararchive.Member{{Tag: "#B"}, {Tag: "#C"}}},
			},
		},
		{
			ID: 7,
			War: wararchive.War{
				EndTime: endTime,
				Clan:    wararchive.Clan{Members: []wararchive.Member{{Tag: "#A"}}},
			},
		},
	})
	if len(rows) != 3 {
		t.Fatalf("history rows = %d, want 3: %#v", len(rows), rows)
	}
	wantIDs := [][]int32{{7, 42}, {42}, {42}}
	for index, tag := range []string{"#A", "#B", "#C"} {
		if rows[index].playerTag != tag || !reflect.DeepEqual(rows[index].warIDs, wantIDs[index]) {
			t.Fatalf("row %d = %#v", index, rows[index])
		}
	}
}
