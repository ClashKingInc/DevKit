-- +goose Up
-- 036-039 are reserved for the separate tournament feature. A pending roster
-- refresh must remember former role IDs after its configuration is changed or
-- deleted, so retries can remove them without managing unrelated roles.
ALTER TABLE public.role_refresh_jobs
    ADD COLUMN roster_role_ids text[] NOT NULL DEFAULT ARRAY[]::text[],
    ADD CONSTRAINT role_refresh_jobs_roster_role_ids_valid CHECK (
        array_position(roster_role_ids, NULL) IS NULL
        AND array_to_string(roster_role_ids, ',') ~ '^([0-9]{15,20}(,[0-9]{15,20})*)?$'
    );

-- +goose Down
ALTER TABLE public.role_refresh_jobs
    DROP CONSTRAINT role_refresh_jobs_roster_role_ids_valid,
    DROP COLUMN roster_role_ids;
