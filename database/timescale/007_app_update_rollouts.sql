-- +goose Up
CREATE TABLE public.app_update_channels (
    channel text NOT NULL,
    platform text NOT NULL,
    runtime_version text NOT NULL,
    active_version text,
    rollout_basis_points integer DEFAULT 0 NOT NULL,
    paused boolean DEFAULT false NOT NULL,
    rollout_from_basis_points integer,
    rollout_to_basis_points integer,
    rollout_starts_at timestamp with time zone,
    rollout_ends_at timestamp with time zone,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT app_update_channels_pkey PRIMARY KEY (channel, platform, runtime_version),
    CONSTRAINT app_update_channels_channel_check CHECK (channel IN ('beta', 'production')),
    CONSTRAINT app_update_channels_platform_check CHECK (platform IN ('ios', 'android')),
    CONSTRAINT app_update_channels_runtime_version_check
        CHECK (runtime_version = btrim(runtime_version) AND runtime_version <> '' AND length(runtime_version) <= 200),
    CONSTRAINT app_update_channels_active_version_check
        CHECK (active_version IS NULL OR (active_version = btrim(active_version) AND active_version <> '' AND length(active_version) <= 80)),
    CONSTRAINT app_update_channels_rollout_check CHECK (rollout_basis_points BETWEEN 0 AND 10000),
    CONSTRAINT app_update_channels_schedule_check CHECK (
        (rollout_from_basis_points IS NULL
            AND rollout_to_basis_points IS NULL
            AND rollout_starts_at IS NULL
            AND rollout_ends_at IS NULL)
        OR
        (rollout_from_basis_points BETWEEN 0 AND 10000
            AND rollout_to_basis_points BETWEEN 0 AND 10000
            AND rollout_starts_at IS NOT NULL
            AND rollout_ends_at IS NOT NULL
            AND rollout_ends_at > rollout_starts_at)
    )
);

CREATE TABLE public.app_update_installations (
    installation_hash bytea NOT NULL,
    channel text NOT NULL,
    platform text NOT NULL,
    runtime_version text NOT NULL,
    current_update_id uuid,
    first_seen_at timestamp with time zone DEFAULT now() NOT NULL,
    last_seen_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT app_update_installations_pkey PRIMARY KEY (installation_hash, channel, platform, runtime_version),
    CONSTRAINT app_update_installations_hash_check CHECK (octet_length(installation_hash) = 32),
    CONSTRAINT app_update_installations_channel_check CHECK (channel IN ('beta', 'production')),
    CONSTRAINT app_update_installations_platform_check CHECK (platform IN ('ios', 'android')),
    CONSTRAINT app_update_installations_runtime_version_check
        CHECK (runtime_version = btrim(runtime_version) AND runtime_version <> '' AND length(runtime_version) <= 200),
    CONSTRAINT app_update_installations_seen_check CHECK (last_seen_at >= first_seen_at)
);

CREATE INDEX idx_app_update_installations_adoption
    ON public.app_update_installations (channel, platform, runtime_version, current_update_id, last_seen_at DESC);

-- +goose Down
DROP TABLE IF EXISTS public.app_update_installations;
DROP TABLE IF EXISTS public.app_update_channels;
