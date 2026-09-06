-- +goose Up
-- Stable coordination identities for subjects that need not have auth_users
-- or any bookmark/history rows. These rows are not authentication identities.
CREATE TABLE public.subject_mutation_locks (
    subject_id text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT subject_mutation_locks_pkey PRIMARY KEY (subject_id),
    CONSTRAINT subject_mutation_locks_nonempty_check CHECK (subject_id <> '')
);

-- +goose Down
-- +goose StatementBegin
DO $$
BEGIN
    RAISE EXCEPTION 'migration 013 is irreversible because stable subject coordination must not be removed while writers depend on it';
END
$$;
-- +goose StatementEnd
