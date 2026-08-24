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
	migrateutil.Main("server_settings", runServerSettings)
}

func runServerSettings(ctx context.Context, cfg migrateutil.Config) error {
	staticClient, err := migrateutil.StaticClient(ctx, cfg)
	if err != nil {
		return err
	}
	defer staticClient.Disconnect(ctx)
	statsClient, err := migrateutil.StatsClient(ctx, cfg)
	if err != nil {
		return err
	}
	defer statsClient.Disconnect(ctx)
	pool, err := migrateutil.TimescalePool(ctx, cfg)
	if err != nil {
		return err
	}
	defer pool.Close()
	plan := migrateutil.OneShotPlan{
		ResetSQL: []string{`DELETE FROM public.servers`},
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
	db := staticClient.Database("usafam")
	roleModes, err := migrateServerDocuments(ctx, cfg, pool, db.Collection("server"))
	if err != nil {
		return err
	}
	if err := migrateServerCommandActivity(ctx, pool, statsClient.Database("new_looper").Collection("command_stats")); err != nil {
		return err
	}
	roleCollections := []struct {
		collection string
		roleType   string
	}{
		{"generalrole", "family"},
		{"linkrole", "not_family"},
		{"family_roles", "family_position"},
		{"legendleagueroles", "league"},
		{"builderleagueroles", "builder_league"},
		{"townhallroles", "townhall"},
		{"builderhallroles", "builderhall"},
		{"achievementroles", "achievement"},
	}
	for _, source := range roleCollections {
		if err := migrateRoleCollection(ctx, cfg, pool, db.Collection(source.collection), source.collection, source.roleType, roleModes); err != nil {
			return err
		}
	}
	if err := migrateStatusRoleCollection(ctx, cfg, pool, db.Collection("statusroles"), roleModes); err != nil {
		return err
	}
	return migrateutil.FinishOneShot(ctx, pool, plan)
}

// migrateServerCommandActivity fills the canonical server activity timestamp
// from historical bot command usage. Servers with no matching command remain
// NULL and are therefore treated as inactive by the 90-day consumers.
func migrateServerCommandActivity(ctx context.Context, exec migrateutil.SQLExecutor, collection *mongo.Collection) error {
	cursor, err := collection.Aggregate(ctx, bson.A{
		bson.M{"$match": bson.M{"server": bson.M{"$ne": nil}, "time": bson.M{"$ne": nil}}},
		bson.M{"$group": bson.M{"_id": "$server", "last_command_at": bson.M{"$max": "$time"}}},
	})
	if err != nil {
		return fmt.Errorf("aggregate server command activity: %w", err)
	}
	defer cursor.Close(ctx)

	updated := int64(0)
	for cursor.Next(ctx) {
		var row bson.M
		if err := cursor.Decode(&row); err != nil {
			return err
		}
		serverID := migrateutil.String(row["_id"])
		lastCommandAt, ok := mongoCommandTime(row["last_command_at"])
		if serverID == "" || !ok {
			continue
		}
		result, err := exec.Exec(ctx, `
			UPDATE public.servers
			SET last_command_at = $2
			WHERE id = $1
		`, serverID, lastCommandAt)
		if err != nil {
			return err
		}
		updated += result.RowsAffected()
	}
	if err := cursor.Err(); err != nil {
		return err
	}
	fmt.Printf("server_settings.command_activity: updated_servers=%d\n", updated)
	return nil
}

func mongoCommandTime(value any) (time.Time, bool) {
	switch typed := value.(type) {
	case int32:
		return time.Unix(int64(typed), 0).UTC(), typed > 0
	case int64:
		return time.Unix(typed, 0).UTC(), typed > 0
	case float64:
		return time.Unix(int64(typed), 0).UTC(), typed > 0
	case bson.DateTime:
		return typed.Time().UTC(), true
	case time.Time:
		return typed.UTC(), true
	default:
		return time.Time{}, false
	}
}

func migrateServerDocuments(ctx context.Context, cfg migrateutil.Config, pool interface {
	Begin(context.Context) (pgx.Tx, error)
}, collection *mongo.Collection) (map[string]string, error) {
	roleModes := map[string]string{}
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
			if err := writeServerDocument(ctx, tx, doc); err != nil {
				return err
			}
		}
		if err := tx.Commit(ctx); err != nil {
			return err
		}
		batch = batch[:0]
		return nil
	}
	seen, err := migrateutil.StreamAll(ctx, cfg, "server_settings", collection, func(doc bson.M) (bool, error) {
		if serverID := migrateutil.String(doc["server"]); serverID != "" {
			roleModes[serverID] = roleMode(doc["role_treatment"])
		}
		batch = append(batch, doc)
		return len(batch) >= cfg.BatchSize, nil
	}, flush)
	fmt.Printf("server_settings.server: scanned_docs=%d\n", seen)
	return roleModes, err
}

