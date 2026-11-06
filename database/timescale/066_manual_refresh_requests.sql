-- +goose Up
-- Member work remains in role_refresh_jobs. This header owns the normal Discord
-- message so a bulk refresh never depends on an interaction token's lifetime.
CREATE TABLE public.role_refresh_requests (
    id text PRIMARY KEY,
    server_id text NOT NULL REFERENCES public.servers(id) ON DELETE CASCADE,
    actor_id text NOT NULL,
    target_id text NOT NULL,
    target_kind text NOT NULL CHECK (target_kind IN ('user', 'role')),
    channel_id text NOT NULL,
    message_id text,
    preview boolean NOT NULL DEFAULT false,
    categories text[] NOT NULL,
    role_treatment text NOT NULL DEFAULT 'both' CHECK (role_treatment IN ('add', 'remove', 'both')),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    published_at timestamptz,
    published_complete boolean NOT NULL DEFAULT false
);
CREATE INDEX role_refresh_requests_progress ON public.role_refresh_requests (published_at NULLS FIRST, id)
    WHERE NOT published_complete;

-- +goose Down
-- Do not strand active authorized jobs by removing their progress owner.
-- +goose StatementBegin
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM public.role_refresh_jobs j JOIN public.role_refresh_requests r ON r.id=j.request_id
        WHERE j.completed_at IS NULL AND j.attempts<12) THEN
        RAISE EXCEPTION 'Active manual refresh jobs must finish before rollback';
    END IF;
END $$;
-- +goose StatementEnd
DROP TABLE public.role_refresh_requests;
