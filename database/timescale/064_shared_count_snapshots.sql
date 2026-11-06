-- +goose Up
-- Additive preparation only. Existing public snapshots remain the read path until
-- bounded history refreshes and the new coordinator have completed validation.
CREATE MATERIALIZED VIEW stats_join_leave_daily_counts
WITH (timescaledb.continuous, timescaledb.materialized_only = false) AS
SELECT time_bucket(INTERVAL '1 day', time) AS day_start,
       count(*) AS row_count
FROM join_leave_history
GROUP BY day_start
WITH NO DATA;

CREATE MATERIALIZED VIEW stats_war_daily_counts
WITH (timescaledb.continuous, timescaledb.materialized_only = false) AS
SELECT time_bucket(INTERVAL '1 day', end_time) AS day_start,
       count(*) AS row_count
FROM wars
GROUP BY day_start
WITH NO DATA;

-- GROUPING identifies the grand total independently of a nullable source key.
-- The total uses a null dimension; unranked CWL ID zero remains its own bucket.
CREATE MATERIALIZED VIEW stats_player_count_snapshot AS
SELECT CASE
           WHEN GROUPING(townhall_level) = 0 THEN 'townhall'
           WHEN GROUPING(COALESCE(league_id, 0)) = 0 THEN 'league'
           ELSE 'total'
       END::text AS scope,
       CASE
           WHEN GROUPING(townhall_level) = 0 THEN townhall_level::integer
           WHEN GROUPING(COALESCE(league_id, 0)) = 0 THEN COALESCE(league_id, 0)
           ELSE NULL::integer
       END AS dimension_id,
       count(*) AS row_count,
       transaction_timestamp() AS refreshed_at
FROM basic_player
GROUP BY GROUPING SETS ((), (townhall_level), (COALESCE(league_id, 0)))
WITH NO DATA;

CREATE UNIQUE INDEX stats_player_count_snapshot_key
ON stats_player_count_snapshot (scope, dimension_id) NULLS NOT DISTINCT;

CREATE MATERIALIZED VIEW stats_clan_count_snapshot AS
SELECT CASE WHEN GROUPING(cwl_league_id) = 0 THEN 'cwl' ELSE 'total' END::text AS scope,
       CASE WHEN GROUPING(cwl_league_id) = 0 THEN cwl_league_id ELSE NULL::integer END AS dimension_id,
       count(*) AS row_count,
       transaction_timestamp() AS refreshed_at
FROM basic_clan
GROUP BY GROUPING SETS ((), (cwl_league_id))
WITH NO DATA;

CREATE UNIQUE INDEX stats_clan_count_snapshot_key
ON stats_clan_count_snapshot (scope, dimension_id) NULLS NOT DISTINCT;

-- +goose Down
DROP MATERIALIZED VIEW stats_clan_count_snapshot;
DROP MATERIALIZED VIEW stats_player_count_snapshot;
DROP MATERIALIZED VIEW stats_war_daily_counts;
DROP MATERIALIZED VIEW stats_join_leave_daily_counts;
