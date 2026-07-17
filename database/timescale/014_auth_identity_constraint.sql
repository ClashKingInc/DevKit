-- +goose Up
ALTER TABLE public.auth_users
    ADD CONSTRAINT auth_users_single_identity_provider
    CHECK (email_hash IS NULL OR discord_user_id IS NULL);

-- +goose Down
ALTER TABLE public.auth_users
    DROP CONSTRAINT IF EXISTS auth_users_single_identity_provider;
