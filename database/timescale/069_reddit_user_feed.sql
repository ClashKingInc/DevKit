-- +goose Up
ALTER TABLE public.server_logs
    ADD COLUMN reddit_min_townhall smallint,
    ADD COLUMN reddit_include_comments boolean NOT NULL DEFAULT false,
    DROP CONSTRAINT server_logs_reddit_settings_scope_check;

-- Extend the existing allowlist without accidentally removing other log types.
-- +goose StatementBegin
DO $$
DECLARE definition text;
BEGIN
    SELECT pg_get_constraintdef(oid) INTO definition
    FROM pg_constraint
    WHERE conrelid = 'public.server_logs'::regclass AND conname = 'server_logs_type_check';
    EXECUTE 'ALTER TABLE public.server_logs DROP CONSTRAINT server_logs_type_check';
    EXECUTE 'ALTER TABLE public.server_logs ADD CONSTRAINT server_logs_type_check ' ||
        replace(definition, '''reddit_feed''::text', '''reddit_feed''::text, ''reddit_user_feed''::text');
END $$;
-- +goose StatementEnd
ALTER TABLE public.server_logs
    ADD CONSTRAINT server_logs_reddit_settings_scope_check CHECK (
        type IN ('reddit_feed', 'reddit_user_feed')
        OR (reddit_role_id IS NULL AND cardinality(reddit_accounts) = 0)
    ),
    ADD CONSTRAINT server_logs_reddit_user_scope CHECK (
        type <> 'reddit_user_feed' OR clan_tag IS NULL
    ),
    ADD CONSTRAINT server_logs_reddit_minimum CHECK (
        reddit_min_townhall IS NULL OR (type = 'reddit_feed' AND reddit_min_townhall > 0)
    ),
    ADD CONSTRAINT server_logs_reddit_comments_scope CHECK (
        NOT reddit_include_comments OR type = 'reddit_user_feed'
    );

-- Preserve existing watched-author subscriptions and their destinations.
-- No historical posts or comments are replayed during the split.
INSERT INTO public.server_logs (
    server_id, clan_tag, type, webhook_id, thread_id, disabled,
    reddit_role_id, reddit_accounts, reddit_include_comments
)
SELECT server_id, NULL, 'reddit_user_feed', webhook_id, thread_id, disabled,
       reddit_role_id, reddit_accounts, true
FROM public.server_logs
WHERE type = 'reddit_feed' AND cardinality(reddit_accounts) > 0
ON CONFLICT (server_id, clan_tag, type) DO NOTHING;
UPDATE public.server_logs SET reddit_accounts = '{}' WHERE type = 'reddit_feed';

-- +goose Down
-- Never drop a user's independently configured feed or saved filter.
-- Empty disposable schemas can still downgrade for migration verification.
-- +goose StatementBegin
DO $$
DECLARE definition text;
BEGIN
    IF EXISTS (SELECT 1 FROM public.server_logs WHERE type='reddit_user_feed' OR reddit_min_townhall IS NOT NULL) THEN
        RAISE EXCEPTION 'Reddit feed settings exist; preserve them and roll application code back first';
    END IF;
    SELECT pg_get_constraintdef(oid) INTO definition FROM pg_constraint
    WHERE conrelid='public.server_logs'::regclass AND conname='server_logs_type_check';
    ALTER TABLE public.server_logs DROP CONSTRAINT server_logs_type_check;
    EXECUTE 'ALTER TABLE public.server_logs ADD CONSTRAINT server_logs_type_check ' ||
        replace(definition, ', ''reddit_user_feed''::text', '');
END $$;
-- +goose StatementEnd
ALTER TABLE public.server_logs
    DROP CONSTRAINT server_logs_reddit_settings_scope_check,
    DROP CONSTRAINT server_logs_reddit_user_scope,
    DROP CONSTRAINT server_logs_reddit_minimum,
    DROP CONSTRAINT server_logs_reddit_comments_scope,
    DROP COLUMN reddit_min_townhall,
    DROP COLUMN reddit_include_comments,
    ADD CONSTRAINT server_logs_reddit_settings_scope_check CHECK (
        type='reddit_feed' OR (reddit_role_id IS NULL AND cardinality(reddit_accounts)=0)
    );
