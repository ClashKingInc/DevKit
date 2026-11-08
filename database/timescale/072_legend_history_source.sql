-- +goose Up
-- The endpoint's league category is not evidence of a player's original league.
-- Keep the legacy namespace separate and preserve only supplied source objects.
ALTER TABLE public.legend_history
    ADD COLUMN league_id integer NULL,
    ADD COLUMN league_snapshot jsonb NULL;
ALTER TABLE public.legend_history
    ADD CONSTRAINT legend_history_league_id_check
        CHECK (league_id IS NULL OR league_id > 0) NOT VALID,
    ADD CONSTRAINT legend_history_league_snapshot_check
        CHECK (league_snapshot IS NULL OR jsonb_typeof(league_snapshot) = 'object') NOT VALID;
-- Both columns were just added with NULL for existing rows. NOT VALID still
-- checks every new write without scanning tens of millions of historical rows
-- under this ALTER TABLE lock. Validate separately if catalog validation is needed.

-- +goose Down
-- +goose StatementBegin
DO $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM public.legend_history
        WHERE league_id IS NOT NULL
           OR league_snapshot IS NOT NULL
    ) THEN
        RAISE EXCEPTION 'Preserve original Legend league metadata before rollback';
    END IF;
END $$;
-- +goose StatementEnd
ALTER TABLE public.legend_history
    DROP CONSTRAINT legend_history_league_snapshot_check,
    DROP CONSTRAINT legend_history_league_id_check,
    DROP COLUMN league_snapshot,
    DROP COLUMN league_id;
