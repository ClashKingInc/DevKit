-- +goose Up
-- Links-only policy: OFF for existing and new servers unless explicitly enabled.
-- The API verifies a supplied token on each new server-scoped linking attempt;
-- previously verified ownership does not bypass this server policy.
ALTER TABLE public.servers
    ADD COLUMN require_api_token_when_linking boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.servers.require_api_token_when_linking IS
    'Require a valid supplied player API token for each new server-scoped linking attempt, including an already verified owner. Does not gate signup or filter linked accounts. Exact committed retries replay the original attempt.';

-- +goose Down
-- +goose StatementBegin
DO $$
BEGIN
    RAISE EXCEPTION 'migration 027 cannot be reversed because enabled server linking-token policies must not be silently removed';
END
$$;
-- +goose StatementEnd
