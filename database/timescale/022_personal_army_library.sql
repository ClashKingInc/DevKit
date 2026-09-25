-- +goose Up
-- Personal base grouping is derived from the Town Hall encoded in base_link.
-- Keep the saved-base identity and timestamp while removing the obsolete label.
ALTER TABLE public.user_saved_bases
    DROP CONSTRAINT user_saved_bases_kind_check,
    DROP COLUMN kind;

-- A personal army is a user-owned reference to one canonical composition.
-- Removing the save never removes the shared composition or retained history.
CREATE TABLE public.user_saved_armies (
    user_id text NOT NULL REFERENCES public.auth_users(user_id) ON DELETE CASCADE,
    share_code text NOT NULL REFERENCES public.army_compositions(share_code) ON DELETE CASCADE,
    saved_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id,share_code)
);
CREATE INDEX idx_user_saved_armies_recent
    ON public.user_saved_armies (user_id,saved_at DESC,share_code);

COMMENT ON TABLE public.user_saved_armies IS
    'Authenticated-user references to canonical army compositions; share_code is the durable identity.';

-- +goose Down
-- Removed personal-base labels cannot be reconstructed, so this migration is
-- intentionally forward-only.
-- +goose StatementBegin
DO $$
BEGIN
    RAISE EXCEPTION 'migration 022 is irreversible: removed personal base labels cannot be reconstructed';
END
$$;
-- +goose StatementEnd
