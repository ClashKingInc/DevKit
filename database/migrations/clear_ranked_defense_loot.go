//go:build ignore

package main

import (
	"context"

	"github.com/ClashKingInc/DevKit/database/migrations/migrateutil"
)

func main() {
	migrateutil.Main("clear_ranked_defense_loot", func(ctx context.Context, cfg migrateutil.Config) error {
		return migrateutil.ClearRankedDefenseLoot(ctx, cfg)
	})
}
