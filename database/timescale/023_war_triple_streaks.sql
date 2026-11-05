-- +goose Up
-- Retain scored outcomes so retries and out-of-order archive backfills cannot
-- double-increment a streak or erase a later reset. No player FK: either roster
-- may contain players the basic-player collector has never seen.
CREATE TABLE public.war_triple_streak_results (
    player_tag text NOT NULL,
    townhall_level smallint NOT NULL CHECK (townhall_level BETWEEN 1 AND 99),
    war_id integer NOT NULL,
    war_end_time timestamptz NOT NULL,
    qualified boolean NOT NULL,
    player_name text NOT NULL,
    clan_tag text NOT NULL,
    PRIMARY KEY (player_tag, townhall_level, war_id)
);
CREATE INDEX war_triple_streak_results_chronological
    ON public.war_triple_streak_results (player_tag, townhall_level, war_end_time DESC, war_id DESC);

CREATE TABLE public.war_triple_streaks (
    player_tag text NOT NULL,
    townhall_level smallint NOT NULL CHECK (townhall_level BETWEEN 1 AND 99),
    streak integer NOT NULL DEFAULT 0 CHECK (streak >= 0 AND streak % 2 = 0),
    last_attack_time timestamptz NOT NULL,
    player_name text NOT NULL,
    clan_tag text NOT NULL,
    PRIMARY KEY (player_tag, townhall_level)
);
CREATE INDEX war_triple_streaks_leaderboard
    ON public.war_triple_streaks (townhall_level, streak DESC, last_attack_time DESC, player_tag)
    WHERE streak > 0;
COMMENT ON COLUMN public.war_triple_streaks.last_attack_time IS
    'End time of the latest scored regular war, including resets; not an individual hit timestamp.';

-- +goose Down
DROP TABLE public.war_triple_streaks;
DROP TABLE public.war_triple_streak_results;
