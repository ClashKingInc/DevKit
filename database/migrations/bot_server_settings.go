//go:build ignore

package main

import (
	"context"
	"fmt"
	"net/url"
	"os"
	"path"
	"strconv"
	"strings"

	"github.com/ClashKingInc/DevKit/database/migrations/migrateutil"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"go.mongodb.org/mongo-driver/v2/bson"
	"go.mongodb.org/mongo-driver/v2/mongo"
)

func main() {
	migrateutil.Main("bot_server_settings", runBotServerSettings)
}

func runBotServerSettings(ctx context.Context, cfg migrateutil.Config) error {
	if scope := strings.TrimSpace(os.Getenv("BOT_SERVER_SETTINGS_ONLY")); scope != "" {
		switch scope {
		case "giveaways":
			return runGiveawaysOnly(ctx, cfg)
		case "reminders":
			return runRemindersOnly(ctx, cfg)
		default:
			return fmt.Errorf("unsupported BOT_SERVER_SETTINGS_ONLY scope %q", scope)
		}
	}

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
	plan := botSettingsOneShotPlan()
	if err := migrateutil.StartOneShot(ctx, pool, plan); err != nil {
		return err
	}
	if err := migrateUserSettings(ctx, cfg, pool, staticClient.Database("usafam").Collection("user_settings")); err != nil {
		return err
	}
	if err := migrateCustomEmbeds(ctx, cfg, pool, staticClient.Database("usafam").Collection("custom_embeds")); err != nil {
		return err
	}
	if err := migrateTicketPanels(ctx, cfg, pool, staticClient.Database("usafam").Collection("tickets")); err != nil {
		return err
	}
	if err := migrateCanonicalTicketPanels(ctx, cfg, pool, staticClient.Database("usafam").Collection("tickets")); err != nil {
		return err
	}
	if err := migrateOpenTickets(ctx, cfg, pool, staticClient.Database("usafam").Collection("open_tickets")); err != nil {
		return err
	}
	if err := migrateReminders(ctx, cfg, pool, staticClient.Database("usafam").Collection("reminders")); err != nil {
		return err
	}
	if err := migrateGiveaways(ctx, cfg, pool, statsClient.Database("clashking").Collection("giveaways")); err != nil {
		return err
	}
	if err := migrateShortLinks(ctx, cfg, pool, statsClient.Database("clashking").Collection("short_links")); err != nil {
		return err
	}
	// Migration 003 intentionally starts autoboards empty. Legacy Mongo
	// autoboards use unfinished button/data/day aliases that cannot be mapped
	// truthfully before the API board-type registry is finalized, so this
	// importer must not scan or recreate them.
	return migrateutil.FinishOneShot(ctx, pool, plan)
}

func runRemindersOnly(ctx context.Context, cfg migrateutil.Config) error {
	staticClient, err := migrateutil.StaticClient(ctx, cfg)
	if err != nil {
		return err
	}
	defer staticClient.Disconnect(ctx)
	pool, err := migrateutil.TimescalePool(ctx, cfg)
	if err != nil {
		return err
	}
	defer pool.Close()
	collection := staticClient.Database("usafam").Collection("reminders")
	sourceCount, err := collection.CountDocuments(ctx, bson.M{})
	if err != nil {
		return fmt.Errorf("preflight source reminders: %w", err)
	}
	if sourceCount == 0 {
		return fmt.Errorf("refusing to truncate reminders: source collection is empty")
	}
	fmt.Printf("settings.reminders: source_docs=%d\n", sourceCount)
	plan := remindersOneShotPlan()
	if err := migrateutil.StartOneShot(ctx, pool, plan); err != nil {
		return err
	}
	if err := migrateReminders(ctx, cfg, pool, collection); err != nil {
		return err
	}
	return migrateutil.FinishOneShot(ctx, pool, plan)
}

func remindersOneShotPlan() migrateutil.OneShotPlan {
	return migrateutil.OneShotPlan{
		ResetSQL:    []string{`TRUNCATE TABLE public.reminders`},
		DropIndexes: []string{`DROP INDEX IF EXISTS public.idx_reminders_server_type_name`},
		CreateIndexes: []string{
			`CREATE INDEX idx_reminders_server_type_name ON public.reminders (server_id, type_name)`,
		},
	}
}

func runGiveawaysOnly(ctx context.Context, cfg migrateutil.Config) error {
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
	collection := statsClient.Database("clashking").Collection("giveaways")
	sourceCount, err := collection.CountDocuments(ctx, bson.M{})
	if err != nil {
		return fmt.Errorf("preflight source giveaways: %w", err)
	}
	if sourceCount == 0 {
		return fmt.Errorf("refusing to truncate giveaways: source collection is empty")
	}
	fmt.Printf("settings.giveaways: source_docs=%d\n", sourceCount)
	plan := giveawaysOneShotPlan()
	if err := migrateutil.StartOneShot(ctx, pool, plan); err != nil {
		return err
	}
	if err := migrateGiveaways(ctx, cfg, pool, collection); err != nil {
		return err
	}
	return migrateutil.FinishOneShot(ctx, pool, plan)
}

