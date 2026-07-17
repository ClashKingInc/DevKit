-- +goose Up
ALTER TABLE public.player_links
    ADD COLUMN IF NOT EXISTS hidden boolean DEFAULT false NOT NULL;

ALTER TABLE public.player_links
    DROP CONSTRAINT IF EXISTS player_links_hidden_requires_verification;

ALTER TABLE public.player_links
    ADD CONSTRAINT player_links_hidden_requires_verification
    CHECK (NOT hidden OR is_verified);

-- +goose Down
-- Intentionally irreversible: preserving the visibility values is safer than
-- dropping the column during a rollback.
