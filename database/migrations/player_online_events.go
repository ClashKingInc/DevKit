//go:build ignore

package main

import (
	"context"
	"fmt"
	"sort"
	"time"

	"github.com/ClashKingInc/DevKit/database/migrations/migrateutil"
	"github.com/jackc/pgx/v5"
	"go.mongodb.org/mongo-driver/v2/bson"
	"go.mongodb.org/mongo-driver/v2/mongo"
	"go.mongodb.org/mongo-driver/v2/mongo/options"
)

type malformedOnlineWindow struct {
	start             time.Time
	end               time.Time
	playerTags        []string
	buckets           int
	controlCountTotal int
}

func main() {
	migrateutil.Main("player_online_events", runPlayerOnlineEvents)
}

func runPlayerOnlineEvents(ctx context.Context, cfg migrateutil.Config) error {
	mongoClient, err := migrateutil.StatsClient(ctx, cfg)
	if err != nil {
		return err
	}
	defer mongoClient.Disconnect(ctx)
	pool, err := migrateutil.TimescalePool(ctx, cfg)
	if err != nil {
		return err
	}
	defer pool.Close()
	collection := mongoClient.Database("looper").Collection("last_online")
	malformed, err := findMalformedOnlineWindow(ctx, mongoClient.Database("looper").Collection("system.buckets.last_online"))
	if err != nil {
		return err
	}
	plan := migrateutil.OneShotPlan{
		ResetSQL: []string{`TRUNCATE TABLE public.player_online_events`},
		DropIndexes: []string{
			`DROP INDEX IF EXISTS public.idx_player_online_events_clan_time`,
			`DROP INDEX IF EXISTS public.idx_player_online_events_player_time`,
			`DROP INDEX IF EXISTS public.player_online_events_seen_at_idx`,
		},
		CreateIndexes: []string{
			`CREATE INDEX idx_player_online_events_clan_time ON public.player_online_events (clan_tag, seen_at DESC)`,
			`CREATE INDEX idx_player_online_events_player_time ON public.player_online_events (tag, seen_at DESC)`,
		},
	}
	if err := migrateutil.StartOneShot(ctx, pool, plan); err != nil {
		return err
	}
	rows := make([][]any, 0, cfg.BatchSize)
	flush := func() error {
		if len(rows) == 0 {
			return nil
		}
		err := flushPlayerOnlineRows(ctx, pool, rows)
		rows = rows[:0]
		return err
	}
	projection := bson.D{
		{Key: "_id", Value: 0},
		{Key: "timestamp", Value: 1},
		{Key: "meta", Value: 1},
	}
	handle := func(doc bson.M) (bool, error) {
		meta := migrateutil.Map(doc["meta"])
		seenAt, ok := migrateutil.Time(doc["timestamp"])
		if !ok || meta == nil {
			return false, nil
		}
		tag := firstOnlineString(meta["tag"], meta["player_tag"], meta["player"])
		clanTag := firstOnlineString(meta["clan_tag"], meta["clan"])
		if tag == "" || clanTag == "" {
			return false, nil
		}
		rows = append(rows, []any{seenAt, tag, clanTag})
		return len(rows) >= cfg.BatchSize, nil
	}
	var seen int64
	if malformed.buckets == 0 {
		seen, err = migrateutil.StreamAllProjected(ctx, cfg, "last_online", collection, projection, handle, flush)
	} else {
		filters := []bson.D{
			{{Key: "timestamp", Value: bson.D{{Key: "$lt", Value: malformed.start}}}},
			{
				{Key: "timestamp", Value: bson.D{
					{Key: "$gte", Value: malformed.start},
					{Key: "$lte", Value: malformed.end},
				}},
				{Key: "meta.tag", Value: bson.D{{Key: "$nin", Value: malformed.playerTags}}},
			},
			{{Key: "timestamp", Value: bson.D{{Key: "$gt", Value: malformed.end}}}},
		}
		for index, filter := range filters {
			partSeen, streamErr := migrateutil.StreamFilteredProjected(
				ctx, cfg, fmt.Sprintf("last_online_part_%d", index+1), collection, filter, projection, handle, flush,
			)
			seen += partSeen
			if streamErr != nil {
				err = streamErr
				break
			}
		}
	}
	if err != nil {
		return err
	}
	if err := migrateutil.FinishOneShot(ctx, pool, plan); err != nil {
		return err
	}
	fmt.Printf(
		"player_online_events: scanned_docs=%d malformed_buckets_skipped=%d malformed_control_count=%d malformed_start=%s malformed_end=%s\n",
		seen, malformed.buckets, malformed.controlCountTotal, malformed.start.Format(time.RFC3339Nano), malformed.end.Format(time.RFC3339Nano),
	)
	return nil
}