func giveawaysOneShotPlan() migrateutil.OneShotPlan {
	return migrateutil.OneShotPlan{
		ResetSQL: []string{`TRUNCATE TABLE public.giveaways`},
		DropIndexes: []string{
			`DROP INDEX IF EXISTS public.idx_giveaways_due_end`,
			`DROP INDEX IF EXISTS public.idx_giveaways_due_start`,
			`DROP INDEX IF EXISTS public.idx_giveaways_end_time`,
			`DROP INDEX IF EXISTS public.idx_giveaways_entries_gin`,
			`DROP INDEX IF EXISTS public.idx_giveaways_pending_event`,
			`DROP INDEX IF EXISTS public.idx_giveaways_server_status`,
		},
		CreateIndexes: []string{
			`CREATE INDEX idx_giveaways_due_end ON public.giveaways (end_time) WHERE status = 'ongoing'`,
			`CREATE INDEX idx_giveaways_due_start ON public.giveaways (start_time) WHERE status = 'scheduled'`,
			`CREATE INDEX idx_giveaways_end_time ON public.giveaways (end_time)`,
			`CREATE INDEX idx_giveaways_entries_gin ON public.giveaways USING gin (entries)`,
			`CREATE INDEX idx_giveaways_pending_event ON public.giveaways (event_pending_at) WHERE event_pending IS NOT NULL`,
			`CREATE INDEX idx_giveaways_server_status ON public.giveaways (server_id, status)`,
		},
	}
}

func botSettingsOneShotPlan() migrateutil.OneShotPlan {
	return migrateutil.OneShotPlan{
		ResetSQL: []string{
			`TRUNCATE TABLE
				public.tickets,
				public.ticket_panel_buttons,
				public.ticket_panel_staff_permissions,
				public.ticket_panel,
				public.ticket_panels,
				public.server_custom_embeds,
				public.reminders,
				public.giveaways,
				public.short_links,
				public.user_settings`,
		},
		DropIndexes: []string{
			`DROP INDEX IF EXISTS public.idx_ticket_panels_components_gin`,
			`DROP INDEX IF EXISTS public.idx_reminders_server_type_name`,
			`DROP INDEX IF EXISTS public.idx_giveaways_due_end`,
			`DROP INDEX IF EXISTS public.idx_giveaways_due_start`,
			`DROP INDEX IF EXISTS public.idx_giveaways_end_time`,
			`DROP INDEX IF EXISTS public.idx_giveaways_entries_gin`,
			`DROP INDEX IF EXISTS public.idx_giveaways_pending_event`,
			`DROP INDEX IF EXISTS public.idx_giveaways_server_status`,
			`DROP INDEX IF EXISTS public.idx_user_settings_search_gin`,
		},
		CreateIndexes: []string{
			`CREATE INDEX idx_ticket_panels_components_gin ON public.ticket_panels USING gin (components)`,
			`CREATE INDEX idx_reminders_server_type_name ON public.reminders (server_id, type_name)`,
			`CREATE INDEX idx_giveaways_due_end ON public.giveaways (end_time) WHERE status = 'ongoing'`,
			`CREATE INDEX idx_giveaways_due_start ON public.giveaways (start_time) WHERE status = 'scheduled'`,
			`CREATE INDEX idx_giveaways_end_time ON public.giveaways (end_time)`,
			`CREATE INDEX idx_giveaways_entries_gin ON public.giveaways USING gin (entries)`,
			`CREATE INDEX idx_giveaways_pending_event ON public.giveaways (event_pending_at) WHERE event_pending IS NOT NULL`,
			`CREATE INDEX idx_giveaways_server_status ON public.giveaways (server_id, status)`,
			`CREATE INDEX idx_user_settings_search_gin ON public.user_settings USING gin (search)`,
		},
	}
}

func migrateUserSettings(ctx context.Context, cfg migrateutil.Config, pool interface {
	Begin(context.Context) (pgx.Tx, error)
}, collection *mongo.Collection) error {
	rows := make([][]any, 0, cfg.BatchSize)
	flush := func() error {
		err := flushRows(ctx, pool, "user_settings", []string{"user_id", "search", "app", "data"}, rows, []int{0}, `
			INSERT INTO user_settings (user_id, search, app, data)
			SELECT user_id, search::jsonb, app::jsonb, data::jsonb FROM _ck_rows
			WHERE user_id <> ''
			ON CONFLICT (user_id) DO UPDATE SET
				search = EXCLUDED.search,
				app = EXCLUDED.app,
				data = EXCLUDED.data,
				updated_at = now()
		`)
		if err == nil {
			rows = rows[:0]
		}
		return err
	}
	seen, err := migrateutil.StreamAll(ctx, cfg, "user_settings", collection, func(doc bson.M) (bool, error) {
		rows = append(rows, []any{
			firstSettingString(doc["discord_user"], doc["discord_id"], doc["user_id"]),
			migrateutil.RawJSON(doc["search"]),
			migrateutil.RawJSON(map[string]any{
				"embed_color":         doc["embed_color"],
				"private_mode":        doc["private_mode"],
				"main_account":        doc["main_account"],
				"server_main_account": doc["server_main_account"],
				"armies":              doc["armies"],
			}),
			migrateutil.RawJSON(doc),
		})
		return len(rows) >= cfg.BatchSize, nil
	}, flush)
	fmt.Printf("settings.user_settings: scanned_docs=%d\n", seen)
	return err
}

