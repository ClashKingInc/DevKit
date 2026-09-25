-- +goose Up
-- Per-observation counts, measured from normalized CC siege on each attack.
-- Entries need not sum to attack_count because some codes have no siege.
ALTER TABLE public.army_setup_daily_stats
    ADD COLUMN siege_usage jsonb NOT NULL DEFAULT '[]'::jsonb
        CHECK (jsonb_typeof(siege_usage) = 'array');
COMMENT ON COLUMN public.army_setup_daily_stats.siege_usage IS
    'Observed normalized Clan Castle siege counts [{id,attacks}] for this day, cohort and group or variant; not inferred from the representative code.';

-- +goose Down
ALTER TABLE public.army_setup_daily_stats DROP COLUMN siege_usage;
