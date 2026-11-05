-- +goose Up
-- Game-driven auto refresh policy. Roster/tenure jobs and manual refresh retain
-- their own behavior; the blacklist excludes members, not individual roles.
ALTER TABLE public.servers
    ADD COLUMN auto_role_treatment text NOT NULL DEFAULT 'both',
    ADD COLUMN auto_role_blacklist_ids text[] NOT NULL DEFAULT ARRAY[]::text[],
    ADD CONSTRAINT servers_auto_role_treatment_valid
        CHECK (auto_role_treatment IN ('add', 'remove', 'both')),
    ADD CONSTRAINT servers_auto_role_blacklist_valid CHECK (
        cardinality(auto_role_blacklist_ids) <= 250
        AND (cardinality(auto_role_blacklist_ids)=0 OR array_ndims(auto_role_blacklist_ids)=1)
        AND array_position(auto_role_blacklist_ids, NULL) IS NULL
        AND array_to_string(auto_role_blacklist_ids, ',') ~ '^([0-9]{15,20}(,[0-9]{15,20})*)?$'
    );

-- +goose Down
ALTER TABLE public.servers
    DROP CONSTRAINT servers_auto_role_blacklist_valid,
    DROP CONSTRAINT servers_auto_role_treatment_valid,
    DROP COLUMN auto_role_blacklist_ids,
    DROP COLUMN auto_role_treatment;
