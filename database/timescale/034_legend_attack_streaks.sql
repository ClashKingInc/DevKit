-- +goose Up
-- This durable summary survives raw-battle retention. It counts consecutive
-- recorded Legend attacks; missing observations cannot prove a lifetime streak.
CREATE TABLE public.legend_attack_streaks (
    player_tag text NOT NULL,
    current_streak bigint NOT NULL DEFAULT 0,
    observed_since timestamptz NOT NULL,
    last_attack_at timestamptz,
    last_non_triple_at timestamptz,
    PRIMARY KEY (player_tag),
    CONSTRAINT legend_attack_streaks_tag_check CHECK (player_tag ~ '^#[0289PYLQGRJCUV]{1,15}$'),
    CONSTRAINT legend_attack_streaks_count_check CHECK (current_streak >= 0),
    CONSTRAINT legend_attack_streaks_order_check CHECK (last_non_triple_at IS NULL OR last_non_triple_at <= last_attack_at)
);

CREATE INDEX legend_attack_streaks_leaders_idx
    ON public.legend_attack_streaks (current_streak DESC, last_attack_at DESC, player_tag)
    WHERE current_streak > 0;

WITH boundaries AS (
    SELECT player_tag,
           min(battle_time) AS observed_since,
           max(battle_time) AS last_attack_at,
           max(battle_time) FILTER (WHERE stars < 3) AS last_non_triple_at
    FROM public.battles_ranked
    WHERE battle_mode = 2 AND direction = 1
    GROUP BY player_tag
)
INSERT INTO public.legend_attack_streaks (
    player_tag,
    current_streak,
    observed_since,
    last_attack_at,
    last_non_triple_at
)
SELECT boundary.player_tag,
       count(*) FILTER (WHERE battle.stars = 3 AND
           (boundary.last_non_triple_at IS NULL OR battle.battle_time > boundary.last_non_triple_at)),
       boundary.observed_since,
       boundary.last_attack_at,
       boundary.last_non_triple_at
FROM boundaries boundary
JOIN public.battles_ranked battle ON battle.player_tag = boundary.player_tag
    AND battle.battle_mode = 2 AND battle.direction = 1
GROUP BY boundary.player_tag, boundary.observed_since, boundary.last_attack_at, boundary.last_non_triple_at;

-- +goose Down
DROP TABLE public.legend_attack_streaks;
