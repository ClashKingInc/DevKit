-- +goose Up
-- Commit an operation identity before customer creation; never generate a new
-- identity simply because an external request timed out. Retry/reconciliation
-- and immutable operation/result handling are enforced by the billing API.
CREATE TABLE public.billing_customer_operations (
    user_id text PRIMARY KEY REFERENCES public.auth_users(user_id) ON DELETE CASCADE,
    operation_id uuid NOT NULL UNIQUE DEFAULT gen_random_uuid(),
    created_at timestamptz NOT NULL DEFAULT now(),
    stripe_customer_id text UNIQUE,
    updated_at timestamptz NOT NULL DEFAULT now()
);

-- Existing preferences win. Adding with true backfills existing rows atomically;
-- changing the default only affects future subscriptions awaiting activation.
ALTER TABLE public.billing_subscriptions
    ADD COLUMN initial_assignment_applied boolean NOT NULL DEFAULT true;
ALTER TABLE public.billing_subscriptions
    ALTER COLUMN initial_assignment_applied SET DEFAULT false;

-- +goose Down
-- +goose StatementBegin
DO $$
BEGIN
    RAISE EXCEPTION 'migration 022 cannot be reversed while customer creation operation identities may be needed for reconciliation';
END
$$;
-- +goose StatementEnd
