-- +goose Up
-- Daily troop-overlap observations. Identity comes from core troops and setup
-- conditions, never a display name, row order or changing representative.
CREATE TABLE public.army_setup_daily_stats (
    day date NOT NULL,
    league_tier_id integer NOT NULL CHECK (league_tier_id > 0),
    rank_limit integer CHECK (rank_limit IN (200,1000)),
    group_key text NOT NULL CHECK (length(group_key) BETWEEN 1 AND 256),
    variant_key text NOT NULL DEFAULT '' CHECK (length(variant_key) <= 1024),
    core_troops integer[] NOT NULL CHECK (cardinality(core_troops) > 0),
    conditions jsonb NOT NULL DEFAULT '[]' CHECK (jsonb_typeof(conditions) = 'array'),
    representative_share_code text NOT NULL CHECK (length(representative_share_code) > 0),
    attack_count bigint NOT NULL CHECK (attack_count > 0),
    zero_star_count bigint NOT NULL CHECK (zero_star_count >= 0),
    one_star_count bigint NOT NULL CHECK (one_star_count >= 0),
    two_star_count bigint NOT NULL CHECK (two_star_count >= 0),
    three_star_count bigint NOT NULL CHECK (three_star_count >= 0),
    destruction_percentage_sum bigint NOT NULL CHECK (destruction_percentage_sum >= 0),
    evidence jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(evidence) = 'object'),
    calculated_at timestamptz NOT NULL DEFAULT now(),
    CHECK (zero_star_count + one_star_count + two_star_count + three_star_count = attack_count),
    CHECK (destruction_percentage_sum <= attack_count * 100),
    CHECK ((variant_key = '' AND conditions = '[]'::jsonb) OR (variant_key <> '' AND jsonb_array_length(conditions) > 0)),
    UNIQUE NULLS NOT DISTINCT (day,league_tier_id,rank_limit,group_key,variant_key)
);
CREATE INDEX army_setup_daily_identity ON public.army_setup_daily_stats(group_key,variant_key,day);
ALTER TABLE public.legend_daily_stats
    ADD COLUMN army_analysis_completed_at timestamptz,
    ADD COLUMN classified_army_attacks bigint,
    ADD CONSTRAINT legend_daily_classified_attacks_check CHECK (
        classified_army_attacks BETWEEN 0 AND attack_count
        AND ((army_analysis_completed_at IS NULL) = (classified_army_attacks IS NULL))
    );
COMMENT ON COLUMN public.army_setup_daily_stats.variant_key IS
    'Empty means independent troop-group overview. Setup rows may overlap and must not be summed to produce overview counts.';
COMMENT ON COLUMN public.legend_daily_stats.army_analysis_completed_at IS
    'Set atomically with setup observations. A missing setup row is not a measured zero; unsupported patterns are not persisted.';

-- +goose Down
-- +goose StatementBegin
DO $$ BEGIN
    RAISE EXCEPTION 'migration 034 is irreversible: daily army setup history is retained';
END $$;
-- +goose StatementEnd
