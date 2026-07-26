-- +goose Up

-- Consolidated from 002_clan_records_drop_updated_at.sql
ALTER TABLE public.clan_records DROP COLUMN IF EXISTS updated_at;
TRUNCATE TABLE public.clan_records;

-- Consolidated from 003_war_single_row_reload.sql
CREATE EXTENSION IF NOT EXISTS timescaledb;

-- +goose StatementBegin
DO $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'basic_clan'
          AND column_name = 'badge_url'
    ) AND NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'basic_clan'
          AND column_name = 'badge_token'
    ) THEN
        ALTER TABLE public.basic_clan RENAME COLUMN badge_url TO badge_token;
    ELSIF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'basic_clan'
          AND column_name = 'badge_token'
    ) THEN
        ALTER TABLE public.basic_clan
            ADD COLUMN badge_token text DEFAULT ''::text NOT NULL;
    END IF;
END $$;
-- +goose StatementEnd

DROP TABLE IF EXISTS public.war_members CASCADE;
DROP TABLE IF EXISTS public.war_missed_attacks CASCADE;
DROP TABLE IF EXISTS public.war_attacks CASCADE;
DROP TABLE IF EXISTS public.wars CASCADE;

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
    CONSTRAINT wars_pkey PRIMARY KEY (war_id),
    CONSTRAINT wars_war_type_check CHECK (war_type = ANY (ARRAY['random'::text, 'cwl'::text, 'friendly'::text]))
);

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

ALTER TABLE public.war_attacks
    ADD CONSTRAINT war_attacks_pkey PRIMARY KEY (war_id, war_end_time, attacker_tag, defender_tag, attack_order);

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

ALTER TABLE public.war_members
    ADD CONSTRAINT war_members_pkey PRIMARY KEY (war_id, war_end_time, clan_tag, player_tag);

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

ALTER TABLE public.war_missed_attacks
    ADD CONSTRAINT war_missed_attacks_pkey PRIMARY KEY (war_id, war_end_time, player_tag);

CREATE INDEX idx_wars_clan_end_time ON public.wars USING btree (clan_tag, end_time DESC);
CREATE INDEX idx_wars_opponent_end_time ON public.wars USING btree (opponent_tag, end_time DESC);
CREATE INDEX idx_wars_war_tag ON public.wars USING btree (war_tag) WHERE war_tag IS NOT NULL;
CREATE INDEX idx_war_attacks_player_time ON public.war_attacks USING btree (attacker_tag, war_end_time DESC);
CREATE INDEX idx_war_attacks_clan_time ON public.war_attacks USING btree (attacking_clan_tag, war_end_time DESC);
CREATE INDEX idx_war_attacks_hitrate ON public.war_attacks USING btree (attacker_townhall, defender_townhall, war_type, war_end_time DESC);
CREATE INDEX idx_war_members_player_time ON public.war_members USING btree (player_tag, war_end_time DESC);
CREATE INDEX idx_war_missed_attacks_player_time ON public.war_missed_attacks USING btree (player_tag, war_end_time DESC);
CREATE INDEX idx_war_missed_attacks_clan_time ON public.war_missed_attacks USING btree (clan_tag, war_end_time DESC);

-- Consolidated from 004_battle_modifier_none.sql
ALTER TABLE public.wars
    ALTER COLUMN battle_modifier SET DEFAULT 'none';

ALTER TABLE public.war_attacks
    ALTER COLUMN battle_modifier SET DEFAULT 'none';

UPDATE public.wars
SET battle_modifier = 'none'
WHERE battle_modifier IS NULL OR btrim(battle_modifier) = '';

UPDATE public.war_attacks
SET battle_modifier = 'none'
WHERE battle_modifier IS NULL OR btrim(battle_modifier) = '';

-- Consolidated from 005_war_members_roster_order.sql
CREATE EXTENSION IF NOT EXISTS timescaledb;

DROP TABLE IF EXISTS public.war_members CASCADE;
DROP TABLE IF EXISTS public.war_missed_attacks CASCADE;
DROP TABLE IF EXISTS public.war_attacks CASCADE;
DROP TABLE IF EXISTS public.wars CASCADE;

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
    CONSTRAINT wars_pkey PRIMARY KEY (war_id),
    CONSTRAINT wars_war_type_check CHECK (war_type = ANY (ARRAY['random'::text, 'cwl'::text, 'friendly'::text]))
);

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

ALTER TABLE public.war_attacks
    ADD CONSTRAINT war_attacks_pkey PRIMARY KEY (war_id, war_end_time, attacker_tag, defender_tag, attack_order);

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

ALTER TABLE public.war_members
    ADD CONSTRAINT war_members_pkey PRIMARY KEY (war_id, war_end_time, clan_tag, player_tag);

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

ALTER TABLE public.war_missed_attacks
    ADD CONSTRAINT war_missed_attacks_pkey PRIMARY KEY (war_id, war_end_time, player_tag);

CREATE INDEX idx_wars_clan_end_time ON public.wars USING btree (clan_tag, end_time DESC);
CREATE INDEX idx_wars_opponent_end_time ON public.wars USING btree (opponent_tag, end_time DESC);
CREATE INDEX idx_wars_war_tag ON public.wars USING btree (war_tag) WHERE war_tag IS NOT NULL;
CREATE INDEX idx_war_attacks_player_time ON public.war_attacks USING btree (attacker_tag, war_end_time DESC);
CREATE INDEX idx_war_attacks_clan_time ON public.war_attacks USING btree (attacking_clan_tag, war_end_time DESC);
CREATE INDEX idx_war_attacks_hitrate ON public.war_attacks USING btree (attacker_townhall, defender_townhall, war_type, war_end_time DESC);
CREATE INDEX idx_war_members_player_time ON public.war_members USING btree (player_tag, war_end_time DESC);
CREATE INDEX idx_war_missed_attacks_player_time ON public.war_missed_attacks USING btree (player_tag, war_end_time DESC);
CREATE INDEX idx_war_missed_attacks_clan_time ON public.war_missed_attacks USING btree (clan_tag, war_end_time DESC);

-- Consolidated from 006_war_members_without_roster_order.sql
CREATE EXTENSION IF NOT EXISTS timescaledb;

DROP TABLE IF EXISTS public.war_members CASCADE;
DROP TABLE IF EXISTS public.war_missed_attacks CASCADE;
DROP TABLE IF EXISTS public.war_attacks CASCADE;
DROP TABLE IF EXISTS public.wars CASCADE;

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
    CONSTRAINT wars_pkey PRIMARY KEY (war_id),
    CONSTRAINT wars_war_type_check CHECK (war_type = ANY (ARRAY['random'::text, 'cwl'::text, 'friendly'::text]))
);

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

ALTER TABLE public.war_attacks
    ADD CONSTRAINT war_attacks_pkey PRIMARY KEY (war_id, war_end_time, attacker_tag, defender_tag, attack_order);

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

ALTER TABLE public.war_members
    ADD CONSTRAINT war_members_pkey PRIMARY KEY (war_id, war_end_time, clan_tag, player_tag);

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

ALTER TABLE public.war_missed_attacks
    ADD CONSTRAINT war_missed_attacks_pkey PRIMARY KEY (war_id, war_end_time, player_tag);

CREATE INDEX idx_wars_clan_end_time ON public.wars USING btree (clan_tag, end_time DESC);
CREATE INDEX idx_wars_opponent_end_time ON public.wars USING btree (opponent_tag, end_time DESC);
CREATE INDEX idx_wars_war_tag ON public.wars USING btree (war_tag) WHERE war_tag IS NOT NULL;
CREATE INDEX idx_war_attacks_player_time ON public.war_attacks USING btree (attacker_tag, war_end_time DESC);
CREATE INDEX idx_war_attacks_clan_time ON public.war_attacks USING btree (attacking_clan_tag, war_end_time DESC);
CREATE INDEX idx_war_attacks_hitrate ON public.war_attacks USING btree (attacker_townhall, defender_townhall, war_type, war_end_time DESC);
CREATE INDEX idx_war_members_player_time ON public.war_members USING btree (player_tag, war_end_time DESC);
CREATE INDEX idx_war_missed_attacks_player_time ON public.war_missed_attacks USING btree (player_tag, war_end_time DESC);
CREATE INDEX idx_war_missed_attacks_clan_time ON public.war_missed_attacks USING btree (clan_tag, war_end_time DESC);

-- Consolidated from 007_player_links_drop_discord_id.sql
ALTER TABLE public.player_links
    DROP COLUMN IF EXISTS discord_id;

-- Consolidated from 008_user_search_items.sql
CREATE TABLE IF NOT EXISTS public.user_bookmarks (
    user_id text NOT NULL,
    entity_type text NOT NULL CHECK (entity_type IN ('player', 'clan')),
    tag text NOT NULL,
    order_index integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    PRIMARY KEY (user_id, entity_type, tag)
);

CREATE INDEX IF NOT EXISTS idx_user_bookmarks_order
    ON public.user_bookmarks (user_id, entity_type, order_index);

CREATE TABLE IF NOT EXISTS public.user_recent_searches (
    user_id text NOT NULL,
    entity_type text NOT NULL CHECK (entity_type IN ('player', 'clan')),
    tag text NOT NULL,
    data jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    PRIMARY KEY (user_id, entity_type, tag, created_at)
);

SELECT create_hypertable(
    'user_recent_searches',
    'created_at',
    chunk_time_interval => INTERVAL '7 days',
    create_default_indexes => FALSE,
    if_not_exists => TRUE
);

