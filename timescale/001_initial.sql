-- +goose Up
CREATE EXTENSION IF NOT EXISTS timescaledb;

CREATE TABLE player_online_events (
    seen_at timestamptz NOT NULL DEFAULT now(),
    tag text NOT NULL,
    clan_tag text NOT NULL,
    townhall_level smallint NOT NULL
);

SELECT create_hypertable(
    'player_online_events',
    'seen_at',
    if_not_exists => TRUE
);

CREATE INDEX idx_player_online_events_clan_time
    ON player_online_events (clan_tag, seen_at DESC);

CREATE INDEX idx_player_online_events_player_time
    ON player_online_events (tag, seen_at DESC);

CREATE TABLE join_leave_history (
    event_time timestamptz NOT NULL DEFAULT now(),
    event_type text NOT NULL CHECK (event_type IN ('join', 'leave')),
    clan_tag text NOT NULL,
    player_tag text NOT NULL,
    townhall_level smallint NOT NULL DEFAULT 0
);

SELECT create_hypertable(
    'join_leave_history',
    'event_time',
    if_not_exists => TRUE
);

CREATE INDEX idx_join_leave_history_clan_time
    ON join_leave_history (clan_tag, event_time DESC);

CREATE INDEX idx_join_leave_history_player_time
    ON join_leave_history (player_tag, event_time DESC);

CREATE TABLE clan_change_history (
    event_time timestamptz NOT NULL DEFAULT now(),
    clan_tag text NOT NULL,
    change_type text NOT NULL CHECK (
        change_type IN ('description', 'clan_level', 'cwl_league_id', 'capital_league_id')
    ),
    previous_value jsonb NOT NULL,
    current_value jsonb NOT NULL
);

SELECT create_hypertable(
    'clan_change_history',
    'event_time',
    if_not_exists => TRUE
);

CREATE INDEX idx_clan_change_history_clan_time
    ON clan_change_history (clan_tag, event_time DESC);

CREATE INDEX idx_clan_change_history_type_time
    ON clan_change_history (change_type, event_time DESC);

CREATE TABLE basic_player (
    tag text PRIMARY KEY,
    name text NOT NULL,
    league_id integer,
    clan_tag text,
    townhall_level integer NOT NULL,
    last_activity timestamptz
);

