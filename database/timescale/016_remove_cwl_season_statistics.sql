-- +goose Up
-- The CWL population aggregate was rejected after migration 010 was published.
-- Its source CWL tables remain authoritative and are intentionally untouched.
DROP PROCEDURE IF EXISTS public.reconcile_cwl_season_statistics(text[]);
DROP TABLE IF EXISTS public.cwl_season_statistics;
DROP FUNCTION IF EXISTS public.cwl_town_halls_valid(jsonb);

-- +goose Down
-- +goose StatementBegin
DO $$
BEGIN
    RAISE EXCEPTION 'migration 016 is irreversible: the rejected CWL season-statistics contract must not be restored by rollback';
END
$$;
-- +goose StatementEnd
