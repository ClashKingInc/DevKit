-- +goose Up

DROP TABLE public.hall_counts;

CREATE MATERIALIZED VIEW public.townhall_counts AS
SELECT
    townhall_level AS level,
    count(*)::bigint AS total_count
FROM public.basic_player
GROUP BY townhall_level
WITH DATA;

CREATE UNIQUE INDEX townhall_counts_level_idx
    ON public.townhall_counts (level);

ALTER TABLE public.player_profile_changes
    RENAME TO player_change_history;

ALTER INDEX public.idx_player_profile_changes_player_time
    RENAME TO idx_player_change_history_player_time;

ALTER INDEX public.idx_player_profile_changes_type_time
    RENAME TO idx_player_change_history_type_time;

ALTER INDEX public.player_profile_changes_event_time_idx
    RENAME TO player_change_history_event_time_idx;

SELECT set_chunk_time_interval(
    'player_online_events',
    INTERVAL '3 months'
);

DROP INDEX public.player_online_events_seen_at_idx;

ALTER TABLE public.player_online_events
    DROP COLUMN townhall_level;

ALTER TABLE public.clan_rankings_current
    DROP COLUMN updated_at;

CREATE TEMP TABLE _ck_player_rankings_current_legacy
ON COMMIT DROP
AS
SELECT *
FROM public.player_rankings_current;

DROP TABLE public.player_rankings_current;

CREATE TABLE public.player_rankings_current (
    player_tag text NOT NULL,
    ranking_type text NOT NULL,
    location_id text NOT NULL,
    rank integer,
    points integer,
    CONSTRAINT player_rankings_current_pkey
        PRIMARY KEY (player_tag, ranking_type, location_id),
    CONSTRAINT player_rankings_current_ranking_type_check
        CHECK (ranking_type = ANY (ARRAY['home'::text, 'builder_base'::text])),
    CONSTRAINT player_rankings_current_location_id_check
        CHECK (location_id = 'global' OR location_id ~ '^[0-9]+$'),
    CONSTRAINT player_rankings_current_placement_check
        CHECK (
            (rank IS NULL AND points IS NULL)
            OR (
                rank IS NOT NULL
                AND points IS NOT NULL
                AND rank > 0
                AND points >= 0
            )
        ),
    CONSTRAINT player_rankings_current_global_rank_check
        CHECK (location_id <> 'global' OR rank IS NOT NULL)
);

CREATE UNIQUE INDEX idx_player_rankings_current_numeric_location
    ON public.player_rankings_current (player_tag, ranking_type)
    WHERE location_id <> 'global';

CREATE INDEX idx_player_rankings_current_scope_rank
    ON public.player_rankings_current (ranking_type, location_id, rank)
    WHERE rank IS NOT NULL;

INSERT INTO public.player_rankings_current (
    player_tag,
    ranking_type,
    location_id,
    rank,
    points
)
SELECT
    legacy.player_tag,
    'home',
    'global',
    legacy.global_rank,
    player.trophies
FROM _ck_player_rankings_current_legacy AS legacy
JOIN public.basic_player AS player
  ON player.tag = legacy.player_tag
WHERE legacy.global_rank > 0
  AND player.trophies >= 0;

ALTER TABLE public.short_links
    DROP COLUMN data;

DROP TABLE public.server_blacklisted_roles;

DROP TABLE public.raid_weekends;

ALTER TABLE public.server_logs
    DROP CONSTRAINT server_logs_type_check,
    ADD CONSTRAINT server_logs_type_check CHECK (type = ANY (ARRAY[
        'join_log', 'leave_log', 'donation_log',
        'clan_achievement_log', 'clan_requirements_log', 'clan_description_log',
        'war_log', 'war_panel', 'cwl_lineup_change_log',
        'capital_donations', 'capital_attacks', 'raid_panel', 'capital_weekly_summary',
        'role_change', 'troop_upgrade', 'super_troop_boost', 'th_upgrade',
        'league_change', 'spell_upgrade', 'hero_upgrade',
        'hero_equipment_upgrade', 'name_change',
        'legend_log_attacks', 'legend_log_defenses',
        'ban_alert', 'reddit_feed'
    ])),
    ADD CONSTRAINT server_logs_new_type_scope_check CHECK (
        (type = 'ban_alert' AND clan_tag IS NOT NULL)
        OR (type = 'reddit_feed' AND clan_tag IS NULL)
        OR type <> ALL (ARRAY['ban_alert', 'reddit_feed'])
    );

DROP TABLE public.server_clan_settings;

ALTER TABLE public.server_clans
    DROP COLUMN clan_channel_id,
    DROP COLUMN name;

DROP TABLE public.server_link_parse_channels;

ALTER TABLE public.server_settings
    DROP COLUMN use_api_token,
    DROP COLUMN banlist_channel_id,
    DROP COLUMN strike_log_channel_id,
    DROP COLUMN reddit_feed_channel_id,
    DROP COLUMN greeting;

ALTER TABLE public.servers
    RENAME CONSTRAINT servers_pkey TO servers_legacy_pkey;

ALTER TABLE public.servers
    RENAME TO servers_legacy;

CREATE TABLE public.servers (
    id text NOT NULL,
    name text NOT NULL,
    joined_at timestamp with time zone DEFAULT now() NOT NULL,
    left_at timestamp with time zone,
    embed_color text,
    nickname_rule text,
    non_family_nickname_rule text,
    change_nickname boolean DEFAULT true NOT NULL,
    flair_non_family boolean DEFAULT true NOT NULL,
    auto_eval_nickname boolean DEFAULT false NOT NULL,
    autoeval_log_channel_id text,
    autoeval_enabled boolean DEFAULT false NOT NULL,
    full_whitelist_role_id text,
    autoboard_limit integer DEFAULT 0 NOT NULL,
    tied_stats_only boolean DEFAULT true NOT NULL,
    family_label text DEFAULT ''::text NOT NULL,
    link_parse_clan boolean DEFAULT true NOT NULL,
    link_parse_army boolean DEFAULT true NOT NULL,
    link_parse_player boolean DEFAULT true NOT NULL,
    link_parse_base boolean DEFAULT true NOT NULL,
    link_parse_show boolean DEFAULT true NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT servers_pkey PRIMARY KEY (id)
);

INSERT INTO public.servers (
    id,
    name,
    joined_at,
    left_at,
    embed_color,
    nickname_rule,
    non_family_nickname_rule,
    change_nickname,
    flair_non_family,
    auto_eval_nickname,
    autoeval_log_channel_id,
    autoeval_enabled,
    full_whitelist_role_id,
    autoboard_limit,
    tied_stats_only,
    family_label,
    link_parse_clan,
    link_parse_army,
    link_parse_player,
    link_parse_base,
    link_parse_show,
    updated_at
)
SELECT
    legacy.id,
    legacy.name,
    legacy.joined_at,
    legacy.left_at,
    legacy.embed_color,
    settings.nickname_rule,
    settings.non_family_nickname_rule,
    COALESCE(settings.change_nickname, true),
    COALESCE(settings.flair_non_family, true),
    COALESCE(settings.auto_eval_nickname, false),
    settings.autoeval_log_channel_id,
    COALESCE(settings.autoeval_enabled, false),
    settings.full_whitelist_role_id,
    COALESCE(settings.autoboard_limit, 0),
    COALESCE(settings.tied_stats_only, true),
    COALESCE(settings.family_label, ''),
    COALESCE(settings.link_parse_clan, true),
    COALESCE(settings.link_parse_army, true),
    COALESCE(settings.link_parse_player, true),
    COALESCE(settings.link_parse_base, true),
    COALESCE(settings.link_parse_show, true),
    COALESCE(settings.updated_at, legacy.updated_at)
