-- +goose Up
-- Existing servers remain opted out. Each experiment is an explicit server
-- choice; this first flag does not create a generic experimentation system.
ALTER TABLE public.servers
    ADD COLUMN IF NOT EXISTS lab_tenure_roles_enabled boolean NOT NULL DEFAULT false;

-- +goose Down
-- Retain the choice during rollback so a later reapply restores it. Before
-- rolling back the API or bot, pause role refresh: older workers do not protect
-- a disabled tenure role when another category shares the same Discord role.
SELECT 1;
