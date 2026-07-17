-- +goose Up
CREATE TABLE public.dashboard_role_grants (
    server_id text NOT NULL REFERENCES public.servers(id) ON DELETE CASCADE,
    role_id text NOT NULL,
    section text NOT NULL,
    access_level text NOT NULL,
    created_by_user_id text REFERENCES public.auth_users(user_id) ON DELETE SET NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT dashboard_role_grants_pkey PRIMARY KEY (server_id, role_id, section),
    CONSTRAINT dashboard_role_grants_section_check CHECK (
        section = ANY (ARRAY[
            'settings',
            'family_settings',
            'logs',
            'clans',
            'rosters',
            'links',
            'moderation',
            'roles',
            'reminders',
            'autoboards',
            'giveaways',
            'panels',
            'tickets',
            'embeds',
            'wars',
            'leaderboards'
        ]::text[])
    ),
    CONSTRAINT dashboard_role_grants_access_level_check CHECK (
        access_level = ANY (ARRAY['view', 'manage']::text[])
    )
);

CREATE INDEX dashboard_role_grants_server_idx
    ON public.dashboard_role_grants (server_id);

CREATE INDEX dashboard_role_grants_role_idx
    ON public.dashboard_role_grants (role_id);

CREATE TABLE public.dashboard_access_audit (
    id uuid DEFAULT uuidv7() NOT NULL PRIMARY KEY,
    server_id text NOT NULL REFERENCES public.servers(id) ON DELETE CASCADE,
    actor_user_id text REFERENCES public.auth_users(user_id) ON DELETE SET NULL,
    action text DEFAULT 'replace_grants' NOT NULL,
    before_grants jsonb DEFAULT '[]'::jsonb NOT NULL,
    after_grants jsonb DEFAULT '[]'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE INDEX dashboard_access_audit_server_created_idx
    ON public.dashboard_access_audit (server_id, created_at DESC);

-- +goose Down
DROP TABLE IF EXISTS public.dashboard_access_audit;
DROP TABLE IF EXISTS public.dashboard_role_grants;
