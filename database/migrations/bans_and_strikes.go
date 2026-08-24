//go:build ignore

package main

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/ClashKingInc/DevKit/database/migrations/migrateutil"
	"github.com/jackc/pgx/v5"
	"go.mongodb.org/mongo-driver/v2/bson"
	"go.mongodb.org/mongo-driver/v2/mongo"
)

type banRow struct {
	serverID  string
	playerTag string
	name      string
	reason    string
	addedBy   string
	editedBy  string
	image     any
	createdAt time.Time
	updatedAt time.Time
}

type strikeRow struct {
	id           string
	serverID     string
	playerTag    string
	createdAt    time.Time
	reason       string
	addedBy      string
	weight       int
	rolloverDate any
	image        any
}

func main() {
	migrateutil.Main("bans_and_strikes", runBansAndStrikes)
}

func runBansAndStrikes(ctx context.Context, cfg migrateutil.Config) error {
	client, err := migrateutil.StaticClient(ctx, cfg)
	if err != nil {
		return err
	}
	defer client.Disconnect(ctx)
	pool, err := migrateutil.TimescalePool(ctx, cfg)
	if err != nil {
		return err
	}
	defer pool.Close()

	plan := bansAndStrikesOneShotPlan()
	if err := migrateutil.StartOneShot(ctx, pool, plan); err != nil {
		return err
	}

	database := client.Database("usafam")
	banCount, err := migrateBanDocuments(ctx, cfg, pool, database.Collection("banlist"))
	if err != nil {
		return err
	}
	strikeCount, err := migrateStrikeDocuments(ctx, cfg, pool, database.Collection("strikes"))
	if err != nil {
		return err
	}
	if err := migrateutil.FinishOneShot(ctx, pool, plan); err != nil {
		return err
	}
	fmt.Printf("bans_and_strikes: bans_written=%d strikes_written=%d\n", banCount, strikeCount)
	return nil
}

func bansAndStrikesOneShotPlan() migrateutil.OneShotPlan {
	return migrateutil.OneShotPlan{
		ResetSQL: []string{`TRUNCATE TABLE public.server_bans, public.strikes`},
		DropIndexes: []string{
			`DROP INDEX IF EXISTS public.idx_server_bans_player_tag`,
			`DROP INDEX IF EXISTS public.idx_strikes_server_id`,
			`DROP INDEX IF EXISTS public.idx_strikes_tag`,
		},
		CreateIndexes: []string{
			`CREATE INDEX idx_server_bans_player_tag ON public.server_bans (player_tag)`,
			`CREATE INDEX idx_strikes_server_id ON public.strikes (server_id)`,
			`CREATE INDEX idx_strikes_tag ON public.strikes (tag)`,
		},
	}
}

func migrateBanDocuments(ctx context.Context, cfg migrateutil.Config, pool interface {
	Begin(context.Context) (pgx.Tx, error)
}, collection *mongo.Collection) (int64, error) {
	rows := make(map[string]banRow, cfg.BatchSize)
	var accepted, written int64
	flush := func() error {
		if len(rows) == 0 {
			return nil
		}
		if err := flushBanRows(ctx, pool, rows); err != nil {
			return err
		}
		written += int64(len(rows))
		rows = make(map[string]banRow, cfg.BatchSize)
		return nil
	}
	seen, err := migrateutil.StreamAll(ctx, cfg, "bans", collection, func(doc bson.M) (bool, error) {
		row, ok := banRowFromDocument(doc)
		if ok {
			accepted++
			rows[row.serverID+"\x00"+row.playerTag] = row
		}
		return len(rows) >= cfg.BatchSize, nil
	}, flush)
	fmt.Printf("bans: scanned_docs=%d accepted_docs=%d written_rows=%d skipped_docs=%d\n", seen, accepted, written, seen-accepted)
	return written, err
}

