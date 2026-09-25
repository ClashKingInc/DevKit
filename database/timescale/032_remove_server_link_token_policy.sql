-- +goose Up
-- Every new account link now verifies an in-game API token, independent of server.
ALTER TABLE public.servers DROP COLUMN require_api_token_when_linking;

-- +goose Down
-- The removed per-server policy cannot be restored from retained data.
-- +goose StatementBegin
DO $$ BEGIN RAISE EXCEPTION 'migration 032 is irreversible: server link token policies were removed'; END $$;
-- +goose StatementEnd