func migrateCustomEmbeds(ctx context.Context, cfg migrateutil.Config, pool interface {
	Begin(context.Context) (pgx.Tx, error)
}, collection *mongo.Collection) error {
	rows := make([][]any, 0, cfg.BatchSize)
	flush := func() error {
		err := flushRows(ctx, pool, "server_custom_embeds", []string{"server_id", "name", "data"}, rows, []int{0, 1}, `
			INSERT INTO server_custom_embeds (server_id, name, data)
			SELECT server_id, name, data::jsonb FROM _ck_rows
			WHERE server_id <> '' AND name <> ''
			ON CONFLICT (server_id, name) DO UPDATE SET data = EXCLUDED.data
		`)
		if err == nil {
			rows = rows[:0]
		}
		return err
	}
	seen, err := migrateutil.StreamAll(ctx, cfg, "custom_embeds", collection, func(doc bson.M) (bool, error) {
		rows = append(rows, []any{migrateutil.String(doc["server"]), migrateutil.String(doc["name"]), migrateutil.RawJSON(doc["data"])})
		return len(rows) >= cfg.BatchSize, nil
	}, flush)
	fmt.Printf("settings.custom_embeds: scanned_docs=%d\n", seen)
	return err
}

func migrateTicketPanels(ctx context.Context, cfg migrateutil.Config, pool interface {
	Begin(context.Context) (pgx.Tx, error)
}, collection *mongo.Collection) error {
	rows := make([][]any, 0, cfg.BatchSize)
	flush := func() error {
		err := flushRows(ctx, pool, "ticket_panels", []string{"server_id", "name", "components", "data"}, rows, []int{0, 1}, `
			INSERT INTO ticket_panels (server_id, name, components, data)
			SELECT server_id, name, components::jsonb, data::jsonb FROM _ck_rows
			WHERE server_id <> '' AND name <> ''
			ON CONFLICT (server_id, name) DO UPDATE SET components = EXCLUDED.components, data = EXCLUDED.data, updated_at = now()
		`)
		if err == nil {
			rows = rows[:0]
		}
		return err
	}
	seen, err := migrateutil.StreamAll(ctx, cfg, "ticket_panels", collection, func(doc bson.M) (bool, error) {
		rows = append(rows, []any{migrateutil.String(doc["server_id"]), migrateutil.String(doc["name"]), migrateutil.RawJSON(doc["components"]), migrateutil.RawJSON(doc)})
		return len(rows) >= cfg.BatchSize, nil
	}, flush)
	fmt.Printf("settings.ticket_panels: scanned_docs=%d\n", seen)
	return err
}

func migrateCanonicalTicketPanels(ctx context.Context, cfg migrateutil.Config, pool interface {
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
			if err := writeCanonicalTicketPanel(ctx, tx, doc); err != nil {
				return err
			}
		}
		if err := tx.Commit(ctx); err != nil {
			return err
		}
		batch = batch[:0]
		return nil
	}
	seen, err := migrateutil.StreamAll(ctx, cfg, "canonical_ticket_panels", collection, func(doc bson.M) (bool, error) {
		batch = append(batch, doc)
		return len(batch) >= cfg.BatchSize, nil
	}, flush)
	fmt.Printf("settings.canonical_ticket_panels: scanned_docs=%d\n", seen)
	return err
}

