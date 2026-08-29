//go:build ignore

package main

import (
	"testing"
	"time"

	"go.mongodb.org/mongo-driver/v2/bson"
)

func TestAnalyzePlayerHistoryNormalizesLegacyRows(t *testing.T) {
	catalog := staticCatalog{
		normalizePlayerHistoryName("P.E.K.K.A"):       {changeType: changeTypeTroopLevel, itemID: 9},
		normalizePlayerHistoryName("Super Barbarian"): {changeType: changeTypeTroopLevel, itemID: 26, superTroop: true},
	}
	tests := []struct {
		name       string
		doc        bson.M
		wantType   int16
		wantID     any
		wantBefore string
		wantAfter  string
		wantReason string
	}{
		{"stripped punctuation", playerHistoryTestDoc("PEKKA", int32(8), int32(9)), changeTypeTroopLevel, int16(9), "8", "9", ""},
		{"super boost", playerHistoryTestDoc("Super Barbarian", int32(10), int32(10)), changeTypeSuperTroopBoost, int16(26), "0", "1", ""},
		{"equal ordinary level", playerHistoryTestDoc("PEKKA", int32(1), int32(1)), 0, nil, "", "", "equal_value"},
		{"level decrease", playerHistoryTestDoc("PEKKA", int32(9), int32(8)), 0, nil, "", "", "decrease"},
		{"missing previous", bson.M{"tag": "#ABC", "time": int64(1_700_000_000), "type": "PEKKA", "value": int32(8)}, 0, nil, "", "", "missing_value"},
		{"builder best alias", playerHistoryTestDoc("bestVersusTrophies", int32(100), int32(101)), changeTypeBestBuilder, nil, "100", "101", ""},
		{"war preference", playerHistoryTestDoc("warPreference", "out", "in"), changeTypeWarPreference, nil, "0", "1", ""},
		{"war preference baseline", bson.M{"tag": "#ABC", "time": int64(1_700_000_000), "type": "warPreference", "value": "in"}, 0, nil, "", "", "missing_value"},
		{"name", playerHistoryTestDoc("name", "Before", "After"), changeTypeName, nil, "Before", "After", ""},
		{"excluded", playerHistoryTestDoc("warStars", int32(5), int32(6)), 0, nil, "", "", "excluded_type"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got := analyzePlayerHistory(test.doc, catalog)
			if got.reason != test.wantReason {
				t.Fatalf("reason = %q, want %q", got.reason, test.wantReason)
			}
			if test.wantReason != "" {
				if got.row != nil {
					t.Fatal("rejected document produced a row")
				}
				return
			}
			if got.row == nil || got.row.changeType != test.wantType || got.row.itemID != test.wantID ||
				got.row.previous != test.wantBefore || got.row.current != test.wantAfter {
				t.Fatalf("row = %#v", got.row)
			}
		})
	}
}

func TestFinalizeGroupRejectsSuperTroopInsideSnapshotCluster(t *testing.T) {
	run := &playerHistoryRun{
		stats:                  playerHistoryStats{rejected: map[string]int64{}, unmappedTypes: map[string]int64{}},
		rows:                   [][]any{},
		snapshotEqualThreshold: 5,
	}
	group := playerHistoryGroup{lastID: bson.NewObjectID()}
	for index := 0; index < 5; index++ {
		group.items = append(group.items, analyzedPlayerHistory{equalItem: true, reason: "equal_value"})
		group.rawCount++
	}
	group.items[0] = analyzedPlayerHistory{
		equalItem: true, superBoost: true,
		row: &playerHistoryRow{changeType: changeTypeSuperTroopBoost, itemID: int16(26), previous: "0", current: "1"},
	}
	run.finalizeGroup(&group)
	if len(run.rows) != 0 || run.stats.rejected["snapshot_cluster"] != 1 {
		t.Fatalf("rows=%d snapshot_cluster=%d", len(run.rows), run.stats.rejected["snapshot_cluster"])
	}
}

func TestNormalizePlayerHistoryTagRepairsEncodedHash(t *testing.T) {
	for input, want := range map[string]string{
		"8GLYGGJQ":     "#8GLYGGJQ",
		"#8GLYGGJQ":    "#8GLYGGJQ",
		"%238GLYGGJQ":  "#8GLYGGJQ",
		"#%238GLYGGJQ": "#8GLYGGJQ",
	} {
		if got := normalizePlayerHistoryTag(input); got != want {
			t.Errorf("normalizePlayerHistoryTag(%q) = %q, want %q", input, got, want)
		}
	}
}

func playerHistoryTestDoc(changeType string, previous, current any) bson.M {
	return bson.M{
		"tag": "#ABC", "time": time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC), "th": int32(16),
		"type": changeType, "p_value": previous, "value": current,
	}
}