FROM public.servers_legacy AS legacy
LEFT JOIN public.server_settings AS settings
  ON settings.server_id = legacy.id;

-- +goose StatementBegin
DO $$
DECLARE
    foreign_key record;
    definition text;
BEGIN
    FOR foreign_key IN
        SELECT
            namespace.nspname AS schema_name,
            relation.relname AS table_name,
            constraint_row.conname AS constraint_name,
            pg_get_constraintdef(constraint_row.oid) AS constraint_definition
        FROM pg_constraint AS constraint_row
        JOIN pg_class AS relation
          ON relation.oid = constraint_row.conrelid
        JOIN pg_namespace AS namespace
          ON namespace.oid = relation.relnamespace
        WHERE constraint_row.contype = 'f'
          AND constraint_row.confrelid = 'public.servers_legacy'::regclass
          AND constraint_row.conrelid <> 'public.server_settings'::regclass
        ORDER BY namespace.nspname, relation.relname, constraint_row.conname
    LOOP
        definition := replace(
            foreign_key.constraint_definition,
            'REFERENCES servers_legacy',
            'REFERENCES public.servers'
        );
        definition := replace(
            definition,
            'REFERENCES public.servers_legacy',
            'REFERENCES public.servers'
        );
        EXECUTE format(
            'ALTER TABLE %I.%I DROP CONSTRAINT %I',
            foreign_key.schema_name,
            foreign_key.table_name,
            foreign_key.constraint_name
        );
        EXECUTE format(
            'ALTER TABLE %I.%I ADD CONSTRAINT %I %s',
            foreign_key.schema_name,
            foreign_key.table_name,
            foreign_key.constraint_name,
            definition
        );
    END LOOP;
END
$$;
-- +goose StatementEnd

DROP TABLE public.server_settings;
DROP TABLE public.servers_legacy;

ALTER TABLE public.leaderboard_snapshot_items
    RENAME TO leaderboard_history;

ALTER TABLE public.leaderboard_history
    RENAME CONSTRAINT leaderboard_snapshot_items_pkey
    TO leaderboard_history_pkey;

ALTER TABLE public.leaderboard_history
    RENAME CONSTRAINT leaderboard_snapshot_items_kind_not_null
    TO leaderboard_history_kind_not_null;

ALTER TABLE public.leaderboard_history
    RENAME CONSTRAINT leaderboard_snapshot_items_location_id_not_null
    TO leaderboard_history_location_id_not_null;

ALTER TABLE public.leaderboard_history
    RENAME CONSTRAINT leaderboard_snapshot_items_snapshot_on_not_null
    TO leaderboard_history_date_not_null;

ALTER TABLE public.leaderboard_history
    RENAME CONSTRAINT leaderboard_snapshot_items_tag_not_null
    TO leaderboard_history_tag_not_null;

ALTER TABLE public.leaderboard_history
    RENAME CONSTRAINT leaderboard_snapshot_items_name_not_null
    TO leaderboard_history_name_not_null;

ALTER TABLE public.leaderboard_history
    RENAME CONSTRAINT leaderboard_snapshot_items_rank_not_null
    TO leaderboard_history_rank_not_null;

ALTER TABLE public.leaderboard_history
    RENAME CONSTRAINT leaderboard_snapshot_items_data_not_null
    TO leaderboard_history_data_not_null;

ALTER INDEX public.idx_leaderboard_snapshot_items_location_rank
    RENAME TO idx_leaderboard_history_location_rank;

ALTER INDEX public.idx_leaderboard_snapshot_items_tag_history
    RENAME TO idx_leaderboard_history_tag_history;

TRUNCATE TABLE public.leaderboard_history;

ALTER TABLE public.leaderboard_history
    ADD CONSTRAINT leaderboard_history_kind_check CHECK (
        kind IN (
            'player_home_trophies',
            'player_builder_base_trophies',
            'clan_home_points',
            'clan_builder_base_points',
            'clan_capital_points'
        )
    ),
    ADD CONSTRAINT leaderboard_history_location_id_check CHECK (
        location_id = 'global' OR location_id ~ '^[0-9]+$'
    ),
    ADD CONSTRAINT leaderboard_history_rank_check CHECK (rank > 0),
    ADD CONSTRAINT leaderboard_history_data_check CHECK (
        jsonb_typeof(data) = 'object'
    );

ALTER TABLE public.legend_history_snapshots
    RENAME TO legend_history;

ALTER TABLE public.legend_history
    RENAME CONSTRAINT legend_history_snapshots_pkey
    TO legend_history_pkey;

ALTER TABLE public.legend_history
    RENAME CONSTRAINT legend_history_snapshots_season_not_null
    TO legend_history_season_not_null;

ALTER TABLE public.legend_history
    RENAME CONSTRAINT legend_history_snapshots_player_tag_not_null
    TO legend_history_player_tag_not_null;

ALTER TABLE public.legend_history
    RENAME CONSTRAINT legend_history_snapshots_rank_not_null
    TO legend_history_rank_not_null;

ALTER TABLE public.legend_history
    RENAME CONSTRAINT legend_history_snapshots_trophies_not_null
    TO legend_history_trophies_not_null;

ALTER TABLE public.legend_history
    RENAME CONSTRAINT legend_history_snapshots_data_not_null
    TO legend_history_data_not_null;

ALTER INDEX public.idx_legend_history_snapshots_rank
    RENAME TO idx_legend_history_season_rank;

TRUNCATE TABLE public.legend_history;

ALTER TABLE public.legend_history
    DROP COLUMN created_at;

CREATE INDEX idx_legend_history_player_season
    ON public.legend_history (player_tag, season DESC);

DROP TABLE public.mobile_live_activities;

UPDATE public.mobile_push_devices AS devices
SET enabled = preferences.enabled
FROM public.mobile_notification_preferences AS preferences
WHERE devices.user_id = preferences.user_id
  AND devices.device_id = preferences.device_id
  AND devices.environment = preferences.environment
  AND devices.enabled IS DISTINCT FROM preferences.enabled;

DROP INDEX public.idx_mobile_notification_preferences_delivery;

ALTER TABLE public.mobile_notification_preferences
    ADD COLUMN league_battles_enabled boolean DEFAULT false NOT NULL,
    ADD COLUMN war_attacks_enabled boolean DEFAULT false NOT NULL,
    ADD COLUMN war_state_enabled boolean DEFAULT false NOT NULL,
    ADD COLUMN war_reminders_enabled boolean DEFAULT false NOT NULL,
    ADD COLUMN events_enabled boolean DEFAULT false NOT NULL,
    ADD COLUMN announcements_enabled boolean DEFAULT false NOT NULL,
    ADD COLUMN upgrade_finishes_enabled boolean DEFAULT false NOT NULL,
    ADD COLUMN monthly_support_enabled boolean DEFAULT false NOT NULL,
    ADD COLUMN reminder_timings_minutes integer[] DEFAULT '{}'::integer[] NOT NULL;