func writeCanonicalTicketPanel(ctx context.Context, tx pgx.Tx, doc bson.M) error {
	serverID := firstSettingString(doc["server_id"], doc["server"])
	name := migrateutil.String(doc["name"])
	if serverID == "" || name == "" {
		return nil
	}
	if _, err := tx.Exec(ctx, `INSERT INTO public.servers (id, name) VALUES ($1, $1) ON CONFLICT DO NOTHING`, serverID); err != nil {
		return err
	}
	panelID := stableUUID("ticket-panel", serverID+"\x00"+name)
	embedName := firstSettingString(doc["embed_name"], doc["embed"])
	var embedServerID, storedEmbedName any
	if embedName != "" {
		var exists bool
		if err := tx.QueryRow(ctx, `
			SELECT EXISTS (
				SELECT 1 FROM public.server_custom_embeds
			 WHERE server_id = $1 AND name = $2
			)
		`, serverID, embedName).Scan(&exists); err != nil {
			return err
		}
		if exists {
			embedServerID = serverID
			storedEmbedName = embedName
		}
	}
	if _, err := tx.Exec(ctx, `
		INSERT INTO public.ticket_panel (
			id, server_id, name, description, parent_channel_id,
			open_category_id, closed_category_id, log_channel_id,
			naming_convention, embed_server_id, embed_name,
			sleep_category_id, status_change_log_channel_id,
			button_click_log_channel_id, ticket_close_log_channel_id
		) VALUES (
			$1::uuid, $2, $3, $4, NULLIF($5, ''),
			NULLIF($6, ''), NULLIF($7, ''), NULLIF($8, ''),
			NULLIF($9, ''), $10, $11,
			NULLIF($12, ''), NULLIF($13, ''), NULLIF($14, ''), NULLIF($15, '')
		)
		ON CONFLICT (id) DO UPDATE SET
			name = EXCLUDED.name,
			description = EXCLUDED.description,
			parent_channel_id = EXCLUDED.parent_channel_id,
			open_category_id = EXCLUDED.open_category_id,
			closed_category_id = EXCLUDED.closed_category_id,
			log_channel_id = EXCLUDED.log_channel_id,
			naming_convention = EXCLUDED.naming_convention,
			embed_server_id = EXCLUDED.embed_server_id,
			embed_name = EXCLUDED.embed_name,
			sleep_category_id = EXCLUDED.sleep_category_id,
			status_change_log_channel_id = EXCLUDED.status_change_log_channel_id,
			button_click_log_channel_id = EXCLUDED.button_click_log_channel_id,
			ticket_close_log_channel_id = EXCLUDED.ticket_close_log_channel_id
	`, panelID, serverID, name, migrateutil.String(doc["description"]),
		firstSettingString(doc["parent_channel"], doc["channel"]),
		migrateutil.String(doc["open-category"]),
		migrateutil.String(doc["closed-category"]),
		firstSettingString(doc["ticket_close_log"], doc["status_change_log"]),
		migrateutil.String(doc["naming"]),
		embedServerID, storedEmbedName,
		migrateutil.String(doc["sleep-category"]),
		migrateutil.String(doc["status_change_log"]),
		migrateutil.String(doc["ticket_button_click_log"]),
		migrateutil.String(doc["ticket_close_log"]),
	); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `DELETE FROM public.ticket_panel_buttons WHERE panel_id = $1::uuid`, panelID); err != nil {
		return err
	}
	for _, raw := range migrateutil.Slice(doc["components"]) {
		component := migrateutil.Map(raw)
		customID := migrateutil.String(component["custom_id"])
		if customID == "" {
			continue
		}
		settings := migrateutil.Map(doc[customID+"_settings"])
		if settings == nil {
			settings = bson.M{}
		}
		buttonID := stableUUID("ticket-panel-button", serverID+"\x00"+name+"\x00"+customID)
		if _, err := tx.Exec(ctx, `
			INSERT INTO public.ticket_panel_buttons (
				id, panel_id, server_id, questions, staff_roles,
				roles_add_on_open, roles_remove_on_open,
				allow_account_apply, min_townhall_level, staff_private_thread,
				send_player_info_to_channel, send_player_info_to_private_thread,
				staff_to_ping, parent_channel_id, open_category_id,
				closed_category_id, log_channel_id, naming_convention,
				custom_id, label, style, emoji
			) VALUES (
				$1::uuid, $2::uuid, $3, $4, $5,
				$6, $7, $8, $9, $10,
				$11, $12, $13, NULLIF($14, ''), NULLIF($15, ''),
				NULLIF($16, ''), NULLIF($17, ''), NULLIF($18, ''),
				$19, NULLIF($20, ''), $21, NULLIF($22, '')
			)
			ON CONFLICT (id) DO UPDATE SET
				questions = EXCLUDED.questions,
				staff_roles = EXCLUDED.staff_roles,
				roles_add_on_open = EXCLUDED.roles_add_on_open,
				roles_remove_on_open = EXCLUDED.roles_remove_on_open,
				allow_account_apply = EXCLUDED.allow_account_apply,
				min_townhall_level = EXCLUDED.min_townhall_level,
				staff_private_thread = EXCLUDED.staff_private_thread,
				send_player_info_to_channel = EXCLUDED.send_player_info_to_channel,
				send_player_info_to_private_thread = EXCLUDED.send_player_info_to_private_thread,
				staff_to_ping = EXCLUDED.staff_to_ping,
				naming_convention = EXCLUDED.naming_convention,
				custom_id = EXCLUDED.custom_id,
				label = EXCLUDED.label,
				style = EXCLUDED.style,
				emoji = EXCLUDED.emoji
		`, buttonID, panelID, serverID,
			ticketQuestions(settings["questions"]),
			stringSlice(settings["mod_role"]),
			stringSlice(settings["roles_to_add"]),
			stringSlice(settings["roles_to_remove"]),
			ticketApplyMode(settings),
			nullableIntInRange(settings["th_min"], 1, 100),
			truthy(settings["private_thread"]),
			truthy(settings["player_info"]),
			truthy(settings["player_info"]),
			stringSlice(settings["mod_role"]),
			firstSettingString(settings["parent_channel"], doc["parent_channel"], doc["channel"]),
			firstSettingString(settings["open_category"], doc["open-category"]),
			firstSettingString(settings["closed_category"], doc["closed-category"]),
			firstSettingString(settings["log_channel"], doc["ticket_close_log"], doc["status_change_log"]),
			firstSettingString(settings["naming"], doc["naming"]),
			customID,
			migrateutil.String(component["label"]),
			nullableIntInRange(component["style"], 1, 5),
			migrateutil.String(component["emoji"]),
		); err != nil {
			return fmt.Errorf(
				"write ticket panel server=%s name=%q button=%s: %w",
				serverID,
				name,
				customID,
				err,
			)
		}
	}
	return nil
}

