//go:build ignore

package main

import (
	"context"
	"fmt"

	"clashking_devkit_database_migrations/migrateutil"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"go.mongodb.org/mongo-driver/v2/bson"
	"go.mongodb.org/mongo-driver/v2/mongo"
)

func main() {
	migrateutil.Main("rosters", runRosters)
}

func runRosters(ctx context.Context, cfg migrateutil.Config) error {
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
	plan := rosterOneShotPlan()
	if err := migrateutil.StartOneShot(ctx, pool, plan); err != nil {
		return err
	}
	db := client.Database("usafam")
	if err := migrateRosterDocuments(ctx, cfg, pool, db.Collection("rosters")); err != nil {
		return err
	}
	if err := migrateRosterGroups(ctx, cfg, pool, db.Collection("roster_groups")); err != nil {
		return err
	}
	if err := migrateRosterSignupCategories(ctx, cfg, pool, db.Collection("roster_signup_categories")); err != nil {
		return err
	}
	if err := migrateRosterAutomations(ctx, cfg, pool, db.Collection("roster_automation_rules")); err != nil {
		return err
	}
	return migrateutil.FinishOneShot(ctx, pool, plan)
}

func rosterOneShotPlan() migrateutil.OneShotPlan {
	return migrateutil.OneShotPlan{
		ResetSQL: []string{
			`TRUNCATE TABLE
				public.roster_group_allowed_signup_categories,
				public.roster_allowed_signup_categories,
				public.roster_display_columns,
				public.roster_sort_fields,
				public.roster_members,
				public.roster_automation_rules,
				public.roster_signup_categories,
				public.rosters,
				public.roster_groups`,
		},
		DropIndexes: []string{
			`DROP INDEX IF EXISTS public.idx_roster_automation_rules_server_group`,
			`DROP INDEX IF EXISTS public.idx_roster_groups_server`,
			`DROP INDEX IF EXISTS public.idx_roster_signup_categories_server`,
			`DROP INDEX IF EXISTS public.idx_rosters_server_clan`,
			`DROP INDEX IF EXISTS public.idx_rosters_server_group`,
		},
		CreateIndexes: []string{
			`CREATE INDEX idx_roster_automation_rules_server_group ON public.roster_automation_rules (server_id, group_id)`,
			`CREATE INDEX idx_roster_groups_server ON public.roster_groups (server_id)`,
			`CREATE INDEX idx_roster_signup_categories_server ON public.roster_signup_categories (server_id, sort_order)`,
			`CREATE INDEX idx_rosters_server_clan ON public.rosters (server_id, clan_tag)`,
			`CREATE INDEX idx_rosters_server_group ON public.rosters (server_id, group_id)`,
		},
	}
}

func migrateRosterDocuments(ctx context.Context, cfg migrateutil.Config, pool interface {
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
			if err := writeRosterDocument(ctx, tx, doc); err != nil {
				return err
			}
		}
		if err := tx.Commit(ctx); err != nil {
			return err
		}
		batch = batch[:0]
		return nil
	}
	seen, err := migrateutil.StreamAll(ctx, cfg, "rosters", collection, func(doc bson.M) (bool, error) {
		batch = append(batch, doc)
		return len(batch) >= cfg.BatchSize, nil
	}, flush)
	fmt.Printf("rosters: scanned_docs=%d\n", seen)
	return err
}

func migrateRosterGroups(ctx context.Context, cfg migrateutil.Config, pool interface {
	Begin(context.Context) (pgx.Tx, error)
}, collection *mongo.Collection) error {
	return streamRosterCollection(ctx, cfg, pool, collection, "roster_groups", func(ctx context.Context, tx pgx.Tx, doc bson.M) error {
		serverID := firstRosterString(doc["server_id"], doc["server"])
		groupID := firstRosterString(doc["group_id"], doc["custom_id"], doc["token"], doc["_id"])
		if serverID == "" || groupID == "" {
			return nil
		}
		if _, err := tx.Exec(ctx, `INSERT INTO servers (id, name) VALUES ($1, $1) ON CONFLICT DO NOTHING`, serverID); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `
			INSERT INTO roster_groups (
				group_id, server_id, name, alias, description, max_accounts_per_user,
				roster_size, min_signups, default_signup_category, created_at, updated_at
			) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, now(), now())
			ON CONFLICT (group_id) DO UPDATE SET
				server_id = EXCLUDED.server_id, name = EXCLUDED.name, alias = EXCLUDED.alias,
				description = EXCLUDED.description, max_accounts_per_user = EXCLUDED.max_accounts_per_user,
				roster_size = EXCLUDED.roster_size, min_signups = EXCLUDED.min_signups,
				default_signup_category = EXCLUDED.default_signup_category, updated_at = now()
		`, groupID, serverID, firstRosterString(doc["name"], doc["alias"], groupID),
			nullableRosterString(doc["alias"]), firstRosterString(doc["description"]),
			nullableRosterInt(doc["max_accounts_per_user"]), nullableRosterInt(doc["roster_size"]),
			nullableRosterInt(doc["min_signups"]), nullableRosterString(doc["default_signup_category"])); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `DELETE FROM roster_group_allowed_signup_categories WHERE group_id = $1`, groupID); err != nil {
			return err
		}
		for position, categoryID := range uniqueRosterStrings(doc["allowed_signup_categories"]) {
			if _, err := tx.Exec(ctx, `INSERT INTO roster_group_allowed_signup_categories (group_id, category_id, position) VALUES ($1, $2, $3)`, groupID, categoryID, position); err != nil {
				return err
			}
		}
		return nil
	})
}

