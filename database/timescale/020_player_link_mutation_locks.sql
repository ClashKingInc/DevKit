-- +goose Up
-- A stable player-tag lock serializes claims even when player_links has no row.
-- Keep this namespace separate from raw user IDs in subject_mutation_locks.
CREATE TABLE public.player_link_mutation_locks (
    tag text NOT NULL,
    CONSTRAINT player_link_mutation_locks_pkey PRIMARY KEY (tag),
    CONSTRAINT player_link_mutation_locks_nonempty_check CHECK (tag <> '')
);

-- +goose Down
-- +goose StatementBegin
DO $$
BEGIN
    RAISE EXCEPTION 'migration 020 is irreversible because stable player link coordination must not be removed while writers depend on it';
END
$$;
-- +goose StatementEnd
