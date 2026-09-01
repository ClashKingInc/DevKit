-- +goose Up
CREATE TABLE public.developer_applications (
    application_id uuid DEFAULT uuidv7() NOT NULL,
    application_name text NOT NULL,
    developer_name text,
    contact_email text,
    redirect_uri text,
    token_hash bytea NOT NULL,
    token_prefix text NOT NULL,
    token_last_used_at timestamp with time zone,
    created_by_admin_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    revoked_at timestamp with time zone,
    CONSTRAINT developer_applications_pkey PRIMARY KEY (application_id),
    CONSTRAINT developer_applications_token_hash_key UNIQUE (token_hash),
    CONSTRAINT developer_applications_application_name_check
        CHECK (application_name = btrim(application_name) AND application_name <> '' AND length(application_name) <= 120),
    CONSTRAINT developer_applications_developer_name_check
        CHECK (developer_name IS NULL OR (developer_name = btrim(developer_name) AND developer_name <> '' AND length(developer_name) <= 120)),
    CONSTRAINT developer_applications_contact_email_check
        CHECK (contact_email IS NULL OR (contact_email = btrim(contact_email) AND contact_email <> '' AND length(contact_email) <= 320)),
    CONSTRAINT developer_applications_redirect_uri_check
        CHECK (redirect_uri IS NULL OR (redirect_uri = btrim(redirect_uri) AND redirect_uri <> '' AND length(redirect_uri) <= 2048)),
    CONSTRAINT developer_applications_token_hash_check
        CHECK (octet_length(token_hash) = 32),
    CONSTRAINT developer_applications_token_prefix_check
        CHECK (token_prefix = btrim(token_prefix) AND token_prefix <> '' AND length(token_prefix) <= 32),
    CONSTRAINT developer_applications_created_by_admin_id_fkey
        FOREIGN KEY (created_by_admin_id) REFERENCES public.admin_users(id) ON DELETE RESTRICT
);

CREATE INDEX idx_developer_applications_created_by_admin_id
    ON public.developer_applications (created_by_admin_id);

CREATE TABLE public.developer_link_grants (
    grant_id uuid DEFAULT uuidv7() NOT NULL,
    application_id uuid NOT NULL,
    user_id text NOT NULL,
    access_mode text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    revoked_at timestamp with time zone,
    CONSTRAINT developer_link_grants_pkey PRIMARY KEY (grant_id),
    CONSTRAINT developer_link_grants_access_mode_check
        CHECK (access_mode IN ('selected', 'all_current_and_future')),
    CONSTRAINT developer_link_grants_application_id_fkey
        FOREIGN KEY (application_id) REFERENCES public.developer_applications(application_id) ON DELETE CASCADE,
    CONSTRAINT developer_link_grants_user_id_fkey
        FOREIGN KEY (user_id) REFERENCES public.auth_users(user_id) ON DELETE CASCADE
);

CREATE UNIQUE INDEX uq_developer_link_grants_current_application_user
    ON public.developer_link_grants (application_id, user_id)
    WHERE revoked_at IS NULL;

CREATE INDEX idx_developer_link_grants_application_id
    ON public.developer_link_grants (application_id);

CREATE INDEX idx_developer_link_grants_user_id
    ON public.developer_link_grants (user_id);

CREATE TABLE public.developer_link_grant_accounts (
    grant_id uuid NOT NULL,
    player_tag text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT developer_link_grant_accounts_pkey PRIMARY KEY (grant_id, player_tag),
    CONSTRAINT developer_link_grant_accounts_grant_id_fkey
        FOREIGN KEY (grant_id) REFERENCES public.developer_link_grants(grant_id) ON DELETE CASCADE,
    CONSTRAINT developer_link_grant_accounts_player_tag_fkey
        FOREIGN KEY (player_tag) REFERENCES public.player_links(tag) ON DELETE CASCADE
);

CREATE INDEX idx_developer_link_grant_accounts_player_tag
    ON public.developer_link_grant_accounts (player_tag);

-- +goose Down
DROP TABLE IF EXISTS public.developer_link_grant_accounts;
DROP TABLE IF EXISTS public.developer_link_grants;
DROP TABLE IF EXISTS public.developer_applications;
