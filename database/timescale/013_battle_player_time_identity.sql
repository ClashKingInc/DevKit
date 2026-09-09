-- +goose Up
-- Tracking stores only the requested player's observation. Never silently drop
-- existing collisions: reconcile/reset them explicitly before this migration.
SET LOCAL lock_timeout = '5s';
ALTER TABLE public.battles_ranked
    DROP CONSTRAINT battles_ranked_pkey,
    ADD PRIMARY KEY (player_tag, battle_time);

-- +goose Down
SET LOCAL lock_timeout = '5s';
ALTER TABLE public.battles_ranked
    DROP CONSTRAINT battles_ranked_pkey,
    ADD PRIMARY KEY (player_tag, battle_time, battle_mode, direction, opponent_tag);