UPDATE public.mobile_notification_preferences
SET league_battles_enabled = 'league_battles' = ANY(enabled_types),
    war_attacks_enabled = 'war_attacks' = ANY(enabled_types),
    war_state_enabled = 'war_state' = ANY(enabled_types),
    war_reminders_enabled = 'war_reminders' = ANY(enabled_types),
    events_enabled = 'events' = ANY(enabled_types),
    announcements_enabled = 'announcements' = ANY(enabled_types),
    upgrade_finishes_enabled = 'upgrade_finishes' = ANY(enabled_types),
    monthly_support_enabled = 'monthly_support' = ANY(enabled_types),
    reminder_timings_minutes = COALESCE((
        SELECT array_agg(converted.minutes ORDER BY converted.ordinality)
        FROM (
            SELECT
                CASE
                    WHEN timing.value ~ '^[0-9]+h$'
                        THEN left(timing.value, -1)::integer * 60
                    WHEN timing.value ~ '^[0-9]+m$'
                        THEN left(timing.value, -1)::integer
                END AS minutes,
                timing.ordinality
            FROM unnest(reminder_timings)
                WITH ORDINALITY AS timing(value, ordinality)
            WHERE timing.value ~ '^[0-9]+[hm]$'
            ORDER BY timing.ordinality
            LIMIT 3
        ) AS converted
        WHERE converted.minutes BETWEEN 1 AND 2820
    ), '{}'::integer[]);

CREATE TABLE public.mobile_notification_accounts (
    user_id text NOT NULL,
    player_tag text NOT NULL,
    source text NOT NULL,
    CONSTRAINT mobile_notification_accounts_pkey
        PRIMARY KEY (user_id, player_tag),
    CONSTRAINT mobile_notification_accounts_source_check
        CHECK (source = ANY (ARRAY['verified'::text, 'bookmarked'::text]))
);

CREATE INDEX idx_mobile_notification_accounts_player
    ON public.mobile_notification_accounts (player_tag, user_id);

INSERT INTO public.mobile_notification_accounts (user_id, player_tag, source)
SELECT DISTINCT preferences.user_id, links.tag, 'verified'
FROM public.mobile_notification_preferences AS preferences
JOIN public.player_links AS links
  ON links.user_id = preferences.user_id
 AND links.is_verified = true
WHERE preferences.account_scope = 'all'
   OR links.tag = ANY(preferences.selected_accounts)
ON CONFLICT (user_id, player_tag) DO UPDATE
SET source = 'verified';

INSERT INTO public.mobile_notification_accounts (user_id, player_tag, source)
SELECT DISTINCT preferences.user_id, bookmarks.tag, 'bookmarked'
FROM public.mobile_notification_preferences AS preferences
JOIN public.user_bookmarks AS bookmarks
  ON bookmarks.user_id = preferences.user_id
 AND bookmarks.entity_type = 'player'
 AND bookmarks.tag = ANY(preferences.selected_accounts)
WHERE preferences.account_scope = 'selected'
ON CONFLICT (user_id, player_tag) DO NOTHING;

INSERT INTO public.mobile_notification_accounts (user_id, player_tag, source)
SELECT DISTINCT subscriptions.user_id, links.tag, 'verified'
FROM public.mobile_notification_subscriptions AS subscriptions
JOIN public.player_links AS links
  ON links.user_id = subscriptions.user_id
 AND links.tag = subscriptions.player_tag
 AND links.is_verified = true
WHERE subscriptions.enabled = true
  AND subscriptions.player_tag <> ''
ON CONFLICT (user_id, player_tag) DO UPDATE
SET source = 'verified';

INSERT INTO public.mobile_notification_accounts (user_id, player_tag, source)
SELECT DISTINCT subscriptions.user_id, bookmarks.tag, 'bookmarked'
FROM public.mobile_notification_subscriptions AS subscriptions
JOIN public.user_bookmarks AS bookmarks
  ON bookmarks.user_id = subscriptions.user_id
 AND bookmarks.entity_type = 'player'
 AND bookmarks.tag = subscriptions.player_tag
WHERE subscriptions.enabled = true
  AND subscriptions.player_tag <> ''
ON CONFLICT (user_id, player_tag) DO NOTHING;

ALTER TABLE public.mobile_notification_preferences
    DROP COLUMN enabled,
    DROP COLUMN locale,
    DROP COLUMN timezone,
    DROP COLUMN enabled_types,
    DROP COLUMN war_attack_modes,
    DROP COLUMN event_types,
    DROP COLUMN reminder_timings,
    DROP COLUMN account_scope,
    DROP COLUMN selected_accounts,
    DROP COLUMN selected_town_halls,
    DROP COLUMN selected_clan_tags,
    DROP COLUMN created_at,
    DROP COLUMN updated_at;

ALTER TABLE public.mobile_notification_preferences
    RENAME COLUMN reminder_timings_minutes TO reminder_timings;

ALTER TABLE public.mobile_notification_preferences
    RENAME CONSTRAINT mobile_notification_preferenc_reminder_timings_minutes_not_null
    TO mobile_notification_preferences_reminder_timings_not_null;

ALTER TABLE public.mobile_notification_preferences
    ADD CONSTRAINT mobile_notification_preferences_reminder_timings_check
    CHECK (
        cardinality(reminder_timings) <= 3
        AND array_position(reminder_timings, NULL) IS NULL
        AND 0 < ALL(reminder_timings)
        AND 2820 >= ALL(reminder_timings)
    );

CREATE INDEX idx_mobile_notification_preferences_announcements
    ON public.mobile_notification_preferences (environment, user_id, device_id)
    WHERE announcements_enabled = true;

DROP TABLE public.mobile_notification_subscriptions;

DROP TABLE public.mobile_war_subscriptions;

DROP INDEX public.idx_mobile_push_devices_enabled_provider;

DROP INDEX public.idx_mobile_push_devices_user_device;

ALTER TABLE public.mobile_push_devices
    DROP CONSTRAINT mobile_push_devices_pkey,
    DROP CONSTRAINT mobile_push_devices_user_id_device_id_provider_environment_key,
    DROP COLUMN id,
    DROP COLUMN timezone,
    DROP COLUMN created_at,
    DROP COLUMN updated_at,
    DROP COLUMN disabled_at,
    DROP COLUMN device_model,
    DROP COLUMN os_version,
    DROP COLUMN build_number,
    ADD CONSTRAINT mobile_push_devices_pkey
        PRIMARY KEY (user_id, device_id, provider, environment);

CREATE INDEX idx_mobile_push_devices_delivery
    ON public.mobile_push_devices (provider, environment, authorization_status)
    WHERE enabled = true;

DROP TABLE public.one_time_login_tokens;

DROP TABLE public.open_tickets;

DROP MATERIALIZED VIEW public.api_global_counts;

CREATE MATERIALIZED VIEW public.api_global_counts AS
SELECT
    1::smallint AS id,
    (SELECT count(DISTINCT player_tag) FROM public.war_members WHERE war_end_time >= now())::bigint AS players_in_war,
    (SELECT count(DISTINCT clan_tag) FROM public.wars WHERE end_time >= now())::bigint AS clans_in_war,
    (SELECT count(*) FROM public.join_leave_history)::bigint AS total_join_leaves,
    (SELECT count(*) FROM public.legend_rankings_current)::bigint AS players_in_legends,
    (SELECT count(*) FROM public.basic_player)::bigint AS player_count,
    (SELECT count(*) FROM public.basic_clan)::bigint AS clan_count,
    (SELECT count(*) FROM public.wars)::bigint AS wars_stored,
    now() AS refreshed_at;

