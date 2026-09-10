package migrateutil

import "testing"

func TestRankedDefenseLootSettings(t *testing.T) {
	apply, batch, database, err := rankedDefenseLootSettings(nil)
	if err != nil || apply || batch != 1000 || database != "" {
		t.Fatal(apply, batch, database, err)
	}
	if _, _, _, err = rankedDefenseLootSettings(map[string]string{
		"RANKED_DEFENSE_LOOT_CLEANUP_APPLY": "true",
	}); err == nil {
		t.Fatal("apply accepted without paused writers")
	}
	apply, batch, database, err = rankedDefenseLootSettings(map[string]string{
		"RANKED_DEFENSE_LOOT_CLEANUP_APPLY":      "true",
		"RANKED_BATTLELOG_WRITERS_PAUSED":        "true",
		"RANKED_DEFENSE_LOOT_CLEANUP_BATCH_SIZE": "25",
		"RANKED_DEFENSE_LOOT_CLEANUP_DATABASE":   "clashking_test",
	})
	if err != nil || !apply || batch != 25 || database != "clashking_test" {
		t.Fatal(apply, batch, database, err)
	}
	for _, value := range []string{"0", "10001", "bad"} {
		if _, _, _, err = rankedDefenseLootSettings(map[string]string{
			"RANKED_DEFENSE_LOOT_CLEANUP_BATCH_SIZE": value,
		}); err == nil {
			t.Fatal(value)
		}
	}
}
