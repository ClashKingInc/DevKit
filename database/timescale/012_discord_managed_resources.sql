-- +goose Up
-- Provenance for resources actually created by the named feature. Existing
-- configuration IDs and reused Discord resources must never be backfilled here.
CREATE TABLE public.discord_managed_resources (
    resource_type text NOT NULL,
    resource_id text NOT NULL,
    server_id text NOT NULL,
    creation_feature text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT discord_managed_resources_pkey PRIMARY KEY (resource_type, resource_id),
    CONSTRAINT discord_managed_resources_resource_id_check
        CHECK (resource_id ~ '^[1-9][0-9]{0,19}$'),
    CONSTRAINT discord_managed_resources_server_id_check
        CHECK (server_id ~ '^[1-9][0-9]{0,19}$'),
    CONSTRAINT discord_managed_resources_feature_check CHECK (
        (resource_type = 'channel' AND creation_feature = 'server_countdown')
        OR (resource_type = 'webhook' AND creation_feature = 'server_log')
    )
);

CREATE INDEX idx_discord_managed_resources_server_feature
    ON public.discord_managed_resources (server_id, creation_feature);

-- +goose Down
-- +goose StatementBegin
DO $$
BEGIN
    RAISE EXCEPTION 'migration 012 is irreversible because Discord resource creation provenance cannot be reconstructed';
END
$$;
-- +goose StatementEnd
