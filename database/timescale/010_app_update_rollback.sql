-- +goose Up
ALTER TABLE public.app_update_channels
    ADD COLUMN rollback_target_version text,
    ADD CONSTRAINT app_update_channels_rollback_target_check CHECK (
        rollback_target_version IS NULL
        OR (
            active_version IS NOT NULL
            AND rollback_target_version = btrim(rollback_target_version)
            AND rollback_target_version <> ''
            AND rollback_target_version <> active_version
            AND length(rollback_target_version) <= 80
        )
    );

-- +goose Down
ALTER TABLE public.app_update_channels
    DROP CONSTRAINT app_update_channels_rollback_target_check,
    DROP COLUMN rollback_target_version;
