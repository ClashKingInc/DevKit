-- +goose Up
-- Server clan membership is unlimited. Keep AutoBoard and AI limits unchanged.
ALTER TABLE public.servers
    DROP COLUMN clan_limit;

-- +goose Down
-- Existing clans are retained even above the restored default. Per-server
-- overrides cannot be recovered after Up; restore them from a release backup.
ALTER TABLE public.servers
    ADD COLUMN clan_limit integer NOT NULL DEFAULT 10
        CHECK (clan_limit BETWEEN 0 AND 10000);
