-- +goose Up
-- Persist the requested role policy across deferred/retried refreshes. Existing
-- manual and automatic jobs retain the previous add-and-remove behavior.
ALTER TABLE public.role_refresh_jobs
    ADD COLUMN role_treatment text NOT NULL DEFAULT 'both',
    ADD CONSTRAINT role_refresh_jobs_treatment_valid
        CHECK (role_treatment IN ('add', 'remove', 'both'));

-- +goose Down
ALTER TABLE public.role_refresh_jobs
    DROP CONSTRAINT role_refresh_jobs_treatment_valid,
    DROP COLUMN role_treatment;