func findMalformedOnlineWindow(ctx context.Context, buckets *mongo.Collection) (malformedOnlineWindow, error) {
	filter := bson.D{
		{Key: "control.version", Value: 2},
		{Key: "data._id", Value: bson.D{{Key: "$type", Value: 10}}},
		{Key: "data.timestamp", Value: bson.D{{Key: "$type", Value: 10}}},
	}
	cursor, err := buckets.Find(ctx, filter, options.Find().SetProjection(bson.D{
		{Key: "_id", Value: 0},
		{Key: "control", Value: 1},
		{Key: "meta", Value: 1},
	}))
	if err != nil {
		return malformedOnlineWindow{}, fmt.Errorf("find malformed online buckets: %w", err)
	}
	defer cursor.Close(ctx)

	window := malformedOnlineWindow{}
	playerTags := map[string]struct{}{}
	for cursor.Next(ctx) {
		var bucket bson.M
		if err := cursor.Decode(&bucket); err != nil {
			return malformedOnlineWindow{}, fmt.Errorf("decode malformed online bucket: %w", err)
		}
		control := migrateutil.Map(bucket["control"])
		start, startOK := migrateutil.Time(migrateutil.Map(control["min"])["timestamp"])
		end, endOK := migrateutil.Time(migrateutil.Map(control["max"])["timestamp"])
		meta := migrateutil.Map(bucket["meta"])
		tag := firstOnlineString(meta["tag"], meta["player_tag"], meta["player"])
		if !startOK || !endOK || tag == "" {
			return malformedOnlineWindow{}, fmt.Errorf("malformed online bucket is missing its time envelope or player tag")
		}
		if window.buckets == 0 || start.Before(window.start) {
			window.start = start
		}
		if window.buckets == 0 || end.After(window.end) {
			window.end = end
		}
		window.buckets++
		window.controlCountTotal += migrateutil.Int(control["count"])
		playerTags[tag] = struct{}{}
	}
	if err := cursor.Err(); err != nil {
		return malformedOnlineWindow{}, fmt.Errorf("scan malformed online buckets: %w", err)
	}
	window.playerTags = make([]string, 0, len(playerTags))
	for tag := range playerTags {
		window.playerTags = append(window.playerTags, tag)
	}
	sort.Strings(window.playerTags)
	return window, nil
}

func flushPlayerOnlineRows(ctx context.Context, pool interface {
	Begin(context.Context) (pgx.Tx, error)
}, rows [][]any) error {
	tx, err := pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, `
		CREATE TEMP TABLE _ck_player_online_events (
			seen_at timestamptz, tag text, clan_tag text
		) ON COMMIT DROP
	`); err != nil {
		return err
	}
	if _, err := tx.CopyFrom(ctx, pgx.Identifier{"_ck_player_online_events"}, []string{
		"seen_at", "tag", "clan_tag",
	}, pgx.CopyFromRows(rows)); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `
		INSERT INTO player_online_events (seen_at, tag, clan_tag)
		SELECT seen_at, tag, clan_tag
		FROM _ck_player_online_events
		WHERE tag <> '' AND clan_tag <> ''
	`); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

func firstOnlineAny(values ...any) any {
	for _, value := range values {
		if migrateutil.String(value) != "" {
			return value
		}
	}
	return nil
}

func firstOnlineString(values ...any) string {
	return migrateutil.String(firstOnlineAny(values...))
}
