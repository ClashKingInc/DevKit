-- +goose Up
-- Population is observed battle-log players, not a reconstructed rank cohort.
CREATE TABLE public.legend_observed_daily_stats (
    day date NOT NULL,
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
    star_counts bigint[] NOT NULL,
    destruction_sum bigint NOT NULL,
    duration_sum bigint NOT NULL,
    attack_types bigint[] NOT NULL,
    calculated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (day, direction),
    CHECK (direction IN (1, 2)),
    CHECK (source_window_start = (day::timestamp AT TIME ZONE 'UTC') + interval '5 hours'),
    CHECK (source_window_end = source_window_start + interval '24 hours'),
    CHECK (eligible_player_count >= observed_player_count
        AND observed_player_count >= complete_player_count + invalid_player_count
        AND complete_player_count >= perfect_player_count
        AND perfect_player_count >= 0 AND invalid_player_count >= 0),
    CHECK (observed_battle_count >= observed_triple_count AND observed_triple_count >= 0),
    CHECK (complete_trophy_sum BETWEEN 0 AND complete_player_count::bigint * 320),
    CHECK (array_ndims(trophy_buckets) = 1 AND array_lower(trophy_buckets, 1) = 1 AND cardinality(trophy_buckets) = 16 AND array_position(trophy_buckets, NULL) IS NULL AND 0 <= ALL(trophy_buckets)),
    CHECK (array_ndims(star_counts) = 1 AND array_lower(star_counts, 1) = 1 AND cardinality(star_counts) = 4 AND array_position(star_counts, NULL) IS NULL AND 0 <= ALL(star_counts)
        AND star_counts[1] + star_counts[2] + star_counts[3] + star_counts[4] = observed_battle_count),
    CHECK (array_ndims(attack_types) = 1 AND array_lower(attack_types, 1) = 1 AND cardinality(attack_types) = 4 AND array_position(attack_types, NULL) IS NULL AND 0 <= ALL(attack_types)
        AND attack_types[1] + attack_types[2] + attack_types[3] + attack_types[4] = observed_battle_count),
    CHECK (star_counts[4] = observed_triple_count),
    CHECK (trophy_buckets[1] + trophy_buckets[2] + trophy_buckets[3] + trophy_buckets[4]
        + trophy_buckets[5] + trophy_buckets[6] + trophy_buckets[7] + trophy_buckets[8]
        + trophy_buckets[9] + trophy_buckets[10] + trophy_buckets[11] + trophy_buckets[12]
        + trophy_buckets[13] + trophy_buckets[14] + trophy_buckets[15] + trophy_buckets[16]
        = complete_player_count),
    CHECK (perfect_player_count <= trophy_buckets[16]),
    CHECK (destruction_sum BETWEEN 0 AND observed_battle_count * 100 AND duration_sum >= 0)
);
COMMENT ON TABLE public.legend_observed_daily_stats IS
    'Completed Legend-day observations without rank membership. Rebuilt by Tracking; API reads summaries and computes only the current partial day live.';

-- +goose Down
DROP TABLE public.legend_observed_daily_stats;
