-- +goose Up

CREATE TABLE auth_users (
    user_id text PRIMARY KEY,
    email_hash text UNIQUE,
    discord_user_id text,
    username text NOT NULL DEFAULT '',
    display_name text NOT NULL DEFAULT '',
    password_hash text,
    verified boolean NOT NULL DEFAULT false,
    profile jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    data jsonb NOT NULL DEFAULT '{}'::jsonb
);

CREATE UNIQUE INDEX idx_auth_users_discord_user_id
    ON auth_users (discord_user_id)
    WHERE discord_user_id IS NOT NULL AND discord_user_id <> '';

CREATE TABLE auth_discord_tokens (
    user_id text NOT NULL REFERENCES auth_users(user_id) ON DELETE CASCADE,
    device_id text NOT NULL DEFAULT '',
    access_token_ciphertext text NOT NULL,
    refresh_token_ciphertext text,
    expires_at timestamptz,
    scopes text[] NOT NULL DEFAULT '{}',
    data jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, device_id)
);

CREATE INDEX idx_auth_discord_tokens_expires_at
    ON auth_discord_tokens (expires_at);

CREATE TABLE auth_refresh_tokens (
    token_hash text PRIMARY KEY,
    user_id text NOT NULL REFERENCES auth_users(user_id) ON DELETE CASCADE,
    device_id text NOT NULL DEFAULT '',
    expires_at timestamptz NOT NULL,
    revoked_at timestamptz,
    data jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_auth_refresh_tokens_user_device
    ON auth_refresh_tokens (user_id, device_id);

CREATE INDEX idx_auth_refresh_tokens_expires_at
    ON auth_refresh_tokens (expires_at);

CREATE TABLE auth_email_verifications (
    email_hash text PRIMARY KEY,
    verification_code_hash text NOT NULL,
    user_id text,
    expires_at timestamptz NOT NULL,
    data jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_auth_email_verifications_expires_at
    ON auth_email_verifications (expires_at);

CREATE TABLE auth_password_reset_tokens (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    email_hash text NOT NULL,
    reset_code_hash text NOT NULL,
    user_id text,
    used boolean NOT NULL DEFAULT false,
    expires_at timestamptz NOT NULL,
    data jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_auth_password_reset_tokens_lookup
    ON auth_password_reset_tokens (email_hash, used, expires_at DESC);

CREATE TABLE api_tokens (
    token_hash text PRIMARY KEY,
    user_id text NOT NULL DEFAULT '',
    server_id text,
    token_type text NOT NULL DEFAULT '',
    expires_at timestamptz,
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_api_tokens_user_type
    ON api_tokens (user_id, token_type);

CREATE INDEX idx_api_tokens_server_id
    ON api_tokens (server_id)
    WHERE server_id IS NOT NULL;

CREATE INDEX idx_api_tokens_expires_at
    ON api_tokens (expires_at);

ALTER TABLE player_links
    ADD COLUMN IF NOT EXISTS user_id text,
    ADD COLUMN IF NOT EXISTS verified_at timestamptz,
    ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now();

CREATE INDEX IF NOT EXISTS idx_player_links_user_order
    ON player_links (user_id, order_index)
    WHERE user_id IS NOT NULL;

ALTER TABLE reminders
    ADD COLUMN IF NOT EXISTS type_name text,
    ADD COLUMN IF NOT EXISTS channel_id text,
    ADD COLUMN IF NOT EXISTS trigger_time text,
    ADD COLUMN IF NOT EXISTS roles text[] NOT NULL DEFAULT '{}',
    ADD COLUMN IF NOT EXISTS war_type_names text[] NOT NULL DEFAULT '{}',
    ADD COLUMN IF NOT EXISTS point_threshold jsonb,
    ADD COLUMN IF NOT EXISTS attack_threshold jsonb,
    ADD COLUMN IF NOT EXISTS roster_id text,
    ADD COLUMN IF NOT EXISTS ping_type text,
    ADD COLUMN IF NOT EXISTS data jsonb NOT NULL DEFAULT '{}'::jsonb,
    ADD COLUMN IF NOT EXISTS created_at timestamptz NOT NULL DEFAULT now(),
    ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now();

CREATE INDEX IF NOT EXISTS idx_reminders_server_type_name
    ON reminders (server_id, type_name);

ALTER TABLE strikes
    ADD COLUMN IF NOT EXISTS image text,
    ADD COLUMN IF NOT EXISTS data jsonb NOT NULL DEFAULT '{}'::jsonb;

ALTER TABLE autoboards
    ADD COLUMN IF NOT EXISTS board_type text NOT NULL DEFAULT '',
    ADD COLUMN IF NOT EXISTS button_id text NOT NULL DEFAULT '',
    ADD COLUMN IF NOT EXISTS days text[] NOT NULL DEFAULT '{}',
    ADD COLUMN IF NOT EXISTS locale text NOT NULL DEFAULT '';

ALTER TABLE rosters
    ADD COLUMN IF NOT EXISTS custom_id text UNIQUE,
    ADD COLUMN IF NOT EXISTS group_id text,
    ADD COLUMN IF NOT EXISTS clan_tag text,
    ADD COLUMN IF NOT EXISTS alias text NOT NULL DEFAULT '',
    ADD COLUMN IF NOT EXISTS members jsonb NOT NULL DEFAULT '[]'::jsonb,
    ADD COLUMN IF NOT EXISTS data jsonb NOT NULL DEFAULT '{}'::jsonb,
    ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now();

ALTER TABLE roster_groups
    ADD COLUMN IF NOT EXISTS group_id text UNIQUE,
    ADD COLUMN IF NOT EXISTS description text NOT NULL DEFAULT '',
    ADD COLUMN IF NOT EXISTS data jsonb NOT NULL DEFAULT '{}'::jsonb,
    ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now();

ALTER TABLE giveaways
    ADD COLUMN IF NOT EXISTS data jsonb NOT NULL DEFAULT '{}'::jsonb;

ALTER TABLE servers
    ADD COLUMN IF NOT EXISTS embed_color text,
    ADD COLUMN IF NOT EXISTS logs_config jsonb NOT NULL DEFAULT '{}'::jsonb,
    ADD COLUMN IF NOT EXISTS status_roles jsonb NOT NULL DEFAULT '{}'::jsonb,
    ADD COLUMN IF NOT EXISTS countdowns jsonb NOT NULL DEFAULT '{}'::jsonb,
    ADD COLUMN IF NOT EXISTS data jsonb NOT NULL DEFAULT '{}'::jsonb,
    ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now();

ALTER TABLE server_clans
    ALTER COLUMN category_id DROP NOT NULL,
    ADD COLUMN IF NOT EXISTS name text NOT NULL DEFAULT '',
    ADD COLUMN IF NOT EXISTS abbreviation text NOT NULL DEFAULT '',
    ADD COLUMN IF NOT EXISTS logs_config jsonb NOT NULL DEFAULT '{}'::jsonb,
    ADD COLUMN IF NOT EXISTS countdowns jsonb NOT NULL DEFAULT '{}'::jsonb,
    ADD COLUMN IF NOT EXISTS data jsonb NOT NULL DEFAULT '{}'::jsonb,
    ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now();

CREATE TABLE short_links (
    id text PRIMARY KEY,
    url text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    data jsonb NOT NULL DEFAULT '{}'::jsonb
);

CREATE TABLE bot_sync_status (
    bot_id text NOT NULL,
    cluster_id integer NOT NULL,
    shard_ids integer[] NOT NULL DEFAULT '{}',
    server_count integer NOT NULL DEFAULT 0,
    member_count integer NOT NULL DEFAULT 0,
    clan_count integer NOT NULL DEFAULT 0,
    servers jsonb NOT NULL DEFAULT '[]'::jsonb,
    updated_at timestamptz NOT NULL DEFAULT now(),
    data jsonb NOT NULL DEFAULT '{}'::jsonb,
    PRIMARY KEY (bot_id, cluster_id)
);

CREATE TABLE autoboards (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    identifier text UNIQUE,
    server_id text NOT NULL,
    type text NOT NULL DEFAULT '',
    channel_id text,
    webhook_id text,
    thread_id text,
    interval_minutes integer,
    next_run_at timestamptz,
    enabled boolean NOT NULL DEFAULT true,
    data jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_autoboards_server_type
    ON autoboards (server_id, type);

CREATE INDEX idx_autoboards_due
    ON autoboards (next_run_at)
    WHERE enabled = true;

CREATE TABLE server_bans (
    server_id text NOT NULL,
    player_tag text NOT NULL,
    player_name text NOT NULL DEFAULT '',
    reason text NOT NULL DEFAULT '',
    added_by text NOT NULL DEFAULT '',
    edited_by jsonb NOT NULL DEFAULT '[]'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    data jsonb NOT NULL DEFAULT '{}'::jsonb,
    PRIMARY KEY (server_id, player_tag)
);

CREATE INDEX idx_server_bans_player_tag
    ON server_bans (player_tag);

CREATE TABLE role_bindings (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    server_id text NOT NULL,
    role_type text NOT NULL,
    role_key text NOT NULL DEFAULT '',
    role_id text NOT NULL,
    data jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (server_id, role_type, role_key, role_id)
);

CREATE INDEX idx_role_bindings_server_type
    ON role_bindings (server_id, role_type);

CREATE TABLE role_ignore_bindings (
    server_id text NOT NULL,
    role_id text NOT NULL,
    data jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (server_id, role_id)
);

CREATE TABLE server_role_settings (
    server_id text PRIMARY KEY,
    family_roles jsonb NOT NULL DEFAULT '{}'::jsonb,
    not_family_roles jsonb NOT NULL DEFAULT '{}'::jsonb,
    family_exclusive_roles jsonb NOT NULL DEFAULT '{}'::jsonb,
    ignored_roles jsonb NOT NULL DEFAULT '[]'::jsonb,
    data jsonb NOT NULL DEFAULT '{}'::jsonb,
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE user_settings (
    user_id text PRIMARY KEY,
    search jsonb NOT NULL DEFAULT '{}'::jsonb,
    app jsonb NOT NULL DEFAULT '{}'::jsonb,
    data jsonb NOT NULL DEFAULT '{}'::jsonb,
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_user_settings_search_gin
    ON user_settings
    USING gin (search);

CREATE TABLE search_groups (
    group_id text PRIMARY KEY,
    user_id text NOT NULL,
    name text NOT NULL,
    type text NOT NULL,
    tags text[] NOT NULL DEFAULT '{}',
    data jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_search_groups_user_type_name
    ON search_groups (user_id, type, name);

CREATE INDEX idx_search_groups_tags
    ON search_groups
    USING gin (tags);

CREATE INDEX IF NOT EXISTS idx_rosters_server_group
    ON rosters (server_id, group_id);

CREATE INDEX IF NOT EXISTS idx_rosters_server_clan
    ON rosters (server_id, clan_tag);

CREATE INDEX IF NOT EXISTS idx_rosters_members_gin
    ON rosters
    USING gin (members);

CREATE INDEX IF NOT EXISTS idx_roster_groups_server
    ON roster_groups (server_id);

CREATE TABLE roster_signup_categories (
    custom_id text PRIMARY KEY,
    server_id text NOT NULL,
    name text NOT NULL DEFAULT '',
    description text NOT NULL DEFAULT '',
    sort_order integer NOT NULL DEFAULT 0,
    data jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_roster_signup_categories_server
    ON roster_signup_categories (server_id, sort_order);

CREATE TABLE roster_automation_rules (
    automation_id text PRIMARY KEY,
    server_id text NOT NULL,
    group_id text,
    enabled boolean NOT NULL DEFAULT true,
    trigger_type text NOT NULL DEFAULT '',
    data jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_roster_automation_rules_server_group
    ON roster_automation_rules (server_id, group_id);

CREATE INDEX IF NOT EXISTS idx_giveaways_server_status
    ON giveaways (server_id, status);

CREATE INDEX IF NOT EXISTS idx_giveaways_end_time
    ON giveaways (end_time);

CREATE INDEX IF NOT EXISTS idx_giveaways_entries_gin
    ON giveaways
    USING gin (entries);

CREATE TABLE ticket_panels (
    server_id text NOT NULL,
    name text NOT NULL,
    components jsonb NOT NULL DEFAULT '[]'::jsonb,
    data jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (server_id, name)
);

CREATE INDEX idx_ticket_panels_components_gin
    ON ticket_panels
    USING gin (components);

CREATE TABLE open_tickets (
    server_id text NOT NULL,
    channel_id text NOT NULL,
    panel_name text,
    status text NOT NULL DEFAULT 'open',
    user_id text,
    set_clan text,
    data jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (server_id, channel_id)
);

CREATE INDEX idx_open_tickets_server_status
    ON open_tickets (server_id, status);

CREATE TABLE custom_embeds (
    server_id text NOT NULL,
    name text NOT NULL,
    data jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (server_id, name)
);

CREATE TABLE player_current_stats (
    player_tag text PRIMARY KEY,
    clan_tag text,
    name text NOT NULL DEFAULT '',
    townhall_level integer,
    last_online_at timestamptz,
    legends jsonb NOT NULL DEFAULT '{}'::jsonb,
    donations jsonb NOT NULL DEFAULT '{}'::jsonb,
    activity jsonb NOT NULL DEFAULT '{}'::jsonb,
    data jsonb NOT NULL DEFAULT '{}'::jsonb,
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_player_current_stats_clan
    ON player_current_stats (clan_tag);

CREATE INDEX idx_player_current_stats_legends_gin
    ON player_current_stats
    USING gin (legends);

ALTER TABLE player_season_stats
    ADD COLUMN IF NOT EXISTS name text NOT NULL DEFAULT '',
    ADD COLUMN IF NOT EXISTS townhall_level integer,
    ADD COLUMN IF NOT EXISTS donations jsonb NOT NULL DEFAULT '{}'::jsonb,
    ADD COLUMN IF NOT EXISTS clan_games jsonb NOT NULL DEFAULT '{}'::jsonb,
    ADD COLUMN IF NOT EXISTS activity jsonb NOT NULL DEFAULT '{}'::jsonb,
    ADD COLUMN IF NOT EXISTS data jsonb NOT NULL DEFAULT '{}'::jsonb;

CREATE INDEX IF NOT EXISTS idx_player_season_stats_clan_season
    ON player_season_stats (clan_tag, season);

CREATE TABLE clan_season_stats (
    clan_tag text NOT NULL,
    season text NOT NULL,
    donations jsonb NOT NULL DEFAULT '{}'::jsonb,
    clan_games jsonb NOT NULL DEFAULT '{}'::jsonb,
    activity jsonb NOT NULL DEFAULT '{}'::jsonb,
    data jsonb NOT NULL DEFAULT '{}'::jsonb,
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (clan_tag, season)
);

CREATE TABLE clan_rankings_current (
    clan_tag text PRIMARY KEY,
    country_code text,
    country_name text,
    rank integer,
    global_rank integer,
    local_rank integer,
    data jsonb NOT NULL DEFAULT '{}'::jsonb,
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_clan_rankings_current_country_rank
    ON clan_rankings_current (country_code, rank);

CREATE TABLE player_rankings_current (
    player_tag text PRIMARY KEY,
    country_code text,
    country_name text,
    rank integer,
    global_rank integer,
    local_rank integer,
    data jsonb NOT NULL DEFAULT '{}'::jsonb,
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_player_rankings_current_country_rank
    ON player_rankings_current (country_code, rank);

CREATE TABLE legend_rankings_current (
    player_tag text PRIMARY KEY,
    rank integer NOT NULL,
    trophies integer NOT NULL DEFAULT 0,
    player_name text NOT NULL DEFAULT '',
    clan_tag text,
    clan_name text NOT NULL DEFAULT '',
    data jsonb NOT NULL DEFAULT '{}'::jsonb,
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_legend_rankings_current_rank
    ON legend_rankings_current (rank);

CREATE TABLE legend_history_snapshots (
    season text NOT NULL,
    player_tag text NOT NULL,
    rank integer NOT NULL,
    trophies integer NOT NULL DEFAULT 0,
    data jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (season, player_tag)
);

CREATE INDEX idx_legend_history_snapshots_rank
    ON legend_history_snapshots (season, rank);

CREATE TABLE player_history_events (
    event_time timestamptz NOT NULL,
    player_tag text NOT NULL,
    clan_tag text NOT NULL DEFAULT '',
    season text NOT NULL DEFAULT '',
    event_type text NOT NULL,
    value integer,
    data jsonb NOT NULL DEFAULT '{}'::jsonb
);

SELECT create_hypertable(
    'player_history_events',
    'event_time',
    chunk_time_interval => INTERVAL '30 days',
    if_not_exists => TRUE
);

CREATE INDEX idx_player_history_events_player_time
    ON player_history_events (player_tag, event_time DESC);

CREATE INDEX idx_player_history_events_clan_season
    ON player_history_events (clan_tag, season, event_type, event_time DESC);

ALTER TABLE join_leave_history
    ADD COLUMN IF NOT EXISTS player_name text,
    ADD COLUMN IF NOT EXISTS clan_role text,
    ADD COLUMN IF NOT EXISTS data jsonb NOT NULL DEFAULT '{}'::jsonb;

CREATE TABLE raid_weekends (
    clan_tag text NOT NULL,
    start_time timestamptz NOT NULL,
    end_time timestamptz NOT NULL,
    state text NOT NULL DEFAULT '',
    total_attacks integer NOT NULL DEFAULT 0,
    capital_total_loot integer NOT NULL DEFAULT 0,
    raids_completed integer NOT NULL DEFAULT 0,
    offensive_reward integer NOT NULL DEFAULT 0,
    defensive_reward integer NOT NULL DEFAULT 0,
    members jsonb NOT NULL DEFAULT '[]'::jsonb,
    attack_log jsonb NOT NULL DEFAULT '[]'::jsonb,
    defense_log jsonb NOT NULL DEFAULT '[]'::jsonb,
    data jsonb NOT NULL DEFAULT '{}'::jsonb,
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (clan_tag, start_time)
);

CREATE INDEX idx_raid_weekends_end_time
    ON raid_weekends (end_time DESC);

CREATE INDEX idx_raid_weekends_members_gin
    ON raid_weekends
    USING gin (members);

CREATE TABLE capital_raid_cache (
    clan_tag text PRIMARY KEY,
    start_time timestamptz,
    end_time timestamptz,
    state text NOT NULL DEFAULT '',
    data jsonb NOT NULL,
    raw jsonb NOT NULL,
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_capital_raid_cache_end_time
    ON capital_raid_cache (end_time DESC);

CREATE TABLE capital_raid_members (
    clan_tag text NOT NULL,
    start_time timestamptz NOT NULL,
    player_tag text NOT NULL,
    player_name text NOT NULL DEFAULT '',
    attack_count integer NOT NULL DEFAULT 0,
    attack_limit integer NOT NULL DEFAULT 0,
    bonus_attack_limit integer NOT NULL DEFAULT 0,
    capital_resources_looted integer NOT NULL DEFAULT 0,
    data jsonb NOT NULL DEFAULT '{}'::jsonb,
    PRIMARY KEY (clan_tag, start_time, player_tag)
);

CREATE INDEX idx_capital_raid_members_player_time
    ON capital_raid_members (player_tag, start_time DESC);

CREATE TABLE bot_settings (
    type text PRIMARY KEY,
    data jsonb NOT NULL DEFAULT '{}'::jsonb,
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE ranking_snapshots (
    ranking_type text NOT NULL,
    location text NOT NULL,
    snapshot_date text NOT NULL,
    data jsonb NOT NULL DEFAULT '{}'::jsonb,
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (ranking_type, location, snapshot_date)
);

CREATE INDEX idx_ranking_snapshots_type_date
    ON ranking_snapshots (ranking_type, snapshot_date);

CREATE TABLE current_war_timers (
    player_tag text PRIMARY KEY,
    war_id text NOT NULL,
    clan_tag text NOT NULL,
    opponent_tag text NOT NULL,
    end_time timestamptz NOT NULL,
    data jsonb NOT NULL DEFAULT '{}'::jsonb,
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_current_war_timers_end_time
    ON current_war_timers (end_time);

-- +goose Down

DROP TABLE IF EXISTS current_war_timers;
DROP TABLE IF EXISTS ranking_snapshots;
DROP TABLE IF EXISTS bot_settings;
DROP TABLE IF EXISTS capital_raid_members;
DROP TABLE IF EXISTS capital_raid_cache;
DROP TABLE IF EXISTS raid_weekends;
DROP TABLE IF EXISTS player_history_events;
DROP TABLE IF EXISTS legend_history_snapshots;
DROP TABLE IF EXISTS legend_rankings_current;
DROP TABLE IF EXISTS player_rankings_current;
DROP TABLE IF EXISTS clan_rankings_current;
DROP TABLE IF EXISTS clan_season_stats;
DROP INDEX IF EXISTS idx_player_season_stats_clan_season;
ALTER TABLE player_season_stats
    DROP COLUMN IF EXISTS data,
    DROP COLUMN IF EXISTS activity,
    DROP COLUMN IF EXISTS clan_games,
    DROP COLUMN IF EXISTS donations,
    DROP COLUMN IF EXISTS townhall_level,
    DROP COLUMN IF EXISTS name;
DROP TABLE IF EXISTS player_current_stats;
DROP TABLE IF EXISTS roster_automation_rules;
DROP TABLE IF EXISTS roster_signup_categories;
DROP TABLE IF EXISTS search_groups;
DROP TABLE IF EXISTS user_settings;
DROP TABLE IF EXISTS custom_embeds;
DROP TABLE IF EXISTS open_tickets;
DROP TABLE IF EXISTS ticket_panels;
DROP TABLE IF EXISTS server_role_settings;
DROP TABLE IF EXISTS role_ignore_bindings;
DROP TABLE IF EXISTS role_bindings;
DROP TABLE IF EXISTS server_bans;
DROP TABLE IF EXISTS autoboards;
DROP TABLE IF EXISTS bot_sync_status;
DROP TABLE IF EXISTS short_links;
ALTER TABLE server_clans
    DROP COLUMN IF EXISTS updated_at,
    DROP COLUMN IF EXISTS data,
    DROP COLUMN IF EXISTS countdowns,
    DROP COLUMN IF EXISTS logs_config,
    DROP COLUMN IF EXISTS abbreviation,
    DROP COLUMN IF EXISTS name,
    ALTER COLUMN category_id SET NOT NULL;
ALTER TABLE servers
    DROP COLUMN IF EXISTS updated_at,
    DROP COLUMN IF EXISTS data,
    DROP COLUMN IF EXISTS countdowns,
    DROP COLUMN IF EXISTS status_roles,
    DROP COLUMN IF EXISTS logs_config,
    DROP COLUMN IF EXISTS embed_color;
ALTER TABLE strikes
    DROP COLUMN IF EXISTS data,
    DROP COLUMN IF EXISTS image;
ALTER TABLE autoboards
    DROP COLUMN IF EXISTS locale,
    DROP COLUMN IF EXISTS days,
    DROP COLUMN IF EXISTS button_id,
    DROP COLUMN IF EXISTS board_type;
ALTER TABLE roster_groups
    DROP COLUMN IF EXISTS updated_at,
    DROP COLUMN IF EXISTS data,
    DROP COLUMN IF EXISTS description,
    DROP COLUMN IF EXISTS group_id;
DROP INDEX IF EXISTS idx_roster_groups_server;
DROP INDEX IF EXISTS idx_rosters_members_gin;
DROP INDEX IF EXISTS idx_rosters_server_clan;
DROP INDEX IF EXISTS idx_rosters_server_group;
ALTER TABLE rosters
    DROP COLUMN IF EXISTS updated_at,
    DROP COLUMN IF EXISTS data,
    DROP COLUMN IF EXISTS members,
    DROP COLUMN IF EXISTS alias,
    DROP COLUMN IF EXISTS clan_tag,
    DROP COLUMN IF EXISTS group_id,
    DROP COLUMN IF EXISTS custom_id;
DROP INDEX IF EXISTS idx_giveaways_entries_gin;
DROP INDEX IF EXISTS idx_giveaways_end_time;
DROP INDEX IF EXISTS idx_giveaways_server_status;
ALTER TABLE giveaways
    DROP COLUMN IF EXISTS data;
DROP INDEX IF EXISTS idx_reminders_server_type_name;
ALTER TABLE reminders
    DROP COLUMN IF EXISTS updated_at,
    DROP COLUMN IF EXISTS created_at,
    DROP COLUMN IF EXISTS data,
    DROP COLUMN IF EXISTS ping_type,
    DROP COLUMN IF EXISTS roster_id,
    DROP COLUMN IF EXISTS attack_threshold,
    DROP COLUMN IF EXISTS point_threshold,
    DROP COLUMN IF EXISTS war_type_names,
    DROP COLUMN IF EXISTS roles,
    DROP COLUMN IF EXISTS trigger_time,
    DROP COLUMN IF EXISTS channel_id,
    DROP COLUMN IF EXISTS type_name;
DROP INDEX IF EXISTS idx_player_links_user_order;
ALTER TABLE player_links
    DROP COLUMN IF EXISTS updated_at,
    DROP COLUMN IF EXISTS verified_at,
    DROP COLUMN IF EXISTS user_id;
DROP TABLE IF EXISTS api_tokens;
DROP TABLE IF EXISTS auth_password_reset_tokens;
DROP TABLE IF EXISTS auth_email_verifications;
DROP TABLE IF EXISTS auth_refresh_tokens;
DROP TABLE IF EXISTS auth_discord_tokens;
DROP TABLE IF EXISTS auth_users;
