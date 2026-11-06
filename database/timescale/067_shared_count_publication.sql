-- +goose Up
-- Revised before its first production application (verified at schema 066). Headline
-- history/population totals intentionally use catalog estimates: no historical
-- bootstrap or per-row counters. Grouped distribution views are deliberately untouched.
SET LOCAL lock_timeout='5s';
SELECT pg_advisory_xact_lock(73194201);
CREATE MATERIALIZED VIEW public.api_global_counts_replacement AS
SELECT 1::smallint AS id,
    (SELECT count(DISTINCT player_tag) FROM player_timers WHERE event_type='war' AND expires_at>=now()) AS players_in_war,
    (SELECT count(DISTINCT clan_tag) FROM wars WHERE end_time>=now()) AS clans_in_war,
    (SELECT approximate_row_count('public.join_leave_history'::regclass)) AS total_join_leaves,
    (SELECT count(*) FROM legend_rankings_current) AS players_in_legends,
    (SELECT approximate_row_count('public.basic_player'::regclass)) AS player_count,
    (SELECT approximate_row_count('public.basic_clan'::regclass)) AS clan_count,
    (SELECT approximate_row_count('public.wars'::regclass)) AS wars_stored,
    now() AS refreshed_at
WITH NO DATA;

REFRESH MATERIALIZED VIEW public.api_global_counts_replacement;

CREATE UNIQUE INDEX api_global_counts_id_replacement_idx ON public.api_global_counts_replacement (id);

DROP MATERIALIZED VIEW public.api_global_counts;

ALTER MATERIALIZED VIEW public.api_global_counts_replacement RENAME TO api_global_counts;

ALTER INDEX api_global_counts_id_replacement_idx RENAME TO api_global_counts_id_idx;

COMMENT ON MATERIALIZED VIEW api_global_counts IS 'Headline player/clan/history totals are Timescale catalog estimates; grouped distributions and current-war metrics remain exact.';
-- Empty preparation aggregates are no longer used. Removing them also removes
-- their invalidation tracking from append-heavy history writes.
DROP MATERIALIZED VIEW stats_join_leave_daily_counts;
DROP MATERIALIZED VIEW stats_war_daily_counts;

-- +goose Down
-- Restore the original exact source scans. Source rows remain untouched;
-- retired preparation aggregates are recreated empty below.
SET LOCAL lock_timeout='5s';
-- Serialize the name swap with the deployed maintenance service.
SELECT pg_advisory_xact_lock(73194201);
CREATE MATERIALIZED VIEW public.api_global_counts_replacement AS
SELECT (1)::smallint AS id,
    ( SELECT count(DISTINCT player_timers.player_tag) AS count
           FROM public.player_timers
          WHERE ((player_timers.event_type = 'war'::text) AND (player_timers.expires_at >= now()))) AS players_in_war,
    ( SELECT count(DISTINCT wars.clan_tag) AS count
           FROM public.wars
          WHERE (wars.end_time >= now())) AS clans_in_war,
    ( SELECT count(*) AS count
           FROM public.join_leave_history) AS total_join_leaves,
    ( SELECT count(*) AS count
           FROM public.legend_rankings_current) AS players_in_legends,
    ( SELECT count(*) AS count
           FROM public.basic_player) AS player_count,
    ( SELECT count(*) AS count
           FROM public.basic_clan) AS clan_count,
    ( SELECT count(*) AS count
           FROM public.wars) AS wars_stored,
    now() AS refreshed_at
WITH NO DATA;

REFRESH MATERIALIZED VIEW public.api_global_counts_replacement;

CREATE UNIQUE INDEX api_global_counts_id_replacement_idx ON public.api_global_counts_replacement (id);

DROP MATERIALIZED VIEW public.api_global_counts;

ALTER MATERIALIZED VIEW public.api_global_counts_replacement RENAME TO api_global_counts;

ALTER INDEX api_global_counts_id_replacement_idx RENAME TO api_global_counts_id_idx;

-- Restore the additive 064 objects without scanning source history.
CREATE MATERIALIZED VIEW stats_join_leave_daily_counts
WITH (timescaledb.continuous, timescaledb.materialized_only=false) AS
SELECT time_bucket(INTERVAL '1 day', time) AS day_start, count(*) AS row_count
FROM join_leave_history GROUP BY day_start WITH NO DATA;
CREATE MATERIALIZED VIEW stats_war_daily_counts
WITH (timescaledb.continuous, timescaledb.materialized_only=false) AS
SELECT time_bucket(INTERVAL '1 day', end_time) AS day_start, count(*) AS row_count
FROM wars GROUP BY day_start WITH NO DATA;
