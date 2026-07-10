-- +goose Up
ALTER TABLE public.clan_records DROP COLUMN IF EXISTS updated_at;
TRUNCATE TABLE public.clan_records;

-- +goose Down
ALTER TABLE public.clan_records
    ADD COLUMN IF NOT EXISTS updated_at timestamp with time zone DEFAULT now() NOT NULL;
