-- +goose NO TRANSACTION
-- +goose Up
-- Final-war ingestion looks up both retained round formats by war tag. Restrict
-- the index to live groups: ended groups never need another completion check.
-- Build online because the live table contains millions of historical groups.
CREATE INDEX CONCURRENTLY idx_cwl_groups_active_rounds
    ON public.cwl_groups USING gin (rounds jsonb_path_ops)
    WHERE state <> 'ended';

-- +goose Down
DROP INDEX CONCURRENTLY public.idx_cwl_groups_active_rounds;