func writeServerDocument(ctx context.Context, tx pgx.Tx, doc bson.M) error {
	serverID := migrateutil.String(doc["server"])
	if serverID == "" {
		return nil
	}
	name := firstString(doc["name"], serverID)
	linkParse := migrateutil.Map(doc["link_parse"])
	if _, err := tx.Exec(ctx, `
		INSERT INTO servers (
			id, name, embed_color,
			nickname_rule, non_family_nickname_rule, change_nickname,
			flair_non_family, auto_eval_nickname, autoeval_log_channel_id,
			autoeval_enabled, full_whitelist_role_id,
			autoboard_limit, tied_stats_only,
			family_label,
			link_parse_clan, link_parse_army, link_parse_player, link_parse_base,
			link_parse_show, updated_at
		) VALUES (
			$1, $2, NULLIF($3, ''),
			$4, $5, $6, $7, $8, $9, $10, $11, $12,
			$13, $14, $15, $16, $17, $18, $19, now()
		)
		ON CONFLICT (id) DO UPDATE SET
			name = EXCLUDED.name,
			embed_color = EXCLUDED.embed_color,
			nickname_rule = EXCLUDED.nickname_rule,
			non_family_nickname_rule = EXCLUDED.non_family_nickname_rule,
			change_nickname = EXCLUDED.change_nickname,
			flair_non_family = EXCLUDED.flair_non_family,
			auto_eval_nickname = EXCLUDED.auto_eval_nickname,
			autoeval_log_channel_id = EXCLUDED.autoeval_log_channel_id,
			autoeval_enabled = EXCLUDED.autoeval_enabled,
			full_whitelist_role_id = EXCLUDED.full_whitelist_role_id,
			autoboard_limit = EXCLUDED.autoboard_limit,
			tied_stats_only = EXCLUDED.tied_stats_only,
			family_label = EXCLUDED.family_label,
			link_parse_clan = EXCLUDED.link_parse_clan,
			link_parse_army = EXCLUDED.link_parse_army,
			link_parse_player = EXCLUDED.link_parse_player,
			link_parse_base = EXCLUDED.link_parse_base,
			link_parse_show = EXCLUDED.link_parse_show,
			updated_at = now()
	`, serverID, name, migrateutil.String(doc["embed_color"]),
		nullableString(doc["nickname_rule"]), nullableString(doc["non_family_nickname_rule"]),
		boolDefault(doc, "change_nickname", true), boolDefault(doc, "flair_non_family", true),
		boolDefault(doc, "auto_eval_nickname", false), nullableString(doc["autoeval_log"]),
		boolDefault(doc, "autoeval", false), nullableString(doc["full_whitelist_role"]),
		migrateutil.Int(doc["autoboard_limit"]),
		boolDefault(doc, "tied", true),
		migrateutil.String(doc["family_label"]),
		boolMapDefault(linkParse, "clan", true), boolMapDefault(linkParse, "army", true),
		boolMapDefault(linkParse, "player", true), boolMapDefault(linkParse, "base", true), boolMapDefault(linkParse, "show", true)); err != nil {
		return err
	}
	welcomeLink := migrateutil.Map(migrateutil.Map(doc["logs"])["welcome_link"])
	if _, err := tx.Exec(ctx, `
		INSERT INTO server_welcome_panels (server_id, embed_name, button_color, welcome_channel_id, updated_at)
		VALUES ($1, $2, $3, $4, now())
		ON CONFLICT (server_id) DO UPDATE SET
			embed_name = EXCLUDED.embed_name,
			button_color = EXCLUDED.button_color,
			welcome_channel_id = EXCLUDED.welcome_channel_id,
			updated_at = now()
	`, serverID, nullableString(firstString(welcomeLink["embed_name"], doc["welcome_link_embed"])),
		firstString(welcomeLink["button_color"], "Grey"),
		nullableString(firstString(welcomeLink["welcome_channel"], doc["welcome_link_channel"]))); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `DELETE FROM server_welcome_panel_buttons WHERE server_id = $1`, serverID); err != nil {
		return err
	}
	for position, value := range migrateutil.Slice(welcomeLink["buttons"]) {
		if button := migrateutil.String(value); button != "" {
			if _, err := tx.Exec(ctx, `INSERT INTO server_welcome_panel_buttons (server_id, button_name, position) VALUES ($1, $2, $3) ON CONFLICT DO NOTHING`, serverID, button, position); err != nil {
				return err
			}
		}
	}
	if _, err := tx.Exec(ctx, `DELETE FROM server_autoeval_triggers WHERE server_id = $1`, serverID); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `DELETE FROM server_logs WHERE server_id = $1 AND clan_tag IS NULL`, serverID); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `DELETE FROM server_countdowns WHERE server_id = $1 AND clan_tag IS NULL`, serverID); err != nil {
		return err
	}
	if err := insertOrderedStrings(ctx, tx, "server_autoeval_triggers", "trigger", serverID, doc["autoeval_triggers"]); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `DELETE FROM server_roles WHERE server_id = $1 AND type IN ('clan_category', 'status')`, serverID); err != nil {
		return err
	}
	for category, role := range migrateutil.Map(doc["category_roles"]) {
		if roleID := migrateutil.String(role); roleID != "" {
			if _, err := tx.Exec(ctx, `INSERT INTO server_roles (server_id, type, option, role_id, mode) VALUES ($1, 'clan_category', $2, $3, $4) ON CONFLICT DO NOTHING`, serverID, category, roleID, roleMode(doc["role_treatment"])); err != nil {
				return err
			}
		}
	}
	for logType, raw := range migrateutil.Map(doc["logs"]) {
		if logType == "welcome_link" {
			continue
		}
		log := migrateutil.Map(raw)
		webhookID := migrateutil.String(log["webhook"])
		if webhookID == "" {
			continue
		}
		disabled := !boolMapDefault(log, "enabled", true) || boolMapDefault(log, "disabled", false)
		clans := make([]string, 0)
		for _, value := range migrateutil.Slice(log["clans"]) {
			if clanTag := migrateutil.String(value); clanTag != "" {
				clans = append(clans, clanTag)
			}
		}
		for _, expandedType := range expandServerLogTypes(logType) {
			if expandedType == "reddit_feed" {
				if _, err := tx.Exec(ctx, `
					INSERT INTO server_logs (server_id, clan_tag, type, webhook_id, thread_id, disabled)
					VALUES ($1, NULL, $2, $3, $4, $5)
					ON CONFLICT (server_id, clan_tag, type) DO UPDATE SET
						webhook_id = EXCLUDED.webhook_id,
						thread_id = EXCLUDED.thread_id,
						disabled = EXCLUDED.disabled,
						updated_at = now()
				`, serverID, expandedType, webhookID, nullableString(log["thread"]), disabled); err != nil {
					return err
				}
				continue
			}
			if expandedType == "ban_alert" && len(clans) == 0 {
				continue
			}
			if len(clans) == 0 {
				if _, err := tx.Exec(ctx, `
					INSERT INTO server_logs (server_id, clan_tag, type, webhook_id, thread_id, disabled)
					VALUES ($1, NULL, $2, $3, $4, $5)
					ON CONFLICT (server_id, clan_tag, type) DO UPDATE SET
						webhook_id = EXCLUDED.webhook_id,
						thread_id = EXCLUDED.thread_id,
						disabled = EXCLUDED.disabled,
						updated_at = now()
				`, serverID, expandedType, webhookID, nullableString(log["thread"]), disabled); err != nil {
					return err
				}
				continue
			}
			for _, clanTag := range clans {
				if _, err := tx.Exec(ctx, `
					INSERT INTO server_logs (server_id, clan_tag, type, webhook_id, thread_id, disabled)
					VALUES ($1, $2, $3, $4, $5, $6)
					ON CONFLICT (server_id, clan_tag, type) DO NOTHING
				`, serverID, clanTag, expandedType, webhookID, nullableString(log["thread"]), disabled); err != nil {
					return err
				}
			}
		}
	}
	for _, raw := range migrateutil.Map(doc["status_roles"]) {
		for _, value := range migrateutil.Slice(raw) {
			role := migrateutil.Map(value)
			roleID := firstString(role["id"], role["role"])
			if roleID == "" {
				continue
			}
			if _, err := tx.Exec(ctx, `
				INSERT INTO server_roles (server_id, type, option, role_id, mode)
				VALUES ($1, 'status', $2, $3, $4) ON CONFLICT DO NOTHING
			`, serverID, firstString(role["key"], role["number"], role["months"], "member"), roleID, roleMode(doc["role_treatment"])); err != nil {
				return err
			}
		}
	}
	countdowns := map[string]any{
		"clan_games_timer": doc["gamesCountdown"], "cwl_timer": doc["cwlCountdown"],
		"raid_weekend_timer": doc["raidCountdown"], "season_end_timer": doc["eosCountdown"],
		"season_day_timer": doc["seasonCountdown"],
	}
	for countdownType, value := range countdowns {
		if channelID := migrateutil.String(value); channelID != "" {
			if _, err := tx.Exec(ctx, `INSERT INTO server_countdowns (server_id, clan_tag, type, channel_id) VALUES ($1, NULL, $2, $3)`, serverID, countdownType, channelID); err != nil {
				return err
			}
		}
	}
	return nil
}

