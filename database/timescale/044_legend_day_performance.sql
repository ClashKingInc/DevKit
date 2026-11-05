-- +goose Up
-- Nullable until a closeout explicitly calculates this player's observed day.
-- Zero means calculated with no battles; NULL must never be read as zero.
ALTER TABLE public.legend_rankings_history
    ADD COLUMN observed_attack_count integer,
    ADD COLUMN observed_attack_triples integer,
    ADD COLUMN observed_attack_trophies integer,
    ADD COLUMN observed_defense_count integer,
    ADD COLUMN observed_defense_triples integer,
    ADD COLUMN observed_defense_trophies integer,
    ADD COLUMN performance_calculated_at timestamptz,
    ADD CONSTRAINT legend_performance_nonnegative CHECK (
        observed_attack_count >= 0 AND observed_attack_triples >= 0
        AND observed_attack_trophies >= 0 AND observed_defense_count >= 0
        AND observed_defense_triples >= 0 AND observed_defense_trophies >= 0
    );

-- Counts describe observations, not proof that tracking covered every battle.
-- Retain the actual source window so a future boundary correction is auditable.
CREATE TABLE public.legend_day_performance (
    day date NOT NULL,
    cohort text NOT NULL,
    direction smallint NOT NULL,
    source_window_start timestamptz NOT NULL,
    source_window_end timestamptz NOT NULL,
    eligible_player_count integer NOT NULL,
    observed_player_count integer NOT NULL,
    complete_player_count integer NOT NULL,
    invalid_player_count integer NOT NULL,
    observed_battle_count bigint NOT NULL,
    observed_triple_count bigint NOT NULL,
    perfect_player_count integer NOT NULL,
    complete_trophy_sum bigint NOT NULL,
    trophy_buckets integer[] NOT NULL,
    calculated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (day, cohort, direction),
    CONSTRAINT legend_performance_cohort CHECK (cohort IN ('legend_i', 'top_1000', 'top_200')),
    CONSTRAINT legend_performance_direction CHECK (direction IN (1, 2)),
    CONSTRAINT legend_performance_window CHECK (source_window_end = source_window_start + interval '24 hours'),
    CONSTRAINT legend_performance_counts CHECK (
        eligible_player_count >= observed_player_count
        AND observed_player_count >= complete_player_count + invalid_player_count
        AND complete_player_count >= perfect_player_count
        AND perfect_player_count >= 0
        AND invalid_player_count >= 0
        AND complete_trophy_sum BETWEEN 0 AND complete_player_count::bigint * 320
        AND observed_battle_count >= observed_triple_count
        AND observed_triple_count >= 0
    ),
    CONSTRAINT legend_performance_buckets CHECK (
        array_ndims(trophy_buckets) = 1
        AND array_lower(trophy_buckets, 1) = 1
        AND cardinality(trophy_buckets) = 16
        AND array_position(trophy_buckets, NULL) IS NULL
        AND 0 <= ALL(trophy_buckets)
    )
);

-- +goose Down
DROP TABLE public.legend_day_performance;
ALTER TABLE public.legend_rankings_history
    DROP CONSTRAINT legend_performance_nonnegative,
    DROP COLUMN observed_attack_count,
    DROP COLUMN observed_attack_triples,
    DROP COLUMN observed_attack_trophies,
    DROP COLUMN observed_defense_count,
    DROP COLUMN observed_defense_triples,
    DROP COLUMN observed_defense_trophies,
    DROP COLUMN performance_calculated_at;
