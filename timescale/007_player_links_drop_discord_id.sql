-- +goose Up
ALTER TABLE public.player_links
    DROP COLUMN IF EXISTS discord_id;

-- +goose Down
ALTER TABLE public.player_links
    ADD COLUMN IF NOT EXISTS discord_id text;