func expandServerLogTypes(value string) []string {
	switch value {
	case "join_leave_log":
		return []string{"join_log", "leave_log"}
	case "capital_donation_log":
		return []string{"capital_donations"}
	case "capital_raid_log":
		return []string{"capital_attacks"}
	case "player_upgrade_log":
		return []string{
			"role_change", "troop_upgrade", "super_troop_boost", "th_upgrade",
			"league_change", "spell_upgrade", "hero_upgrade",
			"hero_equipment_upgrade", "name_change",
		}
	case "legend_log":
		return []string{"legend_log_attacks", "legend_log_defenses"}
	default:
		if canonicalServerLogType(value) != "" {
			return []string{canonicalServerLogType(value)}
		}
		return nil
	}
}

func canonicalServerLogType(value string) string {
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
	case "ban_alert", "reddit_feed":
		return value
	default:
		return ""
	}
}

func migrateRoleCollection(ctx context.Context, cfg migrateutil.Config, pool interface {
	Begin(context.Context) (pgx.Tx, error)
}, collection *mongo.Collection, labelSuffix, roleType string, roleModes map[string]string) error {
	rows := make([]bson.M, 0, cfg.BatchSize)
	flush := func() error {
		if len(rows) == 0 {
			return nil
		}
		tx, err := pool.Begin(ctx)
		if err != nil {
			return err
		}
		defer tx.Rollback(ctx)
		for _, doc := range rows {
			serverID := migrateutil.String(doc["server"])
			roleID := firstString(doc["role"], doc["role_id"], doc["id"])
			if serverID == "" || roleID == "" {
				continue
			}
			if _, err := tx.Exec(ctx, `INSERT INTO servers (id, name) VALUES ($1, $1) ON CONFLICT DO NOTHING`, serverID); err != nil {
				return err
			}
			storedType, roleKey := normalizedRoleRule(roleType, doc)
			if storedType == "" || roleKey == "" {
				continue
			}
			if _, err := tx.Exec(ctx, `
				INSERT INTO server_roles (server_id, type, option, role_id, mode, created_at, updated_at)
				VALUES ($1, $2, $3, $4, $5, now(), now())
				ON CONFLICT (server_id, clan_tag, type, option, role_id) DO UPDATE SET mode = EXCLUDED.mode, updated_at = now()
			`, serverID, storedType, roleKey, roleID, resolvedRoleMode(roleModes[serverID])); err != nil {
				return err
			}
		}
		if err := tx.Commit(ctx); err != nil {
			return err
		}
		rows = rows[:0]
		return nil
	}
	seen, err := migrateutil.StreamAll(ctx, cfg, "server_settings_"+labelSuffix, collection, func(doc bson.M) (bool, error) {
		rows = append(rows, doc)
		return len(rows) >= cfg.BatchSize, nil
	}, flush)
	fmt.Printf("server_settings.%s: scanned_docs=%d\n", labelSuffix, seen)
	return err
}

