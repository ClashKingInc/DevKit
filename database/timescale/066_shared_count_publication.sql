-- +goose Up
-- The bounded initializer covers the entire historical range before switching
-- readers. Never initialize only recent buckets: the CAGG watermark would hide
-- older source rows from its real-time tail.
SET LOCAL lock_timeout='5s';
-- +goose StatementBegin
DO $$ BEGIN
 IF EXISTS(SELECT 1 FROM join_leave_history LIMIT 1)
 AND NOT EXISTS(SELECT 1 FROM tracking_scheduled_jobs WHERE job='count_history_bootstrap_join_leave_history' AND completed_at IS NOT NULL AND period >= (now() AT TIME ZONE 'UTC')::date - 1) THEN
  RAISE EXCEPTION 'Complete bounded join/leave count bootstrap before migration 066';
 END IF;
 IF EXISTS(SELECT 1 FROM wars LIMIT 1)
 AND NOT EXISTS(SELECT 1 FROM tracking_scheduled_jobs WHERE job='count_history_bootstrap_wars' AND completed_at IS NOT NULL AND period >= (now() AT TIME ZONE 'UTC')::date - 1) THEN
  RAISE EXCEPTION 'Complete bounded war count bootstrap before migration 066';
 END IF;
END $$;
-- +goose StatementEnd

REFRESH MATERIALIZED VIEW stats_player_count_snapshot;
REFRESH MATERIALIZED VIEW stats_clan_count_snapshot;

CREATE MATERIALIZED VIEW public.war_league_counts_replacement AS
SELECT dimension_id AS cwl_league_id, row_count AS clan_count FROM stats_clan_count_snapshot WHERE scope='cwl'
WITH NO DATA;

REFRESH MATERIALIZED VIEW public.war_league_counts_replacement;

CREATE MATERIALIZED VIEW public.townhall_counts_replacement AS
SELECT dimension_id AS level, row_count AS total_count FROM stats_player_count_snapshot WHERE scope='townhall'
WITH NO DATA;

REFRESH MATERIALIZED VIEW public.townhall_counts_replacement;

CREATE UNIQUE INDEX townhall_counts_level_replacement_idx ON public.townhall_counts_replacement (level);

CREATE MATERIALIZED VIEW public.api_league_tier_counts_replacement AS
SELECT dimension_id AS league_tier_id, row_count AS player_count, refreshed_at FROM stats_player_count_snapshot WHERE scope='league'
WITH NO DATA;

REFRESH MATERIALIZED VIEW public.api_league_tier_counts_replacement;

CREATE UNIQUE INDEX api_league_tier_counts_id_replacement_idx ON public.api_league_tier_counts_replacement (league_tier_id);

CREATE MATERIALIZED VIEW public.api_global_counts_replacement AS
SELECT 1::smallint AS id,
    (SELECT count(DISTINCT player_tag) FROM player_timers WHERE event_type='war' AND expires_at>=now()) AS players_in_war,
    (SELECT count(DISTINCT clan_tag) FROM wars WHERE end_time>=now()) AS clans_in_war,
    (SELECT COALESCE(sum(row_count),0)::bigint FROM stats_join_leave_daily_counts) AS total_join_leaves,
    (SELECT count(*) FROM legend_rankings_current) AS players_in_legends,
    (SELECT row_count FROM stats_player_count_snapshot WHERE scope='total') AS player_count,
    (SELECT row_count FROM stats_clan_count_snapshot WHERE scope='total') AS clan_count,
    (SELECT COALESCE(sum(row_count),0)::bigint FROM stats_war_daily_counts) AS wars_stored,
    now() AS refreshed_at
WITH NO DATA;

REFRESH MATERIALIZED VIEW public.api_global_counts_replacement;

CREATE UNIQUE INDEX api_global_counts_id_replacement_idx ON public.api_global_counts_replacement (id);

DROP MATERIALIZED VIEW public.war_league_counts;

ALTER MATERIALIZED VIEW public.war_league_counts_replacement RENAME TO war_league_counts;

DROP MATERIALIZED VIEW public.townhall_counts;

ALTER MATERIALIZED VIEW public.townhall_counts_replacement RENAME TO townhall_counts;

ALTER INDEX townhall_counts_level_replacement_idx RENAME TO townhall_counts_level_idx;

DROP MATERIALIZED VIEW public.api_league_tier_counts;

ALTER MATERIALIZED VIEW public.api_league_tier_counts_replacement RENAME TO api_league_tier_counts;

ALTER INDEX api_league_tier_counts_id_replacement_idx RENAME TO api_league_tier_counts_id_idx;

DROP MATERIALIZED VIEW public.api_global_counts;

ALTER MATERIALIZED VIEW public.api_global_counts_replacement RENAME TO api_global_counts;

ALTER INDEX api_global_counts_id_replacement_idx RENAME TO api_global_counts_id_idx;

-- +goose Down
-- Restore the original exact source scans; raw rows and aggregate buckets stay.
SET LOCAL lock_timeout='5s';
CREATE MATERIALIZED VIEW public.war_league_counts_replacement AS
SELECT cwl_league_id,
    count(*) AS clan_count
   FROM public.basic_clan c
  GROUP BY cwl_league_id
WITH NO DATA;

REFRESH MATERIALIZED VIEW public.war_league_counts_replacement;

CREATE MATERIALIZED VIEW public.townhall_counts_replacement AS
SELECT townhall_level AS level,
    count(*) AS total_count
   FROM public.basic_player
  GROUP BY townhall_level
WITH NO DATA;

REFRESH MATERIALIZED VIEW public.townhall_counts_replacement;

CREATE UNIQUE INDEX townhall_counts_level_replacement_idx ON public.townhall_counts_replacement (level);

CREATE MATERIALIZED VIEW public.api_league_tier_counts_replacement AS
SELECT COALESCE(league_id, 0) AS league_tier_id,
    count(*) AS player_count,
    now() AS refreshed_at
   FROM public.basic_player
  GROUP BY COALESCE(league_id, 0)
WITH NO DATA;

REFRESH MATERIALIZED VIEW public.api_league_tier_counts_replacement;

CREATE UNIQUE INDEX api_league_tier_counts_id_replacement_idx ON public.api_league_tier_counts_replacement (league_tier_id);

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

DROP MATERIALIZED VIEW public.war_league_counts;

ALTER MATERIALIZED VIEW public.war_league_counts_replacement RENAME TO war_league_counts;

DROP MATERIALIZED VIEW public.townhall_counts;

ALTER MATERIALIZED VIEW public.townhall_counts_replacement RENAME TO townhall_counts;

ALTER INDEX townhall_counts_level_replacement_idx RENAME TO townhall_counts_level_idx;

DROP MATERIALIZED VIEW public.api_league_tier_counts;

ALTER MATERIALIZED VIEW public.api_league_tier_counts_replacement RENAME TO api_league_tier_counts;

ALTER INDEX api_league_tier_counts_id_replacement_idx RENAME TO api_league_tier_counts_id_idx;

DROP MATERIALIZED VIEW public.api_global_counts;

ALTER MATERIALIZED VIEW public.api_global_counts_replacement RENAME TO api_global_counts;

ALTER INDEX api_global_counts_id_replacement_idx RENAME TO api_global_counts_id_idx;