CREATE UNIQUE INDEX api_global_counts_id_idx
    ON public.api_global_counts (id);

DROP TABLE public.player_current_stats;

DROP TABLE public.player_equipment;

DROP TABLE public.player_heroes;

DROP TABLE public.player_spells;

DROP TABLE public.player_troops;

DROP TABLE public.ranking_snapshots;

DROP TABLE public.player_history_events;

-- +goose Down

ALTER TABLE public.servers
    RENAME CONSTRAINT servers_pkey TO servers_v3_pkey;

ALTER TABLE public.servers
    RENAME TO servers_v3;

CREATE TABLE public.servers (
    id text NOT NULL,
    name text NOT NULL,
    joined_at timestamp with time zone DEFAULT now() NOT NULL,
    left_at timestamp with time zone,
    embed_color text,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT servers_pkey PRIMARY KEY (id)
);

INSERT INTO public.servers (
    id,
    name,
    joined_at,
    left_at,
    embed_color,
    updated_at
)
SELECT
    id,
    name,
    joined_at,
    left_at,
    embed_color,
    updated_at
FROM public.servers_v3;

CREATE TABLE public.server_settings (
    server_id text NOT NULL,
    nickname_rule text,
    non_family_nickname_rule text,
    change_nickname boolean DEFAULT true NOT NULL,
    flair_non_family boolean DEFAULT true NOT NULL,
    auto_eval_nickname boolean DEFAULT false NOT NULL,
    autoeval_log_channel_id text,
    autoeval_enabled boolean DEFAULT false NOT NULL,
    full_whitelist_role_id text,
    autoboard_limit integer DEFAULT 0 NOT NULL,
    use_api_token boolean DEFAULT true NOT NULL,
    tied_stats_only boolean DEFAULT true NOT NULL,
    banlist_channel_id text,
    strike_log_channel_id text,
    reddit_feed_channel_id text,
    family_label text DEFAULT ''::text NOT NULL,
    greeting text,
    link_parse_clan boolean DEFAULT true NOT NULL,
    link_parse_army boolean DEFAULT true NOT NULL,
    link_parse_player boolean DEFAULT true NOT NULL,
    link_parse_base boolean DEFAULT true NOT NULL,
    link_parse_show boolean DEFAULT true NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT server_settings_pkey PRIMARY KEY (server_id),
    CONSTRAINT server_settings_server_id_fkey
        FOREIGN KEY (server_id)
        REFERENCES public.servers(id)
        ON DELETE CASCADE
);

INSERT INTO public.server_settings (
    server_id,
    nickname_rule,
    non_family_nickname_rule,
    change_nickname,
    flair_non_family,
    auto_eval_nickname,
    autoeval_log_channel_id,
    autoeval_enabled,
    full_whitelist_role_id,
    autoboard_limit,
    tied_stats_only,
    family_label,
    link_parse_clan,
    link_parse_army,
    link_parse_player,
    link_parse_base,
    link_parse_show,
    updated_at
)
SELECT
    id,
    nickname_rule,
    non_family_nickname_rule,
    change_nickname,
    flair_non_family,
    auto_eval_nickname,
    autoeval_log_channel_id,
    autoeval_enabled,
    full_whitelist_role_id,
    autoboard_limit,
    tied_stats_only,
    family_label,
    link_parse_clan,
    link_parse_army,
    link_parse_player,
    link_parse_base,
    link_parse_show,
    updated_at
FROM public.servers_v3;

-- +goose StatementBegin
DO $$
DECLARE
    foreign_key record;
    definition text;
BEGIN
    FOR foreign_key IN
        SELECT
            namespace.nspname AS schema_name,
            relation.relname AS table_name,
            constraint_row.conname AS constraint_name,
            pg_get_constraintdef(constraint_row.oid) AS constraint_definition
        FROM pg_constraint AS constraint_row
        JOIN pg_class AS relation
          ON relation.oid = constraint_row.conrelid
        JOIN pg_namespace AS namespace
          ON namespace.oid = relation.relnamespace
        WHERE constraint_row.contype = 'f'
          AND constraint_row.confrelid = 'public.servers_v3'::regclass
        ORDER BY namespace.nspname, relation.relname, constraint_row.conname
    LOOP
        definition := replace(
            foreign_key.constraint_definition,
            'REFERENCES servers_v3',
            'REFERENCES public.servers'
        );
        definition := replace(
            definition,
            'REFERENCES public.servers_v3',
            'REFERENCES public.servers'
        );
        EXECUTE format(
            'ALTER TABLE %I.%I DROP CONSTRAINT %I',
            foreign_key.schema_name,
            foreign_key.table_name,
            foreign_key.constraint_name
        );
        EXECUTE format(
            'ALTER TABLE %I.%I ADD CONSTRAINT %I %s',
            foreign_key.schema_name,
            foreign_key.table_name,
            foreign_key.constraint_name,
            definition
        );
    END LOOP;
END
$$;
-- +goose StatementEnd

DROP TABLE public.servers_v3;

CREATE TABLE public.server_link_parse_channels (
    server_id text NOT NULL
        REFERENCES public.servers(id) ON DELETE CASCADE,
    channel_id text NOT NULL,
    CONSTRAINT server_link_parse_channels_pkey
        PRIMARY KEY (server_id, channel_id)
);

ALTER TABLE public.server_clans
    ADD COLUMN clan_channel_id text,
    ADD COLUMN name text DEFAULT ''::text NOT NULL;

CREATE TABLE public.server_clan_settings (
    server_id text NOT NULL,
    clan_tag text NOT NULL,
    greeting text DEFAULT ''::text NOT NULL,
    auto_greet_option text DEFAULT 'Never'::text NOT NULL,
    ban_alert_channel_id text,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT server_clan_settings_pkey
        PRIMARY KEY (server_id, clan_tag),
    CONSTRAINT server_clan_settings_clan_tag_server_id_fkey
        FOREIGN KEY (clan_tag, server_id)
        REFERENCES public.server_clans(tag, server_id)
        ON DELETE CASCADE
);

DELETE FROM public.server_logs
WHERE type IN ('ban_alert', 'reddit_feed');

ALTER TABLE public.server_logs
    DROP CONSTRAINT server_logs_type_check,
    DROP CONSTRAINT server_logs_new_type_scope_check,
    ADD CONSTRAINT server_logs_type_check CHECK (type = ANY (ARRAY[
        'join_log', 'leave_log', 'donation_log',
        'clan_achievement_log', 'clan_requirements_log', 'clan_description_log',
        'war_log', 'war_panel', 'cwl_lineup_change_log',
        'capital_donations', 'capital_attacks', 'raid_panel', 'capital_weekly_summary',
        'role_change', 'troop_upgrade', 'super_troop_boost', 'th_upgrade',
        'league_change', 'spell_upgrade', 'hero_upgrade',
        'hero_equipment_upgrade', 'name_change',
        'legend_log_attacks', 'legend_log_defenses'
    ]));

