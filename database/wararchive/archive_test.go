package wararchive

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"os"
	"testing"
	"time"

	"github.com/google/uuid"
)

func TestMarshalOnlyOmitsEmptyWarTag(t *testing.T) {
	payload, err := Marshal(War{
		BattleModifier: BattleModifierNone,
		StartTime:      time.Unix(1, 0).UTC(),
		Clan:           Clan{Members: []Member{{Attacks: []Attack{}}}},
		Opponent:       Clan{Members: []Member{}},
	})
	if err != nil {
		t.Fatal(err)
	}
	var decoded map[string]any
	if err := json.Unmarshal(payload, &decoded); err != nil {
		t.Fatal(err)
	}
	if _, exists := decoded["warTag"]; exists {
		t.Fatal("empty warTag must be omitted")
	}
	if _, exists := decoded["type"]; exists {
		t.Fatal("SQL-only war type must not be archived")
	}
	requireJSONKeys(t, decoded, "startTime", "battleModifier")
	clan := decoded["clan"].(map[string]any)
	requireJSONKeys(t, clan, "name", "badgeToken", "clanLevel", "attacks", "stars", "destructionPercentage")
	member := clan["members"].([]any)[0].(map[string]any)
	requireJSONKeys(t, member, "name", "townhallLevel", "mapPosition", "attacks")
}

func TestMarshalRejectsMissingStartTime(t *testing.T) {
	if _, err := Marshal(War{}); err == nil {
		t.Fatal("war without startTime was marshaled")
	}
}

func requireJSONKeys(t *testing.T, value map[string]any, keys ...string) {
	t.Helper()
	for _, key := range keys {
		if _, exists := value[key]; !exists {
			t.Errorf("JSON object omitted %q: %#v", key, value)
		}
	}
}

func TestDeterministicV7IsStableAndOrderIndependent(t *testing.T) {
	prep := time.Date(2026, 8, 23, 12, 30, 0, 0, time.UTC)
	first := DeterministicV7("#AAA", "#BBB", prep, "#WAR")
	second := DeterministicV7("#BBB", "#AAA", prep, "#WAR")
	if first != second {
		t.Fatalf("swapping clan perspectives changed id: %s != %s", first, second)
	}
	if first.Version() != 7 {
		t.Fatalf("version = %d, want 7", first.Version())
	}
	var encoded [8]byte
	copy(encoded[2:], first[:6])
	if got := int64(binary.BigEndian.Uint64(encoded[:])); got != prep.UnixMilli() {
		t.Fatalf("timestamp = %d, want %d", got, prep.UnixMilli())
	}
}

func TestNormalizeBattleModifier(t *testing.T) {
	tests := map[string]string{
		"":            BattleModifierNone,
		"null":        BattleModifierNone,
		"NONE":        BattleModifierNone,
		"hardMode":    BattleModifierHardMode,
		"HARD_MODE":   BattleModifierHardMode,
		"minus_one":   BattleModifierMinusOne,
		"MINUS_TWO":   BattleModifierMinusTwo,
		"minus-three": BattleModifierMinusThree,
		"unknown":     BattleModifierNone,
	}
	for input, want := range tests {
		if got := NormalizeBattleModifier(input); got != want {
			t.Errorf("NormalizeBattleModifier(%q) = %q, want %q", input, got, want)
		}
	}
}