func migrateRosterSignupCategories(ctx context.Context, cfg migrateutil.Config, pool interface {
	Begin(context.Context) (pgx.Tx, error)
}, collection *mongo.Collection) error {
	return streamRosterCollection(ctx, cfg, pool, collection, "roster_signup_categories", func(ctx context.Context, tx pgx.Tx, doc bson.M) error {
		serverID := firstRosterString(doc["server_id"], doc["server"])
		customID := firstRosterString(doc["custom_id"], doc["token"], doc["_id"])
		if serverID == "" || customID == "" {
			return nil
		}
		if _, err := tx.Exec(ctx, `INSERT INTO servers (id, name) VALUES ($1, $1) ON CONFLICT DO NOTHING`, serverID); err != nil {
			return err
		}
		_, err := tx.Exec(ctx, `
			INSERT INTO roster_signup_categories (custom_id, server_id, name, alias, description, sort_order, created_at, updated_at)
			VALUES ($1, $2, $3, $4, $5, $6, now(), now())
			ON CONFLICT (custom_id) DO UPDATE SET
				server_id = EXCLUDED.server_id, name = EXCLUDED.name, alias = EXCLUDED.alias,
				description = EXCLUDED.description, sort_order = EXCLUDED.sort_order, updated_at = now()
		`, customID, serverID, firstRosterString(doc["name"], doc["alias"], customID), nullableRosterString(doc["alias"]),
			firstRosterString(doc["description"]), migrateutil.Int(doc["sort_order"]))
		return err
	})
}

func migrateRosterAutomations(ctx context.Context, cfg migrateutil.Config, pool interface {
	Begin(context.Context) (pgx.Tx, error)
}, collection *mongo.Collection) error {
	return streamRosterCollection(ctx, cfg, pool, collection, "roster_automation_rules", func(ctx context.Context, tx pgx.Tx, doc bson.M) error {
		serverID := firstRosterString(doc["server_id"], doc["server"])
		automationID := firstRosterString(doc["automation_id"], doc["custom_id"], doc["_id"])
		if serverID == "" || automationID == "" {
			return nil
		}
		if _, err := tx.Exec(ctx, `INSERT INTO servers (id, name) VALUES ($1, $1) ON CONFLICT DO NOTHING`, serverID); err != nil {
			return err
		}
		options := migrateutil.Map(doc["options"])
		_, err := tx.Exec(ctx, `
			INSERT INTO roster_automation_rules (
				automation_id, server_id, roster_id, group_id, enabled, trigger_type,
				action_type, offset_seconds, discord_channel_id, ping_type, executed,
				executed_at, last_triggered_at, execution_status, last_missed_at, created_at, updated_at
			) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, now(), now())
			ON CONFLICT (automation_id) DO UPDATE SET
				server_id = EXCLUDED.server_id, roster_id = EXCLUDED.roster_id, group_id = EXCLUDED.group_id,
				enabled = EXCLUDED.enabled, trigger_type = EXCLUDED.trigger_type, action_type = EXCLUDED.action_type,
				offset_seconds = EXCLUDED.offset_seconds, discord_channel_id = EXCLUDED.discord_channel_id,
				ping_type = EXCLUDED.ping_type, executed = EXCLUDED.executed, executed_at = EXCLUDED.executed_at,
				last_triggered_at = EXCLUDED.last_triggered_at, execution_status = EXCLUDED.execution_status,
				last_missed_at = EXCLUDED.last_missed_at, updated_at = now()
		`, automationID, serverID, nullableRosterString(doc["roster_id"]), nullableRosterString(doc["group_id"]),
			boolRosterDefault(doc, "active", true), firstRosterString(doc["trigger_type"]), firstRosterString(doc["action_type"]),
			migrateutil.Int(doc["offset_seconds"]), nullableRosterString(doc["discord_channel_id"]), nullableRosterString(options["ping_type"]),
			boolRosterDefault(doc, "executed", false), nullableRosterInt64(doc["executed_at"]), nullableRosterInt64(doc["last_triggered_at"]),
			nullableRosterString(doc["execution_status"]), nullableRosterInt64(doc["last_missed_at"]))
		return err
	})
}