CREATE TABLE public.raid_weekends (
    clan_tag text NOT NULL,
    start_time timestamp with time zone NOT NULL,
    end_time timestamp with time zone NOT NULL,
    state text DEFAULT ''::text NOT NULL,
    total_attacks integer DEFAULT 0 NOT NULL,
    capital_total_loot integer DEFAULT 0 NOT NULL,
    raids_completed integer DEFAULT 0 NOT NULL,
    offensive_reward integer DEFAULT 0 NOT NULL,
    defensive_reward integer DEFAULT 0 NOT NULL,
    members jsonb DEFAULT '[]'::jsonb NOT NULL,
    attack_log jsonb DEFAULT '[]'::jsonb NOT NULL,
    defense_log jsonb DEFAULT '[]'::jsonb NOT NULL,
    data jsonb DEFAULT '{}'::jsonb NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT raid_weekends_pkey PRIMARY KEY (clan_tag, start_time)
);

CREATE INDEX idx_raid_weekends_end_time
    ON public.raid_weekends (end_time DESC);

CREATE INDEX idx_raid_weekends_members_gin
    ON public.raid_weekends USING gin (members);

CREATE TABLE public.server_blacklisted_roles (
    server_id text NOT NULL,
    role_id text NOT NULL,
    CONSTRAINT server_blacklisted_roles_pkey
        PRIMARY KEY (server_id, role_id),
    CONSTRAINT server_blacklisted_roles_server_id_fkey
        FOREIGN KEY (server_id)
        REFERENCES public.servers(id)
        ON DELETE CASCADE
);

ALTER TABLE public.short_links
    ADD COLUMN data jsonb DEFAULT '{}'::jsonb NOT NULL;

CREATE TEMP TABLE _ck_player_rankings_current_normalized
ON COMMIT DROP
AS
SELECT *
FROM public.player_rankings_current;

DROP TABLE public.player_rankings_current;

CREATE TABLE public.player_rankings_current (
    player_tag text NOT NULL,
    country_code text,
    country_name text,
    rank integer,
    global_rank integer,
    local_rank integer,
    data jsonb DEFAULT '{}'::jsonb NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT player_rankings_current_pkey PRIMARY KEY (player_tag)
);

CREATE INDEX idx_player_rankings_current_country_rank
    ON public.player_rankings_current (country_code, rank);

INSERT INTO public.player_rankings_current (
    player_tag,
    country_code,
    country_name,
    rank,
    global_rank,
    local_rank,
    data
)
SELECT
    players.player_tag,
    NULL,
    NULL,
    COALESCE(local_rank.rank, global_rank.rank),
    global_rank.rank,
    local_rank.rank,
    '{}'::jsonb
FROM (
    SELECT DISTINCT player_tag
    FROM _ck_player_rankings_current_normalized
    WHERE ranking_type = 'home'
) AS players
LEFT JOIN _ck_player_rankings_current_normalized AS global_rank
  ON global_rank.player_tag = players.player_tag
 AND global_rank.ranking_type = 'home'
 AND global_rank.location_id = 'global'
LEFT JOIN _ck_player_rankings_current_normalized AS local_rank
  ON local_rank.player_tag = players.player_tag
 AND local_rank.ranking_type = 'home'
 AND local_rank.location_id <> 'global';

ALTER TABLE public.clan_rankings_current
    ADD COLUMN updated_at timestamp with time zone DEFAULT now() NOT NULL;

ALTER TABLE public.player_online_events
    ADD COLUMN townhall_level smallint DEFAULT 0 NOT NULL;

ALTER TABLE public.player_online_events
    ALTER COLUMN townhall_level DROP DEFAULT;

CREATE INDEX player_online_events_seen_at_idx
    ON public.player_online_events (seen_at DESC);

SELECT set_chunk_time_interval(
    'player_online_events',
    INTERVAL '7 days'
);

ALTER INDEX public.player_change_history_event_time_idx
    RENAME TO player_profile_changes_event_time_idx;

ALTER INDEX public.idx_player_change_history_type_time
    RENAME TO idx_player_profile_changes_type_time;

ALTER INDEX public.idx_player_change_history_player_time
    RENAME TO idx_player_profile_changes_player_time;

ALTER TABLE public.player_change_history
    RENAME TO player_profile_changes;

CREATE TABLE public.player_history_events (
    event_time timestamp with time zone NOT NULL,
    player_tag text NOT NULL,
    clan_tag text DEFAULT ''::text NOT NULL,
    season text DEFAULT ''::text NOT NULL,
    event_type text NOT NULL,
    value integer,
    data jsonb DEFAULT '{}'::jsonb NOT NULL
);

SELECT create_hypertable(
    'player_history_events',
    'event_time',
    chunk_time_interval => INTERVAL '30 days',
    create_default_indexes => FALSE,
    if_not_exists => TRUE
);

CREATE INDEX idx_player_history_events_clan_season
    ON public.player_history_events
    (clan_tag, season, event_type, event_time DESC);

CREATE INDEX idx_player_history_events_player_time
    ON public.player_history_events (player_tag, event_time DESC);

CREATE INDEX player_history_events_event_time_idx
    ON public.player_history_events (event_time DESC);

CREATE TABLE public.ranking_snapshots (
    ranking_type text NOT NULL,
    location text NOT NULL,
    snapshot_date text NOT NULL,
    data jsonb DEFAULT '{}'::jsonb NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT ranking_snapshots_pkey
        PRIMARY KEY (ranking_type, location, snapshot_date)
);

CREATE INDEX idx_ranking_snapshots_type_date
    ON public.ranking_snapshots (ranking_type, snapshot_date);

CREATE TABLE public.player_troops (
    player_tag text NOT NULL,
    name text NOT NULL,
    level integer NOT NULL,
    max_level integer NOT NULL,
    village text DEFAULT ''::text NOT NULL,
    super_troop_is_active boolean DEFAULT false NOT NULL,
    CONSTRAINT player_troops_pkey PRIMARY KEY (player_tag, name, village),
    CONSTRAINT player_troops_player_tag_fkey
        FOREIGN KEY (player_tag)
        REFERENCES public.basic_player(tag)
        ON DELETE CASCADE
);

CREATE TABLE public.player_spells (
    player_tag text NOT NULL,
    name text NOT NULL,
    level integer NOT NULL,
    max_level integer NOT NULL,
    village text DEFAULT ''::text NOT NULL,
    CONSTRAINT player_spells_pkey PRIMARY KEY (player_tag, name, village),
    CONSTRAINT player_spells_player_tag_fkey
        FOREIGN KEY (player_tag)
        REFERENCES public.basic_player(tag)
        ON DELETE CASCADE
);

CREATE TABLE public.player_heroes (
    player_tag text NOT NULL,
    name text NOT NULL,
    level integer NOT NULL,
    max_level integer NOT NULL,
    village text DEFAULT ''::text NOT NULL,
    CONSTRAINT player_heroes_pkey PRIMARY KEY (player_tag, name, village),
    CONSTRAINT player_heroes_player_tag_fkey
        FOREIGN KEY (player_tag)
        REFERENCES public.basic_player(tag)
        ON DELETE CASCADE
);

CREATE TABLE public.player_equipment (
    player_tag text NOT NULL,
    name text NOT NULL,
    level integer NOT NULL,
    max_level integer NOT NULL,
    village text DEFAULT ''::text NOT NULL,
    rarity text DEFAULT ''::text NOT NULL,
    CONSTRAINT player_equipment_pkey PRIMARY KEY (player_tag, name, village),
    CONSTRAINT player_equipment_player_tag_fkey
        FOREIGN KEY (player_tag)
        REFERENCES public.basic_player(tag)
        ON DELETE CASCADE
);