CREATE TABLE tracked_player_targets (
    tag text PRIMARY KEY,
    enabled boolean NOT NULL DEFAULT true,
    source text NOT NULL DEFAULT 'manual',
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE player_profile_changes (
    event_time timestamptz NOT NULL DEFAULT now(),
    player_tag text NOT NULL,
    clan_tag text NOT NULL DEFAULT '',
    townhall_level integer NOT NULL DEFAULT 0,
    change_type text NOT NULL,
    previous_value jsonb,
    current_value jsonb
);

SELECT create_hypertable(
    'player_profile_changes',
    'event_time',
    chunk_time_interval => INTERVAL '7 days',
    if_not_exists => TRUE
);

CREATE INDEX idx_player_profile_changes_player_time
    ON player_profile_changes (player_tag, event_time DESC);

CREATE INDEX idx_player_profile_changes_type_time
    ON player_profile_changes (change_type, event_time DESC);

CREATE TABLE player_season_stats (
    player_tag text NOT NULL,
    season text NOT NULL,
    clan_tag text NOT NULL DEFAULT '',
    donated integer NOT NULL DEFAULT 0,
    received integer NOT NULL DEFAULT 0,
    capital_gold_donos integer NOT NULL DEFAULT 0,
    activity_score integer NOT NULL DEFAULT 0,
    last_online_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (player_tag, season, clan_tag)
);

CREATE TABLE battlelogs (
    battle_id uuid NOT NULL,
    army_hash numeric(20, 0) NOT NULL,
    player_tag text NOT NULL,
    player_th smallint NOT NULL,
    opponent_tag text NOT NULL,
    opponent_th smallint NOT NULL,
    league_id integer NOT NULL,
    battle_type text NOT NULL,
    attack boolean NOT NULL,
    stars smallint NOT NULL,
    destruction_percentage smallint NOT NULL,
    gold integer NOT NULL,
    elixir integer NOT NULL,
    dark_elixir integer NOT NULL,
    battle_time timestamptz NOT NULL,
    army_items text[] NOT NULL,
    army_counts jsonb NOT NULL,
    PRIMARY KEY (battle_id, battle_time)
);

SELECT create_hypertable(
    'battlelogs',
    'battle_time',
    chunk_time_interval => INTERVAL '1 day',
    if_not_exists => TRUE
);

ALTER TABLE battlelogs SET (
    timescaledb.compress,
    timescaledb.compress_orderby = 'battle_time DESC',
    timescaledb.compress_segmentby = 'player_tag'
);

SELECT add_compression_policy(
    'battlelogs',
    compress_after => INTERVAL '35 days'
);

CREATE INDEX idx_battlelogs_player_time
    ON battlelogs (player_tag, battle_time DESC);

CREATE INDEX idx_battlelogs_dynamic_search_main
    ON battlelogs (player_th, battle_type, league_id, battle_time DESC)
    WHERE attack = true
      AND player_th = opponent_th
      AND battle_type IN ('ranked', 'legend');

CREATE INDEX idx_battlelogs_army_items
    ON battlelogs
    USING gin (army_items)
    WHERE attack = true
      AND player_th = opponent_th
      AND battle_type IN ('ranked', 'legend');

CREATE INDEX idx_battlelogs_army_counts
    ON battlelogs
    USING gin (army_counts)
    WHERE attack = true
      AND player_th = opponent_th
      AND battle_type IN ('ranked', 'legend');

CREATE MATERIALIZED VIEW townhall_stats_daily
WITH (timescaledb.continuous) AS
SELECT
    time_bucket('1 day', battle_time) AS day_start,
    player_th,
    league_id,
    battle_type,
    count(*) AS attacks,
    count(*) FILTER (WHERE stars = 0) AS zero_stars,
    count(*) FILTER (WHERE stars = 1) AS one_stars,
    count(*) FILTER (WHERE stars = 2) AS two_stars,
    count(*) FILTER (WHERE stars = 3) AS three_stars
FROM battlelogs
WHERE attack = true
  AND player_th = opponent_th
  AND battle_type IN ('ranked', 'legend')
GROUP BY day_start, player_th, league_id, battle_type;

SELECT add_continuous_aggregate_policy(
    'townhall_stats_daily',
    start_offset => INTERVAL '2 hours',
    end_offset => INTERVAL '15 minutes',
    schedule_interval => INTERVAL '1 hour'
);

CREATE TABLE item_usage_daily (
    day_start timestamptz NOT NULL,
    player_th smallint NOT NULL,
    league_id integer NOT NULL,
    battle_type text NOT NULL,
    item_key text NOT NULL,
    uses bigint NOT NULL DEFAULT 0,
    PRIMARY KEY (day_start, player_th, league_id, battle_type, item_key)
);

CREATE INDEX idx_item_usage_daily_item_filters_time
    ON item_usage_daily (item_key, player_th, battle_type);

CREATE TABLE item_hitrate_daily (
    day_start timestamptz NOT NULL,
    player_th smallint NOT NULL,
    league_id integer NOT NULL,
    battle_type text NOT NULL,
    item_key text NOT NULL,
    attacks bigint NOT NULL DEFAULT 0,
    zero_stars bigint NOT NULL DEFAULT 0,
    one_stars bigint NOT NULL DEFAULT 0,
    two_stars bigint NOT NULL DEFAULT 0,
    three_stars bigint NOT NULL DEFAULT 0,
    PRIMARY KEY (day_start, player_th, league_id, battle_type, item_key)
);

CREATE INDEX idx_item_hitrate_daily_item_filters_time
    ON item_hitrate_daily (item_key, player_th, battle_type);

CREATE TABLE servers (
    id text PRIMARY KEY,
    name text NOT NULL,
    joined_at timestamptz NOT NULL DEFAULT now(),
    left_at timestamptz
);

CREATE TABLE clan_categories (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    server_id text NOT NULL REFERENCES servers(id) ON DELETE CASCADE,
    name text NOT NULL,
    UNIQUE (server_id, name)
);

CREATE TABLE server_clans (
    tag text NOT NULL,
    server_id text NOT NULL REFERENCES servers(id) ON DELETE CASCADE,
    category_id uuid NOT NULL REFERENCES clan_categories(id),
    clan_channel_id text,
    PRIMARY KEY (tag, server_id)
);

CREATE TABLE clan_logs (
    server_id text NOT NULL REFERENCES servers(id) ON DELETE CASCADE,
    clan_tag text NOT NULL,
    type text NOT NULL,
    webhook_token text NOT NULL,
    thread_id text,
    PRIMARY KEY (server_id, clan_tag, type),
    FOREIGN KEY (clan_tag, server_id)
        REFERENCES server_clans(tag, server_id)
        ON DELETE CASCADE
);

CREATE TABLE clan_position_roles (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    server_id text NOT NULL REFERENCES servers(id) ON DELETE CASCADE,
    clan_tag text,
    position text NOT NULL CHECK (position IN ('member', 'elder', 'coleader', 'leader')),
    role_id text NOT NULL,
    FOREIGN KEY (clan_tag, server_id)
        REFERENCES server_clans(tag, server_id)
        ON DELETE CASCADE
);

CREATE UNIQUE INDEX idx_clan_position_roles_clan
    ON clan_position_roles (server_id, clan_tag, position)
    WHERE clan_tag IS NOT NULL;

CREATE UNIQUE INDEX idx_clan_position_roles_global
    ON clan_position_roles (server_id, position)
    WHERE clan_tag IS NULL;

CREATE TABLE bases (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    message_id text NOT NULL,
    base_link text NOT NULL,
    downloads integer NOT NULL DEFAULT 0,
    upvotes integer NOT NULL DEFAULT 0,
    downvotes integer NOT NULL DEFAULT 0,
    downloaders text[] NOT NULL DEFAULT '{}',
    whitelisted_role_id text,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE hall_roles (
    server_id text NOT NULL REFERENCES servers(id) ON DELETE CASCADE,
    role_id text NOT NULL,
    hall_level integer NOT NULL,
    is_townhall boolean NOT NULL,
    PRIMARY KEY (server_id, hall_level, is_townhall)
);

CREATE TABLE league_roles (
    server_id text NOT NULL REFERENCES servers(id) ON DELETE CASCADE,
    league_id integer NOT NULL,
    role_id text NOT NULL,
    PRIMARY KEY (server_id, league_id)
);

CREATE TABLE rosters (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    server_id text NOT NULL REFERENCES servers(id) ON DELETE CASCADE,
    linked_clan_tag text NOT NULL,
    title text NOT NULL,
    description text NOT NULL,
    max_size integer NOT NULL,
    minimum_townhall integer,
    maximum_townhall integer,
    image_url text,
    signup_role_id text,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE roster_groups (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    server_id text NOT NULL REFERENCES servers(id) ON DELETE CASCADE,
    name text NOT NULL,
    UNIQUE (server_id, name)
);

CREATE TABLE roster_members (
    tag text NOT NULL,
    roster_id uuid NOT NULL REFERENCES rosters(id) ON DELETE CASCADE,
    roster_group_id uuid REFERENCES roster_groups(id) ON DELETE SET NULL,
    PRIMARY KEY (tag, roster_id)
);

CREATE TABLE player_links (
    tag text PRIMARY KEY,
    is_main boolean NOT NULL DEFAULT false,
    discord_id text,
    order_index integer NOT NULL DEFAULT 0,
    is_verified boolean NOT NULL DEFAULT false,
    source text NOT NULL,
    added_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE player_links_settings (
    tag text NOT NULL REFERENCES player_links(tag) ON DELETE CASCADE,
    server_id text NOT NULL REFERENCES servers(id) ON DELETE CASCADE,
    is_main boolean NOT NULL DEFAULT false,
    PRIMARY KEY (tag, server_id)
);

CREATE TABLE giveaways (
    id text PRIMARY KEY,
    server_id text NOT NULL REFERENCES servers(id) ON DELETE CASCADE,
    prize text NOT NULL,
    channel_id text,
    status text NOT NULL CHECK (status IN ('scheduled', 'ongoing', 'ended')),
    start_time timestamptz NOT NULL,
    end_time timestamptz NOT NULL,
    winners integer NOT NULL,
    mentions text[] NOT NULL DEFAULT '{}',
    text_above_embed text NOT NULL DEFAULT '',
    text_in_embed text NOT NULL DEFAULT '',
    text_on_end text NOT NULL DEFAULT '',
    image_url text,
    profile_picture_required boolean NOT NULL DEFAULT false,
    coc_account_required boolean NOT NULL DEFAULT false,
    roles_mode text NOT NULL DEFAULT 'none',
    roles text[] NOT NULL DEFAULT '{}',
    boosters jsonb NOT NULL DEFAULT '[]'::jsonb,
    entries jsonb NOT NULL DEFAULT '[]'::jsonb,
    winners_list jsonb NOT NULL DEFAULT '[]'::jsonb,
    updated boolean NOT NULL DEFAULT false,
    message_id text,
    event_pending text,
    event_pending_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_giveaways_due_start
    ON giveaways (start_time)
    WHERE status = 'scheduled';

CREATE INDEX idx_giveaways_due_end
    ON giveaways (end_time)
    WHERE status = 'ongoing';

CREATE INDEX idx_giveaways_pending_event
    ON giveaways (event_pending_at)
    WHERE event_pending IS NOT NULL;

CREATE TABLE strikes (
    id text NOT NULL,
    server_id text NOT NULL REFERENCES servers(id) ON DELETE CASCADE,
    tag text NOT NULL,
    date_created timestamptz NOT NULL,
    reason text NOT NULL,
    added_by text NOT NULL,
    strike_weight integer, -- if the weight is NULL, then the strike is a BAN
    rollover_date timestamptz,
    PRIMARY KEY (id, server_id)
);

CREATE INDEX idx_strikes_tag
    ON strikes (tag);

CREATE INDEX idx_strikes_server_id
    ON strikes (server_id);

CREATE TABLE audit_history (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    resource_id uuid,
    resource_type text NOT NULL,
    description text NOT NULL,
    user_id text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE one_time_login_tokens (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    user_id text NOT NULL,
    token_hash text NOT NULL UNIQUE,
    expires_at timestamptz NOT NULL,
    used_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_one_time_login_tokens_user_id
    ON one_time_login_tokens (user_id);

CREATE INDEX idx_one_time_login_tokens_expires_at
    ON one_time_login_tokens (expires_at);

CREATE TABLE mobile_push_devices (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    user_id text NOT NULL,
    device_id text NOT NULL,
    platform text NOT NULL CHECK (platform IN ('ios', 'android')),
    provider text NOT NULL CHECK (provider IN ('apns', 'fcm')),
    environment text NOT NULL DEFAULT 'production' CHECK (environment IN ('sandbox', 'production')),
    token_ciphertext text NOT NULL,
    token_hash text NOT NULL UNIQUE,
    app_version text NOT NULL DEFAULT '',
    build_number text NOT NULL DEFAULT '',
    os_version text NOT NULL DEFAULT '',
    device_model text NOT NULL DEFAULT '',
    enabled boolean NOT NULL DEFAULT true,
    last_seen_at timestamptz NOT NULL DEFAULT now(),
    disabled_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (user_id, device_id, provider, environment)
);

CREATE INDEX idx_mobile_push_devices_user_device
    ON mobile_push_devices (user_id, device_id);

CREATE INDEX idx_mobile_push_devices_enabled_provider
    ON mobile_push_devices (provider, environment, enabled)
    WHERE enabled = true;

CREATE TABLE mobile_war_subscriptions (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    user_id text NOT NULL,
    device_id text NOT NULL,
    clan_tag text NOT NULL,
    war_start_enabled boolean NOT NULL DEFAULT true,
    score_change_enabled boolean NOT NULL DEFAULT true,
    war_end_enabled boolean NOT NULL DEFAULT true,
    cwl_rank_enabled boolean NOT NULL DEFAULT true,
    live_activity_enabled boolean NOT NULL DEFAULT true,
    enabled boolean NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (user_id, device_id, clan_tag)
);

CREATE INDEX idx_mobile_war_subscriptions_clan_enabled
    ON mobile_war_subscriptions (clan_tag, enabled)
    WHERE enabled = true;

CREATE INDEX idx_mobile_war_subscriptions_user_device
    ON mobile_war_subscriptions (user_id, device_id);

CREATE TABLE mobile_live_activities (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    user_id text NOT NULL,
    device_id text NOT NULL,
    activity_id text NOT NULL,
    clan_tag text NOT NULL,
    war_id text,
    cwl_war_tag text,
    environment text NOT NULL DEFAULT 'production' CHECK (environment IN ('sandbox', 'production')),
    push_token_ciphertext text NOT NULL,
    push_token_hash text NOT NULL UNIQUE,
    status text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'ended', 'stale', 'disabled')),
    last_payload_hash text,
    started_at timestamptz NOT NULL DEFAULT now(),
    ended_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (user_id, device_id, activity_id)
);

CREATE INDEX idx_mobile_live_activities_clan_active
    ON mobile_live_activities (clan_tag, status)
    WHERE status = 'active';

CREATE INDEX idx_mobile_live_activities_war_active
    ON mobile_live_activities (war_id, cwl_war_tag, status)
    WHERE status = 'active';

CREATE TABLE basic_clan (
    tag text PRIMARY KEY,
    name text NOT NULL,
    description text NOT NULL DEFAULT '',
    clan_level integer NOT NULL DEFAULT 0,
    location_id integer,
    cwl_league_id integer NOT NULL DEFAULT 48000000,
    capital_league_id integer,
    public_war_log boolean NOT NULL,
    war_wins integer NOT NULL,
    member_count integer NOT NULL,
    badge_url text NOT NULL,
    troops_donated integer NOT NULL,
    troops_received integer NOT NULL,
    member_tags text[] NOT NULL DEFAULT '{}',
    last_active timestamptz
);

CREATE INDEX idx_basic_clan_member_count
    ON basic_clan (member_count);

CREATE INDEX idx_basic_clan_last_active
    ON basic_clan (last_active);

CREATE TABLE war_log_index (
    war_id text NOT NULL,
    clan_tag text NOT NULL,
    opponent_tag text NOT NULL,
    prep_time timestamptz NOT NULL,
    start_time timestamptz,
    end_time timestamptz NOT NULL,
    clan_badge_url text NOT NULL DEFAULT '',
    opponent_badge_url text NOT NULL DEFAULT '',
    size integer NOT NULL,
    war_type text NOT NULL CHECK (war_type IN ('random', 'cwl', 'friendly')),
    state text NOT NULL,
    battle_modifier text NOT NULL DEFAULT '',
    cwl_war_tag text,
    r2_key text,
    stored_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (war_id, clan_tag)
);

CREATE INDEX idx_war_log_index_clan_end_time
    ON war_log_index (clan_tag, end_time DESC);

CREATE INDEX idx_war_log_index_pending_store
    ON war_log_index (end_time)
    WHERE stored_at IS NULL;

CREATE TABLE war_attack_events (
    war_id text NOT NULL,
    war_end_time timestamptz NOT NULL,
    war_type text NOT NULL,
    war_size integer NOT NULL,
    attacking_clan_tag text NOT NULL,
    defending_clan_tag text NOT NULL,
    attacker_tag text NOT NULL,
    defender_tag text NOT NULL,
    attacker_townhall smallint NOT NULL,
    defender_townhall smallint NOT NULL,
    attacker_map_position smallint NOT NULL,
    defender_map_position smallint NOT NULL,
    stars smallint NOT NULL,
    destruction_percentage smallint NOT NULL,
    duration integer NOT NULL,
    attack_order integer NOT NULL,
    battle_modifier text NOT NULL DEFAULT '',
    PRIMARY KEY (war_id, war_end_time, attacker_tag, defender_tag, attack_order)
);

SELECT create_hypertable(
    'war_attack_events',
    'war_end_time',
    chunk_time_interval => INTERVAL '1 day',
    if_not_exists => TRUE
);

CREATE INDEX idx_war_attack_events_clan_time
    ON war_attack_events (attacking_clan_tag, war_end_time DESC);

CREATE INDEX idx_war_attack_events_player_time
    ON war_attack_events (attacker_tag, war_end_time DESC);

CREATE INDEX idx_war_attack_events_hitrate
    ON war_attack_events (attacker_townhall, defender_townhall, war_type, war_end_time DESC);

CREATE TABLE war_schedule (
    war_id text PRIMARY KEY,
    source_clan_tag text NOT NULL,
    opponent_tag text NOT NULL,
    prep_time timestamptz NOT NULL,
    end_time timestamptz NOT NULL,
    next_run_at timestamptz NOT NULL,
    cwl_war_tag text,
    status text NOT NULL CHECK (status IN ('pending', 'storing', 'complete', 'failed')),
    attempts integer NOT NULL DEFAULT 0,
    last_error text,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_war_schedule_pending
    ON war_schedule (next_run_at)
    WHERE status IN ('pending', 'storing');

CREATE TABLE cwl_groups (
    cwl_id text PRIMARY KEY,
    season text NOT NULL,
    cwl_league_id integer NOT NULL,
    clan_tags text[] NOT NULL,
    rounds jsonb NOT NULL,
    data jsonb NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_cwl_groups_season_league
    ON cwl_groups (season, cwl_league_id);

CREATE TABLE leaderboard_snapshot_items (
    kind text NOT NULL,
    location_id text NOT NULL,
    date date NOT NULL,
    tag text NOT NULL,
    name text NOT NULL,
    rank integer NOT NULL,
    data jsonb NOT NULL,
    PRIMARY KEY (kind, location_id, date, tag)
);

CREATE INDEX idx_leaderboard_snapshot_items_tag_history
    ON leaderboard_snapshot_items (kind, tag, date DESC);

CREATE INDEX idx_leaderboard_snapshot_items_location_rank
    ON leaderboard_snapshot_items (kind, location_id, date DESC, rank);

CREATE MATERIALIZED VIEW war_league_counts AS
SELECT
    c.cwl_league_id,
    count(*) AS clan_count
FROM basic_clan c
GROUP BY c.cwl_league_id;

CREATE MATERIALIZED VIEW clan_leaderboards AS
SELECT
    c.tag,
    c.location_id,
    rank() OVER (ORDER BY c.troops_donated DESC, c.tag) AS donated_rank,
    rank() OVER (ORDER BY c.troops_received DESC, c.tag) AS received_rank,
    rank() OVER (ORDER BY c.war_wins DESC, c.tag) AS war_wins_rank,
    rank() OVER (PARTITION BY c.location_id ORDER BY c.troops_donated DESC, c.tag) AS location_donated_rank,
    rank() OVER (PARTITION BY c.location_id ORDER BY c.troops_received DESC, c.tag) AS location_received_rank,
    rank() OVER (PARTITION BY c.location_id ORDER BY c.war_wins DESC, c.tag) AS location_war_wins_rank
FROM basic_clan c;

CREATE UNIQUE INDEX idx_clan_leaderboards_tag
    ON clan_leaderboards (tag);

CREATE INDEX idx_clan_leaderboards_donated_rank
    ON clan_leaderboards (donated_rank);

CREATE INDEX idx_clan_leaderboards_received_rank
    ON clan_leaderboards (received_rank);

CREATE INDEX idx_clan_leaderboards_war_wins_rank
    ON clan_leaderboards (war_wins_rank);

CREATE INDEX idx_clan_leaderboards_location_donated_rank
    ON clan_leaderboards (location_id, location_donated_rank);

CREATE INDEX idx_clan_leaderboards_location_received_rank
    ON clan_leaderboards (location_id, location_received_rank);

CREATE INDEX idx_clan_leaderboards_location_war_wins_rank
    ON clan_leaderboards (location_id, location_war_wins_rank);

CREATE TABLE hall_counts (
    village_type integer NOT NULL,
    level integer NOT NULL,
    total_count integer NOT NULL,
    PRIMARY KEY (village_type, level)
);

CREATE TABLE embeds (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    server_id text NOT NULL REFERENCES servers(id) ON DELETE CASCADE,
    name text NOT NULL,
    data jsonb NOT NULL
);

CREATE TABLE ticket_panel (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    server_id text NOT NULL REFERENCES servers(id) ON DELETE CASCADE,
    name text NOT NULL,
    description text NOT NULL,
    parent_channel_id text, -- if NULL, then opens tickets as a thread under this channel
    open_category_id text,
    closed_category_id text,
    log_channel_id text,
    naming_convention text,
    embed_id uuid REFERENCES embeds(id) ON DELETE SET NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE ticket_panel_staff_permissions (
    panel_id uuid NOT NULL REFERENCES ticket_panel(id) ON DELETE CASCADE,
    role_id text NOT NULL,
    permissions integer NOT NULL, -- bitmask of permissions
    PRIMARY KEY (panel_id, role_id)
);

CREATE TABLE ticket_panel_buttons (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    panel_id uuid NOT NULL REFERENCES ticket_panel(id) ON DELETE CASCADE,
    open_message_embed_id uuid REFERENCES embeds(id) ON DELETE SET NULL,
    questions varchar(200)[] NOT NULL DEFAULT '{}' CHECK (cardinality(questions) <= 5),
    staff_roles text[] NOT NULL DEFAULT '{}',
    roles_add_on_open text[] NOT NULL DEFAULT '{}',
    roles_remove_on_open text[] NOT NULL DEFAULT '{}',
    roles_add_on_close text[] NOT NULL DEFAULT '{}',
    roles_remove_on_close text[] NOT NULL DEFAULT '{}',
    allow_account_apply integer NOT NULL DEFAULT 0, -- 0 means no, else amount of accounts to allow for application
    min_townhall_level integer,
    max_townhall_level integer,
    staff_private_thread boolean NOT NULL DEFAULT false,
    send_player_info_to_channel boolean NOT NULL DEFAULT false,
    send_player_info_to_private_thread boolean NOT NULL DEFAULT false,
    auto_transcript boolean NOT NULL DEFAULT true,
    staff_to_ping text[] DEFAULT '{}', -- if NULL, then no ping, if array is set, then ping those roles

    -- if any of these are NULL use the ticket panel settings, otherwise use these as overrides
    parent_channel_id text,
    open_category_id text,
    closed_category_id text,
    log_channel_id text,
    naming_convention text
);

CREATE TABLE tickets (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    server_id text NOT NULL REFERENCES servers(id) ON DELETE CASCADE,
    channel_id text NOT NULL UNIQUE,
    is_thread boolean NOT NULL DEFAULT false,
    status_id integer NOT NULL DEFAULT 0,
    number serial NOT NULL,
    panel_id uuid NOT NULL REFERENCES ticket_panel(id) ON DELETE CASCADE,
    applicant_accounts text[] NOT NULL DEFAULT '{}',
    created_at timestamptz NOT NULL DEFAULT now(),
    closed_at timestamptz
);

CREATE TABLE reminders (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    server_id text NOT NULL REFERENCES servers(id) ON DELETE CASCADE,
    type integer NOT NULL,
    clan_tag text NOT NULL,
    webhook_token text NOT NULL,
    thread_id text,
    minutes_remaining integer NOT NULL,
    custom_text text NOT NULL DEFAULT '',
    clan_roles integer NOT NULL DEFAULT 0, -- is bitmask
    townhalls integer[],
    war_types integer NOT NULL DEFAULT 0, -- is bitmask
    trigger_threshold integer
);

-- +goose Down
