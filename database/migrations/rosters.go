//go:build ignore

package main

import (
	"context"
	"encoding/json"
	"fmt"
	"regexp"
	"strings"
	"time"

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
	rosterIDs, err := migrateRosterDocuments(ctx, cfg, pool, db.Collection("rosters"))
	if err != nil {
		return err
	}
	if err := migrateRosterGroups(ctx, cfg, pool, db.Collection("roster_groups")); err != nil {
		return err
	}
	if err := migrateRosterAutomations(ctx, cfg, pool, db.Collection("roster_automation_rules"), rosterIDs); err != nil {
		return err
	}
	return migrateutil.FinishOneShot(ctx, pool, plan)
}

func rosterOneShotPlan() migrateutil.OneShotPlan {
	return migrateutil.OneShotPlan{
		ResetSQL: []string{
			`DELETE FROM public.rosters`,
			`TRUNCATE TABLE public.roster_automation_rules, public.roster_groups`,
		},
		DropIndexes: []string{
			`DROP INDEX IF EXISTS public.idx_roster_automation_rules_server_group`,
			`DROP INDEX IF EXISTS public.idx_roster_groups_server`,
			`DROP INDEX IF EXISTS public.idx_rosters_server_clan`,
			`DROP INDEX IF EXISTS public.idx_rosters_server_group`,
		},
		CreateIndexes: []string{
			`CREATE INDEX idx_roster_automation_rules_server_group ON public.roster_automation_rules (server_id, group_id)`,
			`CREATE INDEX idx_roster_groups_server ON public.roster_groups (server_id)`,
			`CREATE INDEX idx_rosters_server_clan ON public.rosters (server_id, clan_tag)`,
			`CREATE INDEX idx_rosters_server_group ON public.rosters (server_id, group_id)`,
		},
	}
}

