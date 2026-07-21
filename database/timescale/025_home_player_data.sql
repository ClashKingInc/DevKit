-- +goose Up
ALTER TABLE public.player_links
    ADD COLUMN IF NOT EXISTS last_login timestamp with time zone;

CREATE TABLE public.player_upgrades (
    player_tag text PRIMARY KEY REFERENCES public.player_links(tag) ON DELETE CASCADE,
    data jsonb DEFAULT '{}'::jsonb NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT player_upgrades_data_object_check
        CHECK (jsonb_typeof(data) = 'object')
);

CREATE TABLE public.player_upgrade_preferences (
    player_tag text PRIMARY KEY REFERENCES public.player_links(tag) ON DELETE CASCADE,
    preferences jsonb DEFAULT '{}'::jsonb NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT player_upgrade_preferences_object_check
        CHECK (jsonb_typeof(preferences) = 'object')
);

-- +goose Down
DROP TABLE IF EXISTS public.player_upgrade_preferences;
DROP TABLE IF EXISTS public.player_upgrades;

ALTER TABLE public.player_links
    DROP COLUMN IF EXISTS last_login;
