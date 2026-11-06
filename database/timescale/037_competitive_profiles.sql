-- +goose Up
ALTER TABLE competitive_profiles
    ADD COLUMN bio text NOT NULL DEFAULT '' CHECK (length(bio) <= 1000),
    ADD COLUMN socials jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(socials)='object');
-- +goose Down
-- +goose StatementBegin
DO $$ BEGIN RAISE EXCEPTION 'Profile content requires a data-preserving forward migration'; END $$;
-- +goose StatementEnd
