-- +goose Up
SET LOCAL lock_timeout = '5s';
ALTER TABLE public.server_countdowns
    ADD COLUMN disabled boolean NOT NULL DEFAULT false;

-- +goose Down
SET LOCAL lock_timeout = '5s';
ALTER TABLE public.server_countdowns
    DROP COLUMN disabled;