func streamRosterCollection(ctx context.Context, cfg migrateutil.Config, pool interface {
	Begin(context.Context) (pgx.Tx, error)
}, collection *mongo.Collection, label string, write func(context.Context, pgx.Tx, bson.M) error) error {
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
			if err := write(ctx, tx, doc); err != nil {
				return err
			}
		}
		if err := tx.Commit(ctx); err != nil {
			return err
		}
		batch = batch[:0]
		return nil
	}
	seen, err := migrateutil.StreamAll(ctx, cfg, label, collection, func(doc bson.M) (bool, error) {
		batch = append(batch, doc)
		return len(batch) >= cfg.BatchSize, nil
	}, flush)
	fmt.Printf("%s: scanned_docs=%d\n", label, seen)
	return err
}

func writeRosterDocument(ctx context.Context, tx pgx.Tx, doc bson.M) error {
	serverID := firstRosterString(doc["server_id"], doc["server"])
	customID := firstRosterString(doc["token"], doc["custom_id"], doc["_id"])
	if serverID == "" || customID == "" {
		return nil
	}
	if _, err := tx.Exec(ctx, `INSERT INTO servers (id, name) VALUES ($1, $1) ON CONFLICT DO NOTHING`, serverID); err != nil {
		return err
	}
	rosterID := uuid.NewSHA1(uuid.NameSpaceOID, []byte("roster:"+customID))
	if _, err := tx.Exec(ctx, `
		INSERT INTO rosters (
			id, custom_id, server_id, group_id, clan_tag, alias, description,
			roster_type, signup_scope, min_townhall, max_townhall, roster_size,
			min_signups, max_accounts_per_user, townhall_restriction,
			default_signup_category, image_url, event_start_time,
			recurrence_days, recurrence_day_of_month, created_at, updated_at
		) VALUES (
			$1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12,
			$13, $14, $15, $16, $17, $18, $19, $20, now(), now()
		)
		ON CONFLICT (custom_id) DO UPDATE SET
			server_id = EXCLUDED.server_id,
			group_id = EXCLUDED.group_id,
			clan_tag = EXCLUDED.clan_tag,
			alias = EXCLUDED.alias,
			description = EXCLUDED.description,
			roster_type = EXCLUDED.roster_type,
			signup_scope = EXCLUDED.signup_scope,
			min_townhall = EXCLUDED.min_townhall,
			max_townhall = EXCLUDED.max_townhall,
			roster_size = EXCLUDED.roster_size,
			min_signups = EXCLUDED.min_signups,
			max_accounts_per_user = EXCLUDED.max_accounts_per_user,
			townhall_restriction = EXCLUDED.townhall_restriction,
			default_signup_category = EXCLUDED.default_signup_category,
			image_url = EXCLUDED.image_url,
			event_start_time = EXCLUDED.event_start_time,
			recurrence_days = EXCLUDED.recurrence_days,
			recurrence_day_of_month = EXCLUDED.recurrence_day_of_month,
			updated_at = now()
	`, rosterID, customID, serverID, nullableRosterString(doc["group_id"]), nullableRosterString(doc["clan_tag"]),
		firstRosterString(doc["alias"], doc["clan_name"], customID), nullableRosterString(doc["description"]),
		firstRosterString(doc["roster_type"], "clan"), firstRosterString(doc["signup_scope"], "clan-only"),
		nullableRosterInt(doc["min_th"]), nullableRosterInt(doc["max_th"]), nullableRosterInt(doc["roster_size"]),
		nullableRosterInt(doc["min_signups"]), nullableRosterInt(doc["max_accounts_per_user"]), nullableRosterString(doc["th_restriction"]),
		nullableRosterString(doc["default_signup_category"]), firstRosterNullable(doc["image"], doc["image_url"]),
		nullableRosterInt64(doc["event_start_time"]), nullableRosterInt(doc["recurrence_days"]), nullableRosterInt(doc["recurrence_day_of_month"])); err != nil {
		return err
	}
	for _, table := range []string{"roster_members", "roster_allowed_signup_categories", "roster_display_columns", "roster_sort_fields"} {
		if _, err := tx.Exec(ctx, `DELETE FROM `+table+` WHERE roster_id = $1`, rosterID); err != nil {
			return err
		}
	}
	for position, member := range uniqueRosterMembers(doc["members"]) {
		tag := migrateutil.String(member["tag"])
		if _, err := tx.Exec(ctx, `
			INSERT INTO roster_members (
				roster_id, tag, name, townhall, hero_levels, discord_user_id,
				discord_username, discord_avatar_url, current_clan_name,
				current_clan_tag, war_preference, trophies, substitute,
				signup_group, hitrate, last_online, current_league, added_at,
				last_updated, is_in_family, member_status, error_details, position
			) VALUES (
				$1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12,
				$13, $14, $15, $16, $17, $18, $19, $20, $21, $22, $23
			)
		`, rosterID, tag, migrateutil.String(member["name"]), migrateutil.Int(member["townhall"]),
			nullableRosterInt(member["hero_lvs"]), nullableRosterString(member["discord"]), nullableRosterString(member["discord_username"]),
			nullableRosterString(member["discord_avatar_url"]), nullableRosterString(member["current_clan"]), nullableRosterString(member["current_clan_tag"]),
			nullableRosterBool(member, "war_pref"), nullableRosterInt(member["trophies"]), nullableRosterBool(member, "sub"),
			nullableRosterString(member["signup_group"]), nullableRosterFloat(member["hitrate"]), nullableRosterInt64(member["last_online"]),
			nullableRosterString(member["current_league"]), nullableRosterInt64(member["added_at"]), nullableRosterInt64(member["last_updated"]),
			nullableRosterBool(member, "is_in_family"), nullableRosterString(member["member_status"]), nullableRosterString(member["error_details"]), position); err != nil {
			return err
		}
	}
	ordered := []struct {
		table  string
		column string
		value  any
	}{
		{"roster_allowed_signup_categories", "category_id", doc["allowed_signup_categories"]},
		{"roster_display_columns", "column_name", doc["columns"]},
		{"roster_sort_fields", "field_name", doc["sort"]},
	}
	for _, list := range ordered {
		for position, value := range uniqueRosterStrings(list.value) {
			if _, err := tx.Exec(ctx, `INSERT INTO `+list.table+` (roster_id, `+list.column+`, position) VALUES ($1, $2, $3)`, rosterID, value, position); err != nil {
				return err
			}
		}
	}
	return nil
}

