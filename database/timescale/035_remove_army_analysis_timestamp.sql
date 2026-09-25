-- +goose Up
-- A non-null classified count is the atomic readiness marker for a finalized
-- daily army analysis, including days with zero classified attacks.
ALTER TABLE public.legend_daily_stats
    DROP CONSTRAINT legend_daily_classified_attacks_check,
    DROP COLUMN army_analysis_completed_at,
    ADD CONSTRAINT legend_daily_classified_attacks_check
        CHECK (classified_army_attacks BETWEEN 0 AND attack_count);
COMMENT ON COLUMN public.legend_daily_stats.classified_army_attacks IS
    'Non-null after daily army analysis commits atomically with its setup observations; zero is a completed empty classification.';

-- +goose Down
-- +goose StatementBegin
DO $$ BEGIN
    RAISE EXCEPTION 'migration 035 is irreversible: army analysis completion timestamps are intentionally removed';
END $$;
-- +goose StatementEnd