CREATE TABLE public.player_current_stats (
    player_tag text NOT NULL,
    clan_tag text,
    name text DEFAULT ''::text NOT NULL,
    townhall_level integer,
    last_online_at timestamp with time zone,
    legends jsonb DEFAULT '{}'::jsonb NOT NULL,
    donations jsonb DEFAULT '{}'::jsonb NOT NULL,
    activity jsonb DEFAULT '{}'::jsonb NOT NULL,
    data jsonb DEFAULT '{}'::jsonb NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT player_current_stats_pkey PRIMARY KEY (player_tag)
);

CREATE INDEX idx_player_current_stats_clan
    ON public.player_current_stats (clan_tag);

CREATE INDEX idx_player_current_stats_legends_gin
    ON public.player_current_stats USING gin (legends);

DROP MATERIALIZED VIEW public.api_global_counts;

CREATE MATERIALIZED VIEW public.api_global_counts AS
SELECT
    1::smallint AS id,
    (SELECT count(DISTINCT player_tag) FROM public.war_members WHERE war_end_time >= now())::bigint AS players_in_war,
    (SELECT count(DISTINCT clan_tag) FROM public.wars WHERE end_time >= now())::bigint AS clans_in_war,
    (SELECT count(*) FROM public.join_leave_history)::bigint AS total_join_leaves,
    (SELECT count(*) FROM public.legend_rankings_current)::bigint AS players_in_legends,
    (SELECT count(*) FROM public.player_current_stats)::bigint AS player_count,
    (SELECT count(*) FROM public.basic_clan)::bigint AS clan_count,
    (SELECT count(*) FROM public.wars)::bigint AS wars_stored,
    now() AS refreshed_at;

CREATE UNIQUE INDEX api_global_counts_id_idx
    ON public.api_global_counts (id);

CREATE TABLE public.open_tickets (
    server_id text NOT NULL,
    channel_id text NOT NULL,
    panel_name text,
    status text DEFAULT 'open'::text NOT NULL,
    user_id text,
    set_clan text,
    data jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT open_tickets_pkey PRIMARY KEY (server_id, channel_id)
);

CREATE INDEX idx_open_tickets_server_status
    ON public.open_tickets (server_id, status);

CREATE TABLE public.one_time_login_tokens (
    id uuid DEFAULT uuidv7() NOT NULL,
    user_id text NOT NULL,
    token_hash text NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    used_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT one_time_login_tokens_pkey PRIMARY KEY (id),
    CONSTRAINT one_time_login_tokens_token_hash_key UNIQUE (token_hash)
);

CREATE INDEX idx_one_time_login_tokens_expires_at
    ON public.one_time_login_tokens (expires_at);

CREATE INDEX idx_one_time_login_tokens_user_id
    ON public.one_time_login_tokens (user_id);

CREATE TABLE public.mobile_push_devices_restored (
    id uuid DEFAULT uuidv7()
        CONSTRAINT mobile_push_devices_id_not_null NOT NULL,
    user_id text
        CONSTRAINT mobile_push_devices_user_id_not_null NOT NULL,
    device_id text
        CONSTRAINT mobile_push_devices_device_id_not_null NOT NULL,
    platform text
        CONSTRAINT mobile_push_devices_platform_not_null NOT NULL,
    provider text
        CONSTRAINT mobile_push_devices_provider_not_null NOT NULL,
    environment text DEFAULT 'production'::text
        CONSTRAINT mobile_push_devices_environment_not_null NOT NULL,
    token_ciphertext text
        CONSTRAINT mobile_push_devices_token_ciphertext_not_null NOT NULL,
    token_hash text
        CONSTRAINT mobile_push_devices_token_hash_not_null NOT NULL,
    app_version text DEFAULT ''::text
        CONSTRAINT mobile_push_devices_app_version_not_null NOT NULL,
    build_number text DEFAULT ''::text
        CONSTRAINT mobile_push_devices_build_number_not_null NOT NULL,
    os_version text DEFAULT ''::text
        CONSTRAINT mobile_push_devices_os_version_not_null NOT NULL,
    device_model text DEFAULT ''::text
        CONSTRAINT mobile_push_devices_device_model_not_null NOT NULL,
    enabled boolean DEFAULT true
        CONSTRAINT mobile_push_devices_enabled_not_null NOT NULL,
    last_seen_at timestamp with time zone DEFAULT now()
        CONSTRAINT mobile_push_devices_last_seen_at_not_null NOT NULL,
    disabled_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now()
        CONSTRAINT mobile_push_devices_created_at_not_null NOT NULL,
    updated_at timestamp with time zone DEFAULT now()
        CONSTRAINT mobile_push_devices_updated_at_not_null NOT NULL,
    authorization_status text DEFAULT 'not_determined'::text
        CONSTRAINT mobile_push_devices_authorization_status_not_null NOT NULL,
    locale text DEFAULT ''::text
        CONSTRAINT mobile_push_devices_locale_not_null NOT NULL,
    timezone text DEFAULT ''::text
        CONSTRAINT mobile_push_devices_timezone_not_null NOT NULL,
    CONSTRAINT mobile_push_devices_restored_environment_check CHECK (
        environment = ANY (ARRAY['sandbox'::text, 'production'::text])
    ),
    CONSTRAINT mobile_push_devices_restored_platform_check CHECK (
        platform = ANY (ARRAY['ios'::text, 'android'::text])
    ),
    CONSTRAINT mobile_push_devices_restored_provider_check CHECK (
        provider = ANY (ARRAY['apns'::text, 'fcm'::text])
    ),
    CONSTRAINT mobile_push_devices_restored_authorization_status_check CHECK (
        authorization_status = ANY (ARRAY[
            'authorized'::text,
            'provisional'::text,
            'denied'::text,
            'not_determined'::text
        ])
    ),
    CONSTRAINT mobile_push_devices_restored_pkey PRIMARY KEY (id),
    CONSTRAINT mobile_push_devices_restored_token_hash_key UNIQUE (token_hash),
    CONSTRAINT mobile_push_devices_restored_natural_key
        UNIQUE (user_id, device_id, provider, environment)
);

INSERT INTO public.mobile_push_devices_restored (
    user_id,
    device_id,
    platform,
    provider,
    environment,
    token_ciphertext,
    token_hash,
    app_version,
    enabled,
    last_seen_at,
    authorization_status,
    locale
)
SELECT
    user_id,
    device_id,
    platform,
    provider,
    environment,
    token_ciphertext,
    token_hash,
    app_version,
    enabled,
    last_seen_at,
    authorization_status,
    locale
FROM public.mobile_push_devices;

CREATE INDEX idx_mobile_push_devices_restored_enabled_provider
    ON public.mobile_push_devices_restored (provider, environment, enabled)
    WHERE enabled = true;

CREATE INDEX idx_mobile_push_devices_restored_user_device
    ON public.mobile_push_devices_restored (user_id, device_id);

DROP TABLE public.mobile_push_devices;

ALTER TABLE public.mobile_push_devices_restored
    RENAME TO mobile_push_devices;

ALTER TABLE public.mobile_push_devices
    RENAME CONSTRAINT mobile_push_devices_restored_environment_check
    TO mobile_push_devices_environment_check;

