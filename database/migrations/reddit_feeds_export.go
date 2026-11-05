//go:build ignore

// Export only legacy Reddit settings. This never writes to Mongo or SQL.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"github.com/ClashKingInc/DevKit/database/migrations/migrateutil"
	"go.mongodb.org/mongo-driver/v2/bson"
	"go.mongodb.org/mongo-driver/v2/mongo/options"
	"os"
)

func main() { migrateutil.Main("reddit_feeds_export", exportRedditFeeds) }
func exportRedditFeeds(ctx context.Context, cfg migrateutil.Config) error {
	path := os.Getenv("REDDIT_FEEDS_SOURCE")
	if path == "" {
		return fmt.Errorf("REDDIT_FEEDS_SOURCE output path required")
	}
	client, e := migrateutil.StaticClient(ctx, cfg)
	if e != nil {
		return e
	}
	defer client.Disconnect(ctx)
	cursor, e := client.Database("usafam").Collection("server").Find(ctx, bson.M{"reddit_feed": bson.M{"$ne": nil}}, options.Find().SetProjection(bson.M{"_id": 0, "server": 1, "reddit_feed": 1, "reddit_role": 1, "reddit_accounts": 1}))
	if e != nil {
		return e
	}
	defer cursor.Close(ctx)
	rows := []map[string]any{}
	for cursor.Next(ctx) {
		var doc bson.M
		if e = cursor.Decode(&doc); e != nil {
			return e
		}
		accounts := []string{}
		for _, v := range migrateutil.Slice(doc["reddit_accounts"]) {
			accounts = append(accounts, migrateutil.String(v))
		}
		rows = append(rows, map[string]any{"server_id": migrateutil.String(doc["server"]), "destination_id": migrateutil.String(doc["reddit_feed"]), "role_id": migrateutil.String(doc["reddit_role"]), "accounts": accounts})
	}
	if e = cursor.Err(); e != nil {
		return e
	}
	data, e := json.MarshalIndent(rows, "", "  ")
	if e != nil {
		return e
	}
	if e = os.WriteFile(path, append(data, '\n'), 0600); e != nil {
		return e
	}
	fmt.Printf("Exported %d legacy Reddit settings; no source writes\n", len(rows))
	return nil
}
