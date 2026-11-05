-- +goose Up
-- Legacy Reddit feeds optionally mention a role and forward comments on posts
-- by selected Reddit accounts. Keep these settings with the destination so a
-- channel change or temporary disable cannot silently discard them.
ALTER TABLE public.server_logs
    ADD COLUMN reddit_role_id text,
    ADD COLUMN reddit_accounts text[] NOT NULL DEFAULT '{}'::text[],
    ADD CONSTRAINT server_logs_reddit_settings_scope_check CHECK (
        type = 'reddit_feed'
        OR (reddit_role_id IS NULL AND cardinality(reddit_accounts) = 0)
    );

-- +goose Down
ALTER TABLE public.server_logs
    DROP CONSTRAINT server_logs_reddit_settings_scope_check,
    DROP COLUMN reddit_accounts,
    DROP COLUMN reddit_role_id;