func migrateStatusRoleCollection(ctx context.Context, cfg migrateutil.Config, pool interface {
	Begin(context.Context) (pgx.Tx, error)
}, collection *mongo.Collection, roleModes map[string]string) error {
	rows := make([]bson.M, 0, cfg.BatchSize)
	flush := func() error {
		if len(rows) == 0 {
			return nil
		}
		tx, err := pool.Begin(ctx)
		if err != nil {
			return err
		}
		defer tx.Rollback(ctx)
		for _, doc := range rows {
			serverID := migrateutil.String(doc["server"])
			roleID := firstString(doc["id"], doc["role"])
			if serverID == "" || roleID == "" {
				continue
			}
			if _, err := tx.Exec(ctx, `INSERT INTO servers (id, name) VALUES ($1, $1) ON CONFLICT DO NOTHING`, serverID); err != nil {
				return err
			}
			if _, err := tx.Exec(ctx, `
				INSERT INTO server_roles (server_id, type, option, role_id, mode, created_at, updated_at)
				VALUES ($1, 'status', $2, $3, $4, now(), now())
				ON CONFLICT (server_id, clan_tag, type, option, role_id) DO UPDATE SET mode = EXCLUDED.mode, updated_at = now()
			`, serverID, firstString(doc["key"], doc["number"], doc["months"], "member"), roleID, resolvedRoleMode(roleModes[serverID])); err != nil {
				return err
			}
		}
		if err := tx.Commit(ctx); err != nil {
			return err
		}
		rows = rows[:0]
		return nil
	}
	seen, err := migrateutil.StreamAll(ctx, cfg, "server_settings_statusroles", collection, func(doc bson.M) (bool, error) {
		rows = append(rows, doc)
		return len(rows) >= cfg.BatchSize, nil
	}, flush)
	fmt.Printf("server_settings.statusroles: scanned_docs=%d\n", seen)
	return err
}

