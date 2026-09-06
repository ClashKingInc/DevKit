-- +goose Up
CREATE SCHEMA IF NOT EXISTS discord_cache;

CREATE TABLE discord_cache.guilds (
    id text PRIMARY KEY,
    data jsonb NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT discord_cache_guilds_id_check CHECK (id <> ''),
    CONSTRAINT discord_cache_guilds_data_check CHECK (jsonb_typeof(data) = 'object')
);

CREATE TABLE discord_cache.channels (
    id text PRIMARY KEY,
    guild_id text,
    data jsonb NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT discord_cache_channels_id_check CHECK (id <> ''),
    CONSTRAINT discord_cache_channels_guild_id_check CHECK (guild_id IS NULL OR guild_id <> ''),
    CONSTRAINT discord_cache_channels_data_check CHECK (jsonb_typeof(data) = 'object')
);

CREATE INDEX idx_discord_cache_channels_guild
    ON discord_cache.channels (guild_id)
    WHERE guild_id IS NOT NULL;

CREATE TABLE discord_cache.users (
    id text PRIMARY KEY,
    data jsonb NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT discord_cache_users_id_check CHECK (id <> ''),
    CONSTRAINT discord_cache_users_data_check CHECK (jsonb_typeof(data) = 'object')
);

CREATE TABLE discord_cache.members (
    guild_id text NOT NULL,
    user_id text NOT NULL,
    data jsonb NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT discord_cache_members_pkey PRIMARY KEY (guild_id, user_id),
    CONSTRAINT discord_cache_members_guild_id_check CHECK (guild_id <> ''),
    CONSTRAINT discord_cache_members_user_id_check CHECK (user_id <> ''),
    CONSTRAINT discord_cache_members_data_check CHECK (jsonb_typeof(data) = 'object')
);

CREATE INDEX idx_discord_cache_members_user
    ON discord_cache.members (user_id);

CREATE TABLE discord_cache.roles (
    guild_id text NOT NULL,
    id text NOT NULL,
    data jsonb NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT discord_cache_roles_pkey PRIMARY KEY (guild_id, id),
    CONSTRAINT discord_cache_roles_guild_id_check CHECK (guild_id <> ''),
    CONSTRAINT discord_cache_roles_id_check CHECK (id <> ''),
    CONSTRAINT discord_cache_roles_data_check CHECK (jsonb_typeof(data) = 'object')
);

CREATE INDEX idx_discord_cache_roles_id
    ON discord_cache.roles (id);

CREATE TABLE discord_cache.application_emojis (
    application_id text NOT NULL,
    logical_name text NOT NULL,
    discord_id text NOT NULL,
    discord_name text NOT NULL,
    animated boolean DEFAULT false NOT NULL,
    source_key text NOT NULL,
    source_updated_at timestamp with time zone NOT NULL,
    synced_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT discord_cache_application_emojis_pkey PRIMARY KEY (application_id, logical_name),
    CONSTRAINT discord_cache_application_emojis_application_id_check CHECK (application_id <> ''),
    CONSTRAINT discord_cache_application_emojis_logical_name_check
        CHECK (logical_name = lower(logical_name) AND logical_name ~ '^[a-z0-9_]{1,32}$'),
    CONSTRAINT discord_cache_application_emojis_discord_id_check CHECK (discord_id <> ''),
    CONSTRAINT discord_cache_application_emojis_discord_name_check
        CHECK (discord_name = lower(discord_name) AND discord_name ~ '^[a-z0-9_]{1,32}$'),
    CONSTRAINT discord_cache_application_emojis_source_key_check CHECK (source_key <> '')
);

CREATE UNIQUE INDEX idx_discord_cache_application_emojis_discord_id
    ON discord_cache.application_emojis (application_id, discord_id);

CREATE TABLE discord_cache.delivery_receipts (
    stream_id text NOT NULL,
    destination_id text NOT NULL,
    claimed_at timestamp with time zone DEFAULT now() NOT NULL,
    delivered_at timestamp with time zone,
    CONSTRAINT discord_cache_delivery_receipts_pkey PRIMARY KEY (stream_id, destination_id),
    CONSTRAINT discord_cache_delivery_receipts_stream_id_check CHECK (stream_id <> ''),
    CONSTRAINT discord_cache_delivery_receipts_destination_id_check CHECK (destination_id <> '')
);

-- +goose Down
DROP TABLE IF EXISTS discord_cache.delivery_receipts;
DROP TABLE IF EXISTS discord_cache.application_emojis;
DROP TABLE IF EXISTS discord_cache.roles;
DROP TABLE IF EXISTS discord_cache.members;
DROP TABLE IF EXISTS discord_cache.users;
DROP TABLE IF EXISTS discord_cache.channels;
DROP TABLE IF EXISTS discord_cache.guilds;
DROP SCHEMA IF EXISTS discord_cache;