func migrateOpenTickets(ctx context.Context, cfg migrateutil.Config, pool interface {
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
			if err := writeOpenTicket(ctx, tx, doc); err != nil {
				return err
			}
		}
		if err := tx.Commit(ctx); err != nil {
			return err
		}
		batch = batch[:0]
		return nil
	}
	seen, err := migrateutil.StreamAll(ctx, cfg, "open_tickets", collection, func(doc bson.M) (bool, error) {
		batch = append(batch, doc)
		return len(batch) >= cfg.BatchSize, nil
	}, flush)
	fmt.Printf("settings.open_tickets: scanned_docs=%d\n", seen)
	return err
}

func writeOpenTicket(ctx context.Context, tx pgx.Tx, doc bson.M) error {
	serverID := firstSettingString(doc["server"], doc["server_id"])
	channelID := firstSettingString(doc["channel"], doc["channel_id"])
	if serverID == "" || channelID == "" {
		return nil
	}
	panelName := firstSettingString(doc["panel"], doc["panel_name"])
	if panelName == "" {
		panelName = "legacy"
	}
	panelID := stableUUID("ticket-panel", serverID+"\x00"+panelName)
	if _, err := tx.Exec(ctx, `INSERT INTO public.servers (id, name) VALUES ($1, $1) ON CONFLICT DO NOTHING`, serverID); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `
		INSERT INTO public.ticket_panel (id, server_id, name, description)
		VALUES ($1::uuid, $2, $3, '')
		ON CONFLICT (id) DO NOTHING
	`, panelID, serverID, panelName); err != nil {
		return err
	}
	status := migrateutil.String(doc["status"])
	switch status {
	case "open", "sleep", "closed", "delete":
	default:
		status = "open"
	}
	account := firstSettingString(doc["apply_account"], doc["applicant_account"])
	accounts := []string{}
	if account != "" {
		accounts = append(accounts, account)
	}
	createdAt := timeFromMongoDocument(doc)
	var closedAt any
	if status == "closed" {
		if value, ok := migrateutil.Time(firstSettingValue(doc["closed_at"], doc["updated_at"])); ok {
			closedAt = value
		}
	}
	_, err := tx.Exec(ctx, `
		INSERT INTO public.tickets (
			id, server_id, channel_id, is_thread, status_id, number, panel_id,
			applicant_accounts, applicant_user_id, thread_id, status,
			naming_convention, assigned_clan_tag, opted_in_user_ids,
			created_at, closed_at
		) VALUES (
			$1::uuid, $2, $3, false, 0, $4, $5::uuid,
			$6, NULLIF($7, ''), NULLIF($8, ''), $9,
			NULLIF($10, ''), NULLIF($11, ''), $12,
			COALESCE($13, now()), $14
		)
		ON CONFLICT (channel_id) DO UPDATE SET
			server_id = EXCLUDED.server_id,
			number = EXCLUDED.number,
			panel_id = EXCLUDED.panel_id,
			applicant_accounts = EXCLUDED.applicant_accounts,
			applicant_user_id = EXCLUDED.applicant_user_id,
			thread_id = EXCLUDED.thread_id,
			status = EXCLUDED.status,
			naming_convention = EXCLUDED.naming_convention,
			assigned_clan_tag = EXCLUDED.assigned_clan_tag,
			opted_in_user_ids = EXCLUDED.opted_in_user_ids
	`, stableUUID("ticket", serverID+"\x00"+channelID), serverID, channelID,
		max(1, migrateutil.Int(doc["number"])), panelID, accounts,
		firstSettingString(doc["user"], doc["user_id"]),
		firstSettingString(doc["thread"], doc["thread_id"]),
		status,
		migrateutil.String(doc["naming"]),
		firstSettingString(doc["set_clan"], doc["assigned_clan_tag"]),
		stringSlice(doc["opted_in"]),
		createdAt,
		closedAt,
	)
	return err
}