func insertOrderedStrings(ctx context.Context, tx pgx.Tx, table, column, serverID string, raw any) error {
	for position, value := range migrateutil.Slice(raw) {
		item := migrateutil.String(value)
		if item == "" {
			continue
		}
		if _, err := tx.Exec(ctx, `INSERT INTO `+table+` (server_id, `+column+`, position) VALUES ($1, $2, $3) ON CONFLICT DO NOTHING`, serverID, item, position); err != nil {
			return err
		}
	}
	return nil
}

func nullableString(value any) any {
	if out := migrateutil.String(value); out != "" {
		return out
	}
	return nil
}

func firstString(values ...any) string {
	for _, value := range values {
		if out := migrateutil.String(value); out != "" {
			return out
		}
	}
	return ""
}

func roleMode(raw any) string {
	hasAdd := false
	hasRemove := false
	for _, value := range migrateutil.Slice(raw) {
		switch migrateutil.String(value) {
		case "Add":
			hasAdd = true
		case "Remove":
			hasRemove = true
		}
	}
	if hasAdd && hasRemove {
		return "both"
	}
	if hasRemove {
		return "remove"
	}
	if hasAdd {
		return "add"
	}
	return "both"
}

func resolvedRoleMode(mode string) string {
	if mode == "add" || mode == "remove" || mode == "both" {
		return mode
	}
	return "both"
}

func normalizedRoleRule(sourceType string, doc bson.M) (string, string) {
	key := firstString(doc["type"], doc["league"], doc["th"], doc["bh"], doc["number"], doc["achievement"], doc["key"])
	switch sourceType {
	case "family":
		return "family", "family"
	case "not_family":
		return "family", "not_family"
	case "family_position":
		switch key {
		case "family_member_roles":
			return "", ""
		case "family_elder_roles":
			key = "elder"
		case "family_co-leader_roles":
			key = "co_leader"
		case "family_leader_roles":
			key = "leader"
		}
		return "clan_role", key
	default:
		return sourceType, key
	}
}

func boolDefault(doc bson.M, key string, fallback bool) bool {
	if _, ok := doc[key]; !ok || doc[key] == nil {
		return fallback
	}
	return migrateutil.Bool(doc[key])
}

func boolMapDefault(doc bson.M, key string, fallback bool) bool {
	if _, ok := doc[key]; !ok || doc[key] == nil {
		return fallback
	}
	return migrateutil.Bool(doc[key])
}

func firstIntPointer(values ...any) any {
	for _, value := range values {
		if migrateutil.String(value) != "" {
			return migrateutil.Int(value)
		}
	}
	return nil
}
