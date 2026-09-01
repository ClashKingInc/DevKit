-- +goose Up
ALTER TABLE public.developer_applications
    DROP CONSTRAINT IF EXISTS developer_applications_created_by_admin_id_fkey;

DROP INDEX IF EXISTS public.idx_developer_applications_created_by_admin_id;

ALTER TABLE public.developer_applications
    DROP COLUMN IF EXISTS created_by_admin_id;

DROP TABLE IF EXISTS public.admin_sessions;
DROP TABLE IF EXISTS public.admin_users;

-- +goose Down
-- +goose StatementBegin
DO $$
BEGIN
    RAISE EXCEPTION 'migration 005 is irreversible because legacy admin and session data was deleted';
END
$$;
-- +goose StatementEnd