func ticketApplyMode(settings bson.M) int {
	if truthy(settings["account_apply"]) {
		if count := nullableIntInRange(settings["num_apply"], 1, 1000); count != nil {
			return count.(int)
		}
		return 25
	}
	return 0
}

func nullableIntInRange(value any, minimum, maximum int) any {
	if out := migrateutil.Int(value); out >= minimum && out <= maximum {
		return out
	}
	return nil
}

func truthy(value any) bool {
	if migrateutil.Bool(value) {
		return true
	}
	switch strings.ToLower(migrateutil.String(value)) {
	case "yes", "on", "enabled", "true", "1":
		return true
	default:
		return false
	}
}

func firstSettingValue(values ...any) any {
	for _, value := range values {
		if value != nil {
			return value
		}
	}
	return nil
}

func timeFromMongoDocument(doc bson.M) any {
	if value, ok := migrateutil.Time(firstSettingValue(doc["created_at"], doc["createdAt"])); ok {
		return value
	}
	if objectID, ok := doc["_id"].(bson.ObjectID); ok {
		return objectID.Timestamp()
	}
	return nil
}

func reminderMinutes(value any) int {
	raw := strings.TrimSpace(strings.ToLower(migrateutil.String(value)))
	raw = strings.TrimSpace(strings.TrimSuffix(raw, "hr"))
	if raw == "" {
		return 0
	}
	hours, err := strconv.ParseFloat(raw, 64)
	if err != nil || hours <= 0 {
		return 0
	}
	return int(hours*60 + 0.5)
}

func reminderMinutesFromDocument(doc bson.M) int {
	if minutes := migrateutil.Int(doc["minutes_remaining"]); minutes > 0 {
		return minutes
	}
	return reminderMinutes(doc["time"])
}

func migrateReminders(ctx context.Context, cfg migrateutil.Config, pool interface {
	Begin(context.Context) (pgx.Tx, error)
}, collection *mongo.Collection) error {
	rows := make([][]any, 0, cfg.BatchSize)
	flush := func() error {
		err := flushRows(ctx, pool, "reminders", []string{"id", "server_id", "type", "type_name", "clan_tag", "webhook_token", "minutes_remaining", "channel_id", "thread_id", "trigger_time", "custom_text", "data"}, rows, []int{0}, `
			INSERT INTO reminders (id, server_id, type, type_name, clan_tag, webhook_token, minutes_remaining, channel_id, thread_id, trigger_time, custom_text, data)
			SELECT id::uuid, server_id, type, type_name, clan_tag, webhook_token, minutes_remaining, NULLIF(channel_id, ''), NULLIF(thread_id, ''), NULLIF(trigger_time, ''), custom_text, data::jsonb
			FROM _ck_rows
			WHERE server_id <> '' AND type_name <> '' AND clan_tag <> ''
			ON CONFLICT (id) DO UPDATE SET
				server_id = EXCLUDED.server_id,
				type = EXCLUDED.type,
				type_name = EXCLUDED.type_name,
				clan_tag = EXCLUDED.clan_tag,
				webhook_token = EXCLUDED.webhook_token,
				minutes_remaining = EXCLUDED.minutes_remaining,
				channel_id = EXCLUDED.channel_id,
				thread_id = EXCLUDED.thread_id,
				trigger_time = EXCLUDED.trigger_time,
				custom_text = EXCLUDED.custom_text,
				data = EXCLUDED.data,
				updated_at = now()
		`)
		if err == nil {
			rows = rows[:0]
		}
		return err
	}
	seen, err := migrateutil.StreamAll(ctx, cfg, "reminders", collection, func(doc bson.M) (bool, error) {
		rows = append(rows, []any{
			stableUUID("reminder", migrateutil.String(doc["_id"])),
			migrateutil.String(doc["server"]),
			migrateutil.Int(doc["type"]),
			migrateutil.String(doc["type"]),
			migrateutil.String(doc["clan"]),
			migrateutil.String(doc["webhook_token"]),
			reminderMinutesFromDocument(doc),
			migrateutil.String(doc["channel"]),
			reminderThreadID(doc),
			migrateutil.String(doc["time"]),
			migrateutil.String(doc["custom_text"]),
			migrateutil.RawJSON(doc),
		})
		return len(rows) >= cfg.BatchSize, nil
	}, flush)
	fmt.Printf("settings.reminders: scanned_docs=%d\n", seen)
	return err
}

