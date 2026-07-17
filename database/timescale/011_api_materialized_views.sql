-- +goose Up
DROP TABLE IF EXISTS public.api_tokens;

CREATE MATERIALIZED VIEW public.api_global_counts AS
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

CREATE UNIQUE INDEX api_global_counts_id_idx
    ON public.api_global_counts (id);

CREATE MATERIALIZED VIEW public.api_league_tier_counts AS
SELECT
    COALESCE(league_id, 0) AS league_tier_id,
    count(*)::bigint AS player_count,
    now() AS refreshed_at
FROM public.basic_player
GROUP BY COALESCE(league_id, 0);

CREATE UNIQUE INDEX api_league_tier_counts_id_idx
    ON public.api_league_tier_counts (league_tier_id);

-- +goose Down
DROP MATERIALIZED VIEW IF EXISTS public.api_league_tier_counts;
DROP MATERIALIZED VIEW IF EXISTS public.api_global_counts;

CREATE TABLE public.api_tokens (
    token_hash text PRIMARY KEY,
    user_id text DEFAULT '' NOT NULL,
    server_id text,
    token_type text DEFAULT '' NOT NULL,
    expires_at timestamp with time zone,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE INDEX idx_api_tokens_expires_at ON public.api_tokens (expires_at);
CREATE INDEX idx_api_tokens_server_id ON public.api_tokens (server_id) WHERE server_id IS NOT NULL;
CREATE INDEX idx_api_tokens_user_type ON public.api_tokens (user_id, token_type);
