-- +goose Up
-- NULL retains V2's existing response to all account changes. An explicit
-- selection restores the legacy five-event filter; an empty array disables
-- game events without disabling manual/settings/link reconciliation.
ALTER TABLE public.servers
    ADD COLUMN auto_role_triggers text[],
    ADD CONSTRAINT servers_auto_role_triggers_valid CHECK (
        auto_role_triggers IS NULL OR (
            cardinality(auto_role_triggers) <= 5
            AND (cardinality(auto_role_triggers)=0 OR array_ndims(auto_role_triggers)=1)
            AND array_position(auto_role_triggers, NULL) IS NULL
            AND auto_role_triggers <@ ARRAY['member_join','member_leave','townhall_change','league_change','role_change']::text[]
        )
    );

-- +goose Down
ALTER TABLE public.servers
    DROP CONSTRAINT servers_auto_role_triggers_valid,
    DROP COLUMN auto_role_triggers;
