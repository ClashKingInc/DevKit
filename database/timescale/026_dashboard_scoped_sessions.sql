-- +goose Up
CREATE TABLE public.dashboard_access_grants (
    id uuid NOT NULL DEFAULT uuidv7(),
    token_hash text NOT NULL,
    user_id text NOT NULL REFERENCES public.auth_users(user_id) ON DELETE CASCADE,
    server_id text NOT NULL REFERENCES public.servers(id) ON DELETE CASCADE,
    source text NOT NULL CHECK (source IN ('app','bot')),
    device_id text NULL,
    permissions jsonb NOT NULL,
    pkce_challenge text NULL,
    expires_at timestamptz NOT NULL DEFAULT now() + interval '2 minutes',
    consumed_at timestamptz NULL,
    PRIMARY KEY (id),
    UNIQUE (token_hash),
    CHECK (source<>'app' OR (device_id IS NOT NULL AND pkce_challenge IS NOT NULL))
);
CREATE TABLE public.dashboard_scoped_sessions (
    id uuid NOT NULL DEFAULT uuidv7(),
    grant_id uuid NOT NULL REFERENCES public.dashboard_access_grants(id),
    user_id text NOT NULL REFERENCES public.auth_users(user_id) ON DELETE CASCADE,
    server_id text NOT NULL REFERENCES public.servers(id) ON DELETE CASCADE,
    device_id text NULL,
    permissions jsonb NOT NULL,
    refresh_hash text NOT NULL,
    expires_at timestamptz NOT NULL,
    revoked_at timestamptz NULL,
    PRIMARY KEY (id),
    UNIQUE (grant_id),
    UNIQUE (refresh_hash)
);
CREATE INDEX dashboard_scoped_user_device ON public.dashboard_scoped_sessions(user_id,device_id);
-- Refresh hashes rotate in the scoped table only; they cannot be redeemed by
-- ordinary native/web refresh endpoints to obtain an unrestricted session.
-- +goose Down
DROP TABLE public.dashboard_scoped_sessions;
DROP TABLE public.dashboard_access_grants;