func migrateGiveaways(ctx context.Context, cfg migrateutil.Config, pool interface {
	Begin(context.Context) (pgx.Tx, error)
}, collection *mongo.Collection) error {
	rows := make([][]any, 0, cfg.BatchSize)
	flush := func() error {
		err := flushRows(ctx, pool, "giveaways", []string{
			"id", "server_id", "prize", "channel_id", "status", "start_time", "end_time", "winners",
			"mentions", "text_above_embed", "text_in_embed", "text_on_end", "image_url",
			"profile_picture_required", "coc_account_required", "roles_mode", "roles", "boosters", "entries", "winners_list",
			"updated", "message_id", "event_pending", "event_pending_at", "created_at", "updated_at",
		}, rows, []int{0}, `
			INSERT INTO giveaways (
				id, server_id, prize, channel_id, status, start_time, end_time, winners,
				mentions, text_above_embed, text_in_embed, text_on_end, image_url,
				profile_picture_required, coc_account_required, roles_mode, roles, boosters, entries, winners_list,
				updated, message_id, event_pending, event_pending_at, created_at, updated_at
			)
			SELECT id, server_id, prize, NULLIF(channel_id, ''), status, start_time, end_time, winners,
				mentions, text_above_embed, text_in_embed, text_on_end, NULLIF(image_url, ''),
				profile_picture_required, coc_account_required, roles_mode, roles, boosters::jsonb, entries::jsonb, winners_list::jsonb,
				updated, NULLIF(message_id, ''), NULLIF(event_pending, ''), event_pending_at,
				COALESCE(created_at, now()), COALESCE(updated_at, now())
			FROM _ck_rows
			WHERE id <> '' AND server_id <> ''
			ON CONFLICT (id) DO UPDATE SET
				server_id = EXCLUDED.server_id,
				prize = EXCLUDED.prize,
				channel_id = EXCLUDED.channel_id,
				status = EXCLUDED.status,
				start_time = EXCLUDED.start_time,
				end_time = EXCLUDED.end_time,
				winners = EXCLUDED.winners,
				mentions = EXCLUDED.mentions,
				text_above_embed = EXCLUDED.text_above_embed,
				text_in_embed = EXCLUDED.text_in_embed,
				text_on_end = EXCLUDED.text_on_end,
				image_url = EXCLUDED.image_url,
				profile_picture_required = EXCLUDED.profile_picture_required,
				coc_account_required = EXCLUDED.coc_account_required,
				roles_mode = EXCLUDED.roles_mode,
				roles = EXCLUDED.roles,
				boosters = EXCLUDED.boosters,
				entries = EXCLUDED.entries,
				winners_list = EXCLUDED.winners_list,
				updated = EXCLUDED.updated,
				message_id = EXCLUDED.message_id,
				event_pending = EXCLUDED.event_pending,
				event_pending_at = EXCLUDED.event_pending_at,
				created_at = EXCLUDED.created_at,
				updated_at = EXCLUDED.updated_at
		`)
		if err == nil {
			rows = rows[:0]
		}
		return err
	}
	seen, err := migrateutil.StreamAll(ctx, cfg, "giveaways", collection, func(doc bson.M) (bool, error) {
		start, startOK := migrateutil.Time(doc["start_time"])
		end, endOK := migrateutil.Time(doc["end_time"])
		if !startOK || !endOK {
			return false, nil
		}
		rows = append(rows, []any{
			migrateutil.String(doc["_id"]),
			migrateutil.String(doc["server_id"]),
			migrateutil.String(doc["prize"]),
			migrateutil.String(doc["channel_id"]),
			migrateutil.String(doc["status"]),
			start,
			end,
			migrateutil.Int(doc["winners"]),
			stringSlice(doc["mentions"]),
			migrateutil.String(doc["text_above_embed"]),
			migrateutil.String(doc["text_in_embed"]),
			migrateutil.String(doc["text_on_end"]),
			giveawayImageName(doc["image_url"]),
			migrateutil.Bool(doc["profile_picture_required"]),
			migrateutil.Bool(doc["coc_account_required"]),
			migrateutil.String(doc["roles_mode"]),
			stringSlice(doc["roles"]),
			migrateutil.RawJSON(doc["boosters"]),
			migrateutil.RawJSON(doc["entries"]),
			migrateutil.RawJSON(doc["winners_list"]),
			migrateutil.Bool(doc["updated"]),
			migrateutil.String(doc["message_id"]),
			migrateutil.String(doc["event_pending"]),
			giveawayOptionalTime(doc["event_pending_at"]),
			giveawayOptionalTime(doc["created_at"]),
			giveawayOptionalTime(doc["updated_at"]),
		})
		return len(rows) >= cfg.BatchSize, nil
	}, flush)
	fmt.Printf("settings.giveaways: scanned_docs=%d\n", seen)
	return err
}

func giveawayOptionalTime(value any) any {
	if parsed, ok := migrateutil.Time(value); ok {
		return parsed
	}
	return nil
}

func giveawayImageName(value any) string {
	raw := strings.TrimSpace(migrateutil.String(value))
	parsed, err := url.Parse(raw)
	if err != nil || !strings.EqualFold(parsed.Hostname(), "cdn.clashking.xyz") {
		return ""
	}
	const prefix = "giveaway_"
	filename := path.Base(parsed.Path)
	if !strings.HasPrefix(filename, prefix) {
		return ""
	}
	return strings.TrimPrefix(filename, prefix)
}