ALTER TABLE public.mobile_push_devices
    RENAME CONSTRAINT mobile_push_devices_restored_platform_check
    TO mobile_push_devices_platform_check;

ALTER TABLE public.mobile_push_devices
    RENAME CONSTRAINT mobile_push_devices_restored_provider_check
    TO mobile_push_devices_provider_check;

ALTER TABLE public.mobile_push_devices
    RENAME CONSTRAINT mobile_push_devices_restored_authorization_status_check
    TO mobile_push_devices_authorization_status_check;

ALTER TABLE public.mobile_push_devices
    RENAME CONSTRAINT mobile_push_devices_restored_pkey
    TO mobile_push_devices_pkey;

ALTER TABLE public.mobile_push_devices
    RENAME CONSTRAINT mobile_push_devices_restored_token_hash_key
    TO mobile_push_devices_token_hash_key;

ALTER TABLE public.mobile_push_devices
    RENAME CONSTRAINT mobile_push_devices_restored_natural_key
    TO mobile_push_devices_user_id_device_id_provider_environment_key;

ALTER INDEX public.idx_mobile_push_devices_restored_enabled_provider
    RENAME TO idx_mobile_push_devices_enabled_provider;

ALTER INDEX public.idx_mobile_push_devices_restored_user_device
    RENAME TO idx_mobile_push_devices_user_device;

CREATE TABLE public.mobile_notification_preferences_restored (
    user_id text
        CONSTRAINT mobile_notification_preferences_user_id_not_null NOT NULL,
    device_id text
        CONSTRAINT mobile_notification_preferences_device_id_not_null NOT NULL,
    environment text DEFAULT 'production'::text
        CONSTRAINT mobile_notification_preferences_environment_not_null NOT NULL,
    enabled boolean DEFAULT true
        CONSTRAINT mobile_notification_preferences_enabled_not_null NOT NULL,
    locale text DEFAULT ''::text
        CONSTRAINT mobile_notification_preferences_locale_not_null NOT NULL,
    timezone text DEFAULT ''::text
        CONSTRAINT mobile_notification_preferences_timezone_not_null NOT NULL,
    enabled_types text[] DEFAULT '{}'::text[]
        CONSTRAINT mobile_notification_preferences_enabled_types_not_null NOT NULL,
    war_attack_modes text[] DEFAULT '{}'::text[]
        CONSTRAINT mobile_notification_preferences_war_attack_modes_not_null NOT NULL,
    event_types text[] DEFAULT '{}'::text[]
        CONSTRAINT mobile_notification_preferences_event_types_not_null NOT NULL,
    reminder_timings text[] DEFAULT '{}'::text[]
        CONSTRAINT mobile_notification_preferences_reminder_timings_not_null NOT NULL,
    account_scope text DEFAULT 'all'::text
        CONSTRAINT mobile_notification_preferences_account_scope_not_null NOT NULL,
    selected_accounts text[] DEFAULT '{}'::text[]
        CONSTRAINT mobile_notification_preferences_selected_accounts_not_null NOT NULL,
    selected_town_halls integer[] DEFAULT '{}'::integer[]
        CONSTRAINT mobile_notification_preferences_selected_town_halls_not_null NOT NULL,
    selected_clan_tags text[] DEFAULT '{}'::text[]
        CONSTRAINT mobile_notification_preferences_selected_clan_tags_not_null NOT NULL,
    created_at timestamp with time zone DEFAULT now()
        CONSTRAINT mobile_notification_preferences_created_at_not_null NOT NULL,
    updated_at timestamp with time zone DEFAULT now()
        CONSTRAINT mobile_notification_preferences_updated_at_not_null NOT NULL,
    CONSTRAINT mobile_notification_preferences_restored_pkey
        PRIMARY KEY (user_id, device_id, environment),
    CONSTRAINT mobile_notification_preferences_restored_environment_check
        CHECK (environment = ANY (ARRAY['sandbox'::text, 'production'::text])),
    CONSTRAINT mobile_notification_preferences_restored_account_scope_check
        CHECK (account_scope = ANY (ARRAY['all'::text, 'selected'::text]))
);

INSERT INTO public.mobile_notification_preferences_restored (
    user_id,
    device_id,
    environment,
    enabled,
    locale,
    timezone,
    enabled_types,
    war_attack_modes,
    event_types,
    reminder_timings,
    account_scope,
    selected_accounts,
    selected_town_halls,
    selected_clan_tags,
    created_at,
    updated_at
)
SELECT
    preferences.user_id,
    preferences.device_id,
    preferences.environment,
    EXISTS (
        SELECT 1
        FROM public.mobile_push_devices AS devices
        WHERE devices.user_id = preferences.user_id
          AND devices.device_id = preferences.device_id
          AND devices.environment = preferences.environment
          AND devices.enabled = true
    ),
    '',
    '',
    array_remove(ARRAY[
        CASE WHEN preferences.league_battles_enabled THEN 'league_battles' END,
        CASE WHEN preferences.war_attacks_enabled THEN 'war_attacks' END,
        CASE WHEN preferences.war_state_enabled THEN 'war_state' END,
        CASE WHEN preferences.war_reminders_enabled THEN 'war_reminders' END,
        CASE WHEN preferences.events_enabled THEN 'events' END,
        CASE WHEN preferences.announcements_enabled THEN 'announcements' END,
        CASE WHEN preferences.upgrade_finishes_enabled THEN 'upgrade_finishes' END,
        CASE WHEN preferences.monthly_support_enabled THEN 'monthly_support' END
    ], NULL),
    '{}'::text[],
    '{}'::text[],
    ARRAY(
        SELECT CASE
            WHEN minutes % 60 = 0 THEN (minutes / 60)::text || 'h'
            ELSE minutes::text || 'm'
        END
        FROM unnest(preferences.reminder_timings) AS minutes
    ),
    CASE
        WHEN EXISTS (
            SELECT 1
            FROM public.mobile_notification_accounts AS accounts
            WHERE accounts.user_id = preferences.user_id
        ) THEN 'selected'
        ELSE 'all'
    END,
    ARRAY(
        SELECT accounts.player_tag
        FROM public.mobile_notification_accounts AS accounts
        WHERE accounts.user_id = preferences.user_id
        ORDER BY accounts.player_tag
    ),
    '{}'::integer[],
    '{}'::text[],
    now(),
    now()
FROM public.mobile_notification_preferences AS preferences;

CREATE INDEX idx_mobile_notification_preferences_restored_delivery
    ON public.mobile_notification_preferences_restored (environment, enabled)
    WHERE enabled = true;

DROP TABLE public.mobile_notification_preferences;

ALTER TABLE public.mobile_notification_preferences_restored
    RENAME TO mobile_notification_preferences;

ALTER TABLE public.mobile_notification_preferences
    RENAME CONSTRAINT mobile_notification_preferences_restored_pkey
    TO mobile_notification_preferences_pkey;

ALTER TABLE public.mobile_notification_preferences
    RENAME CONSTRAINT mobile_notification_preferences_restored_environment_check
    TO mobile_notification_preferences_environment_check;

ALTER TABLE public.mobile_notification_preferences
    RENAME CONSTRAINT mobile_notification_preferences_restored_account_scope_check
    TO mobile_notification_preferences_account_scope_check;

