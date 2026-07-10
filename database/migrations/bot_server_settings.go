//go:build ignore

package main

import (
	"context"
	"fmt"
	"strings"

	"clashking_devkit_database_migrations/migrateutil"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"go.mongodb.org/mongo-driver/v2/bson"
	"go.mongodb.org/mongo-driver/v2/mongo"
)

func main() {
	migrateutil.Main("bot_server_settings", runBotServerSettings)
}

func runBotServerSettings(ctx context.Context, cfg migrateutil.Config) error {
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
	cp, err := migrateutil.LoadCheckpoint(cfg, "bot_server_settings")
	if err != nil {
		return err
	}

	if err := migrateServers(ctx, cfg, cp, pool, staticClient.Database("usafam").Collection("server")); err != nil {
		return err
	}
	if err := migrateBotSettings(ctx, cfg, cp, pool, staticClient.Database("bot").Collection("settings")); err != nil {
		return err
	}
	if err := migrateUserSettings(ctx, cfg, cp, pool, staticClient.Database("usafam").Collection("user_settings")); err != nil {
		return err
	}
	if err := migrateCustomEmbeds(ctx, cfg, cp, pool, staticClient.Database("usafam").Collection("custom_embeds")); err != nil {
		return err
	}
	if err := migrateTicketPanels(ctx, cfg, cp, pool, staticClient.Database("usafam").Collection("tickets")); err != nil {
		return err
	}
	if err := migrateOpenTickets(ctx, cfg, cp, pool, staticClient.Database("usafam").Collection("open_tickets")); err != nil {
		return err
	}
	if err := migrateReminders(ctx, cfg, cp, pool, staticClient.Database("usafam").Collection("reminders")); err != nil {
		return err
	}
	if err := migrateRosters(ctx, cfg, cp, pool, staticClient.Database("usafam").Collection("rosters")); err != nil {
		return err
	}
	if err := migrateGiveaways(ctx, cfg, cp, pool, statsClient.Database("clashking").Collection("giveaways")); err != nil {
		return err
	}
	if err := migrateShortLinks(ctx, cfg, cp, pool, statsClient.Database("clashking").Collection("short_links")); err != nil {
		return err
	}
	return nil
}

func migrateServers(ctx context.Context, cfg migrateutil.Config, cp *migrateutil.Checkpoint, pool interface {
	Begin(context.Context) (pgx.Tx, error)
}, collection *mongo.Collection) error {
	rows := make([][]any, 0, cfg.BatchSize)
	flush := func() error {
		err := flushRows(ctx, pool, "servers", []string{"id", "name", "embed_color", "logs_config", "status_roles", "countdowns", "data"}, rows, `
			INSERT INTO servers (id, name, embed_color, logs_config, status_roles, countdowns, data)
			SELECT id, COALESCE(NULLIF(name, ''), id), NULLIF(embed_color, ''), logs_config::jsonb, status_roles::jsonb, countdowns::jsonb, data::jsonb
			FROM _ck_rows
			ON CONFLICT (id) DO UPDATE SET
				name = EXCLUDED.name,
				embed_color = EXCLUDED.embed_color,
				logs_config = EXCLUDED.logs_config,
				status_roles = EXCLUDED.status_roles,
				countdowns = EXCLUDED.countdowns,
				data = EXCLUDED.data,
				updated_at = now()
		`)
		if err == nil {
			rows = rows[:0]
		}
		return err
	}
	seen, err := migrateutil.StreamByObjectID(ctx, cfg, cp, "server_id", collection, func(doc bson.M) (bool, error) {
		rows = append(rows, []any{
			migrateutil.String(doc["server"]),
			migrateutil.String(doc["name"]),
			migrateutil.String(doc["embed_color"]),
			migrateutil.RawJSON(map[string]any{
				"greeting":             doc["greeting"],
				"welcome_link_channel": doc["welcome_link_channel"],
				"welcome_link_embed":   doc["welcome_link_embed"],
			}),
			migrateutil.RawJSON(map[string]any{
				"leadership_eval": doc["leadership_eval"],
				"auto_nick":       doc["auto_nick"],
			}),
			migrateutil.RawJSON(map[string]any{
				"games": doc["gamesCountdown"],
				"cwl":   doc["cwlCountdown"],
				"raid":  doc["raidCountdown"],
				"eos":   doc["eosCountdown"],
			}),
			migrateutil.RawJSON(doc),
		})
		return len(rows) >= cfg.BatchSize, nil
	}, flush)
	fmt.Printf("settings.server: scanned_docs=%d\n", seen)
	return err
}