func migrateStrikeDocuments(ctx context.Context, cfg migrateutil.Config, pool interface {
	Begin(context.Context) (pgx.Tx, error)
}, collection *mongo.Collection) (int64, error) {
	rows := make(map[string]strikeRow, cfg.BatchSize)
	var accepted, written int64
	flush := func() error {
		if len(rows) == 0 {
			return nil
		}
		if err := flushStrikeRows(ctx, pool, rows); err != nil {
			return err
		}
		written += int64(len(rows))
		rows = make(map[string]strikeRow, cfg.BatchSize)
		return nil
	}
	seen, err := migrateutil.StreamAll(ctx, cfg, "strikes", collection, func(doc bson.M) (bool, error) {
		row, ok := strikeRowFromDocument(doc)
		if ok {
			accepted++
			rows[row.serverID+"\x00"+row.id] = row
		}
		return len(rows) >= cfg.BatchSize, nil
	}, flush)
	fmt.Printf("strikes: scanned_docs=%d accepted_docs=%d written_rows=%d skipped_docs=%d\n", seen, accepted, written, seen-accepted)
	return written, err
}

func banRowFromDocument(doc bson.M) (banRow, bool) {
	serverID := migrateutil.String(doc["server"])
	playerTag := normalizePlayerTag(doc["VillageTag"])
	createdAt, ok := legacyDocumentTime(doc, "DateCreated", "created_at")
	if serverID == "" || playerTag == "" || !ok {
		return banRow{}, false
	}
	updatedAt, updated := legacyDocumentTime(doc, "updated_at")
	if !updated {
		updatedAt = createdAt
	}
	editedBy := doc["edited_by"]
	if migrateutil.Slice(editedBy) == nil {
		editedBy = bson.A{}
	}
	name := firstModerationString(doc["VillageName"], doc["name"], playerTag)
	var image any
	if value := migrateutil.String(doc["image"]); value != "" {
		image = value
	}
	return banRow{
		serverID:  serverID,
		playerTag: playerTag,
		name:      name,
		reason:    migrateutil.String(doc["Notes"]),
		addedBy:   migrateutil.String(doc["added_by"]),
		editedBy:  migrateutil.RawJSON(editedBy),
		image:     image,
		createdAt: createdAt,
		updatedAt: updatedAt,
	}, true
}

func strikeRowFromDocument(doc bson.M) (strikeRow, bool) {
	id := strings.ToUpper(migrateutil.String(doc["strike_id"]))
	serverID := migrateutil.String(doc["server"])
	playerTag := normalizePlayerTag(doc["tag"])
	createdAt, ok := legacyDocumentTime(doc, "date_created", "created_at")
	if id == "" || serverID == "" || playerTag == "" || !ok {
		return strikeRow{}, false
	}
	weight := normalizedStrikeWeight(doc["strike_weight"])
	var rolloverDate any
	if value, valid := migrateutil.Time(doc["rollover_date"]); valid {
		rolloverDate = value
	}
	var image any
	if value := migrateutil.String(doc["image"]); value != "" {
		image = value
	}
	return strikeRow{
		id:           id,
		serverID:     serverID,
		playerTag:    playerTag,
		createdAt:    createdAt,
		reason:       migrateutil.String(doc["reason"]),
		addedBy:      migrateutil.String(doc["added_by"]),
		weight:       weight,
		rolloverDate: rolloverDate,
		image:        image,
	}, true
}

func normalizedStrikeWeight(value any) int {
	weight := migrateutil.Int(value)
	if weight < 1 || weight > 1<<31-1 {
		return 1
	}
	return weight
}

func legacyDocumentTime(doc bson.M, keys ...string) (time.Time, bool) {
	for _, key := range keys {
		value := doc[key]
		if parsed, ok := migrateutil.Time(value); ok {
			return parsed, true
		}
		if raw := migrateutil.String(value); raw != "" {
			for _, layout := range []string{"2006-01-02 15:04:05", "2006-01-02 15:04:05.999999"} {
				if parsed, err := time.ParseInLocation(layout, raw, time.UTC); err == nil {
					return parsed.UTC(), true
				}
			}
		}
	}
	if objectID, ok := doc["_id"].(bson.ObjectID); ok {
		return objectID.Timestamp().UTC(), true
	}
	return time.Time{}, false
}