func migrateRosterDocuments(ctx context.Context, cfg migrateutil.Config, pool interface {
	Begin(context.Context) (pgx.Tx, error)
}, collection *mongo.Collection) (map[string]uuid.UUID, error) {
	rosterIDs := make(map[string]uuid.UUID)
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
			legacyID, rosterID, err := writeRosterDocument(ctx, tx, doc)
			if err != nil {
				return err
			}
			if legacyID != "" {
				rosterIDs[legacyID] = rosterID
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
	return rosterIDs, err
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
				min_signups, created_at, updated_at
			) VALUES ($1, $2, $3, $4, $5, $6, $7, now(), now())
			ON CONFLICT (group_id) DO UPDATE SET
				server_id = EXCLUDED.server_id, name = EXCLUDED.name, alias = EXCLUDED.alias,
				description = EXCLUDED.description, max_accounts_per_user = EXCLUDED.max_accounts_per_user,
				min_signups = EXCLUDED.min_signups,
				updated_at = now()
		`, groupID, serverID, firstRosterString(doc["name"], doc["alias"], groupID),
			nullableRosterString(doc["alias"]), firstRosterString(doc["description"]),
			nullableRosterInt(doc["max_accounts_per_user"]), nullableRosterInt(doc["min_signups"])); err != nil {
			return err
		}
		return nil
	})
}

func migrateRosterAutomations(ctx context.Context, cfg migrateutil.Config, pool interface {
	Begin(context.Context) (pgx.Tx, error)
}, collection *mongo.Collection, rosterIDs map[string]uuid.UUID) error {
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
		var rosterID *uuid.UUID
		if legacyRosterID := firstRosterString(doc["roster_id"]); legacyRosterID != "" {
			if resolved, ok := rosterIDs[legacyRosterID]; ok {
				rosterID = &resolved
			}
		}
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
		`, automationID, serverID, rosterID, nullableRosterString(doc["group_id"]),
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

func writeRosterDocument(ctx context.Context, tx pgx.Tx, doc bson.M) (string, uuid.UUID, error) {
	serverID := firstRosterString(doc["server_id"], doc["server"])
	legacyID := firstRosterString(doc["token"], doc["custom_id"], doc["_id"])
	if serverID == "" || legacyID == "" {
		return "", uuid.Nil, nil
	}
	if _, err := tx.Exec(ctx, `INSERT INTO servers (id, name) VALUES ($1, $1) ON CONFLICT DO NOTHING`, serverID); err != nil {
		return "", uuid.Nil, err
	}
	var rosterID uuid.UUID
	if err := tx.QueryRow(ctx, `
		INSERT INTO rosters (
			server_id, group_id, clan_tag, alias, description,
			roster_type, signup_scope, min_townhall, max_townhall,
			min_signups, max_accounts_per_user, display_column_ids, sort_configuration,
			webhook_id, message_id,
			image_url, event_start_time,
			recurrence_days, recurrence_day_of_month, created_at, updated_at
		) VALUES (
			$1, $2, $3, $4, $5, $6, $7, $8, $9, $10,
			$11, $12::text[], $13::jsonb, $14, $15,
			$16, $17, $18, $19, now(), now()
		)
		RETURNING id
	`, serverID, nullableRosterString(doc["group_id"]), nullableRosterString(doc["clan_tag"]),
		firstRosterString(doc["alias"], doc["clan_name"], "Roster"), nullableRosterString(doc["description"]),
		firstRosterString(doc["roster_type"], "clan"), firstRosterString(doc["signup_scope"], "clan-only"),
		nullableRosterInt(doc["min_th"]), nullableRosterInt(doc["max_th"]),
		nullableRosterInt(doc["min_signups"]), nullableRosterInt(doc["max_accounts_per_user"]), rosterColumnIDs(doc["columns"]), rosterSortConfigurationJSON(doc["sort"]),
		nullableRosterString(doc["webhook_id"]), nullableRosterString(doc["message_id"]),
		firstRosterNullable(doc["image"], doc["image_url"]),
		nullableRosterInt64(doc["event_start_time"]), nullableRosterInt(doc["recurrence_days"]), nullableRosterInt(doc["recurrence_day_of_month"])).Scan(&rosterID); err != nil {
		return "", uuid.Nil, err
	}
	if _, err := tx.Exec(ctx, `DELETE FROM roster_members WHERE roster_id = $1`, rosterID); err != nil {
		return "", uuid.Nil, err
	}
	for position, member := range uniqueRosterMembers(doc["members"]) {
		tag := migrateutil.String(member["tag"])
		if _, err := tx.Exec(ctx, `
			INSERT INTO roster_members (
				roster_id, tag, name, townhall, trophies, current_clan_name,
				current_clan_tag, league_name, hero_level_sum, war_preference,
				discord_user_id, discord_username, discord_avatar_url, hitrate,
				last_online, added_at, refreshed_at, signup_answers,
				is_in_family, member_status, position
			) VALUES (
				$1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11,
				$12, $13, $14, $15, $16, $17, $18, $19, $20, $21
			)
		`, rosterID, tag, migrateutil.String(member["name"]), migrateutil.Int(member["townhall"]), nullableRosterInt(member["trophies"]),
			nullableRosterString(member["current_clan"]), nullableRosterString(member["current_clan_tag"]), nullableRosterString(member["current_league"]),
			migrateutil.Int(member["hero_lvs"]), nullableRosterBool(member, "war_pref"), nullableRosterString(member["discord"]),
			nullableRosterString(member["discord_username"]), nullableRosterString(member["discord_avatar_url"]), nullableRosterFloat(member["hitrate"]),
			nullableRosterTimestamp(member["last_online"]), nullableRosterInt64(member["added_at"]), nullableRosterTimestamp(member["last_updated"]),
			rosterJSON(member["signup_answers"], map[string]any{}), nullableRosterBool(member, "is_in_family"),
			nullableRosterString(member["member_status"]), position); err != nil {
			return "", uuid.Nil, err
		}
	}
	return legacyID, rosterID, nil
}

func rosterSortConfigurationJSON(value any) string {
	items := make([]map[string]string, 0)
	seen := make(map[string]struct{})
	for _, legacy := range uniqueRosterStrings(value) {
		columnID, direction, ok := rosterSortField(legacy)
		if !ok {
			continue
		}
		if _, exists := seen[columnID]; exists {
			continue
		}
		seen[columnID] = struct{}{}
		items = append(items, map[string]string{"columnId": columnID, "direction": direction})
		if len(items) == 5 {
			break
		}
	}
	encoded, _ := json.Marshal(items)
	return string(encoded)
}

var rosterColumnIDPattern = regexp.MustCompile(`^[a-z][a-z0-9_]{0,47}$`)

var legacyRosterColumnIDs = map[string]string{
	"th":               "townhall",
	"town hall":        "townhall",
	"townhall level":   "townhall",
	"name":             "name",
	"player tag":       "tag",
	"tag":              "tag",
	"30 day hitrate":   "hitrate",
	"hit rate":         "hitrate",
	"hitrate":          "hitrate",
	"clan":             "current_clan",
	"current clan":     "current_clan",
	"clan tag":         "current_clan_tag",
	"current clan tag": "current_clan_tag",
	"discord":          "discord",
	"heroes":           "hero_lvs",
	"hero levels":      "hero_lvs",
	"trophies":         "trophies",
	"war opt status":   "war_pref",
	"war pref":         "war_pref",
	"war preference":   "war_pref",
}

var legacyRosterSortFields = map[string]struct {
	columnID  string
	direction string
}{
	"th":                     {"townhall", "desc"},
	"town hall":              {"townhall", "desc"},
	"townhall level":         {"townhall", "desc"},
	"th (high to low)":       {"townhall", "desc"},
	"th (low to high)":       {"townhall", "asc"},
	"name a-z":               {"name", "asc"},
	"name (a-z)":             {"name", "asc"},
	"name z-a":               {"name", "desc"},
	"name (z-a)":             {"name", "desc"},
	"30 day hitrate":         {"hitrate", "desc"},
	"hit rate":               {"hitrate", "desc"},
	"hitrate":                {"hitrate", "desc"},
	"hit rate (high to low)": {"hitrate", "desc"},
	"hit rate (low to high)": {"hitrate", "asc"},
	"heroes":                 {"hero_lvs", "desc"},
	"hero levels":            {"hero_lvs", "desc"},
	"heroes (high to low)":   {"hero_lvs", "desc"},
	"trophies":               {"trophies", "desc"},
	"recent":                 {"added_at", "desc"},
	"recently added":         {"added_at", "desc"},
	"oldest":                 {"added_at", "asc"},
	"first added":            {"added_at", "asc"},
}

func rosterColumnIDs(value any) []string {
	columnIDs := make([]string, 0)
	seen := make(map[string]struct{})
	for _, legacy := range uniqueRosterStrings(value) {
		columnID, ok := rosterColumnID(legacy)
		if !ok {
			continue
		}
		if _, exists := seen[columnID]; exists {
			continue
		}
		seen[columnID] = struct{}{}
		columnIDs = append(columnIDs, columnID)
		if len(columnIDs) == 24 {
			break
		}
	}
	return columnIDs
}

func rosterColumnID(value string) (string, bool) {
	trimmed := strings.TrimSpace(value)
	if canonical, ok := legacyRosterColumnIDs[strings.ToLower(trimmed)]; ok {
		return canonical, true
	}
	return trimmed, rosterColumnIDPattern.MatchString(trimmed)
}

func rosterSortField(value string) (string, string, bool) {
	trimmed := strings.TrimSpace(value)
	direction := "asc"
	if mapped, ok := legacyRosterSortFields[strings.ToLower(trimmed)]; ok {
		return mapped.columnID, mapped.direction, true
	}
	if strings.HasSuffix(trimmed, "_desc") {
		direction = "desc"
		trimmed = strings.TrimSuffix(trimmed, "_desc")
	} else if strings.HasSuffix(trimmed, "_asc") {
		trimmed = strings.TrimSuffix(trimmed, "_asc")
	}
	columnID, ok := rosterColumnID(trimmed)
	return columnID, direction, ok
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

func nullableRosterTimestamp(value any) any {
	if value == nil || migrateutil.String(value) == "" {
		return nil
	}
	switch typed := value.(type) {
	case time.Time:
		return typed.UTC()
	case bson.DateTime:
		return typed.Time().UTC()
	}
	raw := int64(migrateutil.Int(value))
	if raw > 100000000000 {
		return time.UnixMilli(raw).UTC()
	}
	return time.Unix(raw, 0).UTC()
}

func rosterJSON(value, fallback any) string {
	if value == nil {
		value = fallback
	}
	encoded, err := json.Marshal(value)
	if err != nil {
		encoded, _ = json.Marshal(fallback)
	}
	return string(encoded)
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