func migrateBotSettings(ctx context.Context, cfg migrateutil.Config, cp *migrateutil.Checkpoint, pool interface {
	Begin(context.Context) (pgx.Tx, error)
}, collection *mongo.Collection) error {
	rows := make([][]any, 0, 1)
	flush := func() error {
		err := flushRows(ctx, pool, "bot_settings", []string{"type", "data"}, rows, `
			INSERT INTO bot_settings (type, data)
			SELECT type, data::jsonb FROM _ck_rows
			ON CONFLICT (type) DO UPDATE SET data = EXCLUDED.data, updated_at = now()
		`)
		if err == nil {
			rows = rows[:0]
		}
		return err
	}
	seen, err := migrateutil.StreamByObjectID(ctx, cfg, cp, "bot_settings_id", collection, func(doc bson.M) (bool, error) {
		settingType := migrateutil.String(doc["type"])
		if settingType == "" {
			settingType = "bot"
		}
		rows = append(rows, []any{settingType, migrateutil.RawJSON(doc)})
		return len(rows) >= cfg.BatchSize, nil
	}, flush)
	fmt.Printf("settings.bot_settings: scanned_docs=%d\n", seen)
	return err
}

func migrateUserSettings(ctx context.Context, cfg migrateutil.Config, cp *migrateutil.Checkpoint, pool interface {
	Begin(context.Context) (pgx.Tx, error)
}, collection *mongo.Collection) error {
	rows := make([][]any, 0, cfg.BatchSize)
	flush := func() error {
		err := flushRows(ctx, pool, "user_settings", []string{"user_id", "search", "app", "data"}, rows, `
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
	seen, err := migrateutil.StreamByObjectID(ctx, cfg, cp, "user_settings_id", collection, func(doc bson.M) (bool, error) {
		rows = append(rows, []any{
			migrateutil.String(doc["discord_user"]),
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

func migrateCustomEmbeds(ctx context.Context, cfg migrateutil.Config, cp *migrateutil.Checkpoint, pool interface {
	Begin(context.Context) (pgx.Tx, error)
}, collection *mongo.Collection) error {
	rows := make([][]any, 0, cfg.BatchSize)
	flush := func() error {
		err := flushRows(ctx, pool, "custom_embeds", []string{"server_id", "name", "data"}, rows, `
			INSERT INTO custom_embeds (server_id, name, data)
			SELECT server_id, name, data::jsonb FROM _ck_rows
			WHERE server_id <> '' AND name <> ''
			ON CONFLICT (server_id, name) DO UPDATE SET data = EXCLUDED.data
		`)
		if err == nil {
			rows = rows[:0]
		}
		return err
	}
	seen, err := migrateutil.StreamByObjectID(ctx, cfg, cp, "custom_embeds_id", collection, func(doc bson.M) (bool, error) {
		rows = append(rows, []any{migrateutil.String(doc["server"]), migrateutil.String(doc["name"]), migrateutil.RawJSON(doc["data"])})
		return len(rows) >= cfg.BatchSize, nil
	}, flush)
	fmt.Printf("settings.custom_embeds: scanned_docs=%d\n", seen)
	return err
}

func migrateTicketPanels(ctx context.Context, cfg migrateutil.Config, cp *migrateutil.Checkpoint, pool interface {
	Begin(context.Context) (pgx.Tx, error)
}, collection *mongo.Collection) error {
	rows := make([][]any, 0, cfg.BatchSize)
	flush := func() error {
		err := flushRows(ctx, pool, "ticket_panels", []string{"server_id", "name", "components", "data"}, rows, `
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
	seen, err := migrateutil.StreamByObjectID(ctx, cfg, cp, "tickets_panel_id", collection, func(doc bson.M) (bool, error) {
		rows = append(rows, []any{migrateutil.String(doc["server_id"]), migrateutil.String(doc["name"]), migrateutil.RawJSON(doc["components"]), migrateutil.RawJSON(doc)})
		return len(rows) >= cfg.BatchSize, nil
	}, flush)
	fmt.Printf("settings.ticket_panels: scanned_docs=%d\n", seen)
	return err
}

func migrateOpenTickets(ctx context.Context, cfg migrateutil.Config, cp *migrateutil.Checkpoint, pool interface {
	Begin(context.Context) (pgx.Tx, error)
}, collection *mongo.Collection) error {
	rows := make([][]any, 0, cfg.BatchSize)
	flush := func() error {
		err := flushRows(ctx, pool, "open_tickets", []string{"server_id", "channel_id", "panel_name", "status", "user_id", "set_clan", "data"}, rows, `
			INSERT INTO open_tickets (server_id, channel_id, panel_name, status, user_id, set_clan, data)
			SELECT server_id, channel_id, NULLIF(panel_name, ''), COALESCE(NULLIF(status, ''), 'open'), NULLIF(user_id, ''), NULLIF(set_clan, ''), data::jsonb
			FROM _ck_rows
			WHERE server_id <> '' AND channel_id <> ''
			ON CONFLICT (server_id, channel_id) DO UPDATE SET
				panel_name = EXCLUDED.panel_name,
				status = EXCLUDED.status,
				user_id = EXCLUDED.user_id,
				set_clan = EXCLUDED.set_clan,
				data = EXCLUDED.data,
				updated_at = now()
		`)
		if err == nil {
			rows = rows[:0]
		}
		return err
	}
	seen, err := migrateutil.StreamByObjectID(ctx, cfg, cp, "open_tickets_id", collection, func(doc bson.M) (bool, error) {
		rows = append(rows, []any{
			migrateutil.String(doc["server_id"]),
			migrateutil.String(doc["channel"]),
			migrateutil.String(doc["panel_name"]),
			migrateutil.String(doc["status"]),
			migrateutil.String(doc["user"]),
			migrateutil.String(doc["apply_account"]),
			migrateutil.RawJSON(doc),
		})
		return len(rows) >= cfg.BatchSize, nil
	}, flush)
	fmt.Printf("settings.open_tickets: scanned_docs=%d\n", seen)
	return err
}

func migrateReminders(ctx context.Context, cfg migrateutil.Config, cp *migrateutil.Checkpoint, pool interface {
	Begin(context.Context) (pgx.Tx, error)
}, collection *mongo.Collection) error {
	rows := make([][]any, 0, cfg.BatchSize)
	flush := func() error {
		err := flushRows(ctx, pool, "reminders", []string{"id", "server_id", "type", "type_name", "clan_tag", "webhook_token", "minutes_remaining", "channel_id", "trigger_time", "custom_text", "data"}, rows, `
			INSERT INTO reminders (id, server_id, type, type_name, clan_tag, webhook_token, minutes_remaining, channel_id, trigger_time, custom_text, data)
			SELECT id::uuid, server_id, type, type_name, clan_tag, webhook_token, minutes_remaining, NULLIF(channel_id, ''), NULLIF(trigger_time, ''), custom_text, data::jsonb
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
	seen, err := migrateutil.StreamByObjectID(ctx, cfg, cp, "reminders_id", collection, func(doc bson.M) (bool, error) {
		rows = append(rows, []any{
			stableUUID("reminder", migrateutil.String(doc["_id"])),
			migrateutil.String(doc["server"]),
			migrateutil.Int(doc["type"]),
			migrateutil.String(doc["type"]),
			migrateutil.String(doc["clan"]),
			migrateutil.String(doc["webhook_token"]),
			migrateutil.Int(doc["minutes_remaining"]),
			migrateutil.String(doc["channel"]),
			migrateutil.String(doc["time"]),
			migrateutil.String(doc["custom_text"]),
			migrateutil.RawJSON(doc),
		})
		return len(rows) >= cfg.BatchSize, nil
	}, flush)
	fmt.Printf("settings.reminders: scanned_docs=%d\n", seen)
	return err
}

func migrateRosters(ctx context.Context, cfg migrateutil.Config, cp *migrateutil.Checkpoint, pool interface {
	Begin(context.Context) (pgx.Tx, error)
}, collection *mongo.Collection) error {
	rows := make([][]any, 0, cfg.BatchSize)
	flush := func() error {
		err := flushRows(ctx, pool, "rosters", []string{"id", "server_id", "linked_clan_tag", "title", "description", "max_size", "image_url", "custom_id", "clan_tag", "alias", "members", "data"}, rows, `
			INSERT INTO rosters (id, server_id, linked_clan_tag, title, description, max_size, image_url, custom_id, clan_tag, alias, members, data)
			SELECT id::uuid, server_id, linked_clan_tag, title, description, max_size, NULLIF(image_url, ''), NULLIF(custom_id, ''), NULLIF(clan_tag, ''), alias, members::jsonb, data::jsonb
			FROM _ck_rows
			WHERE server_id <> '' AND title <> ''
			ON CONFLICT (id) DO UPDATE SET
				server_id = EXCLUDED.server_id,
				linked_clan_tag = EXCLUDED.linked_clan_tag,
				title = EXCLUDED.title,
				description = EXCLUDED.description,
				max_size = EXCLUDED.max_size,
				image_url = EXCLUDED.image_url,
				custom_id = EXCLUDED.custom_id,
				clan_tag = EXCLUDED.clan_tag,
				alias = EXCLUDED.alias,
				members = EXCLUDED.members,
				data = EXCLUDED.data,
				updated_at = now()
		`)
		if err == nil {
			rows = rows[:0]
		}
		return err
	}
	seen, err := migrateutil.StreamByObjectID(ctx, cfg, cp, "rosters_id", collection, func(doc bson.M) (bool, error) {
		token := migrateutil.String(doc["token"])
		if token == "" {
			token = migrateutil.String(doc["_id"])
		}
		rows = append(rows, []any{
			stableUUID("roster", token),
			migrateutil.String(doc["server_id"]),
			migrateutil.String(doc["clan_tag"]),
			firstSettingString(doc["clan_name"], doc["alias"], doc["token"]),
			migrateutil.String(doc["description"]),
			migrateutil.Int(doc["roster_size"]),
			migrateutil.String(doc["image"]),
			token,
			migrateutil.String(doc["clan_tag"]),
			migrateutil.String(doc["alias"]),
			migrateutil.RawJSON(doc["members"]),
			migrateutil.RawJSON(doc),
		})
		return len(rows) >= cfg.BatchSize, nil
	}, flush)
	fmt.Printf("settings.rosters: scanned_docs=%d\n", seen)
	return err
}

func migrateGiveaways(ctx context.Context, cfg migrateutil.Config, cp *migrateutil.Checkpoint, pool interface {
	Begin(context.Context) (pgx.Tx, error)
}, collection *mongo.Collection) error {
	rows := make([][]any, 0, cfg.BatchSize)
	flush := func() error {
		err := flushRows(ctx, pool, "giveaways", []string{
			"id", "server_id", "prize", "channel_id", "status", "start_time", "end_time", "winners",
			"mentions", "text_above_embed", "text_in_embed", "text_on_end", "image_url",
			"profile_picture_required", "coc_account_required", "roles_mode", "roles", "boosters", "entries", "winners_list", "message_id", "data",
		}, rows, `
			INSERT INTO giveaways (
				id, server_id, prize, channel_id, status, start_time, end_time, winners,
				mentions, text_above_embed, text_in_embed, text_on_end, image_url,
				profile_picture_required, coc_account_required, roles_mode, roles, boosters, entries, winners_list, message_id, data
			)
			SELECT id, server_id, prize, NULLIF(channel_id, ''), status, start_time, end_time, winners,
				mentions, text_above_embed, text_in_embed, text_on_end, NULLIF(image_url, ''),
				profile_picture_required, coc_account_required, roles_mode, roles, boosters::jsonb, entries::jsonb, winners_list::jsonb, NULLIF(message_id, ''), data::jsonb
			FROM _ck_rows
			WHERE id <> '' AND server_id <> ''
			ON CONFLICT (id) DO UPDATE SET
				server_id = EXCLUDED.server_id,
				prize = EXCLUDED.prize,
				status = EXCLUDED.status,
				entries = EXCLUDED.entries,
				winners_list = EXCLUDED.winners_list,
				data = EXCLUDED.data
		`)
		if err == nil {
			rows = rows[:0]
		}
		return err
	}
	seen, err := migrateutil.StreamByObjectID(ctx, cfg, cp, "giveaways_id", collection, func(doc bson.M) (bool, error) {
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
			migrateutil.String(doc["image_url"]),
			migrateutil.Bool(doc["profile_picture_required"]),
			migrateutil.Bool(doc["coc_account_required"]),
			migrateutil.String(doc["roles_mode"]),
			stringSlice(doc["roles"]),
			migrateutil.RawJSON(doc["boosters"]),
			migrateutil.RawJSON(doc["entries"]),
			migrateutil.RawJSON(doc["winners_list"]),
			migrateutil.String(doc["message_id"]),
			migrateutil.RawJSON(doc),
		})
		return len(rows) >= cfg.BatchSize, nil
	}, flush)
	fmt.Printf("settings.giveaways: scanned_docs=%d\n", seen)
	return err
}

func migrateShortLinks(ctx context.Context, cfg migrateutil.Config, cp *migrateutil.Checkpoint, pool interface {
	Begin(context.Context) (pgx.Tx, error)
}, collection *mongo.Collection) error {
	rows := make([][]any, 0, cfg.BatchSize)
	flush := func() error {
		err := flushRows(ctx, pool, "short_links", []string{"id", "url", "data"}, rows, `
			INSERT INTO short_links (id, url, data)
			SELECT id, url, data::jsonb FROM _ck_rows
			WHERE id <> '' AND url <> ''
			ON CONFLICT (id) DO UPDATE SET url = EXCLUDED.url, data = EXCLUDED.data
		`)
		if err == nil {
			rows = rows[:0]
		}
		return err
	}
	seen, err := migrateutil.StreamByObjectID(ctx, cfg, cp, "short_links_id", collection, func(doc bson.M) (bool, error) {
		rows = append(rows, []any{migrateutil.String(doc["_id"]), migrateutil.String(doc["url"]), migrateutil.RawJSON(doc)})
		return len(rows) >= cfg.BatchSize, nil
	}, flush)
	fmt.Printf("settings.short_links: scanned_docs=%d\n", seen)
	return err
}

func flushRows(ctx context.Context, pool interface {
	Begin(context.Context) (pgx.Tx, error)
}, table string, columns []string, rows [][]any, mergeSQL string) error {
	if len(rows) == 0 {
		return nil
	}
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
			"profile_picture_required bool", "coc_account_required bool", "roles_mode text", "roles text[]", "boosters text", "entries text", "winners_list text", "message_id text", "data text",
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

func stringSlice(value any) []string {
	var out []string
	for _, raw := range migrateutil.Slice(value) {
		if item := migrateutil.String(raw); item != "" {
			out = append(out, item)
		}
	}
	return out
}
