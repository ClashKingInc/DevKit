-- +goose Up
-- A per-server opt-in. Discord owns scheduled events; do not store an occurrence
-- ledger here. Unlinking a clan naturally removes this configuration.
ALTER TABLE public.server_clans
    ADD COLUMN war_events_enabled boolean NOT NULL DEFAULT false;

-- +goose Down
ALTER TABLE public.server_clans DROP COLUMN war_events_enabled;
