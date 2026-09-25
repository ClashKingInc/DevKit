-- +goose Up
-- Reserve each client nonce before sending to Discord. A missing message_id is
-- deliberately uncertain after a worker interruption and must not be resent.
CREATE TABLE public.roster_publication_requests (
    roster_id uuid NOT NULL REFERENCES public.rosters(id) ON DELETE CASCADE,
    nonce text NOT NULL CHECK (nonce ~ '^[A-Za-z0-9_-]{1,25}$'),
    payload jsonb NOT NULL CHECK (jsonb_typeof(payload) = 'object'),
    message_id text CHECK (message_id ~ '^[0-9]{1,20}$'),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (roster_id, nonce)
);

-- +goose Down
-- Request history cannot be discarded safely while clients may retry.
-- +goose StatementBegin
DO $$ BEGIN RAISE EXCEPTION 'migration 037 is irreversible: publication idempotency history may exist'; END $$;
-- +goose StatementEnd
