-- +goose Up
-- Short-lived successful Discord claims, NOT partial Gateway snapshots.
-- Credential/device/provider scope is hashed; no raw credential is stored.
CREATE TABLE discord_cache.dashboard_access (
    cache_key text PRIMARY KEY CHECK (cache_key ~ '^[a-f0-9]{64}$'),
    claims jsonb,
    observed_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    expires_at timestamptz,
    lease_token uuid,
    lease_until timestamptz,
    CHECK (claims IS NULL OR jsonb_typeof(claims) = 'object'),
    CHECK (claims IS NULL OR octet_length(claims::text) <= 16384)
);
CREATE INDEX dashboard_access_expiry ON discord_cache.dashboard_access (expires_at);

-- Shared reservation/cooldown timestamps. Locks last for SQL statements only,
-- never for a Discord request or a sleep.
CREATE TABLE discord_cache.request_limits (
    cache_key text PRIMARY KEY CHECK (cache_key ~ '^[a-f0-9]{64}$'),
    next_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    blocked_until timestamptz NOT NULL DEFAULT clock_timestamp()
);

-- +goose Down
DROP TABLE discord_cache.request_limits;
DROP TABLE discord_cache.dashboard_access;
