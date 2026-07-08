-- +goose Up
CREATE TABLE IF NOT EXISTS public.user_bookmarks (
    user_id text NOT NULL,
    entity_type text NOT NULL CHECK (entity_type IN ('player', 'clan')),
    tag text NOT NULL,
    order_index integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    PRIMARY KEY (user_id, entity_type, tag)
);

CREATE INDEX IF NOT EXISTS idx_user_bookmarks_order
    ON public.user_bookmarks (user_id, entity_type, order_index);

CREATE TABLE IF NOT EXISTS public.user_recent_searches (
    user_id text NOT NULL,
    entity_type text NOT NULL CHECK (entity_type IN ('player', 'clan')),
    tag text NOT NULL,
    data jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    PRIMARY KEY (user_id, entity_type, tag, created_at)
);

SELECT create_hypertable(
    'user_recent_searches',
    'created_at',
    chunk_time_interval => INTERVAL '7 days',
    create_default_indexes => FALSE,
    if_not_exists => TRUE
);

CREATE INDEX IF NOT EXISTS idx_user_recent_searches_created
    ON public.user_recent_searches (user_id, entity_type, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_user_recent_searches_expiry
    ON public.user_recent_searches (created_at);

SELECT add_retention_policy('user_recent_searches', INTERVAL '90 days', if_not_exists => TRUE);

-- +goose Down
SELECT remove_retention_policy('user_recent_searches', if_exists => TRUE);
DROP TABLE IF EXISTS public.user_recent_searches CASCADE;
DROP TABLE IF EXISTS public.user_bookmarks CASCADE;
