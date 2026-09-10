-- +goose Up
-- Expand only the storage nullability needed by the bounded defense-loot
-- cleanup. Existing attacks and defenses remain unchanged by this migration.
SET LOCAL lock_timeout = '5s';
ALTER TABLE public.battles_ranked
    ALTER COLUMN looted_resources DROP NOT NULL;

-- +goose Down
SET LOCAL lock_timeout = '5s';
-- +goose StatementBegin
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM public.battles_ranked
        WHERE looted_resources IS NULL
    ) THEN
        RAISE EXCEPTION 'migration 014 rollback refused: ranked rows contain null loot';
    END IF;
END
$$;
-- +goose StatementEnd
ALTER TABLE public.battles_ranked
    ALTER COLUMN looted_resources SET NOT NULL;
