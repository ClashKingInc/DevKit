-- +goose Up
CREATE EXTENSION IF NOT EXISTS timescaledb;

CREATE TABLE public.battlelogs (
    battle_id uuid NOT NULL,
    player_tag text NOT NULL,
    player_th smallint NOT NULL,
    opponent_tag text NOT NULL,
    opponent_th smallint NOT NULL,
    battle_type text NOT NULL,
    attack boolean NOT NULL,
    stars smallint NOT NULL,
    destruction_percentage smallint NOT NULL,
    gold integer NOT NULL,
    elixir integer NOT NULL,
    dark_elixir integer NOT NULL,
    "timestamp" timestamp with time zone NOT NULL,
    army_items text[] NOT NULL,
    army_counts jsonb NOT NULL,
    player_name text NOT NULL,
    opponent_name text NOT NULL,
    duration integer NOT NULL,
    army_share_code text NOT NULL
);

SELECT create_hypertable(
    'battlelogs',
    'timestamp',
    chunk_time_interval => INTERVAL '1 day',
    create_default_indexes => FALSE,
    if_not_exists => TRUE
);

ALTER TABLE public.battlelogs SET (
    timescaledb.compress,
    timescaledb.compress_orderby = 'timestamp DESC',
    timescaledb.compress_segmentby = 'player_tag'
);

SELECT add_compression_policy(
    'battlelogs',
    compress_after => INTERVAL '35 days',
    if_not_exists => TRUE
);


--
-- Name: tracking_process_stats; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tracking_process_stats (
    interval_start timestamp with time zone NOT NULL,
    interval_end timestamp with time zone NOT NULL,
    run_id bigint NOT NULL,
    script text NOT NULL,
    process_started_at timestamp with time zone NOT NULL,
    uptime_ms double precision NOT NULL,
    goroutines integer NOT NULL,
    alloc_bytes bigint NOT NULL,
    heap_objects bigint NOT NULL,
    gc_cycles bigint NOT NULL
);

SELECT create_hypertable(
    'tracking_process_stats',
    'interval_end',
    chunk_time_interval => INTERVAL '1 day',
    create_default_indexes => FALSE,
    if_not_exists => TRUE
);

SELECT add_retention_policy('tracking_process_stats', INTERVAL '14 days', if_not_exists => TRUE);


--
-- Name: tracking_domain_stats; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tracking_domain_stats (
    interval_start timestamp with time zone NOT NULL,
    interval_end timestamp with time zone NOT NULL,
    run_id bigint NOT NULL,
    script text NOT NULL,
    name text NOT NULL,
    last_success timestamp with time zone,
    last_error text,
    requests bigint NOT NULL,
    writes bigint NOT NULL,
    errors bigint NOT NULL,
    request_latency_ms double precision NOT NULL,
    queue_depth integer NOT NULL,
    healthy boolean NOT NULL,
    last_ready_change timestamp with time zone,
    processing_count bigint NOT NULL,
    total_process_time_ms double precision NOT NULL,
    store_batches bigint NOT NULL,
    store_rows_requested bigint NOT NULL,
    store_rows_affected bigint NOT NULL,
    store_duration_ms double precision NOT NULL,
    target_count integer DEFAULT 0 NOT NULL,
    target_cycle bigint DEFAULT 0 NOT NULL,
    target_processed integer DEFAULT 0 NOT NULL
);

SELECT create_hypertable(
    'tracking_domain_stats',
    'interval_end',
    chunk_time_interval => INTERVAL '1 day',
    create_default_indexes => FALSE,
    if_not_exists => TRUE
);

SELECT add_retention_policy('tracking_domain_stats', INTERVAL '14 days', if_not_exists => TRUE);


--
-- Name: join_leave_history; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.join_leave_history (
    "time" timestamp with time zone DEFAULT now() NOT NULL,
    "type" text NOT NULL,
    clan_tag text NOT NULL,
    player_tag text NOT NULL,
    townhall_level smallint DEFAULT 0 NOT NULL,
    player_name text,
    CONSTRAINT join_leave_history_type_check CHECK (("type" = ANY (ARRAY['join'::text, 'leave'::text])))
);

SELECT create_hypertable(
    'join_leave_history',
    'time',
    chunk_time_interval => INTERVAL '3 months',
    create_default_indexes => FALSE,
    if_not_exists => TRUE
);


--
-- Name: clan_change_history; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.clan_change_history (
    event_time timestamp with time zone DEFAULT now() NOT NULL,
    clan_tag text NOT NULL,
    change_type text NOT NULL,
    previous_value jsonb NOT NULL,
    current_value jsonb NOT NULL,
    CONSTRAINT clan_change_history_change_type_check CHECK ((change_type = ANY (ARRAY['description'::text, 'clan_level'::text, 'cwl_league_id'::text, 'capital_league_id'::text])))
);

SELECT create_hypertable(
    'clan_change_history',
    'event_time',
    create_default_indexes => FALSE,
    if_not_exists => TRUE
);