func TestPackFramesDecodeIndependently(t *testing.T) {
	builder, err := NewPackBuilder(42, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer builder.Close()
	wars := []War{
		{State: "warended", PreparationStartTime: time.Unix(1, 0), StartTime: time.Unix(2, 0), EndTime: time.Unix(3, 0), Clan: Clan{Tag: "#A", Members: []Member{}}, Opponent: Clan{Tag: "#B", Members: []Member{}}},
		{State: "warended", PreparationStartTime: time.Unix(4, 0), StartTime: time.Unix(5, 0), EndTime: time.Unix(6, 0), Clan: Clan{Tag: "#C", Members: []Member{}}, Opponent: Clan{Tag: "#D", Members: []Member{}}},
	}
	ids := []uuid.UUID{
		DeterministicV7("#A", "#B", time.Unix(1, 0), ""),
		DeterministicV7("#C", "#D", time.Unix(4, 0), ""),
	}
	for index, war := range wars {
		if _, err := builder.Add(ids[index], war); err != nil {
			t.Fatal(err)
		}
	}
	for index, locator := range builder.Locators() {
		frame := builder.Bytes()[locator.Offset : locator.Offset+int64(locator.CompressedBytes)]
		raw, err := DecodeFrame(frame, nil)
		if err != nil {
			t.Fatal(err)
		}
		want, err := Marshal(wars[index])
		if err != nil {
			t.Fatal(err)
		}
		if !bytes.Equal(raw, want) {
			t.Fatalf("decoded frame %d differs from source", index)
		}
	}
}

func TestCheckedInDictionaryRoundTrip(t *testing.T) {
	dictionary, err := os.ReadFile("../war-json.zdict")
	if err != nil {
		t.Fatal(err)
	}
	war := War{
		State: "warended", PreparationStartTime: time.Unix(1, 0), StartTime: time.Unix(2, 0), EndTime: time.Unix(3, 0),
		Clan:     Clan{Tag: "#A", Members: []Member{{Tag: "#P1", TownhallLevel: 18}}},
		Opponent: Clan{Tag: "#B", Members: []Member{{Tag: "#P2", TownhallLevel: 17}}},
	}
	id := DeterministicV7(war.Clan.Tag, war.Opponent.Tag, war.PreparationStartTime, "")
	builder, err := NewPackBuilder(1, dictionary)
	if err != nil {
		t.Fatal(err)
	}
	defer builder.Close()
	locator, err := builder.Add(id, war)
	if err != nil {
		t.Fatal(err)
	}
	frame := builder.Bytes()[locator.Offset : locator.Offset+int64(locator.CompressedBytes)]
	raw, err := DecodeFrame(frame, dictionary)
	if err != nil {
		t.Fatal(err)
	}
	want, err := Marshal(war)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(raw, want) {
		t.Fatal("dictionary-compressed frame differs from source after decoding")
	}
}

func TestPackStatsAreAdditive(t *testing.T) {
	stats := NewPackStats()
	stats.Add("random", War{
		TeamSize: 2, AttacksPerMember: 2, EndTime: time.Date(2026, 8, 23, 12, 0, 0, 0, time.UTC),
		Clan: Clan{Stars: 7, DestructionPercentage: 80, Members: []Member{
			{Tag: "#A1", TownhallLevel: 18, Attacks: []Attack{{DefenderTag: "#B1", Stars: 0, DestructionPercentage: 65, Duration: 90}}},
			{Tag: "#A2", TownhallLevel: 17, Attacks: []Attack{{DefenderTag: "#B2", Stars: 3, DestructionPercentage: 100, Duration: 120}}},
		}},
		Opponent: Clan{Stars: 5, DestructionPercentage: 70, Members: []Member{
			{Tag: "#B1", TownhallLevel: 18, Attacks: []Attack{{DefenderTag: "#A1", Stars: 2, DestructionPercentage: 85, Duration: 110}}},
			{Tag: "#B2", TownhallLevel: 17, Attacks: []Attack{{DefenderTag: "#A2", Stars: 1, DestructionPercentage: 50, Duration: 80}}},
		}},
	})
	day := stats.ByDay["2026-08-23"]
	if day.WarsByType["random"] != 1 || day.WarsBySize["2"] != 1 {
		t.Fatalf("unexpected war counts: %+v", day)
	}
	if day.TotalAttacks != 4 || day.TotalMissedAttacks != 4 || stats.TotalAttacks() != 4 {
		t.Fatalf("unexpected attack totals: attacks=%d missed=%d", day.TotalAttacks, day.TotalMissedAttacks)
	}
	matchup := day.RegularHitRates["18:18"]
	if matchup.Attacks != 2 || matchup.ZeroStars.Attacks != 1 || matchup.ZeroStars.DestructionPercent != 65 || matchup.ZeroStars.DurationSeconds != 90 || matchup.TwoStars.Attacks != 1 || matchup.TwoStars.DestructionPercent != 85 || matchup.TwoStars.DurationSeconds != 110 {
		t.Fatalf("unexpected matchup: %+v", matchup)
	}
	matchup = day.RegularHitRates["17:17"]
	if matchup.Attacks != 2 || matchup.OneStars.Attacks != 1 || matchup.ThreeStars.Attacks != 1 || matchup.ThreeStars.DurationSeconds != 120 {
		t.Fatalf("unexpected matchup: %+v", matchup)
	}
	bySize := day.RegularByWarSize["2"]
	if bySize.Wars != 1 || bySize.Townhalls["18"] != 2 || bySize.Townhalls["17"] != 2 || bySize.TotalStars != 12 || bySize.Wins != 1 || bySize.Losses != 1 || bySize.Ties != 0 {
		t.Fatalf("unexpected regular war size stats: %+v", bySize)
	}
}

func TestPackStatsKeepNonRegularWarsOutOfRegularBreakdowns(t *testing.T) {
	stats := NewPackStats()
	stats.Add("cwl", War{
		TeamSize: 1, AttacksPerMember: 1, EndTime: time.Date(2026, 8, 24, 1, 0, 0, 0, time.UTC),
		Clan:     Clan{Members: []Member{{Tag: "#A", TownhallLevel: 18}}},
		Opponent: Clan{Members: []Member{{Tag: "#B", TownhallLevel: 18}}},
	})
	day := stats.ByDay["2026-08-24"]
	if day.WarsByType["cwl"] != 1 || day.WarsBySize["1"] != 1 || day.TotalMissedAttacks != 2 {
		t.Fatalf("unexpected daily totals: %+v", day)
	}
	if len(day.RegularHitRates) != 0 || len(day.RegularByWarSize) != 0 {
		t.Fatalf("CWL leaked into regular-war breakdowns: %+v", day)
	}
}

func TestPackStatsRecordTiedRegularWarAsTwoTiedSides(t *testing.T) {
	stats := NewPackStats()
	stats.Add("random", War{
		TeamSize: 1, EndTime: time.Date(2026, 8, 24, 1, 0, 0, 0, time.UTC),
		Clan:     Clan{Stars: 3, DestructionPercentage: 100, Members: []Member{{Tag: "#A", TownhallLevel: 18}}},
		Opponent: Clan{Stars: 3, DestructionPercentage: 100, Members: []Member{{Tag: "#B", TownhallLevel: 18}}},
	})
	value := stats.ByDay["2026-08-24"].RegularByWarSize["1"]
	if value.Wars != 1 || value.Wins != 0 || value.Losses != 0 || value.Ties != 2 {
		t.Fatalf("unexpected tied-war outcomes: %+v", value)
	}
}

func TestPackStatsJSONOmitsLegacyShapes(t *testing.T) {
	raw, err := json.Marshal(NewPackStats())
	if err != nil {
		t.Fatal(err)
	}
	for _, legacy := range []string{`"sides"`, `"byWeekTypeMatchup"`, `"stars"`} {
		if bytes.Contains(raw, []byte(legacy)) {
			t.Fatalf("legacy field %s remains in %s", legacy, raw)
		}
	}
}
