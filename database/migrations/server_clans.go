//go:build ignore

package main

import (
	"context"
	"fmt"
	"time"

	"github.com/ClashKingInc/DevKit/database/migrations/migrateutil"
	"github.com/jackc/pgx/v5"
	"go.mongodb.org/mongo-driver/v2/bson"
	"go.mongodb.org/mongo-driver/v2/mongo"
)

func main() {
	migrateutil.Main("server_clans", runServerClans)
}

func runServerClans(ctx context.Context, cfg migrateutil.Config) error {
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
	plan := migrateutil.OneShotPlan{
		ResetSQL: []string{
			`DELETE FROM public.server_countdowns WHERE clan_tag IS NOT NULL`,
			`DELETE FROM public.server_logs WHERE clan_tag IS NOT NULL`,
			`DELETE FROM public.server_roles WHERE clan_tag IS NOT NULL`,
			`DELETE FROM public.server_clans`,
			`DELETE FROM public.server_clan_categories`,
		},
		DropIndexes: []string{
			`DROP INDEX IF EXISTS public.idx_server_logs_scope`,
			`DROP INDEX IF EXISTS public.idx_server_logs_webhook`,
		},
		CreateIndexes: []string{
			`CREATE INDEX idx_server_logs_scope ON public.server_logs (server_id, clan_tag, type)`,
			`CREATE INDEX idx_server_logs_webhook ON public.server_logs (webhook_id)`,
		},
	}
	if err := migrateutil.StartOneShot(ctx, pool, plan); err != nil {
		return err
	}
	if err := migrateServerClanDocuments(ctx, cfg, pool, client.Database("usafam").Collection("clans")); err != nil {
		return err
	}
	return migrateutil.FinishOneShot(ctx, pool, plan)
}

func migrateServerClanDocuments(ctx context.Context, cfg migrateutil.Config, pool interface {
	Begin(context.Context) (pgx.Tx, error)
}, collection *mongo.Collection) error {
	batch := make([]bson.M, 0, cfg.BatchSize)
	flush := func() error {
		if len(batch) == 0 {
			return nil
		}
		tx, err := pool.Begin(ctx)
		if err != nil {
			return err
		}
		defer tx.Rollback(ctx)
		for _, doc := range batch {
			if err := writeServerClanDocument(ctx, tx, doc); err != nil {
				return err
			}
		}
		if err := tx.Commit(ctx); err != nil {
			return err
		}
		batch = batch[:0]
		return nil
	}
	seen, err := migrateutil.StreamAll(ctx, cfg, "server_clans", collection, func(doc bson.M) (bool, error) {
		batch = append(batch, doc)
		return len(batch) >= cfg.BatchSize, nil
	}, flush)
	fmt.Printf("server_clans: scanned_docs=%d\n", seen)
	return err
}