func normalizePlayerTag(value any) string {
	tag := strings.ToUpper(strings.TrimSpace(migrateutil.String(value)))
	if tag != "" && !strings.HasPrefix(tag, "#") {
		tag = "#" + tag
	}
	return tag
}

func firstModerationString(values ...any) string {
	for _, value := range values {
		if out := migrateutil.String(value); out != "" {
			return out
		}
	}
	return ""
}

func flushBanRows(ctx context.Context, pool interface {
	Begin(context.Context) (pgx.Tx, error)
}, rows map[string]banRow) error {
	tx, err := pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, `
		CREATE TEMP TABLE _ck_server_bans (
			server_id text, player_tag text, player_name text, reason text,
			added_by text, edited_by text, image text, created_at timestamptz,
			updated_at timestamptz
		) ON COMMIT DROP
	`); err != nil {
		return err
	}
	copyRows := make([][]any, 0, len(rows))
	for _, row := range rows {
		copyRows = append(copyRows, []any{
			row.serverID, row.playerTag, row.name, row.reason, row.addedBy,
			row.editedBy, row.image, row.createdAt, row.updatedAt,
		})
	}
	if _, err := tx.CopyFrom(ctx, pgx.Identifier{"_ck_server_bans"}, []string{
		"server_id", "player_tag", "player_name", "reason", "added_by",
		"edited_by", "image", "created_at", "updated_at",
	}, pgx.CopyFromRows(copyRows)); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `
		INSERT INTO public.server_bans (
			server_id, player_tag, player_name, reason, added_by,
			edited_by, image, created_at, updated_at
		)
		SELECT server_id, player_tag, player_name, reason, added_by,
			edited_by::jsonb, image, created_at, updated_at
		FROM _ck_server_bans
		ON CONFLICT (server_id, player_tag) DO UPDATE SET
			player_name = EXCLUDED.player_name,
			reason = EXCLUDED.reason,
			added_by = EXCLUDED.added_by,
			edited_by = EXCLUDED.edited_by,
			image = EXCLUDED.image,
			created_at = EXCLUDED.created_at,
			updated_at = EXCLUDED.updated_at
		WHERE EXCLUDED.updated_at >= server_bans.updated_at
	`); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

func flushStrikeRows(ctx context.Context, pool interface {
	Begin(context.Context) (pgx.Tx, error)
}, rows map[string]strikeRow) error {
	tx, err := pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, `
		CREATE TEMP TABLE _ck_strikes (
			id text, server_id text, tag text, date_created timestamptz,
			reason text, added_by text, strike_weight integer,
			rollover_date timestamptz, image text
		) ON COMMIT DROP
	`); err != nil {
		return err
	}
	copyRows := make([][]any, 0, len(rows))
	for _, row := range rows {
		copyRows = append(copyRows, []any{
			row.id, row.serverID, row.playerTag, row.createdAt, row.reason,
			row.addedBy, row.weight, row.rolloverDate, row.image,
		})
	}
	if _, err := tx.CopyFrom(ctx, pgx.Identifier{"_ck_strikes"}, []string{
		"id", "server_id", "tag", "date_created", "reason", "added_by",
		"strike_weight", "rollover_date", "image",
	}, pgx.CopyFromRows(copyRows)); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `
		INSERT INTO public.strikes (
			id, server_id, tag, date_created, reason, added_by,
			strike_weight, rollover_date, image
		)
		SELECT id, server_id, tag, date_created, reason, added_by,
			strike_weight, rollover_date, image
		FROM _ck_strikes
		ON CONFLICT (id, server_id) DO UPDATE SET
			tag = EXCLUDED.tag,
			date_created = EXCLUDED.date_created,
			reason = EXCLUDED.reason,
			added_by = EXCLUDED.added_by,
			strike_weight = EXCLUDED.strike_weight,
			rollover_date = EXCLUDED.rollover_date,
			image = EXCLUDED.image
		WHERE EXCLUDED.date_created >= strikes.date_created
	`); err != nil {
		return err
	}
	return tx.Commit(ctx)
}
