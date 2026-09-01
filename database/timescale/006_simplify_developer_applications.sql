-- +goose Up
UPDATE public.developer_applications
SET developer_name = application_name
WHERE developer_name IS NULL;

ALTER TABLE public.developer_applications
    ALTER COLUMN developer_name SET NOT NULL,
    ADD COLUMN api_request_count bigint DEFAULT 0 NOT NULL,
    ADD COLUMN links_lookup_count bigint DEFAULT 0 NOT NULL,
    ADD CONSTRAINT developer_applications_api_request_count_nonnegative_check
        CHECK (api_request_count >= 0),
    ADD CONSTRAINT developer_applications_links_lookup_count_nonnegative_check
        CHECK (links_lookup_count >= 0);

DROP TABLE public.developer_link_grant_accounts;
DROP TABLE public.developer_link_grants;

ALTER TABLE public.developer_applications
    DROP COLUMN application_name,
    DROP COLUMN contact_email,
    DROP COLUMN redirect_uri;

-- +goose Down
-- +goose StatementBegin
DO $$
BEGIN
    RAISE EXCEPTION 'migration 006 is irreversible because developer link grants and optional application metadata were deleted';
END
$$;
-- +goose StatementEnd
