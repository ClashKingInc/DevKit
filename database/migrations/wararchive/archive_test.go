package wararchive

import (
	"bytes"
	"encoding/binary"
	"os"
	"testing"
	"time"

	"github.com/google/uuid"
)

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
		{Type: "random", State: "warended", PreparationStartTime: time.Unix(1, 0), EndTime: time.Unix(2, 0), Clan: Clan{Tag: "#A", Members: []Member{}}, Opponent: Clan{Tag: "#B", Members: []Member{}}},
		{Type: "friendly", State: "warended", PreparationStartTime: time.Unix(3, 0), EndTime: time.Unix(4, 0), Clan: Clan{Tag: "#C", Members: []Member{}}, Opponent: Clan{Tag: "#D", Members: []Member{}}},
	}
	ids := []uuid.UUID{
		DeterministicV7("#A", "#B", time.Unix(1, 0), ""),
		DeterministicV7("#C", "#D", time.Unix(3, 0), ""),
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
	dictionary, err := os.ReadFile("../../war-json.zdict")
	if err != nil {
		t.Fatal(err)
	}
	war := War{
		Type: "random", State: "warended", PreparationStartTime: time.Unix(1, 0), EndTime: time.Unix(2, 0),
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
	stats.Add(War{
		Type: "random", TeamSize: 5, BattleModifier: "none",
		Clan:     Clan{Stars: 7, Attacks: 4, Members: []Member{{Tag: "#A", TownhallLevel: 18, Attacks: []Attack{{DefenderTag: "#B", Stars: 3, DestructionPercentage: 100, Duration: 120}}}}},
		Opponent: Clan{Stars: 5, Attacks: 3, Members: []Member{{Tag: "#B", TownhallLevel: 17}}},
	})
	if stats.Wars.Total != 1 || stats.Attacks.Total != 1 {
		t.Fatalf("unexpected totals: wars=%d attacks=%d", stats.Wars.Total, stats.Attacks.Total)
	}
	matchup := stats.Attacks.TownhallMatchups["18:17"]
	if matchup.Attacks != 1 || matchup.Triples != 1 || matchup.Stars != 3 || matchup.DestructionPercent != 100 {
		t.Fatalf("unexpected matchup: %+v", matchup)
	}
}
