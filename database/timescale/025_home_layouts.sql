-- +goose Up
CREATE TABLE public.home_layouts (
    user_id text NOT NULL REFERENCES public.auth_users(user_id) ON DELETE CASCADE,
    revision bigint NOT NULL DEFAULT 1,
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id),
    CHECK (revision > 0)
);
CREATE TABLE public.home_items (
    user_id text NOT NULL REFERENCES public.home_layouts(user_id) ON DELETE CASCADE,
    id text NOT NULL,
    kind text NOT NULL,
    entity_tag text NULL,
    size text NOT NULL,
    position integer NOT NULL,
    PRIMARY KEY (user_id,id),
    UNIQUE (user_id,position) DEFERRABLE INITIALLY DEFERRED,
    CHECK (kind IN ('todo','ranked','upgrade','ranked_player','legend_day','war_score','clan_donations','player_farming')),
    CHECK (size IN ('small','wide')),
    CHECK (position BETWEEN 0 AND 29),
    CHECK ((kind IN ('todo','ranked','upgrade') AND entity_tag IS NULL AND id=kind AND size='wide')
        OR (kind NOT IN ('todo','ranked','upgrade') AND entity_tag ~ '^#[0289PYLQGRJCUV]+$'))
);
-- The API requires exactly one of each built-in item on every replacement.
-- Slots remain stored even when an account/feature makes a card unavailable.
CREATE UNIQUE INDEX home_builtin_once ON public.home_items(user_id,kind)
    WHERE kind IN ('todo','ranked','upgrade');
-- +goose Down
DROP TABLE public.home_items;
DROP TABLE public.home_layouts;