CREATE INDEX IF NOT EXISTS idx_user_recent_searches_created
    ON public.user_recent_searches (user_id, entity_type, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_user_recent_searches_expiry
    ON public.user_recent_searches (created_at);

SELECT add_retention_policy('user_recent_searches', INTERVAL '90 days', if_not_exists => TRUE);

-- Consolidated from 009_app_announcements.sql
CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE IF NOT EXISTS public.app_announcements (
    id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
    title text NOT NULL,
    subtitle text NOT NULL,
    body text DEFAULT '' NOT NULL,
    status text DEFAULT 'draft' NOT NULL CHECK (status IN ('draft', 'scheduled', 'published', 'archived')),
    target text DEFAULT 'all' NOT NULL CHECK (target IN ('all', 'ios', 'android')),
    banner_image_url text,
    html_object_key text,
    html_url text,
    starts_at timestamp with time zone NOT NULL,
    ends_at timestamp with time zone,
    min_app_version text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_app_announcements_active
    ON public.app_announcements (status, target, starts_at, ends_at);

CREATE INDEX IF NOT EXISTS idx_app_announcements_created
    ON public.app_announcements (created_at DESC);

-- Consolidated from 010_dashboard_schema_contracts.sql
ALTER TABLE public.autoboards
    ADD COLUMN IF NOT EXISTS board_type text DEFAULT '' NOT NULL,
    ADD COLUMN IF NOT EXISTS button_id text DEFAULT '' NOT NULL,
    ADD COLUMN IF NOT EXISTS days text[] DEFAULT '{}'::text[] NOT NULL,
    ADD COLUMN IF NOT EXISTS locale text DEFAULT '' NOT NULL;

ALTER TABLE public.roster_groups
    ADD COLUMN IF NOT EXISTS created_at timestamp with time zone DEFAULT now() NOT NULL;

-- The current roster API stores the editable roster document in data and keeps
-- only queryable identity/filter fields as columns. These required columns were
-- part of the superseded roster model and prevented current dashboard creates.
ALTER TABLE public.rosters
    DROP COLUMN IF EXISTS linked_clan_tag,
    DROP COLUMN IF EXISTS title,
    DROP COLUMN IF EXISTS description,
    DROP COLUMN IF EXISTS max_size,
    DROP COLUMN IF EXISTS minimum_townhall,
    DROP COLUMN IF EXISTS maximum_townhall,
    DROP COLUMN IF EXISTS image_url,
    DROP COLUMN IF EXISTS signup_role_id;

-- Consolidated from 011_api_materialized_views.sql
DROP TABLE IF EXISTS public.api_tokens;

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

CREATE MATERIALIZED VIEW public.api_league_tier_counts AS
SELECT
    COALESCE(league_id, 0) AS league_tier_id,
    count(*)::bigint AS player_count,
    now() AS refreshed_at
FROM public.basic_player
GROUP BY COALESCE(league_id, 0);

CREATE UNIQUE INDEX api_league_tier_counts_id_idx
    ON public.api_league_tier_counts (league_tier_id);

-- Consolidated from 012_auth_identity_separation.sql
UPDATE public.auth_users
SET email_hash = NULL,
    password_hash = NULL,
    data = (data - 'email_encrypted' - 'email_hash' - 'password')
        #- '{linked_accounts,email}',
    updated_at = now()
WHERE COALESCE(data -> 'auth_methods', '[]'::jsonb) ? 'discord'
  AND NOT (COALESCE(data -> 'auth_methods', '[]'::jsonb) ? 'email');

-- Consolidated from 013_auth_discord_identity_backfill.sql
UPDATE public.auth_users
SET discord_user_id = user_id,
    data = jsonb_set(
        jsonb_set(data, '{discord_user_id}', to_jsonb(user_id), true),
        '{linked_accounts}',
        COALESCE(data -> 'linked_accounts', '{}'::jsonb)
            || jsonb_build_object(
                'discord',
                COALESCE(data #> '{linked_accounts,discord}', '{}'::jsonb)
                    || jsonb_build_object('discord_user_id', user_id)
            ),
        true
    ),
    updated_at = now()
WHERE COALESCE(data -> 'auth_methods', '[]'::jsonb) ? 'discord'
  AND discord_user_id IS NULL
  AND user_id ~ '^[0-9]{15,20}$';

-- Consolidated from 014_auth_identity_constraint.sql
ALTER TABLE public.auth_users
    ADD CONSTRAINT auth_users_single_identity_provider
    CHECK (email_hash IS NULL OR discord_user_id IS NULL);

-- Consolidated from 015_player_links_hidden.sql
ALTER TABLE public.player_links
    ADD COLUMN IF NOT EXISTS hidden boolean DEFAULT false NOT NULL;

ALTER TABLE public.player_links
    DROP CONSTRAINT IF EXISTS player_links_hidden_requires_verification;

ALTER TABLE public.player_links
    ADD CONSTRAINT player_links_hidden_requires_verification
    CHECK (NOT hidden OR is_verified);

-- Consolidated from 016_dashboard_role_grants.sql
CREATE TABLE public.dashboard_role_grants (
    server_id text NOT NULL REFERENCES public.servers(id) ON DELETE CASCADE,
    role_id text NOT NULL,
    section text NOT NULL,
    access_level text NOT NULL,
    created_by_user_id text REFERENCES public.auth_users(user_id) ON DELETE SET NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT dashboard_role_grants_pkey PRIMARY KEY (server_id, role_id, section),
    CONSTRAINT dashboard_role_grants_section_check CHECK (
        section = ANY (ARRAY[
            'settings',
            'family_settings',
            'logs',
            'clans',
            'rosters',
            'links',
            'moderation',
            'roles',
            'reminders',
            'autoboards',
            'giveaways',
            'panels',
            'tickets',
            'embeds',
            'wars',
            'leaderboards'
        ]::text[])
    ),
    CONSTRAINT dashboard_role_grants_access_level_check CHECK (
        access_level = ANY (ARRAY['view', 'manage']::text[])
    )
);

CREATE INDEX dashboard_role_grants_server_idx
    ON public.dashboard_role_grants (server_id);

CREATE INDEX dashboard_role_grants_role_idx
    ON public.dashboard_role_grants (role_id);

CREATE TABLE public.dashboard_access_audit (
    id uuid DEFAULT uuidv7() NOT NULL PRIMARY KEY,
    server_id text NOT NULL REFERENCES public.servers(id) ON DELETE CASCADE,
    actor_user_id text REFERENCES public.auth_users(user_id) ON DELETE SET NULL,
    action text DEFAULT 'replace_grants' NOT NULL,
    before_grants jsonb DEFAULT '[]'::jsonb NOT NULL,
    after_grants jsonb DEFAULT '[]'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE INDEX dashboard_access_audit_server_created_idx
    ON public.dashboard_access_audit (server_id, created_at DESC);

-- Consolidated from 017_mobile_admin_operations.sql
ALTER TABLE public.mobile_push_devices
    ADD COLUMN IF NOT EXISTS authorization_status text DEFAULT 'not_determined'::text NOT NULL,
    ADD COLUMN IF NOT EXISTS locale text DEFAULT ''::text NOT NULL,
    ADD COLUMN IF NOT EXISTS timezone text DEFAULT ''::text NOT NULL;

-- +goose StatementBegin
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'mobile_push_devices_authorization_status_check'
    ) THEN
        ALTER TABLE public.mobile_push_devices
            ADD CONSTRAINT mobile_push_devices_authorization_status_check
            CHECK (authorization_status = ANY (ARRAY[
                'authorized'::text,
                'provisional'::text,
                'denied'::text,
                'not_determined'::text
            ]));
    END IF;
END $$;
-- +goose StatementEnd

CREATE TABLE IF NOT EXISTS public.mobile_notification_preferences (
    user_id text NOT NULL,
    device_id text NOT NULL,
    environment text DEFAULT 'production'::text NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    locale text DEFAULT ''::text NOT NULL,
    timezone text DEFAULT ''::text NOT NULL,
    enabled_types text[] DEFAULT '{}'::text[] NOT NULL,
    war_attack_modes text[] DEFAULT '{}'::text[] NOT NULL,
    event_types text[] DEFAULT '{}'::text[] NOT NULL,
    reminder_timings text[] DEFAULT '{}'::text[] NOT NULL,
    account_scope text DEFAULT 'all'::text NOT NULL,
    selected_accounts text[] DEFAULT '{}'::text[] NOT NULL,
    selected_town_halls integer[] DEFAULT '{}'::integer[] NOT NULL,
    selected_clan_tags text[] DEFAULT '{}'::text[] NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    PRIMARY KEY (user_id, device_id, environment),
    CONSTRAINT mobile_notification_preferences_environment_check
        CHECK (environment = ANY (ARRAY['sandbox'::text, 'production'::text])),
    CONSTRAINT mobile_notification_preferences_account_scope_check
        CHECK (account_scope = ANY (ARRAY['all'::text, 'selected'::text]))
);

CREATE TABLE IF NOT EXISTS public.mobile_notification_subscriptions (
    id uuid DEFAULT uuidv7() NOT NULL PRIMARY KEY,
    user_id text NOT NULL,
    device_id text NOT NULL,
    environment text DEFAULT 'production'::text NOT NULL,
    notification_type text NOT NULL,
    player_tag text DEFAULT ''::text NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    settings jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT mobile_notification_subscriptions_environment_check
        CHECK (environment = ANY (ARRAY['sandbox'::text, 'production'::text]))
);

CREATE INDEX IF NOT EXISTS idx_mobile_notification_preferences_delivery
    ON public.mobile_notification_preferences (environment, enabled)
    WHERE enabled = true;

CREATE INDEX IF NOT EXISTS idx_mobile_notification_subscriptions_device
    ON public.mobile_notification_subscriptions (user_id, device_id, environment);

CREATE TABLE IF NOT EXISTS public.admin_posts (
    id uuid DEFAULT uuidv7() NOT NULL PRIMARY KEY,
    slug text NOT NULL UNIQUE,
    title text NOT NULL,
    summary text NOT NULL,
    hero_image_url text,
    body_blocks jsonb DEFAULT '[]'::jsonb NOT NULL,
    translations jsonb DEFAULT '{}'::jsonb NOT NULL,
    presentation_type text DEFAULT 'article'::text NOT NULL,
    story_url text,
    story_version integer DEFAULT 1 NOT NULL,
    story_history text[] DEFAULT '{}'::text[] NOT NULL,
    revision_number integer DEFAULT 1 NOT NULL,
    show_on_home boolean DEFAULT true NOT NULL,
    pinned_on_home boolean DEFAULT false NOT NULL,
    target_route text,
    platforms text[] DEFAULT '{ios,android,web}'::text[] NOT NULL,
    dismissible boolean DEFAULT true NOT NULL,
    priority integer DEFAULT 10 NOT NULL,
    status text DEFAULT 'draft'::text NOT NULL,
    starts_at timestamp with time zone,
    ends_at timestamp with time zone,
    also_push_on_publish boolean DEFAULT false NOT NULL,
    push_title text,
    push_body text,
    published_at timestamp with time zone,
    push_sent_at timestamp with time zone,
    created_by text DEFAULT ''::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT admin_posts_status_check
        CHECK ((status = ANY (ARRAY['draft'::text, 'scheduled'::text, 'live'::text, 'expired'::text, 'archived'::text]))),
    CONSTRAINT admin_posts_presentation_type_check
        CHECK ((presentation_type = ANY (ARRAY['article'::text, 'story'::text]))),
    CONSTRAINT admin_posts_story_url_check
        CHECK (presentation_type <> 'story' OR (story_url IS NOT NULL AND story_url LIKE 'https://%')),
    CONSTRAINT admin_posts_pinned_requires_home_check
        CHECK (NOT pinned_on_home OR show_on_home),
    CONSTRAINT admin_posts_story_version_check CHECK (story_version >= 1)
);

ALTER TABLE public.admin_posts
    ADD COLUMN IF NOT EXISTS translations jsonb DEFAULT '{}'::jsonb NOT NULL,
    ADD COLUMN IF NOT EXISTS revision_number integer DEFAULT 1 NOT NULL;

CREATE TABLE IF NOT EXISTS public.admin_post_revisions (
    id uuid DEFAULT uuidv7() NOT NULL PRIMARY KEY,
    post_id uuid NOT NULL REFERENCES public.admin_posts(id) ON DELETE CASCADE,
    revision_number integer NOT NULL,
    snapshot jsonb NOT NULL,
    created_by text DEFAULT ''::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    UNIQUE (post_id, revision_number)
);

CREATE TABLE IF NOT EXISTS public.admin_post_delivery_attempts (
    id uuid DEFAULT uuidv7() NOT NULL PRIMARY KEY,
    post_id uuid NOT NULL REFERENCES public.admin_posts(id) ON DELETE CASCADE,
    attempt_number integer NOT NULL,
    trigger text NOT NULL,
    eligible_count integer DEFAULT 0 NOT NULL,
    sent_count integer DEFAULT 0 NOT NULL,
    skipped_count integer DEFAULT 0 NOT NULL,
    status text NOT NULL,
    error_summary text DEFAULT ''::text NOT NULL,
    attempted_at timestamp with time zone DEFAULT now() NOT NULL,
    UNIQUE (post_id, attempt_number),
    CONSTRAINT admin_post_delivery_trigger_check
        CHECK (trigger = ANY (ARRAY['publish'::text, 'retry'::text, 'manual'::text])),
    CONSTRAINT admin_post_delivery_status_check
        CHECK (status = ANY (ARRAY['queued'::text, 'processing'::text, 'sent'::text, 'partial'::text, 'failed'::text, 'no_audience'::text]))
);

CREATE TABLE IF NOT EXISTS public.admin_notification_campaigns (
    id uuid DEFAULT uuidv7() NOT NULL PRIMARY KEY,
    campaign_key text NOT NULL UNIQUE,
    title text NOT NULL,
    body text NOT NULL,
    target_route text,
    platforms text[] DEFAULT '{ios,android,web}'::text[] NOT NULL,
    target_locales text[] DEFAULT '{}'::text[] NOT NULL,
    translations jsonb DEFAULT '{}'::jsonb NOT NULL,
    status text DEFAULT 'draft'::text NOT NULL,
    trigger_type text DEFAULT 'manual'::text NOT NULL,
    day_of_month integer,
    send_at timestamp with time zone,
    send_time text DEFAULT '09:00'::text,
    last_sent_at timestamp with time zone,
    created_by text DEFAULT ''::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT admin_notification_campaign_status_check CHECK (status = ANY (ARRAY['draft'::text, 'scheduled'::text, 'sent'::text, 'paused'::text])),
    CONSTRAINT admin_notification_campaign_trigger_check CHECK (trigger_type = ANY (ARRAY['manual'::text, 'monthly'::text])),
    CONSTRAINT admin_notification_campaign_day_check CHECK (day_of_month IS NULL OR day_of_month BETWEEN 1 AND 28),
    CONSTRAINT admin_notification_campaign_send_time_check CHECK (send_time IS NULL OR send_time ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'),
    CONSTRAINT admin_notification_campaign_locales_check CHECK (target_locales IS NOT NULL)
);

ALTER TABLE public.admin_notification_campaigns
    ADD COLUMN IF NOT EXISTS target_locales text[] DEFAULT '{}'::text[] NOT NULL,
    ADD COLUMN IF NOT EXISTS translations jsonb DEFAULT '{}'::jsonb NOT NULL,
    ADD COLUMN IF NOT EXISTS send_time text DEFAULT '09:00'::text;

-- +goose StatementBegin
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'admin_notification_campaign_send_time_check'
          AND conrelid = 'public.admin_notification_campaigns'::regclass
    ) THEN
        ALTER TABLE public.admin_notification_campaigns
            ADD CONSTRAINT admin_notification_campaign_send_time_check
            CHECK (send_time IS NULL OR send_time ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$');
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'admin_notification_campaign_locales_check'
          AND conrelid = 'public.admin_notification_campaigns'::regclass
    ) THEN
        ALTER TABLE public.admin_notification_campaigns
            ADD CONSTRAINT admin_notification_campaign_locales_check
            CHECK (target_locales IS NOT NULL);
    END IF;
END $$;
-- +goose StatementEnd

CREATE TABLE IF NOT EXISTS public.admin_feature_flags (
    flag_key text NOT NULL PRIMARY KEY,
    name text NOT NULL,
    description text DEFAULT ''::text NOT NULL,
    enabled boolean DEFAULT false NOT NULL,
    rollout_percentage integer DEFAULT 0 NOT NULL,
    min_app_version text DEFAULT ''::text NOT NULL,
    platforms text[] DEFAULT '{ios,android}'::text[] NOT NULL,
    owner_name text DEFAULT 'Product'::text NOT NULL,
    public_exposure text DEFAULT 'safe'::text NOT NULL,
    starts_at timestamp with time zone,
    ends_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT admin_feature_flags_rollout_check CHECK (rollout_percentage BETWEEN 0 AND 100),
    CONSTRAINT admin_feature_flags_exposure_check CHECK (public_exposure = ANY (ARRAY['safe'::text, 'sensitive'::text]))
);

CREATE TABLE IF NOT EXISTS public.admin_kpi_daily (
    snapshot_date date NOT NULL PRIMARY KEY,
    devices_total integer DEFAULT 0 NOT NULL,
    devices_production integer DEFAULT 0 NOT NULL,
    devices_sandbox integer DEFAULT 0 NOT NULL,
    devices_opted_in integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS public.admin_audit_events (
    id uuid DEFAULT uuidv7() NOT NULL PRIMARY KEY,
    actor text NOT NULL,
    action text NOT NULL,
    resource_type text NOT NULL,
    resource_id text DEFAULT ''::text NOT NULL,
    summary text DEFAULT ''::text NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    ip_address text DEFAULT ''::text NOT NULL,
    user_agent text DEFAULT ''::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS public.admin_users (
    id uuid DEFAULT uuidv7() NOT NULL PRIMARY KEY,
    discord_user_id text NOT NULL UNIQUE,
    username text NOT NULL,
    display_name text NOT NULL,
    avatar_url text DEFAULT ''::text NOT NULL,
    role text DEFAULT 'owner'::text NOT NULL,
    active boolean DEFAULT true NOT NULL,
    last_login_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT admin_users_role_check CHECK (role = ANY (ARRAY['owner'::text, 'admin'::text]))
);

CREATE TABLE IF NOT EXISTS public.admin_sessions (
    id uuid DEFAULT uuidv7() NOT NULL PRIMARY KEY,
    user_id uuid NOT NULL REFERENCES public.admin_users(id) ON DELETE CASCADE,
    token_hash text NOT NULL UNIQUE,
    expires_at timestamp with time zone NOT NULL,
    last_seen_at timestamp with time zone DEFAULT now() NOT NULL,
    revoked_at timestamp with time zone,
    ip_address text DEFAULT ''::text NOT NULL,
    user_agent text DEFAULT ''::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_admin_sessions_user_active
    ON public.admin_sessions (user_id, expires_at DESC)
    WHERE revoked_at IS NULL;

CREATE TABLE IF NOT EXISTS public.admin_campaign_delivery_attempts (
    id uuid DEFAULT uuidv7() NOT NULL PRIMARY KEY,
    campaign_id uuid NOT NULL REFERENCES public.admin_notification_campaigns(id) ON DELETE CASCADE,
    scheduled_for date NOT NULL,
    eligible_count integer DEFAULT 0 NOT NULL,
    sent_count integer DEFAULT 0 NOT NULL,
    skipped_count integer DEFAULT 0 NOT NULL,
    status text NOT NULL,
    attempted_at timestamp with time zone DEFAULT now() NOT NULL,
    UNIQUE (campaign_id, scheduled_for)
);

-- Migration 009 introduced the original announcement model. All current
-- consumers use admin_posts, so preserve legacy rows before retiring it.
-- +goose StatementBegin
DO $$
BEGIN
    IF to_regclass('public.app_announcements') IS NOT NULL THEN
        INSERT INTO public.admin_posts (
            id, slug, title, summary, hero_image_url, body_blocks,
            presentation_type, story_url, show_on_home, platforms, status,
            starts_at, ends_at, published_at, created_at, updated_at
        )
        SELECT
            id,
            'legacy-announcement-' || id::text,
            title,
            subtitle,
            banner_image_url,
            CASE
                WHEN btrim(body) = '' THEN '[]'::jsonb
                ELSE jsonb_build_array(jsonb_build_object('type', 'paragraph', 'text', body))
            END,
            CASE WHEN html_url LIKE 'https://%' THEN 'story' ELSE 'article' END,
            CASE WHEN html_url LIKE 'https://%' THEN html_url ELSE NULL END,
            true,
            CASE WHEN target = 'all' THEN ARRAY['ios', 'android', 'web']::text[] ELSE ARRAY[target]::text[] END,
            CASE
                WHEN status = 'published' AND ends_at IS NOT NULL AND ends_at <= now() THEN 'expired'
                WHEN status = 'published' THEN 'live'
                ELSE status
            END,
            starts_at,
            ends_at,
            CASE WHEN status = 'published' THEN starts_at ELSE NULL END,
            created_at,
            updated_at
        FROM public.app_announcements
        ON CONFLICT (id) DO NOTHING;
    END IF;
END $$;
-- +goose StatementEnd

INSERT INTO public.admin_notification_campaigns
    (campaign_key, title, body, target_route, platforms, translations, status, trigger_type, day_of_month, send_time, last_sent_at, created_by)
VALUES
    (
        'monthly-support',
        'New Season is Live',
        'Getting the Gold Pass? Creator code ClashKing helps us keep a free plan available and continue improving the project, at no extra cost to you. Thank you ❤️',
        '/settings/support',
        '{ios,android,web}',
        $translations${
          "af": {"title": "Nuwe seisoen is hier", "body": "Koop jy die Goue Pas? Skepparkode ClashKing help ons om 'n gratis plan beskikbaar te hou en die projek verder te verbeter, sonder enige ekstra koste vir jou. Dankie ❤️"},
          "ar": {"title": "الموسم الجديد متاح الآن", "body": "هل ستحصل على التذكرة الذهبية؟ يساعدنا رمز المنشئ ClashKing على إبقاء خطة مجانية متاحة ومواصلة تحسين المشروع، دون أي تكلفة إضافية عليك. شكرًا ❤️"},
          "ca": {"title": "La nova temporada ja és aquí", "body": "Compraràs el Passi d'Or? El codi de creador ClashKing ens ajuda a mantenir disponible un pla gratuït i a continuar millorant el projecte, sense cap cost addicional per a tu. Gràcies ❤️"},
          "cs": {"title": "Nová sezóna je tady", "body": "Pořizujete si Zlatý pas? Kód tvůrce ClashKing nám pomáhá zachovat bezplatný tarif a dál projekt vylepšovat, bez dalších nákladů pro vás. Děkujeme ❤️"},
          "da": {"title": "Den nye sæson er i gang", "body": "Køber du Guldpasset? Skaberkoden ClashKing hjælper os med at bevare et gratis abonnement og fortsætte med at forbedre projektet, uden ekstra omkostninger for dig. Tak ❤️"},
          "de": {"title": "Die neue Saison ist da", "body": "Holst du dir den Goldpass? Der Creator-Code ClashKing hilft uns, einen kostenlosen Tarif anzubieten und das Projekt weiterzuentwickeln, ohne zusätzliche Kosten für dich. Danke ❤️"},
          "el": {"title": "Η νέα σεζόν ξεκίνησε", "body": "Θα πάρεις το Χρυσό Πάσο; Ο creator code ClashKing μας βοηθά να διατηρούμε ένα δωρεάν πλάνο και να συνεχίζουμε να βελτιώνουμε το έργο, χωρίς επιπλέον κόστος για εσένα. Ευχαριστούμε ❤️"},
          "es": {"title": "La nueva temporada ya está aquí", "body": "¿Vas a comprar el Pase de Oro? El código de creador ClashKing nos ayuda a mantener un plan gratuito y a seguir mejorando el proyecto, sin ningún coste adicional para ti. Gracias ❤️"},
          "fi": {"title": "Uusi kausi on täällä", "body": "Oletko hankkimassa Kultapassia? Sisällöntuottajakoodi ClashKing auttaa meitä pitämään ilmaisen vaihtoehdon saatavilla ja jatkamaan projektin kehittämistä ilman lisäkustannuksia sinulle. Kiitos ❤️"},
          "fr": {"title": "La nouvelle saison est arrivée", "body": "Tu prends le Pass Or ? Le code créateur ClashKing nous aide à maintenir une offre gratuite et à continuer de faire évoluer le projet, sans coût supplémentaire pour toi. Merci ❤️"},
          "he": {"title": "העונה החדשה כאן", "body": "מתכננים לרכוש את כרטיס הזהב? קוד היוצר ClashKing עוזר לנו לשמור על מסלול חינמי ולהמשיך לשפר את הפרויקט, ללא עלות נוספת עבורכם. תודה ❤️"},
          "hi": {"title": "नया सीज़न शुरू हो गया है", "body": "गोल्ड पास खरीद रहे हैं? क्रिएटर कोड ClashKing हमें मुफ़्त प्लान उपलब्ध रखने और प्रोजेक्ट को बेहतर बनाते रहने में मदद करता है, आपके लिए बिना किसी अतिरिक्त लागत के। धन्यवाद ❤️"},
          "hu": {"title": "Itt az új szezon", "body": "Megveszed az Aranybérletet? A ClashKing alkotói kód segít fenntartani egy ingyenes csomagot és tovább fejleszteni a projektet, számodra többletköltség nélkül. Köszönjük ❤️"},
          "it": {"title": "La nuova stagione è arrivata", "body": "Acquisti il Pass d'oro? Il codice creatore ClashKing ci aiuta a mantenere un piano gratuito e a continuare a migliorare il progetto, senza costi aggiuntivi per te. Grazie ❤️"},
          "ja": {"title": "新シーズン開幕", "body": "ゴールドパスを購入しますか？クリエイターコード「ClashKing」は、無料プランの提供を維持し、プロジェクトを改善し続ける支えになります。追加費用はかかりません。ありがとうございます ❤️"},
          "ko": {"title": "새 시즌이 시작되었습니다", "body": "골드 패스를 구매하시나요? 크리에이터 코드 ClashKing은 무료 플랜을 유지하고 프로젝트를 계속 개선하는 데 도움이 되며, 추가 비용은 없습니다. 감사합니다 ❤️"},
          "nl": {"title": "Het nieuwe seizoen is begonnen", "body": "Koop je de Goudpas? Creatorcode ClashKing helpt ons een gratis abonnement beschikbaar te houden en het project te blijven verbeteren, zonder extra kosten voor jou. Bedankt ❤️"},
          "no": {"title": "Den nye sesongen er i gang", "body": "Kjøper du Gullpasset? Skaperkoden ClashKing hjelper oss med å beholde et gratis abonnement og fortsette å forbedre prosjektet, uten ekstra kostnad for deg. Takk ❤️"},
          "pl": {"title": "Nowy sezon już trwa", "body": "Kupujesz Złotą Przepustkę? Kod twórcy ClashKing pomaga nam utrzymać darmowy plan i dalej rozwijać projekt, bez dodatkowych kosztów dla Ciebie. Dziękujemy ❤️"},
          "pt": {"title": "A nova temporada chegou", "body": "Vai comprar o Passe de Ouro? O código de criador ClashKing ajuda-nos a manter um plano gratuito e a continuar melhorando o projeto, sem nenhum custo adicional para você. Obrigado ❤️"},
          "ro": {"title": "Noul sezon a început", "body": "Cumperi Permisul de Aur? Codul de creator ClashKing ne ajută să menținem un plan gratuit și să continuăm îmbunătățirea proiectului, fără costuri suplimentare pentru tine. Mulțumim ❤️"},
          "ru": {"title": "Новый сезон уже начался", "body": "Покупаете Золотой пропуск? Код автора ClashKing помогает нам сохранять бесплатный тариф и продолжать улучшать проект без дополнительных затрат для вас. Спасибо ❤️"},
          "sr": {"title": "Нова сезона је почела", "body": "Купујете Златну пропусницу? Код креатора ClashKing нам помаже да задржимо бесплатан план и наставимо да унапређујемо пројекат, без додатних трошкова за вас. Хвала ❤️"},
          "sv": {"title": "Den nya säsongen är här", "body": "Köper du Guldpasset? Skaparkoden ClashKing hjälper oss att behålla ett kostnadsfritt abonnemang och fortsätta förbättra projektet, utan extra kostnad för dig. Tack ❤️"},
          "tr": {"title": "Yeni sezon başladı", "body": "Altın Bilet alıyor musun? İçerik üreticisi kodu ClashKing, ücretsiz bir plan sunmaya devam etmemize ve projeyi geliştirmemize yardımcı olur; sana ek bir maliyeti yoktur. Teşekkürler ❤️"},
          "uk": {"title": "Новий сезон уже почався", "body": "Купуєте Золотий пропуск? Код автора ClashKing допомагає нам зберігати безкоштовний план і продовжувати вдосконалювати проєкт без додаткових витрат для вас. Дякуємо ❤️"},
          "ur": {"title": "نیا سیزن شروع ہو گیا ہے", "body": "گولڈ پاس خرید رہے ہیں؟ کریئیٹر کوڈ ClashKing ہمیں مفت پلان دستیاب رکھنے اور پروجیکٹ کو بہتر بناتے رہنے میں مدد کرتا ہے، آپ کے لیے کسی اضافی لاگت کے بغیر۔ شکریہ ❤️"},
          "vi": {"title": "Mùa giải mới đã bắt đầu", "body": "Bạn sẽ mua Vé Vàng? Mã nhà sáng tạo ClashKing giúp chúng tôi duy trì gói miễn phí và tiếp tục cải thiện dự án mà bạn không phải trả thêm chi phí. Cảm ơn ❤️"},
          "zh": {"title": "新赛季已开启", "body": "准备购买黄金令牌吗？创作者代码 ClashKing 能帮助我们保留免费方案并继续改进项目，你无需支付任何额外费用。谢谢 ❤️"}
        }$translations$::jsonb,
        'scheduled',
        'monthly',
        1,
        '09:00',
        now(),
        'system'
    )
ON CONFLICT (campaign_key) DO NOTHING;

-- Mobile feature catalogue. Established features fail open in the client;
-- preview/incomplete surfaces are disabled until explicitly enabled by an
-- administrator. ON CONFLICT preserves values already configured pre-prod.
INSERT INTO public.admin_feature_flags
    (flag_key, name, description, enabled, rollout_percentage, platforms, owner_name, public_exposure)
VALUES
    ('notifications', 'Notification settings', 'Controls push initialization, device registration, and notification settings.', true, 100, '{ios,android}', 'Mobile', 'safe'),
    ('posts', 'Posts archive', 'Shows the posts archive in the account drawer.', true, 100, '{ios,android,web}', 'Content', 'safe'),
    ('home_announcements', 'Home announcements', 'Allows featured post stories to open automatically on the home screen.', true, 100, '{ios,android}', 'Content', 'safe'),
    ('popular_insights', 'Popular insights', 'Shows the experimental locally-derived Popular screen.', false, 0, '{ios,android,web}', 'Product', 'safe'),
    ('leaderboards', 'Leaderboards', 'Shows official player and clan leaderboards backed by the Clash API proxy.', true, 100, '{ios,android,web}', 'Product', 'safe'),
    ('leaderboard_previews', 'Leaderboard endpoint previews', 'Shows unfinished ClashKing leaderboard endpoint mockups below official rankings.', false, 0, '{ios,android,web}', 'Product', 'safe'),
    ('global_stats', 'Global stats', 'Shows aggregate ranking statistics backed by the Clash API proxy.', true, 100, '{ios,android,web}', 'Product', 'safe'),
    ('calculators', 'Calculators', 'Shows ore, ZapQuake, and Fireball calculators.', true, 100, '{ios,android,web}', 'Mobile', 'safe'),
    ('subscription_support', 'Subscription support', 'Shows the unfinished monthly support subscription surface.', false, 0, '{ios,android}', 'Product', 'safe'),
    ('upgrade_tracker', 'Upgrade tracker', 'Shows the upgrade tracker and its remote game-data integration.', true, 100, '{ios,android,web}', 'Mobile', 'safe'),
    ('bases_armies', 'Bases and armies', 'Shows the unfinished Discord-synced bases and armies surface.', false, 0, '{ios,android,web}', 'Discord', 'safe'),
    ('game_assets', 'Game assets', 'Shows the browsable Clash of Clans asset catalogue.', true, 100, '{ios,android,web}', 'Mobile', 'safe'),
    ('clan_rankings_preview', 'Clan rankings preview', 'Shows fabricated clan ranking previews while the real endpoint is unavailable.', false, 0, '{ios,android,web}', 'Product', 'safe'),
    ('cwl_history_preview', 'CWL history preview', 'Shows fabricated CWL history while the real endpoint is unavailable.', false, 0, '{ios,android,web}', 'Product', 'safe'),
    ('account_connections', 'Account connection controls', 'Shows unfinished Discord and email connect/disconnect controls in Settings.', false, 0, '{ios,android,web}', 'Auth', 'safe'),
    ('war_widgets', 'War widgets', 'Shows war home-screen widget configuration and background refresh integration.', true, 100, '{ios,android}', 'Mobile', 'safe'),
    ('feature_requests', 'Feature requests', 'Shows the embedded external feature-request portal.', true, 100, '{ios,android,web}', 'Product', 'safe')
ON CONFLICT (flag_key) DO NOTHING;

CREATE INDEX IF NOT EXISTS idx_admin_posts_status ON public.admin_posts (status);
CREATE INDEX IF NOT EXISTS idx_admin_feature_flags_active ON public.admin_feature_flags (enabled, starts_at, ends_at);
CREATE INDEX IF NOT EXISTS idx_admin_audit_events_created ON public.admin_audit_events (created_at DESC);
CREATE INDEX IF NOT EXISTS idx_admin_audit_events_resource ON public.admin_audit_events (resource_type, resource_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_admin_posts_starts_at ON public.admin_posts (starts_at) WHERE status = 'scheduled';
CREATE INDEX IF NOT EXISTS idx_admin_posts_home_selection
    ON public.admin_posts (pinned_on_home DESC, priority DESC, published_at DESC)
    WHERE status = 'live' AND show_on_home = true;
CREATE INDEX IF NOT EXISTS idx_admin_post_revisions_post
    ON public.admin_post_revisions (post_id, revision_number DESC);
CREATE INDEX IF NOT EXISTS idx_admin_post_delivery_attempts_post
    ON public.admin_post_delivery_attempts (post_id, attempt_number DESC);
CREATE INDEX IF NOT EXISTS idx_admin_notification_campaigns_due
    ON public.admin_notification_campaigns (status, trigger_type, send_at, day_of_month, send_time);
CREATE INDEX IF NOT EXISTS idx_admin_notification_campaigns_target_locales
    ON public.admin_notification_campaigns USING gin (target_locales);

-- Consolidated from 018_schema_history_reconciliation.sql
-- Versions 009-012 briefly collided with an unmerged mobile operations series.
-- Reassert the idempotent parts of the canonical 010-012 contracts for any
-- development database that recorded those version numbers with other SQL.
ALTER TABLE public.autoboards
    ADD COLUMN IF NOT EXISTS board_type text DEFAULT '' NOT NULL,
    ADD COLUMN IF NOT EXISTS button_id text DEFAULT '' NOT NULL,
    ADD COLUMN IF NOT EXISTS days text[] DEFAULT '{}'::text[] NOT NULL,
    ADD COLUMN IF NOT EXISTS locale text DEFAULT '' NOT NULL;

ALTER TABLE public.roster_groups
    ADD COLUMN IF NOT EXISTS created_at timestamp with time zone DEFAULT now() NOT NULL;

ALTER TABLE public.rosters
    DROP COLUMN IF EXISTS linked_clan_tag,
    DROP COLUMN IF EXISTS title,
    DROP COLUMN IF EXISTS description,
    DROP COLUMN IF EXISTS max_size,
    DROP COLUMN IF EXISTS minimum_townhall,
    DROP COLUMN IF EXISTS maximum_townhall,
    DROP COLUMN IF EXISTS image_url,
    DROP COLUMN IF EXISTS signup_role_id;

DROP TABLE IF EXISTS public.api_tokens;

CREATE MATERIALIZED VIEW IF NOT EXISTS public.api_global_counts AS
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

CREATE UNIQUE INDEX IF NOT EXISTS api_global_counts_id_idx
    ON public.api_global_counts (id);

CREATE MATERIALIZED VIEW IF NOT EXISTS public.api_league_tier_counts AS
SELECT
    COALESCE(league_id, 0) AS league_tier_id,
    count(*)::bigint AS player_count,
    now() AS refreshed_at
FROM public.basic_player
GROUP BY COALESCE(league_id, 0);

CREATE UNIQUE INDEX IF NOT EXISTS api_league_tier_counts_id_idx
    ON public.api_league_tier_counts (league_tier_id);

UPDATE public.auth_users
SET email_hash = NULL,
    password_hash = NULL,
    data = (data - 'email_encrypted' - 'email_hash' - 'password')
        #- '{linked_accounts,email}',
    updated_at = now()
WHERE COALESCE(data -> 'auth_methods', '[]'::jsonb) ? 'discord'
  AND NOT (COALESCE(data -> 'auth_methods', '[]'::jsonb) ? 'email');

-- Consolidated from 019_normalize_server_roster_settings.sql
-- +goose StatementBegin
CREATE FUNCTION pg_temp.ck_bool(value text, fallback boolean DEFAULT NULL)
RETURNS boolean LANGUAGE plpgsql AS $$
BEGIN
    IF value IS NULL OR btrim(value) = '' THEN RETURN fallback; END IF;
    RETURN value::boolean;
EXCEPTION WHEN OTHERS THEN RETURN fallback;
END
$$;
-- +goose StatementEnd

-- +goose StatementBegin
CREATE FUNCTION pg_temp.ck_int(value text, fallback integer DEFAULT NULL)
RETURNS integer LANGUAGE plpgsql AS $$
BEGIN
    IF value IS NULL OR btrim(value) = '' THEN RETURN fallback; END IF;
    RETURN value::integer;
EXCEPTION WHEN OTHERS THEN RETURN fallback;
END
$$;
-- +goose StatementEnd

-- +goose StatementBegin
CREATE FUNCTION pg_temp.ck_bigint(value text, fallback bigint DEFAULT NULL)
RETURNS bigint LANGUAGE plpgsql AS $$
BEGIN
    IF value IS NULL OR btrim(value) = '' THEN RETURN fallback; END IF;
    RETURN value::bigint;
EXCEPTION WHEN OTHERS THEN RETURN fallback;
END
$$;
-- +goose StatementEnd

-- +goose StatementBegin
CREATE FUNCTION pg_temp.ck_float(value text, fallback double precision DEFAULT NULL)
RETURNS double precision LANGUAGE plpgsql AS $$
BEGIN
    IF value IS NULL OR btrim(value) = '' THEN RETURN fallback; END IF;
    RETURN value::double precision;
EXCEPTION WHEN OTHERS THEN RETURN fallback;
END
$$;
-- +goose StatementEnd

-- +goose StatementBegin
CREATE FUNCTION pg_temp.ck_role_mode(value jsonb, fallback text DEFAULT 'sync')
RETURNS text LANGUAGE plpgsql AS $$
BEGIN
    IF jsonb_typeof(value) <> 'array' THEN RETURN fallback; END IF;
    IF value @> '["Add"]'::jsonb AND value @> '["Remove"]'::jsonb THEN RETURN 'sync'; END IF;
    IF value @> '["Remove"]'::jsonb THEN RETURN 'remove'; END IF;
    IF value @> '["Add"]'::jsonb THEN RETURN 'add'; END IF;
    RETURN fallback;
END
$$;
-- +goose StatementEnd

CREATE TABLE public.server_settings (
    server_id text PRIMARY KEY REFERENCES public.servers(id) ON DELETE CASCADE,
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
    family_label text DEFAULT '' NOT NULL,
    greeting text,
    link_parse_clan boolean DEFAULT true NOT NULL,
    link_parse_army boolean DEFAULT true NOT NULL,
    link_parse_player boolean DEFAULT true NOT NULL,
    link_parse_base boolean DEFAULT true NOT NULL,
    link_parse_show boolean DEFAULT true NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.server_autoeval_triggers (
    server_id text NOT NULL REFERENCES public.servers(id) ON DELETE CASCADE,
    trigger text NOT NULL,
    position integer DEFAULT 0 NOT NULL,
    PRIMARY KEY (server_id, trigger)
);

CREATE TABLE public.server_blacklisted_roles (
    server_id text NOT NULL REFERENCES public.servers(id) ON DELETE CASCADE,
    role_id text NOT NULL,
    PRIMARY KEY (server_id, role_id)
);

CREATE TABLE public.server_link_parse_channels (
    server_id text NOT NULL REFERENCES public.servers(id) ON DELETE CASCADE,
    channel_id text NOT NULL,
    PRIMARY KEY (server_id, channel_id)
);

CREATE TABLE public.server_logs (
    server_id text NOT NULL REFERENCES public.servers(id) ON DELETE CASCADE,
    log_type text NOT NULL,
    enabled boolean DEFAULT false NOT NULL,
    channel_id text,
    thread_id text,
    webhook_id text,
    include_buttons boolean,
    ping_role_id text,
    PRIMARY KEY (server_id, log_type)
);

CREATE TABLE public.server_log_clans (
    server_id text NOT NULL,
    log_type text NOT NULL,
    clan_tag text NOT NULL,
    PRIMARY KEY (server_id, log_type, clan_tag),
    FOREIGN KEY (server_id, log_type) REFERENCES public.server_logs(server_id, log_type) ON DELETE CASCADE
);

CREATE TABLE public.server_welcome_panels (
    server_id text PRIMARY KEY REFERENCES public.servers(id) ON DELETE CASCADE,
    embed_name text,
    button_color text DEFAULT 'Grey' NOT NULL,
    welcome_channel_id text,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE public.server_welcome_panel_buttons (
    server_id text NOT NULL REFERENCES public.server_welcome_panels(server_id) ON DELETE CASCADE,
    button_name text NOT NULL,
    position integer DEFAULT 0 NOT NULL,
    PRIMARY KEY (server_id, button_name)
);

CREATE TABLE public.role_rules (
    id uuid DEFAULT uuidv7() PRIMARY KEY,
    server_id text NOT NULL REFERENCES public.servers(id) ON DELETE CASCADE,
    clan_tag text,
    type text NOT NULL,
    option text NOT NULL,
    role_id text NOT NULL,
    mode text DEFAULT 'sync' NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT role_rules_type_check CHECK (type = ANY (ARRAY[
        'townhall', 'builderhall', 'league', 'builder_league',
        'clan_role', 'clan_category', 'family', 'achievement',
        'status', 'ignored'
    ])),
    CONSTRAINT role_rules_mode_check CHECK (mode = ANY (ARRAY['add', 'remove', 'sync'])),
    CONSTRAINT role_rules_scope_check CHECK (clan_tag IS NULL OR type = 'clan_role'),
    CONSTRAINT role_rules_option_check CHECK (btrim(option) <> ''),
    CONSTRAINT role_rules_role_id_check CHECK (btrim(role_id) <> ''),
    CONSTRAINT role_rules_clan_fkey FOREIGN KEY (clan_tag, server_id)
        REFERENCES public.server_clans(tag, server_id) ON DELETE CASCADE,
    UNIQUE NULLS NOT DISTINCT (server_id, clan_tag, type, option, role_id)
);

CREATE INDEX idx_role_rules_server_type ON public.role_rules (server_id, type);
CREATE INDEX idx_role_rules_clan ON public.role_rules (server_id, clan_tag) WHERE clan_tag IS NOT NULL;

CREATE TABLE public.server_clan_settings (
    server_id text NOT NULL,
    clan_tag text NOT NULL,
    greeting text DEFAULT '' NOT NULL,
    auto_greet_option text DEFAULT 'Never' NOT NULL,
    ban_alert_channel_id text,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    PRIMARY KEY (server_id, clan_tag),
    FOREIGN KEY (clan_tag, server_id) REFERENCES public.server_clans(tag, server_id) ON DELETE CASCADE
);

CREATE TABLE public.countdowns (
    server_id text NOT NULL REFERENCES public.servers(id) ON DELETE CASCADE,
    clan_tag text,
    channel_id text NOT NULL,
    type text NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT countdowns_type_check CHECK (type = ANY (ARRAY[
        'clan_games_timer', 'cwl_timer', 'raid_weekend_timer',
        'season_end_timer', 'season_day_timer', 'war_score', 'war_timer'
    ])),
    CONSTRAINT countdowns_scope_check CHECK (
        (type = ANY (ARRAY['war_score', 'war_timer']) AND clan_tag IS NOT NULL)
        OR
        (type <> ALL (ARRAY['war_score', 'war_timer']) AND clan_tag IS NULL)
    ),
    CONSTRAINT countdowns_clan_fkey FOREIGN KEY (clan_tag, server_id)
        REFERENCES public.server_clans(tag, server_id) ON DELETE CASCADE,
    UNIQUE NULLS NOT DISTINCT (server_id, clan_tag, type)
);

CREATE INDEX idx_countdowns_server ON public.countdowns (server_id, type);

ALTER TABLE public.clan_logs
    ADD COLUMN IF NOT EXISTS channel_id text,
    ADD COLUMN IF NOT EXISTS active_war_id text,
    ADD COLUMN IF NOT EXISTS active_raid_id text,
    ADD COLUMN IF NOT EXISTS message_id text;

INSERT INTO public.server_settings (
    server_id, nickname_rule, non_family_nickname_rule, change_nickname,
    flair_non_family, auto_eval_nickname, autoeval_log_channel_id,
    autoeval_enabled, full_whitelist_role_id,
    autoboard_limit, use_api_token, tied_stats_only, banlist_channel_id,
    strike_log_channel_id, reddit_feed_channel_id, family_label, greeting,
    link_parse_clan, link_parse_army, link_parse_player, link_parse_base,
    link_parse_show, updated_at
)
SELECT id,
       NULLIF(data->>'nickname_rule', ''),
       NULLIF(data->>'non_family_nickname_rule', ''),
       pg_temp.ck_bool(data->>'change_nickname', true),
       pg_temp.ck_bool(data->>'flair_non_family', true),
       pg_temp.ck_bool(data->>'auto_eval_nickname', false),
       NULLIF(data->>'autoeval_log', ''),
       pg_temp.ck_bool(data->>'autoeval', false),
       NULLIF(data->>'full_whitelist_role', ''),
       pg_temp.ck_int(data->>'autoboard_limit', 0),
       pg_temp.ck_bool(data->>'api_token', true),
       pg_temp.ck_bool(data->>'tied', true),
       NULLIF(data->>'banlist', ''),
       NULLIF(data->>'strike_log', ''),
       NULLIF(data->>'reddit_feed', ''),
       COALESCE(data->>'family_label', ''),
       NULLIF(data->>'greeting', ''),
       pg_temp.ck_bool(data#>>'{link_parse,clan}', true),
       pg_temp.ck_bool(data#>>'{link_parse,army}', true),
       pg_temp.ck_bool(data#>>'{link_parse,player}', true),
       pg_temp.ck_bool(data#>>'{link_parse,base}', true),
       pg_temp.ck_bool(data#>>'{link_parse,show}', true),
       updated_at
FROM public.servers
ON CONFLICT (server_id) DO NOTHING;

INSERT INTO public.server_autoeval_triggers (server_id, trigger, position)
SELECT s.id, value, ordinality::integer
FROM public.servers s
CROSS JOIN LATERAL jsonb_array_elements_text(
    CASE WHEN jsonb_typeof(s.data->'autoeval_triggers') = 'array' THEN s.data->'autoeval_triggers' ELSE '[]'::jsonb END
) WITH ORDINALITY AS item(value, ordinality)
ON CONFLICT DO NOTHING;

INSERT INTO public.server_blacklisted_roles (server_id, role_id)
SELECT s.id, value
FROM public.servers s
CROSS JOIN LATERAL jsonb_array_elements_text(
    CASE WHEN jsonb_typeof(s.data->'blacklisted_roles') = 'array' THEN s.data->'blacklisted_roles' ELSE '[]'::jsonb END
) AS item(value)
ON CONFLICT DO NOTHING;

INSERT INTO public.role_rules (server_id, type, option, role_id, mode)
SELECT s.id, 'clan_category', item.key, item.value #>> '{}', pg_temp.ck_role_mode(s.data->'role_treatment')
FROM public.servers s
CROSS JOIN LATERAL jsonb_each(
    CASE WHEN jsonb_typeof(s.data->'category_roles') = 'object' THEN s.data->'category_roles' ELSE '{}'::jsonb END
) AS item(key, value)
WHERE item.value #>> '{}' <> ''
ON CONFLICT DO NOTHING;

INSERT INTO public.server_link_parse_channels (server_id, channel_id)
SELECT s.id, value
FROM public.servers s
CROSS JOIN LATERAL jsonb_array_elements_text(
    CASE WHEN jsonb_typeof(s.data#>'{link_parse,channels}') = 'array' THEN s.data#>'{link_parse,channels}' ELSE '[]'::jsonb END
) AS item(value)
ON CONFLICT DO NOTHING;

INSERT INTO public.server_logs (server_id, log_type, enabled, channel_id, thread_id, webhook_id, include_buttons, ping_role_id)
SELECT s.id, item.key,
       pg_temp.ck_bool(item.value->>'enabled', item.value ? 'webhook'),
       NULLIF(item.value->>'channel', ''), NULLIF(item.value->>'thread', ''),
       NULLIF(item.value->>'webhook', ''),
       pg_temp.ck_bool(item.value->>'include_buttons'),
       NULLIF(item.value->>'ping_role', '')
FROM public.servers s
CROSS JOIN LATERAL jsonb_each(
    CASE WHEN jsonb_typeof(s.logs_config) = 'object' THEN s.logs_config ELSE '{}'::jsonb END
) AS item(key, value)
WHERE jsonb_typeof(item.value) = 'object' AND item.key <> 'welcome_link'
ON CONFLICT DO NOTHING;

INSERT INTO public.role_rules (server_id, type, option, role_id, mode)
SELECT s.id, 'status',
       COALESCE(NULLIF(item.value->>'key', ''), NULLIF(item.value->>'number', ''), NULLIF(item.value->>'months', ''), 'member'),
       COALESCE(NULLIF(item.value->>'id', ''), NULLIF(item.value->>'role', '')),
       pg_temp.ck_role_mode(s.data->'role_treatment')
FROM public.servers s
CROSS JOIN LATERAL jsonb_array_elements(
    CASE WHEN jsonb_typeof(s.status_roles->'discord') = 'array' THEN s.status_roles->'discord' ELSE '[]'::jsonb END
) WITH ORDINALITY AS item(value, ordinality)
WHERE COALESCE(NULLIF(item.value->>'id', ''), NULLIF(item.value->>'role', '')) IS NOT NULL
ON CONFLICT DO NOTHING;

INSERT INTO public.server_welcome_panels (server_id, embed_name, button_color, welcome_channel_id, updated_at)
SELECT s.id,
       COALESCE(NULLIF(s.logs_config#>>'{welcome_link,embed_name}', ''), NULLIF(s.data->>'welcome_link_embed', '')),
       COALESCE(NULLIF(s.logs_config#>>'{welcome_link,button_color}', ''), 'Grey'),
       COALESCE(NULLIF(s.logs_config#>>'{welcome_link,welcome_channel}', ''), NULLIF(s.data->>'welcome_link_channel', '')),
       s.updated_at
FROM public.servers s
WHERE s.logs_config ? 'welcome_link' OR s.data ? 'welcome_link_embed' OR s.data ? 'welcome_link_channel'
ON CONFLICT (server_id) DO NOTHING;

INSERT INTO public.server_welcome_panel_buttons (server_id, button_name, position)
SELECT s.id, item.value, item.ordinality::integer
FROM public.servers s
CROSS JOIN LATERAL jsonb_array_elements_text(
    CASE WHEN jsonb_typeof(s.logs_config#>'{welcome_link,buttons}') = 'array'
         THEN s.logs_config#>'{welcome_link,buttons}' ELSE '[]'::jsonb END
) WITH ORDINALITY AS item(value, ordinality)
ON CONFLICT DO NOTHING;

INSERT INTO public.countdowns (server_id, clan_tag, type, channel_id)
SELECT s.id, NULL,
       CASE item.key
           WHEN 'gamesCountdown' THEN 'clan_games_timer'
           WHEN 'cwlCountdown' THEN 'cwl_timer'
           WHEN 'raidCountdown' THEN 'raid_weekend_timer'
           WHEN 'eosCountdown' THEN 'season_end_timer'
           WHEN 'seasonCountdown' THEN 'season_day_timer'
       END,
       item.value
FROM public.servers s
CROSS JOIN LATERAL jsonb_each_text(
    CASE WHEN jsonb_typeof(s.countdowns) = 'object' THEN s.countdowns ELSE '{}'::jsonb END
) AS item(key, value)
WHERE item.value <> '' AND item.key = ANY (ARRAY[
    'gamesCountdown', 'cwlCountdown', 'raidCountdown', 'eosCountdown', 'seasonCountdown'
])
ON CONFLICT DO NOTHING;

INSERT INTO public.clan_categories (server_id, name)
SELECT DISTINCT server_id, data->>'category'
FROM public.server_clans
WHERE COALESCE(data->>'category', '') <> ''
ON CONFLICT (server_id, name) DO NOTHING;

UPDATE public.server_clans sc
SET category_id = category.id
FROM public.clan_categories category
WHERE sc.server_id = category.server_id
  AND sc.data->>'category' = category.name
  AND sc.category_id IS NULL;

INSERT INTO public.server_clan_settings (
    server_id, clan_tag, greeting, auto_greet_option,
    ban_alert_channel_id, updated_at
)
SELECT server_id, tag, COALESCE(data->>'greeting', ''),
       COALESCE(NULLIF(data->>'auto_greet_option', ''), 'Never'),
       NULLIF(data->>'ban_alert_channel', ''),
       updated_at
FROM public.server_clans
ON CONFLICT DO NOTHING;

INSERT INTO public.role_rules (server_id, clan_tag, type, option, role_id, mode)
SELECT server_id, tag, 'clan_role', 'member', data->>'generalRole', 'sync'
FROM public.server_clans
WHERE COALESCE(data->>'generalRole', '') <> ''
ON CONFLICT DO NOTHING;

INSERT INTO public.role_rules (server_id, clan_tag, type, option, role_id, mode)
SELECT server_id, tag, 'clan_role', 'leader', data->>'leaderRole',
       CASE WHEN pg_temp.ck_bool(data->>'leadership_eval', true) THEN 'sync' ELSE 'remove' END
FROM public.server_clans
WHERE COALESCE(data->>'leaderRole', '') <> ''
ON CONFLICT DO NOTHING;

INSERT INTO public.role_rules (server_id, type, option, role_id, mode)
SELECT settings.server_id, 'family', 'member', role.value #>> '{}',
       pg_temp.ck_role_mode(settings.data->'role_treatment')
FROM public.server_role_settings settings
CROSS JOIN LATERAL jsonb_path_query(settings.family_roles, '$.** ? (@.type() == "string")') AS role(value)
WHERE COALESCE(role.value #>> '{}', '') <> ''
ON CONFLICT DO NOTHING;

INSERT INTO public.role_rules (server_id, type, option, role_id, mode)
SELECT settings.server_id, 'family', 'not_family', role.value #>> '{}',
       pg_temp.ck_role_mode(settings.data->'role_treatment')
FROM public.server_role_settings settings
CROSS JOIN LATERAL jsonb_path_query(settings.not_family_roles, '$.** ? (@.type() == "string")') AS role(value)
WHERE COALESCE(role.value #>> '{}', '') <> ''
ON CONFLICT DO NOTHING;

INSERT INTO public.role_rules (server_id, type, option, role_id, mode)
SELECT settings.server_id, 'family', 'only_family', role.value #>> '{}',
       pg_temp.ck_role_mode(settings.data->'role_treatment')
FROM public.server_role_settings settings
CROSS JOIN LATERAL jsonb_path_query(settings.family_exclusive_roles, '$.** ? (@.type() == "string")') AS role(value)
WHERE COALESCE(role.value #>> '{}', '') <> ''
ON CONFLICT DO NOTHING;

INSERT INTO public.role_rules (server_id, type, option, role_id, mode)
SELECT settings.server_id, 'ignored', 'evaluation', role.value #>> '{}', 'sync'
FROM public.server_role_settings settings
CROSS JOIN LATERAL jsonb_path_query(settings.ignored_roles, '$.** ? (@.type() == "string")') AS role(value)
WHERE COALESCE(role.value #>> '{}', '') <> ''
ON CONFLICT DO NOTHING;

INSERT INTO public.role_rules (server_id, type, option, role_id, mode, created_at, updated_at)
SELECT binding.server_id,
       CASE binding.role_type
           WHEN 'family_position' THEN 'clan_role'
           WHEN 'family' THEN 'family'
           WHEN 'not_family' THEN 'family'
           WHEN 'only_family' THEN 'family'
           WHEN 'ignored' THEN 'ignored'
           ELSE binding.role_type
       END,
       CASE
           WHEN binding.role_type = 'family_position' THEN
               CASE binding.role_key
                   WHEN 'family_member_roles' THEN 'member'
                   WHEN 'family_elder_roles' THEN 'elder'
                   WHEN 'family_co-leader_roles' THEN 'co_leader'
                   WHEN 'family_leader_roles' THEN 'leader'
                   ELSE binding.role_key
               END
           WHEN binding.role_type = 'family' THEN 'member'
           WHEN binding.role_type = 'not_family' THEN 'not_family'
           WHEN binding.role_type = 'only_family' THEN 'only_family'
           WHEN binding.role_type = 'ignored' THEN 'evaluation'
           ELSE binding.role_key
       END,
       binding.role_id,
       pg_temp.ck_role_mode(server.data->'role_treatment'),
       binding.created_at,
       binding.updated_at
FROM public.role_bindings binding
JOIN public.servers server ON server.id = binding.server_id
WHERE binding.role_type = ANY (ARRAY[
    'townhall', 'builderhall', 'league', 'builder_league',
    'achievement', 'family_position', 'family', 'not_family',
    'only_family', 'ignored'
])
  AND (
      COALESCE(binding.role_key, '') <> ''
      OR binding.role_type = ANY (ARRAY['family', 'not_family', 'only_family', 'ignored'])
  )
ON CONFLICT DO NOTHING;

INSERT INTO public.role_rules (server_id, clan_tag, type, option, role_id, mode, created_at, updated_at)
SELECT role.server_id, role.clan_tag, 'clan_role',
       CASE role.position WHEN 'coleader' THEN 'co_leader' ELSE role.position END,
       role.role_id, pg_temp.ck_role_mode(server.data->'role_treatment'), now(), now()
FROM public.clan_position_roles role
JOIN public.servers server ON server.id = role.server_id
ON CONFLICT DO NOTHING;

INSERT INTO public.role_rules (server_id, type, option, role_id, mode)
SELECT role.server_id,
       CASE WHEN role.is_townhall THEN 'townhall' ELSE 'builderhall' END,
       role.hall_level::text, role.role_id,
       pg_temp.ck_role_mode(server.data->'role_treatment')
FROM public.hall_roles role
JOIN public.servers server ON server.id = role.server_id
ON CONFLICT DO NOTHING;

INSERT INTO public.role_rules (server_id, type, option, role_id, mode)
SELECT role.server_id, 'league', role.league_id::text, role.role_id,
       pg_temp.ck_role_mode(server.data->'role_treatment')
FROM public.league_roles role
JOIN public.servers server ON server.id = role.server_id
ON CONFLICT DO NOTHING;

INSERT INTO public.role_rules (server_id, type, option, role_id, mode, created_at)
SELECT role.server_id, 'ignored', 'evaluation', role.role_id, 'sync', role.created_at
FROM public.role_ignore_bindings role
ON CONFLICT DO NOTHING;

INSERT INTO public.clan_logs (
    server_id, clan_tag, type, webhook_token, thread_id, channel_id,
    active_war_id, active_raid_id, message_id
)
SELECT sc.server_id, sc.tag, item.key, item.value->>'webhook',
       NULLIF(item.value->>'thread', ''), NULLIF(item.value->>'channel', ''),
       NULLIF(item.value->>'war_id', ''), NULLIF(item.value->>'raid_id', ''),
       COALESCE(NULLIF(item.value->>'war_message', ''), NULLIF(item.value->>'raid_message', ''))
FROM public.server_clans sc
CROSS JOIN LATERAL jsonb_each(
    CASE WHEN jsonb_typeof(sc.logs_config) = 'object' THEN sc.logs_config ELSE '{}'::jsonb END
) AS item(key, value)
WHERE jsonb_typeof(item.value) = 'object' AND COALESCE(item.value->>'webhook', '') <> ''
ON CONFLICT (server_id, clan_tag, type) DO UPDATE SET
    webhook_token = EXCLUDED.webhook_token,
    thread_id = EXCLUDED.thread_id,
    channel_id = EXCLUDED.channel_id,
    active_war_id = EXCLUDED.active_war_id,
    active_raid_id = EXCLUDED.active_raid_id,
    message_id = EXCLUDED.message_id;

INSERT INTO public.countdowns (server_id, clan_tag, type, channel_id)
SELECT sc.server_id, sc.tag,
       CASE item.key WHEN 'warCountdown' THEN 'war_score' WHEN 'warTimerCountdown' THEN 'war_timer' END,
       item.value
FROM public.server_clans sc
CROSS JOIN LATERAL jsonb_each_text(
    CASE WHEN jsonb_typeof(sc.countdowns) = 'object' THEN sc.countdowns ELSE '{}'::jsonb END
) AS item(key, value)
WHERE item.value <> '' AND item.key = ANY (ARRAY['warCountdown', 'warTimerCountdown'])
ON CONFLICT DO NOTHING;

ALTER TABLE public.rosters
    ADD COLUMN IF NOT EXISTS description text,
    ADD COLUMN IF NOT EXISTS roster_type text DEFAULT 'clan' NOT NULL,
    ADD COLUMN IF NOT EXISTS signup_scope text DEFAULT 'clan-only' NOT NULL,
    ADD COLUMN IF NOT EXISTS min_townhall integer,
    ADD COLUMN IF NOT EXISTS max_townhall integer,
    ADD COLUMN IF NOT EXISTS roster_size integer,
    ADD COLUMN IF NOT EXISTS min_signups integer,
    ADD COLUMN IF NOT EXISTS max_accounts_per_user integer,
    ADD COLUMN IF NOT EXISTS townhall_restriction text,
    ADD COLUMN IF NOT EXISTS default_signup_category text,
    ADD COLUMN IF NOT EXISTS image_url text,
    ADD COLUMN IF NOT EXISTS event_start_time bigint,
    ADD COLUMN IF NOT EXISTS recurrence_days integer,
    ADD COLUMN IF NOT EXISTS recurrence_day_of_month integer;

UPDATE public.rosters
SET description = COALESCE(NULLIF(data->>'description', ''), description),
    alias = COALESCE(NULLIF(alias, ''), custom_id, id::text),
    roster_type = COALESCE(NULLIF(data->>'roster_type', ''), roster_type),
    signup_scope = COALESCE(NULLIF(data->>'signup_scope', ''), signup_scope),
    min_townhall = pg_temp.ck_int(data->>'min_th'),
    max_townhall = pg_temp.ck_int(data->>'max_th'),
    roster_size = pg_temp.ck_int(data->>'roster_size'),
    min_signups = pg_temp.ck_int(data->>'min_signups'),
    max_accounts_per_user = pg_temp.ck_int(data->>'max_accounts_per_user'),
    townhall_restriction = NULLIF(data->>'th_restriction', ''),
    default_signup_category = NULLIF(data->>'default_signup_category', ''),
    image_url = COALESCE(NULLIF(data->>'image', ''), image_url),
    event_start_time = pg_temp.ck_bigint(data->>'event_start_time'),
    recurrence_days = pg_temp.ck_int(data->>'recurrence_days'),
    recurrence_day_of_month = pg_temp.ck_int(data->>'recurrence_day_of_month');

ALTER TABLE public.rosters
    ALTER COLUMN description DROP NOT NULL,
    DROP COLUMN IF EXISTS linked_clan_tag,
    DROP COLUMN IF EXISTS title,
    DROP COLUMN IF EXISTS max_size,
    DROP COLUMN IF EXISTS minimum_townhall,
    DROP COLUMN IF EXISTS maximum_townhall,
    DROP COLUMN IF EXISTS signup_role_id;

ALTER TABLE public.roster_members
    DROP COLUMN IF EXISTS roster_group_id,
    ADD COLUMN IF NOT EXISTS name text DEFAULT '' NOT NULL,
    ADD COLUMN IF NOT EXISTS townhall integer DEFAULT 0 NOT NULL,
    ADD COLUMN IF NOT EXISTS hero_levels integer,
    ADD COLUMN IF NOT EXISTS discord_user_id text,
    ADD COLUMN IF NOT EXISTS discord_username text,
    ADD COLUMN IF NOT EXISTS discord_avatar_url text,
    ADD COLUMN IF NOT EXISTS current_clan_name text,
    ADD COLUMN IF NOT EXISTS current_clan_tag text,
    ADD COLUMN IF NOT EXISTS war_preference boolean,
    ADD COLUMN IF NOT EXISTS trophies integer,
    ADD COLUMN IF NOT EXISTS substitute boolean,
    ADD COLUMN IF NOT EXISTS signup_group text,
    ADD COLUMN IF NOT EXISTS hitrate double precision,
    ADD COLUMN IF NOT EXISTS last_online bigint,
    ADD COLUMN IF NOT EXISTS current_league text,
    ADD COLUMN IF NOT EXISTS added_at bigint,
    ADD COLUMN IF NOT EXISTS last_updated bigint,
    ADD COLUMN IF NOT EXISTS is_in_family boolean,
    ADD COLUMN IF NOT EXISTS member_status text,
    ADD COLUMN IF NOT EXISTS error_details text,
    ADD COLUMN IF NOT EXISTS position integer DEFAULT 0 NOT NULL;

INSERT INTO public.roster_members (
    roster_id, tag, name, townhall, hero_levels, discord_user_id,
    discord_username, discord_avatar_url, current_clan_name,
    current_clan_tag, war_preference, trophies, substitute, signup_group,
    hitrate, last_online, current_league, added_at, last_updated,
    is_in_family, member_status, error_details, position
)
SELECT r.id, member.value->>'tag', COALESCE(member.value->>'name', ''),
       pg_temp.ck_int(member.value->>'townhall', 0),
       pg_temp.ck_int(member.value->>'hero_lvs'),
       NULLIF(member.value->>'discord', ''), NULLIF(member.value->>'discord_username', ''),
       NULLIF(member.value->>'discord_avatar_url', ''), NULLIF(member.value->>'current_clan', ''),
       NULLIF(member.value->>'current_clan_tag', ''),
       pg_temp.ck_bool(member.value->>'war_pref'),
       pg_temp.ck_int(member.value->>'trophies'),
       pg_temp.ck_bool(member.value->>'sub'),
       NULLIF(member.value->>'signup_group', ''), pg_temp.ck_float(member.value->>'hitrate'),
       pg_temp.ck_bigint(member.value->>'last_online'), NULLIF(member.value->>'current_league', ''),
       pg_temp.ck_bigint(member.value->>'added_at'), pg_temp.ck_bigint(member.value->>'last_updated'),
       pg_temp.ck_bool(member.value->>'is_in_family'),
       NULLIF(member.value->>'member_status', ''), NULLIF(member.value->>'error_details', ''),
       member.ordinality::integer
FROM public.rosters r
CROSS JOIN LATERAL jsonb_array_elements(
    CASE WHEN jsonb_typeof(r.members) = 'array' THEN r.members ELSE '[]'::jsonb END
) WITH ORDINALITY AS member(value, ordinality)
WHERE COALESCE(member.value->>'tag', '') <> ''
ON CONFLICT (tag, roster_id) DO UPDATE SET
    name = EXCLUDED.name, townhall = EXCLUDED.townhall,
    hero_levels = EXCLUDED.hero_levels, discord_user_id = EXCLUDED.discord_user_id,
    discord_username = EXCLUDED.discord_username, discord_avatar_url = EXCLUDED.discord_avatar_url,
    current_clan_name = EXCLUDED.current_clan_name, current_clan_tag = EXCLUDED.current_clan_tag,
    war_preference = EXCLUDED.war_preference, trophies = EXCLUDED.trophies,
    substitute = EXCLUDED.substitute, signup_group = EXCLUDED.signup_group,
    hitrate = EXCLUDED.hitrate, last_online = EXCLUDED.last_online,
    current_league = EXCLUDED.current_league, added_at = EXCLUDED.added_at,
    last_updated = EXCLUDED.last_updated, is_in_family = EXCLUDED.is_in_family,
    member_status = EXCLUDED.member_status, error_details = EXCLUDED.error_details,
    position = EXCLUDED.position;

CREATE TABLE public.roster_allowed_signup_categories (
    roster_id uuid NOT NULL REFERENCES public.rosters(id) ON DELETE CASCADE,
    category_id text NOT NULL,
    position integer DEFAULT 0 NOT NULL,
    PRIMARY KEY (roster_id, category_id)
);

CREATE TABLE public.roster_display_columns (
    roster_id uuid NOT NULL REFERENCES public.rosters(id) ON DELETE CASCADE,
    column_name text NOT NULL,
    position integer DEFAULT 0 NOT NULL,
    PRIMARY KEY (roster_id, column_name)
);

CREATE TABLE public.roster_sort_fields (
    roster_id uuid NOT NULL REFERENCES public.rosters(id) ON DELETE CASCADE,
    field_name text NOT NULL,
    position integer DEFAULT 0 NOT NULL,
    PRIMARY KEY (roster_id, field_name)
);

INSERT INTO public.roster_allowed_signup_categories (roster_id, category_id, position)
SELECT r.id, item.value, item.ordinality::integer
FROM public.rosters r
CROSS JOIN LATERAL jsonb_array_elements_text(
    CASE WHEN jsonb_typeof(r.data->'allowed_signup_categories') = 'array' THEN r.data->'allowed_signup_categories' ELSE '[]'::jsonb END
) WITH ORDINALITY AS item(value, ordinality)
ON CONFLICT DO NOTHING;

INSERT INTO public.roster_display_columns (roster_id, column_name, position)
SELECT r.id, item.value, item.ordinality::integer
FROM public.rosters r
CROSS JOIN LATERAL jsonb_array_elements_text(
    CASE WHEN jsonb_typeof(r.data->'columns') = 'array' THEN r.data->'columns' ELSE '[]'::jsonb END
) WITH ORDINALITY AS item(value, ordinality)
ON CONFLICT DO NOTHING;

INSERT INTO public.roster_sort_fields (roster_id, field_name, position)
SELECT r.id, item.value, item.ordinality::integer
FROM public.rosters r
CROSS JOIN LATERAL jsonb_array_elements_text(
    CASE WHEN jsonb_typeof(r.data->'sort') = 'array' THEN r.data->'sort' ELSE '[]'::jsonb END
) WITH ORDINALITY AS item(value, ordinality)
ON CONFLICT DO NOTHING;

ALTER TABLE public.roster_groups
    ADD COLUMN IF NOT EXISTS alias text,
    ADD COLUMN IF NOT EXISTS max_accounts_per_user integer,
    ADD COLUMN IF NOT EXISTS roster_size integer,
    ADD COLUMN IF NOT EXISTS min_signups integer,
    ADD COLUMN IF NOT EXISTS default_signup_category text;

UPDATE public.roster_groups
SET alias = COALESCE(NULLIF(data->>'alias', ''), NULLIF(name, '')),
    max_accounts_per_user = pg_temp.ck_int(data->>'max_accounts_per_user'),
    roster_size = pg_temp.ck_int(data->>'roster_size'),
    min_signups = pg_temp.ck_int(data->>'min_signups'),
    default_signup_category = NULLIF(data->>'default_signup_category', '');

CREATE TABLE public.roster_group_allowed_signup_categories (
    group_id text NOT NULL REFERENCES public.roster_groups(group_id) ON DELETE CASCADE,
    category_id text NOT NULL,
    position integer DEFAULT 0 NOT NULL,
    PRIMARY KEY (group_id, category_id)
);

INSERT INTO public.roster_group_allowed_signup_categories (group_id, category_id, position)
SELECT groups.group_id, item.value, item.ordinality::integer
FROM public.roster_groups groups
CROSS JOIN LATERAL jsonb_array_elements_text(
    CASE WHEN jsonb_typeof(groups.data->'allowed_signup_categories') = 'array'
         THEN groups.data->'allowed_signup_categories' ELSE '[]'::jsonb END
) WITH ORDINALITY AS item(value, ordinality)
WHERE groups.group_id IS NOT NULL
ON CONFLICT DO NOTHING;

ALTER TABLE public.roster_signup_categories
    ADD COLUMN IF NOT EXISTS alias text;

UPDATE public.roster_signup_categories
SET alias = COALESCE(NULLIF(data->>'alias', ''), NULLIF(name, ''));

ALTER TABLE public.roster_automation_rules
    ADD COLUMN IF NOT EXISTS roster_id text,
    ADD COLUMN IF NOT EXISTS action_type text DEFAULT '' NOT NULL,
    ADD COLUMN IF NOT EXISTS offset_seconds integer DEFAULT 0 NOT NULL,
    ADD COLUMN IF NOT EXISTS discord_channel_id text,
    ADD COLUMN IF NOT EXISTS ping_type text,
    ADD COLUMN IF NOT EXISTS executed boolean DEFAULT false NOT NULL,
    ADD COLUMN IF NOT EXISTS executed_at bigint,
    ADD COLUMN IF NOT EXISTS last_triggered_at bigint,
    ADD COLUMN IF NOT EXISTS execution_status text,
    ADD COLUMN IF NOT EXISTS last_missed_at bigint;

UPDATE public.roster_automation_rules
SET roster_id = NULLIF(data->>'roster_id', ''),
    action_type = COALESCE(NULLIF(data->>'action_type', ''), action_type),
    offset_seconds = pg_temp.ck_int(data->>'offset_seconds', 0),
    discord_channel_id = NULLIF(data->>'discord_channel_id', ''),
    ping_type = NULLIF(data#>>'{options,ping_type}', ''),
    executed = pg_temp.ck_bool(data->>'executed', false),
    executed_at = pg_temp.ck_bigint(data->>'executed_at'),
    last_triggered_at = pg_temp.ck_bigint(data->>'last_triggered_at'),
    execution_status = NULLIF(data->>'execution_status', ''),
    last_missed_at = pg_temp.ck_bigint(data->>'last_missed_at');

ALTER TABLE public.roster_groups DROP COLUMN data;
ALTER TABLE public.roster_signup_categories DROP COLUMN data;
ALTER TABLE public.roster_automation_rules DROP COLUMN data;

DROP TABLE public.bot_sync_status;

DROP TABLE public.clan_position_roles;
DROP TABLE public.hall_roles;
DROP TABLE public.league_roles;
DROP TABLE public.role_ignore_bindings;
DROP TABLE public.role_bindings;
DROP TABLE public.server_role_settings;
DROP TABLE public.search_groups;

ALTER TABLE public.servers
    DROP COLUMN logs_config,
    DROP COLUMN status_roles,
    DROP COLUMN countdowns,
    DROP COLUMN data;

ALTER TABLE public.server_clans
    DROP COLUMN logs_config,
    DROP COLUMN countdowns,
    DROP COLUMN data;

ALTER TABLE public.rosters
    DROP COLUMN members,
    DROP COLUMN data;

-- Consolidated from 020_unify_server_logs.sql
ALTER TABLE public.server_logs RENAME TO server_logs_legacy;

CREATE TABLE public.server_logs (
    server_id text NOT NULL REFERENCES public.servers(id) ON DELETE CASCADE,
    clan_tag text,
    type text NOT NULL,
    webhook_id text NOT NULL,
    thread_id text,
    active_war_id text,
    active_raid_id text,
    message_id text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT server_logs_type_check CHECK (type = ANY (ARRAY[
        'join_log', 'leave_log', 'donation_log',
        'clan_achievement_log', 'clan_requirements_log', 'clan_description_log',
        'war_log', 'war_panel', 'cwl_lineup_change_log',
        'capital_donations', 'capital_attacks', 'raid_panel', 'capital_weekly_summary',
        'role_change', 'troop_upgrade', 'super_troop_boost', 'th_upgrade',
        'league_change', 'spell_upgrade', 'hero_upgrade',
        'hero_equipment_upgrade', 'name_change',
        'legend_log_attacks', 'legend_log_defenses'
    ])),
    CONSTRAINT server_logs_webhook_id_check CHECK (btrim(webhook_id) <> ''),
    CONSTRAINT server_logs_clan_fkey FOREIGN KEY (clan_tag, server_id)
        REFERENCES public.server_clans(tag, server_id) ON DELETE CASCADE,
    CONSTRAINT server_logs_scope_type_key
        UNIQUE NULLS NOT DISTINCT (server_id, clan_tag, type)
);

CREATE INDEX idx_server_logs_scope ON public.server_logs (server_id, clan_tag, type);
CREATE INDEX idx_server_logs_webhook ON public.server_logs (webhook_id);

INSERT INTO public.server_logs (server_id, clan_tag, type, webhook_id, thread_id)
SELECT legacy.server_id,
       scope.clan_tag,
       expanded.type,
       legacy.webhook_id,
       legacy.thread_id
FROM public.server_logs_legacy legacy
LEFT JOIN public.server_log_clans scope
    ON scope.server_id = legacy.server_id AND scope.log_type = legacy.log_type
CROSS JOIN LATERAL unnest(
    CASE legacy.log_type
        WHEN 'join_leave_log' THEN ARRAY['join_log', 'leave_log']::text[]
        WHEN 'capital_donation_log' THEN ARRAY['capital_donations']::text[]
        WHEN 'capital_raid_log' THEN ARRAY['capital_attacks']::text[]
        WHEN 'player_upgrade_log' THEN ARRAY[
            'role_change', 'troop_upgrade', 'super_troop_boost', 'th_upgrade',
            'league_change', 'spell_upgrade', 'hero_upgrade',
            'hero_equipment_upgrade', 'name_change'
        ]::text[]
        WHEN 'legend_log' THEN ARRAY['legend_log_attacks', 'legend_log_defenses']::text[]
        ELSE ARRAY[legacy.log_type]::text[]
    END
) AS expanded(type)
WHERE legacy.enabled = true
  AND COALESCE(btrim(legacy.webhook_id), '') <> ''
ON CONFLICT (server_id, clan_tag, type) DO UPDATE SET
    webhook_id = EXCLUDED.webhook_id,
    thread_id = EXCLUDED.thread_id,
    updated_at = now();

INSERT INTO public.server_logs (
    server_id, clan_tag, type, webhook_id, thread_id,
    active_war_id, active_raid_id, message_id
)
SELECT server_id,
       clan_tag,
       CASE type
           WHEN 'join' THEN 'join_log'
           WHEN 'leave' THEN 'leave_log'
           WHEN 'donations' THEN 'donation_log'
           WHEN 'war' THEN 'war_log'
           WHEN 'capital' THEN 'capital_attacks'
           ELSE type
       END,
       webhook_token,
       thread_id,
       active_war_id,
       active_raid_id,
       message_id
FROM public.clan_logs
WHERE COALESCE(btrim(webhook_token), '') <> ''
ON CONFLICT (server_id, clan_tag, type) DO UPDATE SET
    webhook_id = EXCLUDED.webhook_id,
    thread_id = EXCLUDED.thread_id,
    active_war_id = EXCLUDED.active_war_id,
    active_raid_id = EXCLUDED.active_raid_id,
    message_id = EXCLUDED.message_id,
    updated_at = now();

DROP TABLE public.server_log_clans;
DROP TABLE public.server_logs_legacy;
DROP TABLE public.clan_logs;

-- Consolidated from 021_add_server_logs_disabled.sql
ALTER TABLE public.server_logs
    ADD COLUMN disabled boolean DEFAULT false NOT NULL;

-- Consolidated from 022_link_server_clans_to_basic_clan.sql
DELETE FROM public.server_clans sc
WHERE NOT EXISTS (
    SELECT 1
    FROM public.basic_clan clan
    WHERE clan.tag = sc.tag
);

ALTER TABLE public.server_clans
    ADD CONSTRAINT server_clans_basic_clan_fkey
    FOREIGN KEY (tag) REFERENCES public.basic_clan(tag) ON DELETE CASCADE;

-- Consolidated from 023_rename_server_roles.sql
ALTER TABLE public.role_rules DROP CONSTRAINT role_rules_type_check;
ALTER TABLE public.role_rules DROP CONSTRAINT role_rules_mode_check;

DELETE FROM public.role_rules
WHERE type = 'ignored'
   OR (type = 'family' AND option = 'only_family')
   OR (type = 'clan_role' AND option = 'member' AND clan_tag IS NULL);

DELETE FROM public.role_rules duplicate
USING public.role_rules canonical
WHERE duplicate.server_id = canonical.server_id
  AND duplicate.clan_tag IS NOT DISTINCT FROM canonical.clan_tag
  AND duplicate.type = 'family'
  AND duplicate.option = 'member'
  AND canonical.type = 'family'
  AND canonical.option = 'family'
  AND duplicate.role_id = canonical.role_id;

UPDATE public.role_rules
SET option = 'family', updated_at = now()
WHERE type = 'family' AND option = 'member';

UPDATE public.role_rules
SET mode = 'both', updated_at = now()
WHERE mode = 'sync';

ALTER TABLE public.role_rules ALTER COLUMN mode SET DEFAULT 'both';
ALTER TABLE public.role_rules RENAME TO server_roles;

ALTER TABLE public.server_roles RENAME CONSTRAINT role_rules_pkey TO server_roles_pkey;
ALTER TABLE public.server_roles RENAME CONSTRAINT role_rules_server_id_fkey TO server_roles_server_id_fkey;
ALTER TABLE public.server_roles RENAME CONSTRAINT role_rules_clan_fkey TO server_roles_clan_fkey;
ALTER TABLE public.server_roles RENAME CONSTRAINT role_rules_scope_check TO server_roles_scope_check;
ALTER TABLE public.server_roles RENAME CONSTRAINT role_rules_option_check TO server_roles_option_check;
ALTER TABLE public.server_roles RENAME CONSTRAINT role_rules_role_id_check TO server_roles_role_id_check;
ALTER TABLE public.server_roles RENAME CONSTRAINT role_rules_server_id_clan_tag_type_option_role_id_key TO server_roles_server_id_clan_tag_type_option_role_id_key;

ALTER INDEX public.idx_role_rules_server_type RENAME TO idx_server_roles_server_type;
ALTER INDEX public.idx_role_rules_clan RENAME TO idx_server_roles_clan;

ALTER TABLE public.server_roles
    ADD CONSTRAINT server_roles_type_check CHECK (type = ANY (ARRAY[
        'townhall', 'builderhall', 'league', 'builder_league',
        'clan_role', 'clan_category', 'family', 'achievement', 'status'
    ])),
    ADD CONSTRAINT server_roles_mode_check CHECK (mode = ANY (ARRAY['add', 'remove', 'both']));

-- Consolidated from 024_enforce_server_role_options.sql
ALTER TABLE public.server_roles
    ADD CONSTRAINT server_roles_supported_option_check CHECK (
        (type <> 'family' OR (clan_tag IS NULL AND option = ANY (ARRAY['family', 'not_family'])))
        AND
        (type <> 'clan_role' OR (
            option = ANY (ARRAY['member', 'elder', 'co_leader', 'leader'])
            AND NOT (clan_tag IS NULL AND option = 'member')
        ))
    );

-- Consolidated from 025_home_player_data.sql
ALTER TABLE public.player_links
    ADD COLUMN IF NOT EXISTS last_login timestamp with time zone;

CREATE TABLE public.player_upgrades (
    player_tag text PRIMARY KEY REFERENCES public.player_links(tag) ON DELETE CASCADE,
    data jsonb DEFAULT '{}'::jsonb NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT player_upgrades_data_object_check
        CHECK (jsonb_typeof(data) = 'object')
);

CREATE TABLE public.player_upgrade_preferences (
    player_tag text PRIMARY KEY REFERENCES public.player_links(tag) ON DELETE CASCADE,
    preferences jsonb DEFAULT '{}'::jsonb NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT player_upgrade_preferences_object_check
        CHECK (jsonb_typeof(preferences) = 'object')
);

-- Consolidated from 026_v2_schema_cleanup.sql
ALTER TABLE public.auth_discord_tokens
    DROP COLUMN IF EXISTS scopes,
    DROP COLUMN IF EXISTS data;

ALTER TABLE public.auth_email_verifications
    ADD COLUMN IF NOT EXISTS username text,
    ADD COLUMN IF NOT EXISTS password_hash text,
    ADD COLUMN IF NOT EXISTS device_id text;

UPDATE public.auth_email_verifications
SET username = data #>> '{user_data,username}',
    password_hash = data #>> '{user_data,password}',
    device_id = data #>> '{user_data,device_id}';

ALTER TABLE public.auth_email_verifications
    ALTER COLUMN username SET NOT NULL,
    ALTER COLUMN password_hash SET NOT NULL,
    ALTER COLUMN device_id SET NOT NULL,
    DROP COLUMN IF EXISTS user_id,
    DROP COLUMN IF EXISTS data;

WITH ranked_password_resets AS (
    SELECT id,
           row_number() OVER (
               PARTITION BY email_hash
               ORDER BY created_at DESC, id DESC
           ) AS row_number
    FROM public.auth_password_reset_tokens
)
DELETE FROM public.auth_password_reset_tokens AS reset
USING ranked_password_resets AS ranked
WHERE reset.id = ranked.id
  AND ranked.row_number > 1;

DROP INDEX IF EXISTS public.idx_auth_password_reset_tokens_lookup;

ALTER TABLE public.auth_password_reset_tokens
    DROP CONSTRAINT IF EXISTS auth_password_reset_tokens_pkey,
    DROP COLUMN IF EXISTS id,
    DROP COLUMN IF EXISTS used,
    DROP COLUMN IF EXISTS data,
    ADD CONSTRAINT auth_password_reset_tokens_pkey PRIMARY KEY (email_hash);

CREATE INDEX idx_auth_password_reset_tokens_expires_at
    ON public.auth_password_reset_tokens (expires_at);

ALTER TABLE public.auth_refresh_tokens
    DROP COLUMN IF EXISTS revoked_at,
    DROP COLUMN IF EXISTS data,
    DROP COLUMN IF EXISTS created_at;

ALTER TABLE public.auth_users
    ALTER COLUMN username DROP DEFAULT,
    ALTER COLUMN username DROP NOT NULL;

UPDATE public.auth_users
SET username = NULL
WHERE discord_user_id IS NOT NULL;

ALTER TABLE public.auth_users
    DROP COLUMN IF EXISTS display_name,
    DROP COLUMN IF EXISTS verified,
    DROP COLUMN IF EXISTS profile,
    DROP COLUMN IF EXISTS data;

ALTER TABLE public.bases
    ADD COLUMN IF NOT EXISTS server_id text,
    ADD COLUMN IF NOT EXISTS channel_id text,
    ADD COLUMN IF NOT EXISTS images text[] DEFAULT '{}'::text[] NOT NULL,
    ADD COLUMN IF NOT EXISTS description text DEFAULT ''::text NOT NULL,
    ADD COLUMN IF NOT EXISTS upvoter_ids text[] DEFAULT '{}'::text[] NOT NULL,
    ADD COLUMN IF NOT EXISTS downvoter_ids text[] DEFAULT '{}'::text[] NOT NULL,
    DROP COLUMN IF EXISTS whitelisted_role_id,
    DROP COLUMN IF EXISTS downloads,
    DROP COLUMN IF EXISTS upvotes,
    DROP COLUMN IF EXISTS downvotes,
    ADD CONSTRAINT bases_description_length_check
        CHECK (char_length(description) <= 1000),
    ADD CONSTRAINT bases_images_count_check
        CHECK (cardinality(images) <= 4),
    ADD CONSTRAINT bases_voter_ids_no_overlap_check
        CHECK (NOT (upvoter_ids && downvoter_ids)),
    ADD CONSTRAINT bases_message_location_pair_check
        CHECK ((server_id IS NULL) = (channel_id IS NULL));

DROP TABLE IF EXISTS public.bot_settings;

DROP TABLE IF EXISTS public.capital_raid_members;
DROP TABLE IF EXISTS public.capital_raid_cache;

ALTER TABLE public.server_clans
    DROP CONSTRAINT IF EXISTS server_clans_category_id_fkey,
    ADD CONSTRAINT server_clans_category_id_fkey
        FOREIGN KEY (category_id)
        REFERENCES public.clan_categories(id)
        ON DELETE SET NULL;

ALTER TABLE public.basic_clan
    ADD COLUMN IF NOT EXISTS builder_base_points integer DEFAULT 0 NOT NULL,
    ADD COLUMN IF NOT EXISTS capital_points integer DEFAULT 0 NOT NULL;

CREATE TEMP TABLE _ck_clan_rankings_current_legacy
ON COMMIT DROP
AS
SELECT *
FROM public.clan_rankings_current;

DROP TABLE public.clan_rankings_current;

CREATE TABLE public.clan_rankings_current (
    clan_tag text NOT NULL,
    ranking_type text NOT NULL,
    location_id text NOT NULL,
    rank integer NOT NULL,
    points integer NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT clan_rankings_current_pkey
        PRIMARY KEY (clan_tag, ranking_type, location_id),
    CONSTRAINT clan_rankings_current_ranking_type_check
        CHECK (ranking_type = ANY (ARRAY['home'::text, 'builder_base'::text, 'capital'::text])),
    CONSTRAINT clan_rankings_current_location_id_check
        CHECK (location_id = 'global' OR location_id ~ '^[0-9]+$')
);

CREATE INDEX idx_clan_rankings_current_scope_rank
    ON public.clan_rankings_current (ranking_type, location_id, rank);

INSERT INTO public.clan_rankings_current (
    clan_tag, ranking_type, location_id, rank, points, updated_at
)
SELECT
    legacy.clan_tag,
    'home',
    'global',
    legacy.global_rank,
    CASE
        WHEN jsonb_typeof(legacy.data -> 'points') = 'number'
             AND (legacy.data ->> 'points') ~ '^[0-9]+$'
            THEN (legacy.data ->> 'points')::integer
        ELSE COALESCE(clan.clan_points, 0)
    END,
    legacy.updated_at
FROM _ck_clan_rankings_current_legacy AS legacy
LEFT JOIN public.basic_clan AS clan
    ON clan.tag = legacy.clan_tag
WHERE legacy.global_rank IS NOT NULL;

INSERT INTO public.clan_rankings_current (
    clan_tag, ranking_type, location_id, rank, points, updated_at
)
SELECT
    legacy.clan_tag,
    'home',
    clan.location_id::text,
    legacy.local_rank,
    CASE
        WHEN jsonb_typeof(legacy.data -> 'points') = 'number'
             AND (legacy.data ->> 'points') ~ '^[0-9]+$'
            THEN (legacy.data ->> 'points')::integer
        ELSE clan.clan_points
    END,
    legacy.updated_at
FROM _ck_clan_rankings_current_legacy AS legacy
JOIN public.basic_clan AS clan
    ON clan.tag = legacy.clan_tag
WHERE legacy.local_rank IS NOT NULL
  AND clan.location_id IS NOT NULL;

DROP TABLE public.clan_season_stats;

ALTER TABLE public.countdowns
    RENAME TO server_countdowns;

ALTER TABLE public.current_war_timers
    DROP COLUMN IF EXISTS data,
    DROP COLUMN IF EXISTS updated_at;

CREATE INDEX idx_current_war_timers_war_id
    ON public.current_war_timers (war_id);

ALTER TABLE public.custom_embeds
    RENAME TO server_custom_embeds;

LOCK TABLE public.server_custom_embeds IN SHARE ROW EXCLUSIVE MODE;

CREATE TEMP TABLE _ck_legacy_embed_targets
ON COMMIT DROP
AS
SELECT
    legacy.id AS legacy_embed_id,
    legacy.server_id AS source_server_id,
    legacy.server_id AS target_server_id,
    legacy.name AS legacy_name,
    legacy.data
FROM public.embeds AS legacy
UNION
SELECT
    legacy.id,
    legacy.server_id,
    panel.server_id,
    legacy.name,
    legacy.data
FROM public.embeds AS legacy
JOIN public.ticket_panel AS panel
    ON panel.embed_id = legacy.id
UNION
SELECT
    legacy.id,
    legacy.server_id,
    panel.server_id,
    legacy.name,
    legacy.data
FROM public.embeds AS legacy
JOIN public.ticket_panel_buttons AS button
    ON button.open_message_embed_id = legacy.id
JOIN public.ticket_panel AS panel
    ON panel.id = button.panel_id;

CREATE TEMP TABLE _ck_legacy_embed_map
ON COMMIT DROP
AS
WITH bases AS (
    SELECT
        target.*,
        format(
            'legacy:%s:%s:%s',
            target.legacy_embed_id::text,
            encode(convert_to(target.source_server_id, 'UTF8'), 'hex'),
            encode(convert_to(target.legacy_name, 'UTF8'), 'hex')
        ) AS base_name
    FROM _ck_legacy_embed_targets AS target
)
SELECT
    base.*,
    candidate.template_name
FROM bases AS base
LEFT JOIN LATERAL (
    SELECT
        CASE
            WHEN suffix.value = 0 THEN base.base_name
            ELSE format('%s:copy:%s', base.base_name, suffix.value)
        END AS template_name
    FROM generate_series(0, 100000) AS suffix(value)
    WHERE NOT EXISTS (
        SELECT 1
        FROM public.server_custom_embeds AS existing
        WHERE existing.server_id = base.target_server_id
          AND existing.name = CASE
              WHEN suffix.value = 0 THEN base.base_name
              ELSE format('%s:copy:%s', base.base_name, suffix.value)
          END
    )
    ORDER BY suffix.value
    LIMIT 1
) AS candidate ON TRUE;

-- +goose StatementBegin
DO $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM _ck_legacy_embed_map
        WHERE template_name IS NULL
    ) THEN
        RAISE EXCEPTION 'could not allocate collision-safe server_custom_embeds names for legacy embeds';
    END IF;
END;
$$;
-- +goose StatementEnd

INSERT INTO public.server_custom_embeds (server_id, name, data)
SELECT target_server_id, template_name, data
FROM _ck_legacy_embed_map;

ALTER TABLE public.ticket_panel
    ADD COLUMN embed_server_id text,
    ADD COLUMN embed_name text;

ALTER TABLE public.ticket_panel_buttons
    ADD COLUMN server_id text,
    ADD COLUMN open_message_embed_server_id text,
    ADD COLUMN open_message_embed_name text;

UPDATE public.ticket_panel AS panel
SET embed_server_id = mapping.target_server_id,
    embed_name = mapping.template_name
FROM _ck_legacy_embed_map AS mapping
WHERE panel.embed_id = mapping.legacy_embed_id
  AND panel.server_id = mapping.target_server_id;

UPDATE public.ticket_panel_buttons AS button
SET server_id = panel.server_id
FROM public.ticket_panel AS panel
WHERE button.panel_id = panel.id;

UPDATE public.ticket_panel_buttons AS button
SET open_message_embed_server_id = mapping.target_server_id,
    open_message_embed_name = mapping.template_name
FROM _ck_legacy_embed_map AS mapping
WHERE button.open_message_embed_id = mapping.legacy_embed_id
  AND button.server_id = mapping.target_server_id;

-- +goose StatementBegin
DO $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM public.ticket_panel
        WHERE embed_id IS NOT NULL
          AND (embed_server_id IS NULL OR embed_name IS NULL)
    ) THEN
        RAISE EXCEPTION 'could not resolve one or more ticket_panel legacy embed references';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM public.ticket_panel_buttons
        WHERE open_message_embed_id IS NOT NULL
          AND (open_message_embed_server_id IS NULL OR open_message_embed_name IS NULL)
    ) THEN
        RAISE EXCEPTION 'could not resolve one or more ticket_panel_buttons legacy embed references';
    END IF;
END;
$$;
-- +goose StatementEnd

ALTER TABLE public.ticket_panel_buttons
    ALTER COLUMN server_id SET NOT NULL;

ALTER TABLE public.ticket_panel
    ADD CONSTRAINT ticket_panel_id_server_id_key UNIQUE (id, server_id),
    ADD CONSTRAINT ticket_panel_embed_scope_check
        CHECK (
            (embed_server_id IS NULL AND embed_name IS NULL)
            OR (embed_server_id = server_id AND embed_name IS NOT NULL)
        ),
    ADD CONSTRAINT ticket_panel_embed_template_fkey
        FOREIGN KEY (embed_server_id, embed_name)
        REFERENCES public.server_custom_embeds(server_id, name)
        ON DELETE SET NULL;

ALTER TABLE public.ticket_panel_buttons
    ADD CONSTRAINT ticket_panel_buttons_embed_scope_check
        CHECK (
            (open_message_embed_server_id IS NULL AND open_message_embed_name IS NULL)
            OR (
                open_message_embed_server_id = server_id
                AND open_message_embed_name IS NOT NULL
            )
        ),
    ADD CONSTRAINT ticket_panel_buttons_panel_server_fkey
        FOREIGN KEY (panel_id, server_id)
        REFERENCES public.ticket_panel(id, server_id)
        ON DELETE CASCADE,
    ADD CONSTRAINT ticket_panel_buttons_open_message_embed_template_fkey
        FOREIGN KEY (open_message_embed_server_id, open_message_embed_name)
        REFERENCES public.server_custom_embeds(server_id, name)
        ON DELETE SET NULL;

ALTER TABLE public.ticket_panel
    DROP CONSTRAINT ticket_panel_embed_id_fkey,
    DROP COLUMN embed_id;

ALTER TABLE public.ticket_panel_buttons
    DROP CONSTRAINT ticket_panel_buttons_open_message_embed_id_fkey,
    DROP CONSTRAINT ticket_panel_buttons_panel_id_fkey,
    DROP COLUMN open_message_embed_id;

DROP TABLE public.embeds;

ALTER TABLE public.giveaways
    DROP COLUMN IF EXISTS data;

CREATE TABLE public.cwl_group_clans (
    cwl_id text NOT NULL,
    clan_tag text NOT NULL,
    name text NOT NULL DEFAULT ''::text,
    clan_level integer NOT NULL DEFAULT 0,
    badge_token text NOT NULL DEFAULT ''::text,
    members jsonb NOT NULL DEFAULT '[]'::jsonb,
    CONSTRAINT cwl_group_clans_pkey PRIMARY KEY (cwl_id, clan_tag),
    CONSTRAINT cwl_group_clans_cwl_id_fkey
        FOREIGN KEY (cwl_id) REFERENCES public.cwl_groups(cwl_id) ON DELETE CASCADE,
    CONSTRAINT cwl_group_clans_members_array_check CHECK (jsonb_typeof(members) = 'array')
);

INSERT INTO public.cwl_group_clans (
    cwl_id, clan_tag, name, clan_level, badge_token, members
)
SELECT
    groups.cwl_id,
    clan.value ->> 'tag',
    COALESCE(clan.value ->> 'name', ''),
    COALESCE(NULLIF(clan.value ->> 'clanLevel', '')::integer, 0),
    COALESCE(
        NULLIF(clan.value ->> 'badgeToken', ''),
        NULLIF(clan.value ->> 'badge_token', ''),
        NULLIF(clan.value #>> '{badgeUrls,medium}', ''),
        ''
    ),
    COALESCE(clan.value -> 'members', '[]'::jsonb)
FROM public.cwl_groups AS groups
CROSS JOIN LATERAL jsonb_array_elements(COALESCE(groups.data -> 'clans', '[]'::jsonb)) AS clan(value)
WHERE COALESCE(clan.value ->> 'tag', '') <> ''
  AND jsonb_typeof(COALESCE(clan.value -> 'members', '[]'::jsonb)) = 'array'
ON CONFLICT (cwl_id, clan_tag) DO UPDATE SET
    name = EXCLUDED.name,
    clan_level = EXCLUDED.clan_level,
    badge_token = EXCLUDED.badge_token,
    members = EXCLUDED.members;

ALTER TABLE public.cwl_groups
    ADD COLUMN state text NOT NULL DEFAULT 'preparation'::text,
    ADD COLUMN war_size smallint,
    ADD COLUMN ended_at timestamp with time zone;

UPDATE public.cwl_groups
SET state = COALESCE(NULLIF(data ->> 'state', ''), 'preparation');

ALTER TABLE public.cwl_groups
    ADD CONSTRAINT cwl_groups_state_check
        CHECK (state = ANY (ARRAY['notInWar'::text, 'preparation'::text, 'inWar'::text, 'ended'::text])),
    ALTER COLUMN cwl_league_id DROP NOT NULL,
    DROP COLUMN clan_tags,
    DROP COLUMN data;

CREATE INDEX idx_cwl_groups_season_league_size
    ON public.cwl_groups (season, cwl_league_id, war_size);

CREATE INDEX idx_cwl_group_clans_clan_cwl
    ON public.cwl_group_clans (clan_tag, cwl_id DESC);

CREATE INDEX idx_cwl_group_clans_members_gin
    ON public.cwl_group_clans USING gin (members jsonb_path_ops);

CREATE TABLE public.cwl_standings (
    cwl_id text NOT NULL,
    clan_tag text NOT NULL,
    season text NOT NULL,
    cwl_league_id integer NOT NULL,
    war_size smallint NOT NULL,
    stars integer NOT NULL DEFAULT 0,
    destruction numeric(12, 4) NOT NULL DEFAULT 0,
    wins smallint NOT NULL DEFAULT 0,
    losses smallint NOT NULL DEFAULT 0,
    ties smallint NOT NULL DEFAULT 0,
    wars_finished smallint NOT NULL DEFAULT 0,
    total_clans_in_group smallint NOT NULL DEFAULT 0,
    group_rank integer,
    global_rank integer,
    updated_at timestamp with time zone NOT NULL DEFAULT now(),
    CONSTRAINT cwl_standings_pkey PRIMARY KEY (cwl_id, clan_tag),
    CONSTRAINT cwl_standings_group_clan_fkey
        FOREIGN KEY (cwl_id, clan_tag)
        REFERENCES public.cwl_group_clans(cwl_id, clan_tag)
        ON DELETE CASCADE,
    CONSTRAINT cwl_standings_war_size_check CHECK (war_size > 0),
    CONSTRAINT cwl_standings_nonnegative_check CHECK (
        stars >= 0 AND destruction >= 0 AND wins >= 0 AND losses >= 0
        AND ties >= 0 AND wars_finished >= 0 AND total_clans_in_group >= 0
    )
);

CREATE INDEX idx_cwl_standings_group_rank
    ON public.cwl_standings (cwl_id, group_rank);

CREATE INDEX idx_cwl_standings_global_rank
    ON public.cwl_standings (season, cwl_league_id, war_size, global_rank);

CREATE INDEX idx_cwl_standings_clan_season
    ON public.cwl_standings (clan_tag, season DESC);

-- Consolidated from 027_cwl_identity_and_lookup.sql
-- The local CWL snapshot/standing rows are intentionally disposable. The
-- authoritative legacy group source remains Mongo and can be re-imported with
-- database/migrations/cwl_groups.go after this schema is applied.
TRUNCATE TABLE
    public.cwl_standings,
    public.cwl_group_clans,
    public.cwl_groups;

-- The CWL importer is an offline one-shot load. Remove every index and
-- dependent foreign key from the loaded tables; cwl_groups.go restores the
-- complete constraint/index set only after its final successful batch.
DROP INDEX IF EXISTS public.idx_cwl_groups_season_league;
DROP INDEX IF EXISTS public.idx_cwl_groups_season_league_size;
DROP INDEX IF EXISTS public.idx_cwl_group_clans_clan_cwl;

ALTER TABLE public.cwl_standings
    DROP CONSTRAINT cwl_standings_group_clan_fkey;

ALTER TABLE public.cwl_group_clans
    DROP CONSTRAINT cwl_group_clans_cwl_id_fkey,
    DROP CONSTRAINT cwl_group_clans_pkey;

ALTER TABLE public.cwl_groups
    DROP CONSTRAINT cwl_groups_pkey;

ALTER TABLE public.cwl_groups
    DROP COLUMN created_at,
    DROP COLUMN updated_at,
    DROP COLUMN ended_at,
    ADD CONSTRAINT cwl_groups_id_format_check
        CHECK (cwl_id ~ '^[A-Za-z0-9_-]{12}$');

ALTER TABLE public.cwl_group_clans
    DROP COLUMN members,
    ADD CONSTRAINT cwl_group_clans_badge_token_check
        CHECK (badge_token !~ '/|\.png$');

CREATE TABLE public.cwl_group_members (
    cwl_id text NOT NULL,
    clan_tag text NOT NULL,
    name text NOT NULL DEFAULT ''::text,
    tag text NOT NULL,
    town_hall smallint NOT NULL DEFAULT 0,
    CONSTRAINT cwl_group_members_town_hall_check CHECK (town_hall >= 0)
);

-- +goose Down
-- These two files are a clean baseline. Restore from a backup instead of
-- attempting to reverse the complete production schema in place.
SELECT 1;
