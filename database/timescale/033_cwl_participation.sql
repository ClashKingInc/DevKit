-- +goose Up
-- Manually rebuilt CWL participation buckets; raw groups and wars remain canonical.
CREATE TABLE public.cwl_participation (
    season text NOT NULL,
    cwl_league_id integer NOT NULL,
    war_size smallint NOT NULL,
    group_count bigint NOT NULL,
    clan_count bigint NOT NULL,
    registered_player_count bigint NOT NULL,
    townhall_counts jsonb NOT NULL,
    same_th_hitrates jsonb,
    finalized_wars bigint NOT NULL,
    archived_wars bigint NOT NULL,
    refreshed_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (season, cwl_league_id, war_size),
    CONSTRAINT cwl_participation_season_check CHECK (season ~ '^[0-9]{4}-(0[1-9]|1[0-2])$'),
    CONSTRAINT cwl_participation_league_check CHECK (cwl_league_id > 48000000),
    CONSTRAINT cwl_participation_size_check CHECK (war_size BETWEEN 1 AND 50),
    CONSTRAINT cwl_participation_counts_check CHECK (
        group_count >= 0 AND clan_count >= 0 AND registered_player_count >= 0
        AND finalized_wars >= 0 AND archived_wars >= 0 AND archived_wars <= finalized_wars
    ),
    CONSTRAINT cwl_participation_townhall_check CHECK (jsonb_typeof(townhall_counts) = 'array'),
    CONSTRAINT cwl_participation_hitrates_check CHECK (
        same_th_hitrates IS NULL OR jsonb_typeof(same_th_hitrates) = 'array'
    )
);

-- +goose Down
DROP TABLE public.cwl_participation;
