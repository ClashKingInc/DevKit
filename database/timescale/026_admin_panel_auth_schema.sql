-- +goose Up
-- Reconcile admin panel authentication tables for environments that applied
-- mobile admin schema changes before the panel-local session tables existed.

CREATE TABLE IF NOT EXISTS public.admin_audit_events (
    id uuid DEFAULT uuidv7() NOT NULL PRIMARY KEY,
    actor text NOT NULL,
    action text NOT NULL,
    resource_type text NOT NULL,
    resource_id text DEFAULT ''::text NOT NULL,
    summary text DEFAULT ''::text NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    ip_address text DEFAULT ''::text NOT NULL,
    user_agent text DEFAULT ''::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS public.admin_users (
    id uuid DEFAULT uuidv7() NOT NULL PRIMARY KEY,
    discord_user_id text NOT NULL UNIQUE,
    username text NOT NULL,
    display_name text NOT NULL,
    avatar_url text DEFAULT ''::text NOT NULL,
    role text DEFAULT 'owner'::text NOT NULL,
    active boolean DEFAULT true NOT NULL,
    last_login_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);

-- +goose StatementBegin
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'admin_users_role_check'
          AND conrelid = 'public.admin_users'::regclass
    ) THEN
        ALTER TABLE public.admin_users
            ADD CONSTRAINT admin_users_role_check
            CHECK (role = ANY (ARRAY['owner'::text, 'admin'::text]));
    END IF;
END $$;
-- +goose StatementEnd

CREATE TABLE IF NOT EXISTS public.admin_sessions (
    id uuid DEFAULT uuidv7() NOT NULL PRIMARY KEY,
    user_id uuid NOT NULL REFERENCES public.admin_users(id) ON DELETE CASCADE,
    token_hash text NOT NULL UNIQUE,
    expires_at timestamp with time zone NOT NULL,
    last_seen_at timestamp with time zone DEFAULT now() NOT NULL,
    revoked_at timestamp with time zone,
    ip_address text DEFAULT ''::text NOT NULL,
    user_agent text DEFAULT ''::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_admin_audit_events_created
    ON public.admin_audit_events (created_at DESC);

CREATE INDEX IF NOT EXISTS idx_admin_audit_events_resource
    ON public.admin_audit_events (resource_type, resource_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_admin_sessions_user_active
    ON public.admin_sessions (user_id, expires_at DESC)
    WHERE revoked_at IS NULL;

-- +goose Down
-- No-op: these tables are also part of 017_mobile_admin_operations.sql on
-- current main, so rolling back this reconciliation migration must not drop
-- schema owned by the earlier migration.