ALTER INDEX public.idx_mobile_notification_preferences_restored_delivery
    RENAME TO idx_mobile_notification_preferences_delivery;

CREATE TABLE public.mobile_notification_subscriptions (
    id uuid DEFAULT uuidv7() NOT NULL,
    user_id text NOT NULL,
    device_id text NOT NULL,
    environment text DEFAULT 'production'::text NOT NULL,
    notification_type text NOT NULL,
    player_tag text DEFAULT ''::text NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    settings jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT mobile_notification_subscriptions_pkey PRIMARY KEY (id),
    CONSTRAINT mobile_notification_subscriptions_environment_check
        CHECK (environment = ANY (ARRAY['sandbox'::text, 'production'::text]))
);

CREATE INDEX idx_mobile_notification_subscriptions_device
    ON public.mobile_notification_subscriptions
    (user_id, device_id, environment);

CREATE TABLE public.mobile_war_subscriptions (
    id uuid DEFAULT uuidv7() NOT NULL,
    user_id text NOT NULL,
    device_id text NOT NULL,
    clan_tag text NOT NULL,
    war_start_enabled boolean DEFAULT true NOT NULL,
    score_change_enabled boolean DEFAULT true NOT NULL,
    war_end_enabled boolean DEFAULT true NOT NULL,
    cwl_rank_enabled boolean DEFAULT true NOT NULL,
    live_activity_enabled boolean DEFAULT true NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT mobile_war_subscriptions_pkey PRIMARY KEY (id),
    CONSTRAINT mobile_war_subscriptions_user_id_device_id_clan_tag_key
        UNIQUE (user_id, device_id, clan_tag)
);

CREATE INDEX idx_mobile_war_subscriptions_clan_enabled
    ON public.mobile_war_subscriptions (clan_tag, enabled)
    WHERE enabled = true;

CREATE INDEX idx_mobile_war_subscriptions_user_device
    ON public.mobile_war_subscriptions (user_id, device_id);

DROP TABLE public.mobile_notification_accounts;

CREATE TABLE public.mobile_live_activities (
    id uuid DEFAULT uuidv7() NOT NULL,
    user_id text NOT NULL,
    device_id text NOT NULL,
    activity_id text NOT NULL,
    clan_tag text NOT NULL,
    war_id text,
    war_tag text,
    environment text DEFAULT 'production'::text NOT NULL,
    push_token_ciphertext text NOT NULL,
    push_token_hash text NOT NULL,
    status text DEFAULT 'active'::text NOT NULL,
    last_payload_hash text,
    started_at timestamp with time zone DEFAULT now() NOT NULL,
    ended_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT mobile_live_activities_environment_check CHECK (
        environment = ANY (ARRAY['sandbox'::text, 'production'::text])
    ),
    CONSTRAINT mobile_live_activities_status_check CHECK (
        status = ANY (ARRAY['active'::text, 'ended'::text, 'stale'::text, 'disabled'::text])
    ),
    CONSTRAINT mobile_live_activities_pkey PRIMARY KEY (id),
    CONSTRAINT mobile_live_activities_push_token_hash_key UNIQUE (push_token_hash),
    CONSTRAINT mobile_live_activities_user_id_device_id_activity_id_key
        UNIQUE (user_id, device_id, activity_id)
);

CREATE INDEX idx_mobile_live_activities_clan_active
    ON public.mobile_live_activities (clan_tag, status)
    WHERE status = 'active'::text;

CREATE INDEX idx_mobile_live_activities_war_active
    ON public.mobile_live_activities (war_id, war_tag, status)
    WHERE status = 'active'::text;

DROP INDEX public.idx_legend_history_player_season;

ALTER TABLE public.legend_history
    ADD COLUMN created_at timestamp with time zone DEFAULT now()
        CONSTRAINT legend_history_snapshots_created_at_not_null NOT NULL;

ALTER INDEX public.idx_legend_history_season_rank
    RENAME TO idx_legend_history_snapshots_rank;

ALTER TABLE public.legend_history
    RENAME CONSTRAINT legend_history_pkey
    TO legend_history_snapshots_pkey;

ALTER TABLE public.legend_history
    RENAME CONSTRAINT legend_history_season_not_null
    TO legend_history_snapshots_season_not_null;

ALTER TABLE public.legend_history
    RENAME CONSTRAINT legend_history_player_tag_not_null
    TO legend_history_snapshots_player_tag_not_null;

ALTER TABLE public.legend_history
    RENAME CONSTRAINT legend_history_rank_not_null
    TO legend_history_snapshots_rank_not_null;

ALTER TABLE public.legend_history
    RENAME CONSTRAINT legend_history_trophies_not_null
    TO legend_history_snapshots_trophies_not_null;

ALTER TABLE public.legend_history
    RENAME CONSTRAINT legend_history_data_not_null
    TO legend_history_snapshots_data_not_null;

ALTER TABLE public.legend_history
    RENAME TO legend_history_snapshots;

ALTER TABLE public.leaderboard_history
    DROP CONSTRAINT leaderboard_history_kind_check,
    DROP CONSTRAINT leaderboard_history_location_id_check,
    DROP CONSTRAINT leaderboard_history_rank_check,
    DROP CONSTRAINT leaderboard_history_data_check;

ALTER INDEX public.idx_leaderboard_history_location_rank
    RENAME TO idx_leaderboard_snapshot_items_location_rank;

ALTER INDEX public.idx_leaderboard_history_tag_history
    RENAME TO idx_leaderboard_snapshot_items_tag_history;

ALTER TABLE public.leaderboard_history
    RENAME CONSTRAINT leaderboard_history_pkey
    TO leaderboard_snapshot_items_pkey;

ALTER TABLE public.leaderboard_history
    RENAME CONSTRAINT leaderboard_history_kind_not_null
    TO leaderboard_snapshot_items_kind_not_null;

ALTER TABLE public.leaderboard_history
    RENAME CONSTRAINT leaderboard_history_location_id_not_null
    TO leaderboard_snapshot_items_location_id_not_null;

ALTER TABLE public.leaderboard_history
    RENAME CONSTRAINT leaderboard_history_date_not_null
    TO leaderboard_snapshot_items_snapshot_on_not_null;

ALTER TABLE public.leaderboard_history
    RENAME CONSTRAINT leaderboard_history_tag_not_null
    TO leaderboard_snapshot_items_tag_not_null;

ALTER TABLE public.leaderboard_history
    RENAME CONSTRAINT leaderboard_history_name_not_null
    TO leaderboard_snapshot_items_name_not_null;

ALTER TABLE public.leaderboard_history
    RENAME CONSTRAINT leaderboard_history_rank_not_null
    TO leaderboard_snapshot_items_rank_not_null;

ALTER TABLE public.leaderboard_history
    RENAME CONSTRAINT leaderboard_history_data_not_null
    TO leaderboard_snapshot_items_data_not_null;

ALTER TABLE public.leaderboard_history
    RENAME TO leaderboard_snapshot_items;

CREATE TABLE public.hall_counts (
    village_type integer NOT NULL,
    level integer NOT NULL,
    total_count integer NOT NULL,
    CONSTRAINT hall_counts_pkey PRIMARY KEY (village_type, level)
);

INSERT INTO public.hall_counts (village_type, level, total_count)
SELECT 0, level, total_count::integer
FROM public.townhall_counts;

DROP MATERIALIZED VIEW public.townhall_counts;
