-- +goose Up
-- A nullable choice lets existing users pick explicitly during onboarding or Settings.
-- Ownership and deletion follow the existing authenticated account row.
ALTER TABLE public.auth_users
    ADD COLUMN avatar_id text,
    ADD CONSTRAINT auth_users_avatar_id_check
        CHECK (avatar_id IN ('barbarian', 'archer', 'goblin', 'giant', 'wizard', 'hog-rider', 'valkyrie', 'barbarian-king', 'archer-queen', 'royal-champion', 'minion-prince'));

-- +goose Down
ALTER TABLE public.auth_users
    DROP CONSTRAINT auth_users_avatar_id_check,
    DROP COLUMN avatar_id;