func writeServerClanDocument(ctx context.Context, tx pgx.Tx, doc bson.M) error {
	serverID := migrateutil.String(doc["server"])
	clanTag := migrateutil.String(doc["tag"])
	if serverID == "" || clanTag == "" {
		return nil
	}
	var trackedClanExists bool
	if err := tx.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM basic_clan WHERE tag = $1)`, clanTag).Scan(&trackedClanExists); err != nil {
		return err
	}
	if !trackedClanExists {
		return nil
	}
	addedAt, err := serverClanAddedAt(doc)
	if err != nil {
		return fmt.Errorf("server clan %s on server %s: %w", clanTag, serverID, err)
	}
	if _, err := tx.Exec(ctx, `INSERT INTO servers (id, name) VALUES ($1, $1) ON CONFLICT DO NOTHING`, serverID); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `
		INSERT INTO server_clans (tag, server_id, abbreviation, added_at, updated_at)
		VALUES ($1, $2, $3, $4, now())
		ON CONFLICT (tag, server_id) DO UPDATE SET
			abbreviation = EXCLUDED.abbreviation,
			added_at = EXCLUDED.added_at,
			updated_at = now()
	`, clanTag, serverID, migrateutil.String(doc["abbreviation"]), addedAt); err != nil {
		return err
	}
	logs := migrateutil.Map(doc["logs"])
	if category := migrateutil.String(doc["category"]); category != "" {
		if _, err := tx.Exec(ctx, `
			WITH selected AS (
				INSERT INTO server_clan_categories (server_id, name, position)
				SELECT $1, $3, COALESCE(max(position) + 1, 0)
				FROM server_clan_categories
				WHERE server_id = $1
				ON CONFLICT (server_id, name) DO UPDATE SET name = EXCLUDED.name
				RETURNING id
			)
			UPDATE server_clans SET category_id = (SELECT id FROM selected)
			WHERE server_id = $1 AND tag = $2
		`, serverID, clanTag, category); err != nil {
			return err
		}
	} else if _, err := tx.Exec(ctx, `UPDATE server_clans SET category_id = NULL WHERE server_id = $1 AND tag = $2`, serverID, clanTag); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `DELETE FROM server_roles WHERE server_id = $1 AND clan_tag = $2 AND type = 'clan_role'`, serverID, clanTag); err != nil {
		return err
	}
	if roleID := migrateutil.String(doc["generalRole"]); roleID != "" {
		if _, err := tx.Exec(ctx, `INSERT INTO server_roles (server_id, clan_tag, type, option, role_id, mode) VALUES ($1, $2, 'clan_role', 'member', $3, 'both')`, serverID, clanTag, roleID); err != nil {
			return err
		}
	}
	if roleID := migrateutil.String(doc["leaderRole"]); roleID != "" {
		mode := "both"
		if value, ok := doc["leadership_eval"]; ok && value != nil && !migrateutil.Bool(value) {
			mode = "remove"
		}
		if _, err := tx.Exec(ctx, `INSERT INTO server_roles (server_id, clan_tag, type, option, role_id, mode) VALUES ($1, $2, 'clan_role', 'leader', $3, $4)`, serverID, clanTag, roleID, mode); err != nil {
			return err
		}
	}
	if _, err := tx.Exec(ctx, `DELETE FROM server_logs WHERE server_id = $1 AND clan_tag = $2`, serverID, clanTag); err != nil {
		return err
	}
	for logType, raw := range logs {
		logType = canonicalClanLogType(logType)
		if logType == "" {
			continue
		}
		log := migrateutil.Map(raw)
		webhookID := migrateutil.String(log["webhook"])
		if webhookID == "" {
			continue
		}
		if _, err := tx.Exec(ctx, `
			INSERT INTO server_logs (
				server_id, clan_tag, type, webhook_id, thread_id,
				active_war_id, active_raid_id, message_id, disabled
			) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
		`, serverID, clanTag, logType, webhookID, nullableClanString(log["thread"]),
			nullableClanString(log["war_id"]), nullableClanString(log["raid_id"]),
			firstClanNullable(log["war_message"], log["raid_message"]), clanLogDisabled(log)); err != nil {
			return err
		}
	}
	if _, err := tx.Exec(ctx, `DELETE FROM server_countdowns WHERE server_id = $1 AND clan_tag = $2`, serverID, clanTag); err != nil {
		return err
	}
	countdowns := map[string]any{"war_score": doc["warCountdown"], "war_timer": doc["warTimerCountdown"]}
	for countdownType, value := range countdowns {
		if channelID := migrateutil.String(value); channelID != "" {
			if _, err := tx.Exec(ctx, `INSERT INTO server_countdowns (server_id, clan_tag, type, channel_id) VALUES ($1, $2, $3, $4)`, serverID, clanTag, countdownType, channelID); err != nil {
				return err
			}
		}
	}
	return nil
}

func serverClanAddedAt(doc bson.M) (time.Time, error) {
	objectID, ok := doc["_id"].(bson.ObjectID)
	if !ok {
		return time.Time{}, fmt.Errorf("_id must be a Mongo ObjectID")
	}
	return objectID.Timestamp().UTC(), nil
}

func canonicalClanLogType(value string) string {
	switch value {
	case "join":
		return "join_log"
	case "leave":
		return "leave_log"
	case "donations":
		return "donation_log"
	case "war":
		return "war_log"
	case "capital":
		return "capital_attacks"
	case "join_log", "leave_log", "donation_log",
		"clan_achievement_log", "clan_requirements_log", "clan_description_log",
		"war_log", "war_panel", "cwl_lineup_change_log",
		"capital_donations", "capital_attacks", "raid_panel", "capital_weekly_summary",
		"role_change", "troop_upgrade", "super_troop_boost", "th_upgrade",
		"league_change", "spell_upgrade", "hero_upgrade",
		"hero_equipment_upgrade", "name_change", "legend_log_attacks", "legend_log_defenses":
		return value
	case "ban_alert":
		return value
	default:
		return ""
	}
}

func nullableClanString(value any) any {
	if out := migrateutil.String(value); out != "" {
		return out
	}
	return nil
}

func firstClanString(values ...any) string {
	for _, value := range values {
		if out := migrateutil.String(value); out != "" {
			return out
		}
	}
	return ""
}

func firstClanNullable(values ...any) any {
	if out := firstClanString(values...); out != "" {
		return out
	}
	return nil
}

func clanLogDisabled(log bson.M) bool {
	if migrateutil.Bool(log["disabled"]) {
		return true
	}
	if value, ok := log["enabled"]; ok && value != nil {
		return !migrateutil.Bool(value)
	}
	return false
}
