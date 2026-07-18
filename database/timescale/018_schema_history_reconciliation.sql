-- +goose Up
-- Versions 009-012 briefly collided with an unmerged mobile operations series.
-- Reassert the idempotent parts of the canonical 010-012 contracts for any
-- development database that recorded those version numbers with other SQL.
ALTER TABLE public.autoboards
    ADD COLUMN IF NOT EXISTS board_type text DEFAULT '' NOT NULL,
    ADD COLUMN IF NOT EXISTS button_id text DEFAULT '' NOT NULL,
    ADD COLUMN IF NOT EXISTS days text[] DEFAULT '{}'::text[] NOT NULL,
    ADD COLUMN IF NOT EXISTS locale text DEFAULT '' NOT NULL;

ALTER TABLE public.roster_groups
    ADD COLUMN IF NOT EXISTS created_at timestamp with time zone DEFAULT now() NOT NULL;

ALTER TABLE public.rosters
    DROP COLUMN IF EXISTS linked_clan_tag,
    DROP COLUMN IF EXISTS title,
    DROP COLUMN IF EXISTS description,
    DROP COLUMN IF EXISTS max_size,
    DROP COLUMN IF EXISTS minimum_townhall,
    DROP COLUMN IF EXISTS maximum_townhall,
    DROP COLUMN IF EXISTS image_url,
    DROP COLUMN IF EXISTS signup_role_id;

DROP TABLE IF EXISTS public.api_tokens;

CREATE MATERIALIZED VIEW IF NOT EXISTS public.api_global_counts AS
SELECT
    1::smallint AS id,
    (SELECT count(DISTINCT player_tag) FROM public.war_members WHERE war_end_time >= now())::bigint AS players_in_war,
    (SELECT count(DISTINCT clan_tag) FROM public.wars WHERE end_time >= now())::bigint AS clans_in_war,
    (SELECT count(*) FROM public.join_leave_history)::bigint AS total_join_leaves,
    (SELECT count(*) FROM public.legend_rankings_current)::bigint AS players_in_legends,
    (SELECT count(*) FROM public.player_current_stats)::bigint AS player_count,
    (SELECT count(*) FROM public.basic_clan)::bigint AS clan_count,
    (SELECT count(*) FROM public.wars)::bigint AS wars_stored,
    now() AS refreshed_at;

CREATE UNIQUE INDEX IF NOT EXISTS api_global_counts_id_idx
    ON public.api_global_counts (id);

CREATE MATERIALIZED VIEW IF NOT EXISTS public.api_league_tier_counts AS
SELECT
    COALESCE(league_id, 0) AS league_tier_id,
    count(*)::bigint AS player_count,
    now() AS refreshed_at
FROM public.basic_player
GROUP BY COALESCE(league_id, 0);

CREATE UNIQUE INDEX IF NOT EXISTS api_league_tier_counts_id_idx
    ON public.api_league_tier_counts (league_tier_id);

UPDATE public.auth_users
SET email_hash = NULL,
    password_hash = NULL,
    data = (data - 'email_encrypted' - 'email_hash' - 'password')
        #- '{linked_accounts,email}',
    updated_at = now()
WHERE COALESCE(data -> 'auth_methods', '[]'::jsonb) ? 'discord'
  AND NOT (COALESCE(data -> 'auth_methods', '[]'::jsonb) ? 'email');

-- +goose Down
-- Intentionally irreversible. This migration reconciles databases whose
-- recorded history cannot reveal which colliding SQL files were executed.
