-- +goose Up
-- Preserve existing restrictions while giving new rosters an open signup scope.
UPDATE public.rosters SET signup_scope = 'family-only' WHERE signup_scope = 'family-wide';
ALTER TABLE public.rosters
    ALTER COLUMN signup_scope SET DEFAULT 'anyone',
    ADD CONSTRAINT rosters_signup_scope_check
        CHECK (signup_scope IN ('clan-only', 'family-only', 'anyone'));

COMMENT ON COLUMN public.rosters.signup_scope IS
    'Clan eligibility for self-signup: selected clan, any server-linked clan, or anyone. Account verification and other signup limits still apply.';

-- +goose Down
-- Reverting cannot represent unrestricted signups without changing eligibility.
-- +goose StatementBegin
DO $$
BEGIN
    RAISE EXCEPTION 'migration 023 is forward-only: the previous schema cannot represent anyone signup scope';
END
$$;
-- +goose StatementEnd