--
-- Name: api_tokens; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.api_tokens (
    token_hash text NOT NULL,
    user_id text DEFAULT ''::text NOT NULL,
    server_id text,
    token_type text DEFAULT ''::text NOT NULL,
    expires_at timestamp with time zone,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: audit_history; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.audit_history (
    id uuid DEFAULT uuidv7() NOT NULL,
    resource_id uuid,
    resource_type text NOT NULL,
    description text NOT NULL,
    user_id text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: auth_discord_tokens; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.auth_discord_tokens (
    user_id text NOT NULL,
    device_id text DEFAULT ''::text NOT NULL,
    access_token_ciphertext text NOT NULL,
    refresh_token_ciphertext text,
    expires_at timestamp with time zone,
    scopes text[] DEFAULT '{}'::text[] NOT NULL,
    data jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: auth_email_verifications; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.auth_email_verifications (
    email_hash text NOT NULL,
    verification_code_hash text NOT NULL,
    user_id text,
    expires_at timestamp with time zone NOT NULL,
    data jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: auth_password_reset_tokens; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.auth_password_reset_tokens (
    id uuid DEFAULT uuidv7() NOT NULL,
    email_hash text NOT NULL,
    reset_code_hash text NOT NULL,
    user_id text,
    used boolean DEFAULT false NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    data jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: auth_refresh_tokens; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.auth_refresh_tokens (
    token_hash text NOT NULL,
    user_id text NOT NULL,
    device_id text DEFAULT ''::text NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    revoked_at timestamp with time zone,
    data jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: auth_users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.auth_users (
    user_id text NOT NULL,
    email_hash text,
    discord_user_id text,
    username text DEFAULT ''::text NOT NULL,
    display_name text DEFAULT ''::text NOT NULL,
    password_hash text,
    verified boolean DEFAULT false NOT NULL,
    profile jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    data jsonb DEFAULT '{}'::jsonb NOT NULL
);


--
-- Name: autoboards; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.autoboards (
    id uuid DEFAULT uuidv7() NOT NULL,
    identifier text,
    server_id text NOT NULL,
    type text DEFAULT ''::text NOT NULL,
    channel_id text,
    webhook_id text,
    thread_id text,
    interval_minutes integer,
    next_run_at timestamp with time zone,
    enabled boolean DEFAULT true NOT NULL,
    data jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: bases; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.bases (
    id uuid DEFAULT uuidv7() NOT NULL,
    message_id text NOT NULL,
    base_link text NOT NULL,
    downloads integer DEFAULT 0 NOT NULL,
    upvotes integer DEFAULT 0 NOT NULL,
    downvotes integer DEFAULT 0 NOT NULL,
    downloaders text[] DEFAULT '{}'::text[] NOT NULL,
    whitelisted_role_id text,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: basic_clan; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.basic_clan (
    tag text NOT NULL,
    name text NOT NULL,
    description text DEFAULT ''::text NOT NULL,
    clan_level integer DEFAULT 0 NOT NULL,
    location_id integer,
    cwl_league_id integer DEFAULT 48000000 NOT NULL,
    capital_league_id integer,
    public_war_log boolean NOT NULL,
    war_wins integer NOT NULL,
    war_win_streak integer DEFAULT 0 NOT NULL,
    clan_points integer DEFAULT 0 NOT NULL,
    member_count integer NOT NULL,
    badge_token text NOT NULL,
    troops_donated integer NOT NULL,
    troops_received integer NOT NULL,
    members jsonb DEFAULT '[]'::jsonb NOT NULL,
    last_active timestamp with time zone
);


--
-- Name: clan_records; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.clan_records (
    tag text NOT NULL,
    clan_points integer DEFAULT 0 NOT NULL,
    clan_points_at timestamp with time zone,
    war_win_streak integer DEFAULT 0 NOT NULL,
    war_win_streak_at timestamp with time zone,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: basic_player; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.basic_player (
    tag text NOT NULL,
    name text NOT NULL,
    league_id integer,
    clan_tag text,
    townhall_level integer NOT NULL,
    battlelogs_tracking_ttl timestamp with time zone,
    trophies integer DEFAULT 0 NOT NULL
);


--
-- Name: bot_settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.bot_settings (
    type text NOT NULL,
    data jsonb DEFAULT '{}'::jsonb NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: bot_sync_status; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.bot_sync_status (
    bot_id text NOT NULL,
    cluster_id integer NOT NULL,
    shard_ids integer[] DEFAULT '{}'::integer[] NOT NULL,
    server_count integer DEFAULT 0 NOT NULL,
    member_count integer DEFAULT 0 NOT NULL,
    clan_count integer DEFAULT 0 NOT NULL,
    servers jsonb DEFAULT '[]'::jsonb NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    data jsonb DEFAULT '{}'::jsonb NOT NULL
);


--
-- Name: capital_raid_cache; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.capital_raid_cache (
    clan_tag text NOT NULL,
    start_time timestamp with time zone,
    end_time timestamp with time zone,
    state text DEFAULT ''::text NOT NULL,
    data jsonb NOT NULL,
    raw jsonb NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: capital_raid_members; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.capital_raid_members (
    clan_tag text NOT NULL,
    start_time timestamp with time zone NOT NULL,
    player_tag text NOT NULL,
    player_name text DEFAULT ''::text NOT NULL,
    attack_count integer DEFAULT 0 NOT NULL,
    attack_limit integer DEFAULT 0 NOT NULL,
    bonus_attack_limit integer DEFAULT 0 NOT NULL,
    capital_resources_looted integer DEFAULT 0 NOT NULL,
    data jsonb DEFAULT '{}'::jsonb NOT NULL
);


--
-- Name: clan_categories; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.clan_categories (
    id uuid DEFAULT uuidv7() NOT NULL,
    server_id text NOT NULL,
    name text NOT NULL
);


--
-- Name: clan_leaderboards; Type: MATERIALIZED VIEW; Schema: public; Owner: -
--

CREATE MATERIALIZED VIEW public.clan_leaderboards AS
 SELECT c.tag,
    c.location_id,
    rank() OVER (ORDER BY c.troops_donated DESC, c.tag) AS donated_rank,
    rank() OVER (ORDER BY c.troops_received DESC, c.tag) AS received_rank,
    rank() OVER (ORDER BY c.war_wins DESC, c.tag) AS war_wins_rank,
    CASE
        WHEN c.war_wins >= 50 THEN rank() OVER (ORDER BY
        CASE
            WHEN c.war_wins >= 50 THEN c.war_win_streak
            ELSE NULL::integer
        END DESC NULLS LAST, c.tag)
        ELSE NULL::bigint
    END AS war_win_streak_rank,
    rank() OVER (PARTITION BY c.location_id ORDER BY c.troops_donated DESC, c.tag) AS location_donated_rank,
    rank() OVER (PARTITION BY c.location_id ORDER BY c.troops_received DESC, c.tag) AS location_received_rank,
    rank() OVER (PARTITION BY c.location_id ORDER BY c.war_wins DESC, c.tag) AS location_war_wins_rank
   FROM public.basic_clan c
  WITH NO DATA;


--
-- Name: clan_logs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.clan_logs (
    server_id text NOT NULL,
    clan_tag text NOT NULL,
    type text NOT NULL,
    webhook_token text NOT NULL,
    thread_id text
);


--
-- Name: clan_position_roles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.clan_position_roles (
    id uuid DEFAULT uuidv7() NOT NULL,
    server_id text NOT NULL,
    clan_tag text,
    "position" text NOT NULL,
    role_id text NOT NULL,
    CONSTRAINT clan_position_roles_position_check CHECK (("position" = ANY (ARRAY['member'::text, 'elder'::text, 'coleader'::text, 'leader'::text])))
);


--
-- Name: clan_rankings_current; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.clan_rankings_current (
    clan_tag text NOT NULL,
    country_code text,
    country_name text,
    rank integer,
    global_rank integer,
    local_rank integer,
    data jsonb DEFAULT '{}'::jsonb NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: clan_season_stats; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.clan_season_stats (
    clan_tag text NOT NULL,
    season text NOT NULL,
    donations jsonb DEFAULT '{}'::jsonb NOT NULL,
    clan_games jsonb DEFAULT '{}'::jsonb NOT NULL,
    activity jsonb DEFAULT '{}'::jsonb NOT NULL,
    data jsonb DEFAULT '{}'::jsonb NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: current_war_timers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.current_war_timers (
    player_tag text NOT NULL,
    war_id text NOT NULL,
    clan_tag text NOT NULL,
    opponent_tag text NOT NULL,
    end_time timestamp with time zone NOT NULL,
    data jsonb DEFAULT '{}'::jsonb NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: custom_embeds; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.custom_embeds (
    server_id text NOT NULL,
    name text NOT NULL,
    data jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: cwl_groups; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.cwl_groups (
    cwl_id text NOT NULL,
    season text NOT NULL,
    cwl_league_id integer NOT NULL,
    clan_tags text[] NOT NULL,
    rounds jsonb NOT NULL,
    data jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: embeds; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.embeds (
    id uuid DEFAULT uuidv7() NOT NULL,
    server_id text NOT NULL,
    name text NOT NULL,
    data jsonb NOT NULL
);


--
-- Name: giveaways; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.giveaways (
    id text NOT NULL,
    server_id text NOT NULL,
    prize text NOT NULL,
    channel_id text,
    status text NOT NULL,
    start_time timestamp with time zone NOT NULL,
    end_time timestamp with time zone NOT NULL,
    winners integer NOT NULL,
    mentions text[] DEFAULT '{}'::text[] NOT NULL,
    text_above_embed text DEFAULT ''::text NOT NULL,
    text_in_embed text DEFAULT ''::text NOT NULL,
    text_on_end text DEFAULT ''::text NOT NULL,
    image_url text,
    profile_picture_required boolean DEFAULT false NOT NULL,
    coc_account_required boolean DEFAULT false NOT NULL,
    roles_mode text DEFAULT 'none'::text NOT NULL,
    roles text[] DEFAULT '{}'::text[] NOT NULL,
    boosters jsonb DEFAULT '[]'::jsonb NOT NULL,
    entries jsonb DEFAULT '[]'::jsonb NOT NULL,
    winners_list jsonb DEFAULT '[]'::jsonb NOT NULL,
    updated boolean DEFAULT false NOT NULL,
    message_id text,
    event_pending text,
    event_pending_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    data jsonb DEFAULT '{}'::jsonb NOT NULL,
    CONSTRAINT giveaways_status_check CHECK ((status = ANY (ARRAY['scheduled'::text, 'ongoing'::text, 'ended'::text])))
);


--
-- Name: hall_counts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.hall_counts (
    village_type integer NOT NULL,
    level integer NOT NULL,
    total_count integer NOT NULL
);


--
-- Name: hall_roles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.hall_roles (
    server_id text NOT NULL,
    role_id text NOT NULL,
    hall_level integer NOT NULL,
    is_townhall boolean NOT NULL
);


--
-- Name: leaderboard_snapshot_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.leaderboard_snapshot_items (
    kind text NOT NULL,
    location_id text NOT NULL,
    date date CONSTRAINT leaderboard_snapshot_items_snapshot_on_not_null NOT NULL,
    tag text NOT NULL,
    name text NOT NULL,
    rank integer NOT NULL,
    data jsonb NOT NULL
);


--
-- Name: league_roles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.league_roles (
    server_id text NOT NULL,
    league_id integer NOT NULL,
    role_id text NOT NULL
);


--
-- Name: legend_history_snapshots; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.legend_history_snapshots (
    season text NOT NULL,
    player_tag text NOT NULL,
    rank integer NOT NULL,
    trophies integer DEFAULT 0 NOT NULL,
    data jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: legend_rankings_current; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.legend_rankings_current (
    player_tag text NOT NULL,
    rank integer NOT NULL,
    trophies integer DEFAULT 0 NOT NULL,
    player_name text DEFAULT ''::text NOT NULL,
    clan_tag text,
    clan_name text DEFAULT ''::text NOT NULL,
    data jsonb DEFAULT '{}'::jsonb NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: mobile_live_activities; Type: TABLE; Schema: public; Owner: -
--

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
    CONSTRAINT mobile_live_activities_environment_check CHECK ((environment = ANY (ARRAY['sandbox'::text, 'production'::text]))),
    CONSTRAINT mobile_live_activities_status_check CHECK ((status = ANY (ARRAY['active'::text, 'ended'::text, 'stale'::text, 'disabled'::text])))
);


--
-- Name: mobile_push_devices; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.mobile_push_devices (
    id uuid DEFAULT uuidv7() NOT NULL,
    user_id text NOT NULL,
    device_id text NOT NULL,
    platform text NOT NULL,
    provider text NOT NULL,
    environment text DEFAULT 'production'::text NOT NULL,
    token_ciphertext text NOT NULL,
    token_hash text NOT NULL,
    app_version text DEFAULT ''::text NOT NULL,
    build_number text DEFAULT ''::text NOT NULL,
    os_version text DEFAULT ''::text NOT NULL,
    device_model text DEFAULT ''::text NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    last_seen_at timestamp with time zone DEFAULT now() NOT NULL,
    disabled_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT mobile_push_devices_environment_check CHECK ((environment = ANY (ARRAY['sandbox'::text, 'production'::text]))),
    CONSTRAINT mobile_push_devices_platform_check CHECK ((platform = ANY (ARRAY['ios'::text, 'android'::text]))),
    CONSTRAINT mobile_push_devices_provider_check CHECK ((provider = ANY (ARRAY['apns'::text, 'fcm'::text])))
);


--
-- Name: mobile_war_subscriptions; Type: TABLE; Schema: public; Owner: -
--

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
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: one_time_login_tokens; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.one_time_login_tokens (
    id uuid DEFAULT uuidv7() NOT NULL,
    user_id text NOT NULL,
    token_hash text NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    used_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: open_tickets; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.open_tickets (
    server_id text NOT NULL,
    channel_id text NOT NULL,
    panel_name text,
    status text DEFAULT 'open'::text NOT NULL,
    user_id text,
    set_clan text,
    data jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: player_current_stats; Type: TABLE; Schema: public; Owner: -
--

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
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: player_equipment; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.player_equipment (
    player_tag text NOT NULL,
    name text NOT NULL,
    level integer NOT NULL,
    max_level integer NOT NULL,
    village text DEFAULT ''::text NOT NULL,
    rarity text DEFAULT ''::text NOT NULL
);


--
-- Name: player_heroes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.player_heroes (
    player_tag text NOT NULL,
    name text NOT NULL,
    level integer NOT NULL,
    max_level integer NOT NULL,
    village text DEFAULT ''::text NOT NULL
);


--
-- Name: player_history_events; Type: TABLE; Schema: public; Owner: -
--

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


--
-- Name: player_links; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.player_links (
    tag text NOT NULL,
    is_main boolean DEFAULT false NOT NULL,
    order_index integer DEFAULT 0 NOT NULL,
    is_verified boolean DEFAULT false NOT NULL,
    source text NOT NULL,
    added_at timestamp with time zone DEFAULT now() NOT NULL,
    user_id text,
    verified_at timestamp with time zone,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: player_links_settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.player_links_settings (
    tag text NOT NULL,
    server_id text NOT NULL,
    is_main boolean DEFAULT false NOT NULL
);


--
-- Name: player_online_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.player_online_events (
    seen_at timestamp with time zone DEFAULT now() NOT NULL,
    tag text NOT NULL,
    clan_tag text NOT NULL,
    townhall_level smallint NOT NULL
);

SELECT create_hypertable(
    'player_online_events',
    'seen_at',
    create_default_indexes => FALSE,
    if_not_exists => TRUE
);


--
-- Name: player_profile_changes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.player_profile_changes (
    event_time timestamp with time zone DEFAULT now() NOT NULL,
    player_tag text NOT NULL,
    clan_tag text DEFAULT ''::text NOT NULL,
    townhall_level integer DEFAULT 0 NOT NULL,
    change_type text NOT NULL,
    previous_value jsonb,
    current_value jsonb
);

SELECT create_hypertable(
    'player_profile_changes',
    'event_time',
    chunk_time_interval => INTERVAL '7 days',
    create_default_indexes => FALSE,
    if_not_exists => TRUE
);


--
-- Name: player_rankings_current; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.player_rankings_current (
    player_tag text NOT NULL,
    country_code text,
    country_name text,
    rank integer,
    global_rank integer,
    local_rank integer,
    data jsonb DEFAULT '{}'::jsonb NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: player_season_stats; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.player_season_stats (
    player_tag text NOT NULL,
    season text NOT NULL,
    clan_tag text DEFAULT ''::text NOT NULL,
    donated integer DEFAULT 0 NOT NULL,
    received integer DEFAULT 0 NOT NULL,
    capital_gold_donos integer DEFAULT 0 NOT NULL,
    activity_score integer DEFAULT 0 NOT NULL,
    last_online_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    name text DEFAULT ''::text NOT NULL,
    townhall_level integer,
    donations jsonb DEFAULT '{}'::jsonb NOT NULL,
    clan_games jsonb DEFAULT '{}'::jsonb NOT NULL,
    activity jsonb DEFAULT '{}'::jsonb NOT NULL,
    data jsonb DEFAULT '{}'::jsonb NOT NULL
);


--
-- Name: player_spells; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.player_spells (
    player_tag text NOT NULL,
    name text NOT NULL,
    level integer NOT NULL,
    max_level integer NOT NULL,
    village text DEFAULT ''::text NOT NULL
);


--
-- Name: player_troops; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.player_troops (
    player_tag text NOT NULL,
    name text NOT NULL,
    level integer NOT NULL,
    max_level integer NOT NULL,
    village text DEFAULT ''::text NOT NULL,
    super_troop_is_active boolean DEFAULT false NOT NULL
);


--
-- Name: raid_weekends; Type: TABLE; Schema: public; Owner: -
--

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
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: ranked_league_group_members; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ranked_league_group_members (
    season_id bigint NOT NULL,
    group_tag text NOT NULL,
    league_tier_id integer NOT NULL,
    player_tag text NOT NULL,
    player_name text NOT NULL,
    clan_tag text,
    clan_name text,
    placement integer NOT NULL,
    league_trophies integer NOT NULL,
    attack_win_count integer NOT NULL,
    attack_lose_count integer NOT NULL,
    defense_win_count integer NOT NULL,
    defense_lose_count integer NOT NULL
);


--
-- Name: ranking_snapshots; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ranking_snapshots (
    ranking_type text NOT NULL,
    location text NOT NULL,
    snapshot_date text NOT NULL,
    data jsonb DEFAULT '{}'::jsonb NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: reminders; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.reminders (
    id uuid DEFAULT uuidv7() NOT NULL,
    server_id text NOT NULL,
    type integer NOT NULL,
    clan_tag text NOT NULL,
    webhook_token text NOT NULL,
    thread_id text,
    minutes_remaining integer NOT NULL,
    custom_text text DEFAULT ''::text NOT NULL,
    clan_roles integer DEFAULT 0 NOT NULL,
    townhalls integer[],
    war_types integer DEFAULT 0 NOT NULL,
    trigger_threshold integer,
    type_name text,
    channel_id text,
    trigger_time text,
    roles text[] DEFAULT '{}'::text[] NOT NULL,
    war_type_names text[] DEFAULT '{}'::text[] NOT NULL,
    point_threshold jsonb,
    attack_threshold jsonb,
    roster_id text,
    ping_type text,
    data jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: role_bindings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.role_bindings (
    id uuid DEFAULT uuidv7() NOT NULL,
    server_id text NOT NULL,
    role_type text NOT NULL,
    role_key text DEFAULT ''::text NOT NULL,
    role_id text NOT NULL,
    data jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: role_ignore_bindings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.role_ignore_bindings (
    server_id text NOT NULL,
    role_id text NOT NULL,
    data jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: roster_automation_rules; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.roster_automation_rules (
    automation_id text NOT NULL,
    server_id text NOT NULL,
    group_id text,
    enabled boolean DEFAULT true NOT NULL,
    trigger_type text DEFAULT ''::text NOT NULL,
    data jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: roster_groups; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.roster_groups (
    id uuid DEFAULT uuidv7() NOT NULL,
    server_id text NOT NULL,
    name text NOT NULL,
    group_id text,
    description text DEFAULT ''::text NOT NULL,
    data jsonb DEFAULT '{}'::jsonb NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: roster_members; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.roster_members (
    tag text NOT NULL,
    roster_id uuid NOT NULL,
    roster_group_id uuid
);


--
-- Name: roster_signup_categories; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.roster_signup_categories (
    custom_id text NOT NULL,
    server_id text NOT NULL,
    name text DEFAULT ''::text NOT NULL,
    description text DEFAULT ''::text NOT NULL,
    sort_order integer DEFAULT 0 NOT NULL,
    data jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: rosters; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.rosters (
    id uuid DEFAULT uuidv7() NOT NULL,
    server_id text NOT NULL,
    linked_clan_tag text NOT NULL,
    title text NOT NULL,
    description text NOT NULL,
    max_size integer NOT NULL,
    minimum_townhall integer,
    maximum_townhall integer,
    image_url text,
    signup_role_id text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    custom_id text,
    group_id text,
    clan_tag text,
    alias text DEFAULT ''::text NOT NULL,
    members jsonb DEFAULT '[]'::jsonb NOT NULL,
    data jsonb DEFAULT '{}'::jsonb NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: search_groups; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.search_groups (
    group_id text NOT NULL,
    user_id text NOT NULL,
    name text NOT NULL,
    type text NOT NULL,
    tags text[] DEFAULT '{}'::text[] NOT NULL,
    data jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: user_bookmarks; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_bookmarks (
    user_id text NOT NULL,
    entity_type text NOT NULL,
    tag text NOT NULL,
    order_index integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT user_bookmarks_entity_type_check CHECK ((entity_type = ANY (ARRAY['player'::text, 'clan'::text])))
);


--
-- Name: user_recent_searches; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_recent_searches (
    user_id text NOT NULL,
    entity_type text NOT NULL,
    tag text NOT NULL,
    data jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT user_recent_searches_entity_type_check CHECK ((entity_type = ANY (ARRAY['player'::text, 'clan'::text])))
);

SELECT create_hypertable(
    'user_recent_searches',
    'created_at',
    chunk_time_interval => INTERVAL '7 days',
    create_default_indexes => FALSE,
    if_not_exists => TRUE
);

SELECT add_retention_policy('user_recent_searches', INTERVAL '90 days', if_not_exists => TRUE);


--
-- Name: server_bans; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.server_bans (
    server_id text NOT NULL,
    player_tag text NOT NULL,
    player_name text DEFAULT ''::text NOT NULL,
    reason text DEFAULT ''::text NOT NULL,
    added_by text DEFAULT ''::text NOT NULL,
    edited_by jsonb DEFAULT '[]'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    data jsonb DEFAULT '{}'::jsonb NOT NULL
);


--
-- Name: server_clans; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.server_clans (
    tag text NOT NULL,
    server_id text NOT NULL,
    category_id uuid,
    clan_channel_id text,
    name text DEFAULT ''::text NOT NULL,
    abbreviation text DEFAULT ''::text NOT NULL,
    logs_config jsonb DEFAULT '{}'::jsonb NOT NULL,
    countdowns jsonb DEFAULT '{}'::jsonb NOT NULL,
    data jsonb DEFAULT '{}'::jsonb NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: server_role_settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.server_role_settings (
    server_id text NOT NULL,
    family_roles jsonb DEFAULT '{}'::jsonb NOT NULL,
    not_family_roles jsonb DEFAULT '{}'::jsonb NOT NULL,
    family_exclusive_roles jsonb DEFAULT '{}'::jsonb NOT NULL,
    ignored_roles jsonb DEFAULT '[]'::jsonb NOT NULL,
    data jsonb DEFAULT '{}'::jsonb NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: servers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.servers (
    id text NOT NULL,
    name text NOT NULL,
    joined_at timestamp with time zone DEFAULT now() NOT NULL,
    left_at timestamp with time zone,
    embed_color text,
    logs_config jsonb DEFAULT '{}'::jsonb NOT NULL,
    status_roles jsonb DEFAULT '{}'::jsonb NOT NULL,
    countdowns jsonb DEFAULT '{}'::jsonb NOT NULL,
    data jsonb DEFAULT '{}'::jsonb NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: short_links; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.short_links (
    id text NOT NULL,
    url text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    data jsonb DEFAULT '{}'::jsonb NOT NULL
);


--
-- Name: strikes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.strikes (
    id text NOT NULL,
    server_id text NOT NULL,
    tag text NOT NULL,
    date_created timestamp with time zone NOT NULL,
    reason text NOT NULL,
    added_by text NOT NULL,
    strike_weight integer,
    rollover_date timestamp with time zone,
    image text,
    data jsonb DEFAULT '{}'::jsonb NOT NULL
);


--
-- Name: ticket_panel; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ticket_panel (
    id uuid DEFAULT uuidv7() NOT NULL,
    server_id text NOT NULL,
    name text NOT NULL,
    description text NOT NULL,
    parent_channel_id text,
    open_category_id text,
    closed_category_id text,
    log_channel_id text,
    naming_convention text,
    embed_id uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: ticket_panel_buttons; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ticket_panel_buttons (
    id uuid DEFAULT uuidv7() NOT NULL,
    panel_id uuid NOT NULL,
    open_message_embed_id uuid,
    questions character varying(200)[] DEFAULT '{}'::character varying[] NOT NULL,
    staff_roles text[] DEFAULT '{}'::text[] NOT NULL,
    roles_add_on_open text[] DEFAULT '{}'::text[] NOT NULL,
    roles_remove_on_open text[] DEFAULT '{}'::text[] NOT NULL,
    roles_add_on_close text[] DEFAULT '{}'::text[] NOT NULL,
    roles_remove_on_close text[] DEFAULT '{}'::text[] NOT NULL,
    allow_account_apply integer DEFAULT 0 NOT NULL,
    min_townhall_level integer,
    max_townhall_level integer,
    staff_private_thread boolean DEFAULT false NOT NULL,
    send_player_info_to_channel boolean DEFAULT false NOT NULL,
    send_player_info_to_private_thread boolean DEFAULT false CONSTRAINT ticket_panel_buttons_send_player_info_to_private_threa_not_null NOT NULL,
    auto_transcript boolean DEFAULT true NOT NULL,
    staff_to_ping text[] DEFAULT '{}'::text[],
    parent_channel_id text,
    open_category_id text,
    closed_category_id text,
    log_channel_id text,
    naming_convention text,
    CONSTRAINT ticket_panel_buttons_questions_check CHECK ((cardinality(questions) <= 5))
);


--
-- Name: ticket_panel_staff_permissions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ticket_panel_staff_permissions (
    panel_id uuid NOT NULL,
    role_id text NOT NULL,
    permissions integer NOT NULL
);


--
-- Name: ticket_panels; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ticket_panels (
    server_id text NOT NULL,
    name text NOT NULL,
    components jsonb DEFAULT '[]'::jsonb NOT NULL,
    data jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: tickets; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tickets (
    id uuid DEFAULT uuidv7() NOT NULL,
    server_id text NOT NULL,
    channel_id text NOT NULL,
    is_thread boolean DEFAULT false NOT NULL,
    status_id integer DEFAULT 0 NOT NULL,
    number integer NOT NULL,
    panel_id uuid NOT NULL,
    applicant_accounts text[] DEFAULT '{}'::text[] NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    closed_at timestamp with time zone
);


--
-- Name: tickets_number_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.tickets_number_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: tickets_number_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.tickets_number_seq OWNED BY public.tickets.number;




--
-- Name: tracked_player_targets; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tracked_player_targets (
    tag text NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    source text DEFAULT 'manual'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: tracking_stats_run_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.tracking_stats_run_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: user_settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_settings (
    user_id text NOT NULL,
    search jsonb DEFAULT '{}'::jsonb NOT NULL,
    app jsonb DEFAULT '{}'::jsonb NOT NULL,
    data jsonb DEFAULT '{}'::jsonb NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: war_attacks; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.war_attacks (
    war_id text NOT NULL,
    war_end_time timestamp with time zone NOT NULL,
    war_type text NOT NULL,
    war_size integer NOT NULL,
    attacking_clan_tag text NOT NULL,
    defending_clan_tag text NOT NULL,
    attacker_tag text NOT NULL,
    attacker_name text DEFAULT ''::text NOT NULL,
    defender_tag text NOT NULL,
    defender_name text DEFAULT ''::text NOT NULL,
    attacker_townhall smallint NOT NULL,
    defender_townhall smallint NOT NULL,
    attacker_map_position smallint NOT NULL,
    defender_map_position smallint NOT NULL,
    stars smallint NOT NULL,
    destruction_percentage smallint NOT NULL,
    duration integer NOT NULL,
    attack_order integer NOT NULL,
    battle_modifier text DEFAULT 'none'::text NOT NULL
);

SELECT create_hypertable(
    'war_attacks',
    'war_end_time',
    chunk_time_interval => INTERVAL '3 months',
    create_default_indexes => FALSE,
    if_not_exists => TRUE
);


--
-- Name: war_members; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.war_members (
    war_id text NOT NULL,
    war_end_time timestamp with time zone NOT NULL,
    clan_tag text NOT NULL,
    opponent_tag text NOT NULL,
    player_tag text NOT NULL,
    player_name text DEFAULT ''::text NOT NULL,
    townhall_level smallint NOT NULL,
    map_position smallint NOT NULL
);

SELECT create_hypertable(
    'war_members',
    'war_end_time',
    chunk_time_interval => INTERVAL '3 months',
    create_default_indexes => FALSE,
    if_not_exists => TRUE
);


--
-- Name: war_missed_attacks; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.war_missed_attacks (
    war_id text NOT NULL,
    war_end_time timestamp with time zone NOT NULL,
    clan_tag text NOT NULL,
    opponent_tag text NOT NULL,
    player_tag text NOT NULL,
    player_name text DEFAULT ''::text NOT NULL,
    townhall_level smallint NOT NULL,
    map_position smallint NOT NULL,
    expected_attacks smallint NOT NULL,
    attack_count smallint NOT NULL,
    missed_attacks smallint NOT NULL
);

SELECT create_hypertable(
    'war_missed_attacks',
    'war_end_time',
    chunk_time_interval => INTERVAL '3 months',
    create_default_indexes => FALSE,
    if_not_exists => TRUE
);


--
-- Name: war_league_counts; Type: MATERIALIZED VIEW; Schema: public; Owner: -
--

CREATE MATERIALIZED VIEW public.war_league_counts AS
 SELECT cwl_league_id,
    count(*) AS clan_count
   FROM public.basic_clan c
  GROUP BY cwl_league_id
  WITH NO DATA;


--
-- Name: war_schedule; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.war_schedule (
    schedule_key text NOT NULL,
    war_id text NOT NULL,
    source_clan_tag text NOT NULL,
    opponent_tag text NOT NULL,
    prep_time timestamp with time zone NOT NULL,
    end_time timestamp with time zone NOT NULL,
    next_run_at timestamp with time zone NOT NULL,
    war_tag text
);


--
-- Name: wars; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.wars (
    war_id text NOT NULL,
    clan_tag text NOT NULL,
    opponent_tag text NOT NULL,
    prep_time timestamp with time zone NOT NULL,
    start_time timestamp with time zone,
    end_time timestamp with time zone NOT NULL,
    size integer NOT NULL,
    attacks_per_member integer DEFAULT 1 NOT NULL,
    war_type text NOT NULL,
    state text NOT NULL,
    battle_modifier text DEFAULT 'none'::text NOT NULL,
    war_tag text,
    clan_name text DEFAULT ''::text NOT NULL,
    opponent_name text DEFAULT ''::text NOT NULL,
    clan_badge_token text DEFAULT ''::text NOT NULL,
    opponent_badge_token text DEFAULT ''::text NOT NULL,
    clan_level integer DEFAULT 0 NOT NULL,
    opponent_clan_level integer DEFAULT 0 NOT NULL,
    clan_attacks integer DEFAULT 0 NOT NULL,
    opponent_attacks integer DEFAULT 0 NOT NULL,
    clan_stars integer DEFAULT 0 NOT NULL,
    opponent_stars integer DEFAULT 0 NOT NULL,
    clan_destruction_percentage double precision DEFAULT 0 NOT NULL,
    opponent_destruction_percentage double precision DEFAULT 0 NOT NULL,
    CONSTRAINT wars_war_type_check CHECK ((war_type = ANY (ARRAY['random'::text, 'cwl'::text, 'friendly'::text])))
);


--
-- Name: tickets number; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE public.tickets ALTER COLUMN number SET DEFAULT nextval('public.tickets_number_seq'::regclass);


--
-- Name: api_tokens api_tokens_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.api_tokens
    ADD CONSTRAINT api_tokens_pkey PRIMARY KEY (token_hash);


--
-- Name: audit_history audit_history_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.audit_history
    ADD CONSTRAINT audit_history_pkey PRIMARY KEY (id);


--
-- Name: auth_discord_tokens auth_discord_tokens_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.auth_discord_tokens
    ADD CONSTRAINT auth_discord_tokens_pkey PRIMARY KEY (user_id, device_id);


--
-- Name: auth_email_verifications auth_email_verifications_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.auth_email_verifications
    ADD CONSTRAINT auth_email_verifications_pkey PRIMARY KEY (email_hash);


--
-- Name: auth_password_reset_tokens auth_password_reset_tokens_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.auth_password_reset_tokens
    ADD CONSTRAINT auth_password_reset_tokens_pkey PRIMARY KEY (id);


--
-- Name: auth_refresh_tokens auth_refresh_tokens_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.auth_refresh_tokens
    ADD CONSTRAINT auth_refresh_tokens_pkey PRIMARY KEY (token_hash);


--
-- Name: auth_users auth_users_email_hash_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.auth_users
    ADD CONSTRAINT auth_users_email_hash_key UNIQUE (email_hash);


--
-- Name: auth_users auth_users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.auth_users
    ADD CONSTRAINT auth_users_pkey PRIMARY KEY (user_id);


--
-- Name: autoboards autoboards_identifier_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.autoboards
    ADD CONSTRAINT autoboards_identifier_key UNIQUE (identifier);


--
-- Name: autoboards autoboards_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.autoboards
    ADD CONSTRAINT autoboards_pkey PRIMARY KEY (id);


--
-- Name: bases bases_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.bases
    ADD CONSTRAINT bases_pkey PRIMARY KEY (id);


--
-- Name: basic_clan basic_clan_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.basic_clan
    ADD CONSTRAINT basic_clan_pkey PRIMARY KEY (tag);


--
-- Name: clan_records clan_records_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.clan_records
    ADD CONSTRAINT clan_records_pkey PRIMARY KEY (tag);


--
-- Name: basic_player basic_player_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.basic_player
    ADD CONSTRAINT basic_player_pkey PRIMARY KEY (tag);


--
-- Name: battlelogs battlelogs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.battlelogs
    ADD CONSTRAINT battlelogs_pkey PRIMARY KEY (battle_id, "timestamp");


--
-- Name: bot_settings bot_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.bot_settings
    ADD CONSTRAINT bot_settings_pkey PRIMARY KEY (type);


--
-- Name: bot_sync_status bot_sync_status_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.bot_sync_status
    ADD CONSTRAINT bot_sync_status_pkey PRIMARY KEY (bot_id, cluster_id);


--
-- Name: capital_raid_cache capital_raid_cache_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.capital_raid_cache
    ADD CONSTRAINT capital_raid_cache_pkey PRIMARY KEY (clan_tag);


--
-- Name: capital_raid_members capital_raid_members_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.capital_raid_members
    ADD CONSTRAINT capital_raid_members_pkey PRIMARY KEY (clan_tag, start_time, player_tag);


--
-- Name: clan_categories clan_categories_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.clan_categories
    ADD CONSTRAINT clan_categories_pkey PRIMARY KEY (id);


--
-- Name: clan_categories clan_categories_server_id_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.clan_categories
    ADD CONSTRAINT clan_categories_server_id_name_key UNIQUE (server_id, name);


--
-- Name: clan_logs clan_logs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.clan_logs
    ADD CONSTRAINT clan_logs_pkey PRIMARY KEY (server_id, clan_tag, type);


--
-- Name: clan_position_roles clan_position_roles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.clan_position_roles
    ADD CONSTRAINT clan_position_roles_pkey PRIMARY KEY (id);


--
-- Name: clan_rankings_current clan_rankings_current_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.clan_rankings_current
    ADD CONSTRAINT clan_rankings_current_pkey PRIMARY KEY (clan_tag);


--
-- Name: clan_season_stats clan_season_stats_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.clan_season_stats
    ADD CONSTRAINT clan_season_stats_pkey PRIMARY KEY (clan_tag, season);


--
-- Name: current_war_timers current_war_timers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.current_war_timers
    ADD CONSTRAINT current_war_timers_pkey PRIMARY KEY (player_tag);


--
-- Name: custom_embeds custom_embeds_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.custom_embeds
    ADD CONSTRAINT custom_embeds_pkey PRIMARY KEY (server_id, name);


--
-- Name: cwl_groups cwl_groups_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.cwl_groups
    ADD CONSTRAINT cwl_groups_pkey PRIMARY KEY (cwl_id);


--
-- Name: embeds embeds_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.embeds
    ADD CONSTRAINT embeds_pkey PRIMARY KEY (id);


--
-- Name: giveaways giveaways_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.giveaways
    ADD CONSTRAINT giveaways_pkey PRIMARY KEY (id);


--
-- Name: hall_counts hall_counts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.hall_counts
    ADD CONSTRAINT hall_counts_pkey PRIMARY KEY (village_type, level);


--
-- Name: hall_roles hall_roles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.hall_roles
    ADD CONSTRAINT hall_roles_pkey PRIMARY KEY (server_id, hall_level, is_townhall);


--
-- Name: leaderboard_snapshot_items leaderboard_snapshot_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.leaderboard_snapshot_items
    ADD CONSTRAINT leaderboard_snapshot_items_pkey PRIMARY KEY (kind, location_id, date, tag);


--
-- Name: league_roles league_roles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.league_roles
    ADD CONSTRAINT league_roles_pkey PRIMARY KEY (server_id, league_id);


--
-- Name: legend_history_snapshots legend_history_snapshots_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.legend_history_snapshots
    ADD CONSTRAINT legend_history_snapshots_pkey PRIMARY KEY (season, player_tag);


--
-- Name: legend_rankings_current legend_rankings_current_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.legend_rankings_current
    ADD CONSTRAINT legend_rankings_current_pkey PRIMARY KEY (player_tag);


--
-- Name: mobile_live_activities mobile_live_activities_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.mobile_live_activities
    ADD CONSTRAINT mobile_live_activities_pkey PRIMARY KEY (id);


--
-- Name: mobile_live_activities mobile_live_activities_push_token_hash_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.mobile_live_activities
    ADD CONSTRAINT mobile_live_activities_push_token_hash_key UNIQUE (push_token_hash);


--
-- Name: mobile_live_activities mobile_live_activities_user_id_device_id_activity_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.mobile_live_activities
    ADD CONSTRAINT mobile_live_activities_user_id_device_id_activity_id_key UNIQUE (user_id, device_id, activity_id);


--
-- Name: mobile_push_devices mobile_push_devices_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.mobile_push_devices
    ADD CONSTRAINT mobile_push_devices_pkey PRIMARY KEY (id);


--
-- Name: mobile_push_devices mobile_push_devices_token_hash_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.mobile_push_devices
    ADD CONSTRAINT mobile_push_devices_token_hash_key UNIQUE (token_hash);


--
-- Name: mobile_push_devices mobile_push_devices_user_id_device_id_provider_environment_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.mobile_push_devices
    ADD CONSTRAINT mobile_push_devices_user_id_device_id_provider_environment_key UNIQUE (user_id, device_id, provider, environment);


--
-- Name: mobile_war_subscriptions mobile_war_subscriptions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.mobile_war_subscriptions
    ADD CONSTRAINT mobile_war_subscriptions_pkey PRIMARY KEY (id);


--
-- Name: mobile_war_subscriptions mobile_war_subscriptions_user_id_device_id_clan_tag_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.mobile_war_subscriptions
    ADD CONSTRAINT mobile_war_subscriptions_user_id_device_id_clan_tag_key UNIQUE (user_id, device_id, clan_tag);


--
-- Name: one_time_login_tokens one_time_login_tokens_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.one_time_login_tokens
    ADD CONSTRAINT one_time_login_tokens_pkey PRIMARY KEY (id);


--
-- Name: one_time_login_tokens one_time_login_tokens_token_hash_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.one_time_login_tokens
    ADD CONSTRAINT one_time_login_tokens_token_hash_key UNIQUE (token_hash);


--
-- Name: open_tickets open_tickets_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.open_tickets
    ADD CONSTRAINT open_tickets_pkey PRIMARY KEY (server_id, channel_id);


--
-- Name: player_current_stats player_current_stats_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.player_current_stats
    ADD CONSTRAINT player_current_stats_pkey PRIMARY KEY (player_tag);


--
-- Name: player_equipment player_equipment_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.player_equipment
    ADD CONSTRAINT player_equipment_pkey PRIMARY KEY (player_tag, name, village);


--
-- Name: player_heroes player_heroes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.player_heroes
    ADD CONSTRAINT player_heroes_pkey PRIMARY KEY (player_tag, name, village);


--
-- Name: player_links player_links_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.player_links
    ADD CONSTRAINT player_links_pkey PRIMARY KEY (tag);


--
-- Name: player_links_settings player_links_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.player_links_settings
    ADD CONSTRAINT player_links_settings_pkey PRIMARY KEY (tag, server_id);


--
-- Name: player_rankings_current player_rankings_current_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.player_rankings_current
    ADD CONSTRAINT player_rankings_current_pkey PRIMARY KEY (player_tag);


--
-- Name: player_season_stats player_season_stats_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.player_season_stats
    ADD CONSTRAINT player_season_stats_pkey PRIMARY KEY (player_tag, season, clan_tag);


--
-- Name: player_spells player_spells_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.player_spells
    ADD CONSTRAINT player_spells_pkey PRIMARY KEY (player_tag, name, village);


--
-- Name: player_troops player_troops_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.player_troops
    ADD CONSTRAINT player_troops_pkey PRIMARY KEY (player_tag, name, village);


--
-- Name: raid_weekends raid_weekends_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.raid_weekends
    ADD CONSTRAINT raid_weekends_pkey PRIMARY KEY (clan_tag, start_time);


--
-- Name: ranked_league_group_members ranked_league_group_members_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.ranked_league_group_members
    ADD CONSTRAINT ranked_league_group_members_pkey PRIMARY KEY (season_id, group_tag, player_tag);


--
-- Name: ranking_snapshots ranking_snapshots_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.ranking_snapshots
    ADD CONSTRAINT ranking_snapshots_pkey PRIMARY KEY (ranking_type, location, snapshot_date);


--
-- Name: reminders reminders_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.reminders
    ADD CONSTRAINT reminders_pkey PRIMARY KEY (id);


--
-- Name: role_bindings role_bindings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.role_bindings
    ADD CONSTRAINT role_bindings_pkey PRIMARY KEY (id);


--
-- Name: role_bindings role_bindings_server_id_role_type_role_key_role_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.role_bindings
    ADD CONSTRAINT role_bindings_server_id_role_type_role_key_role_id_key UNIQUE (server_id, role_type, role_key, role_id);


--
-- Name: role_ignore_bindings role_ignore_bindings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.role_ignore_bindings
    ADD CONSTRAINT role_ignore_bindings_pkey PRIMARY KEY (server_id, role_id);


--
-- Name: roster_automation_rules roster_automation_rules_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.roster_automation_rules
    ADD CONSTRAINT roster_automation_rules_pkey PRIMARY KEY (automation_id);


--
-- Name: roster_groups roster_groups_group_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.roster_groups
    ADD CONSTRAINT roster_groups_group_id_key UNIQUE (group_id);


--
-- Name: roster_groups roster_groups_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.roster_groups
    ADD CONSTRAINT roster_groups_pkey PRIMARY KEY (id);


--
-- Name: roster_groups roster_groups_server_id_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.roster_groups
    ADD CONSTRAINT roster_groups_server_id_name_key UNIQUE (server_id, name);


--
-- Name: roster_members roster_members_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.roster_members
    ADD CONSTRAINT roster_members_pkey PRIMARY KEY (tag, roster_id);


--
-- Name: roster_signup_categories roster_signup_categories_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.roster_signup_categories
    ADD CONSTRAINT roster_signup_categories_pkey PRIMARY KEY (custom_id);


--
-- Name: rosters rosters_custom_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.rosters
    ADD CONSTRAINT rosters_custom_id_key UNIQUE (custom_id);


--
-- Name: rosters rosters_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.rosters
    ADD CONSTRAINT rosters_pkey PRIMARY KEY (id);


--
-- Name: search_groups search_groups_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.search_groups
    ADD CONSTRAINT search_groups_pkey PRIMARY KEY (group_id);


--
-- Name: server_bans server_bans_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.server_bans
    ADD CONSTRAINT server_bans_pkey PRIMARY KEY (server_id, player_tag);


--
-- Name: server_clans server_clans_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.server_clans
    ADD CONSTRAINT server_clans_pkey PRIMARY KEY (tag, server_id);


--
-- Name: server_role_settings server_role_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.server_role_settings
    ADD CONSTRAINT server_role_settings_pkey PRIMARY KEY (server_id);


--
-- Name: servers servers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.servers
    ADD CONSTRAINT servers_pkey PRIMARY KEY (id);


--
-- Name: short_links short_links_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.short_links
    ADD CONSTRAINT short_links_pkey PRIMARY KEY (id);


--
-- Name: strikes strikes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.strikes
    ADD CONSTRAINT strikes_pkey PRIMARY KEY (id, server_id);


--
-- Name: ticket_panel_buttons ticket_panel_buttons_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.ticket_panel_buttons
    ADD CONSTRAINT ticket_panel_buttons_pkey PRIMARY KEY (id);


--
-- Name: ticket_panel ticket_panel_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.ticket_panel
    ADD CONSTRAINT ticket_panel_pkey PRIMARY KEY (id);


--
-- Name: ticket_panel_staff_permissions ticket_panel_staff_permissions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.ticket_panel_staff_permissions
    ADD CONSTRAINT ticket_panel_staff_permissions_pkey PRIMARY KEY (panel_id, role_id);


--
-- Name: ticket_panels ticket_panels_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.ticket_panels
    ADD CONSTRAINT ticket_panels_pkey PRIMARY KEY (server_id, name);


--
-- Name: tickets tickets_channel_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.tickets
    ADD CONSTRAINT tickets_channel_id_key UNIQUE (channel_id);


--
-- Name: tickets tickets_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.tickets
    ADD CONSTRAINT tickets_pkey PRIMARY KEY (id);


--
-- Name: tracked_player_targets tracked_player_targets_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.tracked_player_targets
    ADD CONSTRAINT tracked_player_targets_pkey PRIMARY KEY (tag);


--
-- Name: user_bookmarks user_bookmarks_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.user_bookmarks
    ADD CONSTRAINT user_bookmarks_pkey PRIMARY KEY (user_id, entity_type, tag);


--
-- Name: user_recent_searches user_recent_searches_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.user_recent_searches
    ADD CONSTRAINT user_recent_searches_pkey PRIMARY KEY (user_id, entity_type, tag, created_at);


--
-- Name: user_settings user_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.user_settings
    ADD CONSTRAINT user_settings_pkey PRIMARY KEY (user_id);


--
-- Name: war_attacks war_attacks_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.war_attacks
    ADD CONSTRAINT war_attacks_pkey PRIMARY KEY (war_id, war_end_time, attacker_tag, defender_tag, attack_order);


--
-- Name: war_members war_members_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.war_members
    ADD CONSTRAINT war_members_pkey PRIMARY KEY (war_id, war_end_time, clan_tag, player_tag);


--
-- Name: war_missed_attacks war_missed_attacks_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.war_missed_attacks
    ADD CONSTRAINT war_missed_attacks_pkey PRIMARY KEY (war_id, war_end_time, player_tag);


--
-- Name: war_schedule war_schedule_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.war_schedule
    ADD CONSTRAINT war_schedule_pkey PRIMARY KEY (schedule_key);


--
-- Name: war_schedule war_schedule_war_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.war_schedule
    ADD CONSTRAINT war_schedule_war_id_key UNIQUE (war_id);


--
-- Name: wars wars_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.wars
    ADD CONSTRAINT wars_pkey PRIMARY KEY (war_id);


CREATE MATERIALIZED VIEW public.townhall_stats_daily
WITH (timescaledb.continuous) AS
SELECT
    time_bucket('1 day', "timestamp") AS day_start,
    player_th,
    battle_type,
    count(*) AS attacks,
    count(*) FILTER (WHERE stars = 0) AS zero_stars,
    count(*) FILTER (WHERE stars = 1) AS one_stars,
    count(*) FILTER (WHERE stars = 2) AS two_stars,
    count(*) FILTER (WHERE stars = 3) AS three_stars
FROM public.battlelogs
WHERE attack = true
  AND player_th = opponent_th
  AND battle_type IN ('ranked', 'legend')
GROUP BY day_start, player_th, battle_type
WITH NO DATA;

SELECT add_continuous_aggregate_policy(
    'townhall_stats_daily',
    start_offset => INTERVAL '7 days',
    end_offset => INTERVAL '15 minutes',
    schedule_interval => INTERVAL '1 hour'
);

--
-- Name: battlelogs_battle_time_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX battlelogs_battle_time_idx ON public.battlelogs USING btree ("timestamp" DESC);


--
-- Name: clan_change_history_event_time_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX clan_change_history_event_time_idx ON public.clan_change_history USING btree (event_time DESC);


--
-- Name: idx_api_tokens_expires_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_api_tokens_expires_at ON public.api_tokens USING btree (expires_at);


--
-- Name: idx_api_tokens_server_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_api_tokens_server_id ON public.api_tokens USING btree (server_id) WHERE (server_id IS NOT NULL);


--
-- Name: idx_api_tokens_user_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_api_tokens_user_type ON public.api_tokens USING btree (user_id, token_type);


--
-- Name: idx_auth_discord_tokens_expires_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_auth_discord_tokens_expires_at ON public.auth_discord_tokens USING btree (expires_at);


--
-- Name: idx_auth_email_verifications_expires_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_auth_email_verifications_expires_at ON public.auth_email_verifications USING btree (expires_at);


--
-- Name: idx_auth_password_reset_tokens_lookup; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_auth_password_reset_tokens_lookup ON public.auth_password_reset_tokens USING btree (email_hash, used, expires_at DESC);


--
-- Name: idx_auth_refresh_tokens_expires_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_auth_refresh_tokens_expires_at ON public.auth_refresh_tokens USING btree (expires_at);


--
-- Name: idx_auth_refresh_tokens_user_device; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_auth_refresh_tokens_user_device ON public.auth_refresh_tokens USING btree (user_id, device_id);


--
-- Name: idx_auth_users_discord_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_auth_users_discord_user_id ON public.auth_users USING btree (discord_user_id) WHERE ((discord_user_id IS NOT NULL) AND (discord_user_id <> ''::text));


--
-- Name: idx_autoboards_due; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_autoboards_due ON public.autoboards USING btree (next_run_at) WHERE (enabled = true);


--
-- Name: idx_autoboards_server_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_autoboards_server_type ON public.autoboards USING btree (server_id, type);


--
-- Name: idx_basic_clan_last_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_basic_clan_last_active ON public.basic_clan USING btree (last_active);


--
-- Name: idx_basic_clan_member_count; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_basic_clan_member_count ON public.basic_clan USING btree (member_count);


--
-- Name: idx_basic_player_battlelogs_ttl_legend; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_basic_player_battlelogs_ttl_legend ON public.basic_player USING btree (battlelogs_tracking_ttl DESC, tag) WHERE (league_id = 105000036);


--
-- Name: idx_basic_player_battlelogs_ttl_standard; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_basic_player_battlelogs_ttl_standard ON public.basic_player USING btree (battlelogs_tracking_ttl DESC, tag) WHERE (league_id IS DISTINCT FROM 105000036);


--
-- Name: idx_basic_player_league_trophies; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_basic_player_league_trophies ON public.basic_player USING btree (league_id, trophies DESC) WHERE ((league_id IS NOT NULL) AND (league_id <> 105000000));


--
-- Name: idx_basic_player_townhall_league_trophies; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_basic_player_townhall_league_trophies ON public.basic_player USING btree (townhall_level, league_id DESC, trophies DESC) WHERE ((townhall_level >= 7) AND (league_id IS NOT NULL) AND (league_id <> 105000000));


--
-- Name: idx_battlelogs_army_counts; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_battlelogs_army_counts ON public.battlelogs USING gin (army_counts) WHERE ((attack = true) AND (player_th = opponent_th) AND (battle_type = ANY (ARRAY['ranked'::text, 'legend'::text])));


--
-- Name: idx_battlelogs_army_items; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_battlelogs_army_items ON public.battlelogs USING gin (army_items) WHERE ((attack = true) AND (player_th = opponent_th) AND (battle_type = ANY (ARRAY['ranked'::text, 'legend'::text])));


--
-- Name: idx_battlelogs_dynamic_search_main; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_battlelogs_dynamic_search_main ON public.battlelogs USING btree (player_th, battle_type, "timestamp" DESC) WHERE ((attack = true) AND (player_th = opponent_th) AND (battle_type = ANY (ARRAY['ranked'::text, 'legend'::text])));


--
-- Name: idx_battlelogs_player_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_battlelogs_player_time ON public.battlelogs USING btree (player_tag, "timestamp" DESC);


--
-- Name: idx_battlelogs_ranked_legend_th_type_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_battlelogs_ranked_legend_th_type_time ON public.battlelogs USING btree (player_th, opponent_th, battle_type, "timestamp" DESC) WHERE (battle_type = ANY (ARRAY['ranked'::text, 'legend'::text]));


--
-- Name: idx_capital_raid_cache_end_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_capital_raid_cache_end_time ON public.capital_raid_cache USING btree (end_time DESC);


--
-- Name: idx_capital_raid_members_player_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_capital_raid_members_player_time ON public.capital_raid_members USING btree (player_tag, start_time DESC);


--
-- Name: idx_clan_change_history_clan_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_clan_change_history_clan_time ON public.clan_change_history USING btree (clan_tag, event_time DESC);


--
-- Name: idx_clan_change_history_type_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_clan_change_history_type_time ON public.clan_change_history USING btree (change_type, event_time DESC);


--
-- Name: idx_clan_leaderboards_donated_rank; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_clan_leaderboards_donated_rank ON public.clan_leaderboards USING btree (donated_rank);


--
-- Name: idx_clan_leaderboards_location_donated_rank; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_clan_leaderboards_location_donated_rank ON public.clan_leaderboards USING btree (location_id, location_donated_rank);


--
-- Name: idx_clan_leaderboards_location_received_rank; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_clan_leaderboards_location_received_rank ON public.clan_leaderboards USING btree (location_id, location_received_rank);


--
-- Name: idx_clan_leaderboards_location_war_wins_rank; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_clan_leaderboards_location_war_wins_rank ON public.clan_leaderboards USING btree (location_id, location_war_wins_rank);


--
-- Name: idx_clan_leaderboards_received_rank; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_clan_leaderboards_received_rank ON public.clan_leaderboards USING btree (received_rank);


--
-- Name: idx_clan_leaderboards_tag; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_clan_leaderboards_tag ON public.clan_leaderboards USING btree (tag);


--
-- Name: idx_clan_leaderboards_war_wins_rank; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_clan_leaderboards_war_wins_rank ON public.clan_leaderboards USING btree (war_wins_rank);


--
-- Name: idx_clan_leaderboards_war_win_streak_rank; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_clan_leaderboards_war_win_streak_rank ON public.clan_leaderboards USING btree (war_win_streak_rank) WHERE (war_win_streak_rank IS NOT NULL);


--
-- Name: idx_clan_position_roles_clan; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_clan_position_roles_clan ON public.clan_position_roles USING btree (server_id, clan_tag, "position") WHERE (clan_tag IS NOT NULL);


--
-- Name: idx_clan_position_roles_global; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_clan_position_roles_global ON public.clan_position_roles USING btree (server_id, "position") WHERE (clan_tag IS NULL);


--
-- Name: idx_clan_rankings_current_country_rank; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_clan_rankings_current_country_rank ON public.clan_rankings_current USING btree (country_code, rank);


--
-- Name: idx_current_war_timers_end_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_current_war_timers_end_time ON public.current_war_timers USING btree (end_time);


--
-- Name: idx_cwl_groups_season_league; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_cwl_groups_season_league ON public.cwl_groups USING btree (season, cwl_league_id);


--
-- Name: idx_giveaways_due_end; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_giveaways_due_end ON public.giveaways USING btree (end_time) WHERE (status = 'ongoing'::text);


--
-- Name: idx_giveaways_due_start; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_giveaways_due_start ON public.giveaways USING btree (start_time) WHERE (status = 'scheduled'::text);


--
-- Name: idx_giveaways_end_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_giveaways_end_time ON public.giveaways USING btree (end_time);


--
-- Name: idx_giveaways_entries_gin; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_giveaways_entries_gin ON public.giveaways USING gin (entries);


--
-- Name: idx_giveaways_pending_event; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_giveaways_pending_event ON public.giveaways USING btree (event_pending_at) WHERE (event_pending IS NOT NULL);


--
-- Name: idx_giveaways_server_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_giveaways_server_status ON public.giveaways USING btree (server_id, status);


--
-- Name: idx_join_leave_history_clan_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_join_leave_history_clan_time ON public.join_leave_history USING btree (clan_tag, "time" DESC);


--
-- Name: idx_join_leave_history_player; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_join_leave_history_player ON public.join_leave_history USING btree (player_tag);


--
-- Name: idx_leaderboard_snapshot_items_location_rank; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_leaderboard_snapshot_items_location_rank ON public.leaderboard_snapshot_items USING btree (kind, location_id, date DESC, rank);


--
-- Name: idx_leaderboard_snapshot_items_tag_history; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_leaderboard_snapshot_items_tag_history ON public.leaderboard_snapshot_items USING btree (kind, tag, date DESC);


--
-- Name: idx_legend_history_snapshots_rank; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_legend_history_snapshots_rank ON public.legend_history_snapshots USING btree (season, rank);


--
-- Name: idx_legend_rankings_current_rank; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_legend_rankings_current_rank ON public.legend_rankings_current USING btree (rank);


--
-- Name: idx_mobile_live_activities_clan_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_mobile_live_activities_clan_active ON public.mobile_live_activities USING btree (clan_tag, status) WHERE (status = 'active'::text);


--
-- Name: idx_mobile_live_activities_war_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_mobile_live_activities_war_active ON public.mobile_live_activities USING btree (war_id, war_tag, status) WHERE (status = 'active'::text);


--
-- Name: idx_mobile_push_devices_enabled_provider; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_mobile_push_devices_enabled_provider ON public.mobile_push_devices USING btree (provider, environment, enabled) WHERE (enabled = true);


--
-- Name: idx_mobile_push_devices_user_device; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_mobile_push_devices_user_device ON public.mobile_push_devices USING btree (user_id, device_id);


--
-- Name: idx_mobile_war_subscriptions_clan_enabled; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_mobile_war_subscriptions_clan_enabled ON public.mobile_war_subscriptions USING btree (clan_tag, enabled) WHERE (enabled = true);


--
-- Name: idx_mobile_war_subscriptions_user_device; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_mobile_war_subscriptions_user_device ON public.mobile_war_subscriptions USING btree (user_id, device_id);


--
-- Name: idx_one_time_login_tokens_expires_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_one_time_login_tokens_expires_at ON public.one_time_login_tokens USING btree (expires_at);


--
-- Name: idx_one_time_login_tokens_user_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_one_time_login_tokens_user_id ON public.one_time_login_tokens USING btree (user_id);


--
-- Name: idx_open_tickets_server_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_open_tickets_server_status ON public.open_tickets USING btree (server_id, status);


--
-- Name: idx_player_current_stats_clan; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_player_current_stats_clan ON public.player_current_stats USING btree (clan_tag);


--
-- Name: idx_player_current_stats_legends_gin; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_player_current_stats_legends_gin ON public.player_current_stats USING gin (legends);


--
-- Name: idx_player_history_events_clan_season; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_player_history_events_clan_season ON public.player_history_events USING btree (clan_tag, season, event_type, event_time DESC);


--
-- Name: idx_player_history_events_player_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_player_history_events_player_time ON public.player_history_events USING btree (player_tag, event_time DESC);


--
-- Name: idx_player_links_user_order; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_player_links_user_order ON public.player_links USING btree (user_id, order_index) WHERE (user_id IS NOT NULL);


--
-- Name: idx_player_online_events_clan_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_player_online_events_clan_time ON public.player_online_events USING btree (clan_tag, seen_at DESC);


--
-- Name: idx_player_online_events_player_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_player_online_events_player_time ON public.player_online_events USING btree (tag, seen_at DESC);


--
-- Name: idx_player_profile_changes_player_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_player_profile_changes_player_time ON public.player_profile_changes USING btree (player_tag, event_time DESC);


--
-- Name: idx_player_profile_changes_type_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_player_profile_changes_type_time ON public.player_profile_changes USING btree (change_type, event_time DESC);


--
-- Name: idx_player_rankings_current_country_rank; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_player_rankings_current_country_rank ON public.player_rankings_current USING btree (country_code, rank);


--
-- Name: idx_player_season_stats_clan_season; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_player_season_stats_clan_season ON public.player_season_stats USING btree (clan_tag, season);


--
-- Name: idx_raid_weekends_end_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_raid_weekends_end_time ON public.raid_weekends USING btree (end_time DESC);


--
-- Name: idx_raid_weekends_members_gin; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_raid_weekends_members_gin ON public.raid_weekends USING gin (members);


--
-- Name: idx_ranked_group_members_group_placement; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ranked_group_members_group_placement ON public.ranked_league_group_members USING btree (season_id, group_tag, placement);


--
-- Name: idx_ranked_group_members_player_season; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ranked_group_members_player_season ON public.ranked_league_group_members USING btree (player_tag, season_id DESC);


--
-- Name: idx_ranked_group_members_season_tier_group; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ranked_group_members_season_tier_group ON public.ranked_league_group_members USING btree (season_id, league_tier_id, group_tag);


--
-- Name: idx_ranking_snapshots_type_date; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ranking_snapshots_type_date ON public.ranking_snapshots USING btree (ranking_type, snapshot_date);


--
-- Name: idx_reminders_server_type_name; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_reminders_server_type_name ON public.reminders USING btree (server_id, type_name);


--
-- Name: idx_role_bindings_server_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_role_bindings_server_type ON public.role_bindings USING btree (server_id, role_type);


--
-- Name: idx_roster_automation_rules_server_group; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_roster_automation_rules_server_group ON public.roster_automation_rules USING btree (server_id, group_id);


--
-- Name: idx_roster_groups_server; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_roster_groups_server ON public.roster_groups USING btree (server_id);


--
-- Name: idx_roster_signup_categories_server; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_roster_signup_categories_server ON public.roster_signup_categories USING btree (server_id, sort_order);


--
-- Name: idx_rosters_members_gin; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rosters_members_gin ON public.rosters USING gin (members);


--
-- Name: idx_rosters_server_clan; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rosters_server_clan ON public.rosters USING btree (server_id, clan_tag);


--
-- Name: idx_rosters_server_group; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rosters_server_group ON public.rosters USING btree (server_id, group_id);


--
-- Name: idx_search_groups_tags; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_search_groups_tags ON public.search_groups USING gin (tags);


--
-- Name: idx_search_groups_user_type_name; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_search_groups_user_type_name ON public.search_groups USING btree (user_id, type, name);


--
-- Name: idx_server_bans_player_tag; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_server_bans_player_tag ON public.server_bans USING btree (player_tag);


--
-- Name: idx_strikes_server_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_strikes_server_id ON public.strikes USING btree (server_id);


--
-- Name: idx_strikes_tag; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_strikes_tag ON public.strikes USING btree (tag);


--
-- Name: idx_ticket_panels_components_gin; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ticket_panels_components_gin ON public.ticket_panels USING gin (components);


--
-- Name: idx_tracking_domain_stats_health_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_tracking_domain_stats_health_time ON public.tracking_domain_stats USING btree (healthy, interval_end DESC) WHERE (healthy = false);


--
-- Name: idx_tracking_domain_stats_name_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_tracking_domain_stats_name_time ON public.tracking_domain_stats USING btree (name, interval_end DESC);


--
-- Name: idx_tracking_domain_stats_run_name_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_tracking_domain_stats_run_name_time ON public.tracking_domain_stats USING btree (run_id, name, interval_end DESC);


--
-- Name: idx_tracking_domain_stats_script_name_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_tracking_domain_stats_script_name_time ON public.tracking_domain_stats USING btree (script, name, interval_end DESC);


--
-- Name: idx_tracking_process_stats_run_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_tracking_process_stats_run_time ON public.tracking_process_stats USING btree (run_id, interval_end DESC);


--
-- Name: idx_tracking_process_stats_script_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_tracking_process_stats_script_time ON public.tracking_process_stats USING btree (script, interval_end DESC);


--
-- Name: idx_user_bookmarks_order; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_user_bookmarks_order ON public.user_bookmarks USING btree (user_id, entity_type, order_index);


--
-- Name: idx_user_recent_searches_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_user_recent_searches_created ON public.user_recent_searches USING btree (user_id, entity_type, created_at DESC);


--
-- Name: idx_user_recent_searches_expiry; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_user_recent_searches_expiry ON public.user_recent_searches USING btree (created_at);


--
-- Name: idx_user_settings_search_gin; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_user_settings_search_gin ON public.user_settings USING gin (search);


--
-- Name: idx_war_attacks_clan_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_war_attacks_clan_time ON public.war_attacks USING btree (attacking_clan_tag, war_end_time DESC);


--
-- Name: idx_war_attacks_hitrate; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_war_attacks_hitrate ON public.war_attacks USING btree (attacker_townhall, defender_townhall, war_type, war_end_time DESC);


--
-- Name: idx_war_attacks_player_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_war_attacks_player_time ON public.war_attacks USING btree (attacker_tag, war_end_time DESC);


--
-- Name: idx_war_members_player_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_war_members_player_time ON public.war_members USING btree (player_tag, war_end_time DESC);


--
-- Name: idx_war_missed_attacks_clan_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_war_missed_attacks_clan_time ON public.war_missed_attacks USING btree (clan_tag, war_end_time DESC);


--
-- Name: idx_war_missed_attacks_player_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_war_missed_attacks_player_time ON public.war_missed_attacks USING btree (player_tag, war_end_time DESC);


--
-- Name: idx_war_schedule_next_run; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_war_schedule_next_run ON public.war_schedule USING btree (next_run_at);


--
-- Name: idx_war_schedule_source_opponent; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_war_schedule_source_opponent ON public.war_schedule USING btree (source_clan_tag, opponent_tag);


--
-- Name: idx_wars_clan_end_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_wars_clan_end_time ON public.wars USING btree (clan_tag, end_time DESC);


--
-- Name: idx_wars_opponent_end_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_wars_opponent_end_time ON public.wars USING btree (opponent_tag, end_time DESC);


--
-- Name: idx_wars_war_tag; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_wars_war_tag ON public.wars USING btree (war_tag) WHERE (war_tag IS NOT NULL);


--
-- Name: player_history_events_event_time_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX player_history_events_event_time_idx ON public.player_history_events USING btree (event_time DESC);


--
-- Name: player_online_events_seen_at_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX player_online_events_seen_at_idx ON public.player_online_events USING btree (seen_at DESC);


--
-- Name: player_profile_changes_event_time_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX player_profile_changes_event_time_idx ON public.player_profile_changes USING btree (event_time DESC);


--
-- Name: tracking_domain_stats_interval_end_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tracking_domain_stats_interval_end_idx ON public.tracking_domain_stats USING btree (interval_end DESC);


--
-- Name: tracking_process_stats_interval_end_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tracking_process_stats_interval_end_idx ON public.tracking_process_stats USING btree (interval_end DESC);


--
-- Name: auth_discord_tokens auth_discord_tokens_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.auth_discord_tokens
    ADD CONSTRAINT auth_discord_tokens_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.auth_users(user_id) ON DELETE CASCADE;


--
-- Name: auth_refresh_tokens auth_refresh_tokens_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.auth_refresh_tokens
    ADD CONSTRAINT auth_refresh_tokens_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.auth_users(user_id) ON DELETE CASCADE;


--
-- Name: clan_categories clan_categories_server_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.clan_categories
    ADD CONSTRAINT clan_categories_server_id_fkey FOREIGN KEY (server_id) REFERENCES public.servers(id) ON DELETE CASCADE;


--
-- Name: clan_logs clan_logs_clan_tag_server_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.clan_logs
    ADD CONSTRAINT clan_logs_clan_tag_server_id_fkey FOREIGN KEY (clan_tag, server_id) REFERENCES public.server_clans(tag, server_id) ON DELETE CASCADE;


--
-- Name: clan_logs clan_logs_server_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.clan_logs
    ADD CONSTRAINT clan_logs_server_id_fkey FOREIGN KEY (server_id) REFERENCES public.servers(id) ON DELETE CASCADE;


--
-- Name: clan_position_roles clan_position_roles_clan_tag_server_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.clan_position_roles
    ADD CONSTRAINT clan_position_roles_clan_tag_server_id_fkey FOREIGN KEY (clan_tag, server_id) REFERENCES public.server_clans(tag, server_id) ON DELETE CASCADE;


--
-- Name: clan_position_roles clan_position_roles_server_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.clan_position_roles
    ADD CONSTRAINT clan_position_roles_server_id_fkey FOREIGN KEY (server_id) REFERENCES public.servers(id) ON DELETE CASCADE;


--
-- Name: embeds embeds_server_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.embeds
    ADD CONSTRAINT embeds_server_id_fkey FOREIGN KEY (server_id) REFERENCES public.servers(id) ON DELETE CASCADE;


--
-- Name: giveaways giveaways_server_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.giveaways
    ADD CONSTRAINT giveaways_server_id_fkey FOREIGN KEY (server_id) REFERENCES public.servers(id) ON DELETE CASCADE;


--
-- Name: hall_roles hall_roles_server_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.hall_roles
    ADD CONSTRAINT hall_roles_server_id_fkey FOREIGN KEY (server_id) REFERENCES public.servers(id) ON DELETE CASCADE;


--
-- Name: league_roles league_roles_server_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.league_roles
    ADD CONSTRAINT league_roles_server_id_fkey FOREIGN KEY (server_id) REFERENCES public.servers(id) ON DELETE CASCADE;


--
-- Name: player_equipment player_equipment_player_tag_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.player_equipment
    ADD CONSTRAINT player_equipment_player_tag_fkey FOREIGN KEY (player_tag) REFERENCES public.basic_player(tag) ON DELETE CASCADE;


--
-- Name: player_heroes player_heroes_player_tag_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.player_heroes
    ADD CONSTRAINT player_heroes_player_tag_fkey FOREIGN KEY (player_tag) REFERENCES public.basic_player(tag) ON DELETE CASCADE;


--
-- Name: player_links_settings player_links_settings_server_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.player_links_settings
    ADD CONSTRAINT player_links_settings_server_id_fkey FOREIGN KEY (server_id) REFERENCES public.servers(id) ON DELETE CASCADE;


--
-- Name: player_links_settings player_links_settings_tag_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.player_links_settings
    ADD CONSTRAINT player_links_settings_tag_fkey FOREIGN KEY (tag) REFERENCES public.player_links(tag) ON DELETE CASCADE;


--
-- Name: player_spells player_spells_player_tag_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.player_spells
    ADD CONSTRAINT player_spells_player_tag_fkey FOREIGN KEY (player_tag) REFERENCES public.basic_player(tag) ON DELETE CASCADE;


--
-- Name: player_troops player_troops_player_tag_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.player_troops
    ADD CONSTRAINT player_troops_player_tag_fkey FOREIGN KEY (player_tag) REFERENCES public.basic_player(tag) ON DELETE CASCADE;


--
-- Name: reminders reminders_server_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.reminders
    ADD CONSTRAINT reminders_server_id_fkey FOREIGN KEY (server_id) REFERENCES public.servers(id) ON DELETE CASCADE;


--
-- Name: roster_groups roster_groups_server_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.roster_groups
    ADD CONSTRAINT roster_groups_server_id_fkey FOREIGN KEY (server_id) REFERENCES public.servers(id) ON DELETE CASCADE;


--
-- Name: roster_members roster_members_roster_group_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.roster_members
    ADD CONSTRAINT roster_members_roster_group_id_fkey FOREIGN KEY (roster_group_id) REFERENCES public.roster_groups(id) ON DELETE SET NULL;


--
-- Name: roster_members roster_members_roster_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.roster_members
    ADD CONSTRAINT roster_members_roster_id_fkey FOREIGN KEY (roster_id) REFERENCES public.rosters(id) ON DELETE CASCADE;


--
-- Name: rosters rosters_server_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.rosters
    ADD CONSTRAINT rosters_server_id_fkey FOREIGN KEY (server_id) REFERENCES public.servers(id) ON DELETE CASCADE;


--
-- Name: server_clans server_clans_category_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.server_clans
    ADD CONSTRAINT server_clans_category_id_fkey FOREIGN KEY (category_id) REFERENCES public.clan_categories(id);


--
-- Name: server_clans server_clans_server_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.server_clans
    ADD CONSTRAINT server_clans_server_id_fkey FOREIGN KEY (server_id) REFERENCES public.servers(id) ON DELETE CASCADE;


--
-- Name: strikes strikes_server_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.strikes
    ADD CONSTRAINT strikes_server_id_fkey FOREIGN KEY (server_id) REFERENCES public.servers(id) ON DELETE CASCADE;


--
-- Name: ticket_panel_buttons ticket_panel_buttons_open_message_embed_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.ticket_panel_buttons
    ADD CONSTRAINT ticket_panel_buttons_open_message_embed_id_fkey FOREIGN KEY (open_message_embed_id) REFERENCES public.embeds(id) ON DELETE SET NULL;


--
-- Name: ticket_panel_buttons ticket_panel_buttons_panel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.ticket_panel_buttons
    ADD CONSTRAINT ticket_panel_buttons_panel_id_fkey FOREIGN KEY (panel_id) REFERENCES public.ticket_panel(id) ON DELETE CASCADE;


--
-- Name: ticket_panel ticket_panel_embed_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.ticket_panel
    ADD CONSTRAINT ticket_panel_embed_id_fkey FOREIGN KEY (embed_id) REFERENCES public.embeds(id) ON DELETE SET NULL;


--
-- Name: ticket_panel ticket_panel_server_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.ticket_panel
    ADD CONSTRAINT ticket_panel_server_id_fkey FOREIGN KEY (server_id) REFERENCES public.servers(id) ON DELETE CASCADE;


--
-- Name: ticket_panel_staff_permissions ticket_panel_staff_permissions_panel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.ticket_panel_staff_permissions
    ADD CONSTRAINT ticket_panel_staff_permissions_panel_id_fkey FOREIGN KEY (panel_id) REFERENCES public.ticket_panel(id) ON DELETE CASCADE;


--
-- Name: tickets tickets_panel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.tickets
    ADD CONSTRAINT tickets_panel_id_fkey FOREIGN KEY (panel_id) REFERENCES public.ticket_panel(id) ON DELETE CASCADE;


--
-- Name: tickets tickets_server_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.tickets
    ADD CONSTRAINT tickets_server_id_fkey FOREIGN KEY (server_id) REFERENCES public.servers(id) ON DELETE CASCADE;


--

-- +goose Down
SELECT remove_continuous_aggregate_policy('townhall_stats_daily', if_exists => TRUE);
SELECT remove_compression_policy('battlelogs', if_exists => TRUE);
SELECT remove_retention_policy('user_recent_searches', if_exists => TRUE);
SELECT remove_retention_policy('tracking_domain_stats', if_exists => TRUE);
SELECT remove_retention_policy('tracking_process_stats', if_exists => TRUE);
DROP MATERIALIZED VIEW IF EXISTS public.townhall_stats_daily CASCADE;
DROP MATERIALIZED VIEW IF EXISTS public.war_league_counts CASCADE;
DROP MATERIALIZED VIEW IF EXISTS public.clan_leaderboards CASCADE;
DROP TABLE IF EXISTS public.wars CASCADE;
DROP TABLE IF EXISTS public.war_schedule CASCADE;
DROP TABLE IF EXISTS public.war_members CASCADE;
DROP TABLE IF EXISTS public.war_missed_attacks CASCADE;
DROP TABLE IF EXISTS public.war_attacks CASCADE;
DROP TABLE IF EXISTS public.user_settings CASCADE;
DROP TABLE IF EXISTS public.tracked_player_targets CASCADE;
DROP TABLE IF EXISTS public.user_recent_searches CASCADE;
DROP TABLE IF EXISTS public.user_bookmarks CASCADE;
DROP TABLE IF EXISTS public.tickets CASCADE;
DROP TABLE IF EXISTS public.ticket_panels CASCADE;
DROP TABLE IF EXISTS public.ticket_panel_staff_permissions CASCADE;
DROP TABLE IF EXISTS public.ticket_panel_buttons CASCADE;
DROP TABLE IF EXISTS public.ticket_panel CASCADE;
DROP TABLE IF EXISTS public.strikes CASCADE;
DROP TABLE IF EXISTS public.short_links CASCADE;
DROP TABLE IF EXISTS public.servers CASCADE;
DROP TABLE IF EXISTS public.server_role_settings CASCADE;
DROP TABLE IF EXISTS public.server_clans CASCADE;
DROP TABLE IF EXISTS public.server_bans CASCADE;
DROP TABLE IF EXISTS public.search_groups CASCADE;
DROP TABLE IF EXISTS public.rosters CASCADE;
DROP TABLE IF EXISTS public.roster_signup_categories CASCADE;
DROP TABLE IF EXISTS public.roster_members CASCADE;
DROP TABLE IF EXISTS public.roster_groups CASCADE;
DROP TABLE IF EXISTS public.roster_automation_rules CASCADE;
DROP TABLE IF EXISTS public.role_ignore_bindings CASCADE;
DROP TABLE IF EXISTS public.role_bindings CASCADE;
DROP TABLE IF EXISTS public.reminders CASCADE;
DROP TABLE IF EXISTS public.ranking_snapshots CASCADE;
DROP TABLE IF EXISTS public.ranked_league_group_members CASCADE;
DROP TABLE IF EXISTS public.raid_weekends CASCADE;
DROP TABLE IF EXISTS public.player_troops CASCADE;
DROP TABLE IF EXISTS public.player_spells CASCADE;
DROP TABLE IF EXISTS public.player_season_stats CASCADE;
DROP TABLE IF EXISTS public.player_rankings_current CASCADE;
DROP TABLE IF EXISTS public.player_profile_changes CASCADE;
DROP TABLE IF EXISTS public.player_online_events CASCADE;
DROP TABLE IF EXISTS public.player_links_settings CASCADE;
DROP TABLE IF EXISTS public.player_links CASCADE;
DROP TABLE IF EXISTS public.player_history_events CASCADE;
DROP TABLE IF EXISTS public.player_heroes CASCADE;
DROP TABLE IF EXISTS public.player_equipment CASCADE;
DROP TABLE IF EXISTS public.player_current_stats CASCADE;
DROP TABLE IF EXISTS public.open_tickets CASCADE;
DROP TABLE IF EXISTS public.one_time_login_tokens CASCADE;
DROP TABLE IF EXISTS public.mobile_war_subscriptions CASCADE;
DROP TABLE IF EXISTS public.mobile_push_devices CASCADE;
DROP TABLE IF EXISTS public.mobile_live_activities CASCADE;
DROP TABLE IF EXISTS public.legend_rankings_current CASCADE;
DROP TABLE IF EXISTS public.legend_history_snapshots CASCADE;
DROP TABLE IF EXISTS public.league_roles CASCADE;
DROP TABLE IF EXISTS public.leaderboard_snapshot_items CASCADE;
DROP TABLE IF EXISTS public.hall_roles CASCADE;
DROP TABLE IF EXISTS public.hall_counts CASCADE;
DROP TABLE IF EXISTS public.giveaways CASCADE;
DROP TABLE IF EXISTS public.embeds CASCADE;
DROP TABLE IF EXISTS public.cwl_groups CASCADE;
DROP TABLE IF EXISTS public.custom_embeds CASCADE;
DROP TABLE IF EXISTS public.current_war_timers CASCADE;
DROP TABLE IF EXISTS public.clan_season_stats CASCADE;
DROP TABLE IF EXISTS public.clan_records CASCADE;
DROP TABLE IF EXISTS public.clan_rankings_current CASCADE;
DROP TABLE IF EXISTS public.clan_position_roles CASCADE;
DROP TABLE IF EXISTS public.clan_logs CASCADE;
DROP TABLE IF EXISTS public.clan_categories CASCADE;
DROP TABLE IF EXISTS public.capital_raid_members CASCADE;
DROP TABLE IF EXISTS public.capital_raid_cache CASCADE;
DROP TABLE IF EXISTS public.bot_sync_status CASCADE;
DROP TABLE IF EXISTS public.bot_settings CASCADE;
DROP TABLE IF EXISTS public.basic_player CASCADE;
DROP TABLE IF EXISTS public.basic_clan CASCADE;
DROP TABLE IF EXISTS public.bases CASCADE;
DROP TABLE IF EXISTS public.autoboards CASCADE;
DROP TABLE IF EXISTS public.auth_users CASCADE;
DROP TABLE IF EXISTS public.auth_refresh_tokens CASCADE;
DROP TABLE IF EXISTS public.auth_password_reset_tokens CASCADE;
DROP TABLE IF EXISTS public.auth_email_verifications CASCADE;
DROP TABLE IF EXISTS public.auth_discord_tokens CASCADE;
DROP TABLE IF EXISTS public.audit_history CASCADE;
DROP TABLE IF EXISTS public.api_tokens CASCADE;
DROP TABLE IF EXISTS public.clan_change_history CASCADE;
DROP TABLE IF EXISTS public.join_leave_history CASCADE;
DROP TABLE IF EXISTS public.tracking_domain_stats CASCADE;
DROP TABLE IF EXISTS public.tracking_process_stats CASCADE;
DROP TABLE IF EXISTS public.battlelogs CASCADE;
DROP SEQUENCE IF EXISTS public.tracking_stats_run_id_seq;
DROP SEQUENCE IF EXISTS public.tickets_number_seq;