func uniqueRosterMembers(value any) []bson.M {
	members := make([]bson.M, 0, len(migrateutil.Slice(value)))
	seen := make(map[string]struct{})
	for _, raw := range migrateutil.Slice(value) {
		member := migrateutil.Map(raw)
		tag := migrateutil.String(member["tag"])
		if tag == "" {
			continue
		}
		if _, exists := seen[tag]; exists {
			continue
		}
		seen[tag] = struct{}{}
		members = append(members, member)
	}
	return members
}

func uniqueRosterStrings(value any) []string {
	values := make([]string, 0, len(migrateutil.Slice(value)))
	seen := make(map[string]struct{})
	for _, raw := range migrateutil.Slice(value) {
		item := migrateutil.String(raw)
		if item == "" {
			continue
		}
		if _, exists := seen[item]; exists {
			continue
		}
		seen[item] = struct{}{}
		values = append(values, item)
	}
	return values
}

func firstRosterString(values ...any) string {
	for _, value := range values {
		if out := migrateutil.String(value); out != "" {
			return out
		}
	}
	return ""
}

func nullableRosterString(value any) any {
	if out := migrateutil.String(value); out != "" {
		return out
	}
	return nil
}

func firstRosterNullable(values ...any) any {
	if out := firstRosterString(values...); out != "" {
		return out
	}
	return nil
}

func nullableRosterInt(value any) any {
	if migrateutil.String(value) == "" {
		return nil
	}
	return migrateutil.Int(value)
}

func nullableRosterInt64(value any) any {
	if migrateutil.String(value) == "" {
		return nil
	}
	return int64(migrateutil.Int(value))
}

func nullableRosterFloat(value any) any {
	if migrateutil.String(value) == "" {
		return nil
	}
	switch typed := value.(type) {
	case float64:
		return typed
	case float32:
		return float64(typed)
	default:
		return float64(migrateutil.Int(value))
	}
}

func nullableRosterBool(doc bson.M, key string) any {
	if _, ok := doc[key]; !ok || doc[key] == nil {
		return nil
	}
	return migrateutil.Bool(doc[key])
}

func boolRosterDefault(doc bson.M, key string, fallback bool) bool {
	if _, ok := doc[key]; !ok || doc[key] == nil {
		return fallback
	}
	return migrateutil.Bool(doc[key])
}
