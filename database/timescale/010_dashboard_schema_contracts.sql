-- +goose Up
ALTER TABLE public.autoboards
    ADD COLUMN IF NOT EXISTS board_type text DEFAULT '' NOT NULL,
    ADD COLUMN IF NOT EXISTS button_id text DEFAULT '' NOT NULL,
    ADD COLUMN IF NOT EXISTS days text[] DEFAULT '{}'::text[] NOT NULL,
    ADD COLUMN IF NOT EXISTS locale text DEFAULT '' NOT NULL;

ALTER TABLE public.roster_groups
    ADD COLUMN IF NOT EXISTS created_at timestamp with time zone DEFAULT now() NOT NULL;

-- The current roster API stores the editable roster document in data and keeps
-- only queryable identity/filter fields as columns. These required columns were
-- part of the superseded roster model and prevented current dashboard creates.
ALTER TABLE public.rosters
    DROP COLUMN IF EXISTS linked_clan_tag,
    DROP COLUMN IF EXISTS title,
    DROP COLUMN IF EXISTS description,
    DROP COLUMN IF EXISTS max_size,
    DROP COLUMN IF EXISTS minimum_townhall,
    DROP COLUMN IF EXISTS maximum_townhall,
    DROP COLUMN IF EXISTS image_url,
    DROP COLUMN IF EXISTS signup_role_id;

-- +goose Down
ALTER TABLE public.rosters
    ADD COLUMN IF NOT EXISTS linked_clan_tag text DEFAULT '' NOT NULL,
    ADD COLUMN IF NOT EXISTS title text DEFAULT '' NOT NULL,
    ADD COLUMN IF NOT EXISTS description text DEFAULT '' NOT NULL,
    ADD COLUMN IF NOT EXISTS max_size integer DEFAULT 0 NOT NULL,
    ADD COLUMN IF NOT EXISTS minimum_townhall integer,
    ADD COLUMN IF NOT EXISTS maximum_townhall integer,
    ADD COLUMN IF NOT EXISTS image_url text,
    ADD COLUMN IF NOT EXISTS signup_role_id text;

ALTER TABLE public.roster_groups
    DROP COLUMN IF EXISTS created_at;

ALTER TABLE public.autoboards
    DROP COLUMN IF EXISTS locale,
    DROP COLUMN IF EXISTS days,
    DROP COLUMN IF EXISTS button_id,
    DROP COLUMN IF EXISTS board_type;