func migrateShortLinks(ctx context.Context, cfg migrateutil.Config, pool interface {
	Begin(context.Context) (pgx.Tx, error)
}, collection *mongo.Collection) error {
	rows := make([][]any, 0, cfg.BatchSize)
	flush := func() error {
		err := flushRows(ctx, pool, "short_links", []string{"id", "url"}, rows, []int{0}, `
			INSERT INTO short_links (id, url)
			SELECT id, url FROM _ck_rows
			WHERE id <> '' AND url <> ''
			ON CONFLICT (id) DO UPDATE SET url = EXCLUDED.url
		`)
		if err == nil {
			rows = rows[:0]
		}
		return err
	}
	seen, err := migrateutil.StreamAll(ctx, cfg, "short_links", collection, func(doc bson.M) (bool, error) {
		rows = append(rows, []any{migrateutil.String(doc["_id"]), migrateutil.String(doc["url"])})
		return len(rows) >= cfg.BatchSize, nil
	}, flush)
	fmt.Printf("settings.short_links: scanned_docs=%d\n", seen)
	return err
}

func flushRows(ctx context.Context, pool interface {
	Begin(context.Context) (pgx.Tx, error)
}, table string, columns []string, rows [][]any, conflictKeyIndexes []int, mergeSQL string) error {
	if len(rows) == 0 {
		return nil
	}
	rows = dedupeRowsByIndexes(rows, conflictKeyIndexes)
	tx, err := pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	defs := make([]string, 0, len(columns))
	for _, column := range columns {
		defs = append(defs, column+" text")
	}
	if table == "giveaways" {
		defs = []string{
			"id text", "server_id text", "prize text", "channel_id text", "status text", "start_time timestamptz", "end_time timestamptz", "winners int",
			"mentions text[]", "text_above_embed text", "text_in_embed text", "text_on_end text", "image_url text",
			"profile_picture_required bool", "coc_account_required bool", "roles_mode text", "roles text[]", "boosters text", "entries text", "winners_list text",
			"updated bool", "message_id text", "event_pending text", "event_pending_at timestamptz", "created_at timestamptz", "updated_at timestamptz",
		}
	}
	if table == "rosters" {
		defs[5] = "max_size int"
	}
	if table == "reminders" {
		defs[2] = "type int"
		defs[6] = "minutes_remaining int"
	}
	if _, err := tx.Exec(ctx, "CREATE TEMP TABLE _ck_rows ("+strings.Join(defs, ", ")+") ON COMMIT DROP"); err != nil {
		return err
	}
	if _, err := tx.CopyFrom(ctx, pgx.Identifier{"_ck_rows"}, columns, pgx.CopyFromRows(rows)); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, mergeSQL); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

func dedupeRowsByIndexes(rows [][]any, keyIndexes []int) [][]any {
	if len(rows) < 2 || len(keyIndexes) == 0 {
		return rows
	}
	seen := make(map[string]struct{}, len(rows))
	deduplicated := make([][]any, 0, len(rows))
	for index := len(rows) - 1; index >= 0; index-- {
		row := rows[index]
		var key strings.Builder
		valid := true
		for _, keyIndex := range keyIndexes {
			if keyIndex < 0 || keyIndex >= len(row) {
				valid = false
				break
			}
			value := fmt.Sprint(row[keyIndex])
			fmt.Fprintf(&key, "%d:%s", len(value), value)
		}
		if !valid {
			continue
		}
		if _, exists := seen[key.String()]; exists {
			continue
		}
		seen[key.String()] = struct{}{}
		deduplicated = append(deduplicated, row)
	}
	for left, right := 0, len(deduplicated)-1; left < right; left, right = left+1, right-1 {
		deduplicated[left], deduplicated[right] = deduplicated[right], deduplicated[left]
	}
	return deduplicated
}

func stableUUID(prefix, value string) string {
	return uuid.NewSHA1(uuid.NameSpaceOID, []byte(prefix+":"+value)).String()
}

func firstSettingString(values ...any) string {
	for _, value := range values {
		if out := migrateutil.String(value); out != "" {
			return out
		}
	}
	return ""
}

func reminderThreadID(doc bson.M) string {
	return firstSettingString(doc["thread_id"], doc["thread"])
}

func stringSlice(value any) []string {
	out := make([]string, 0)
	for _, raw := range migrateutil.Slice(value) {
		if item := migrateutil.String(raw); item != "" {
			out = append(out, item)
		}
	}
	return out
}

func ticketQuestions(value any) []string {
	questions := stringSlice(value)
	if len(questions) > 5 {
		questions = questions[:5]
	}
	for index, question := range questions {
		runes := []rune(question)
		if len(runes) > 200 {
			questions[index] = string(runes[:200])
		}
	}
	return questions
}
