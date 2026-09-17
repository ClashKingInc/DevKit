-- +goose Up
-- Populate from Tracking after migration, before deploying the API reader.
CREATE MATERIALIZED VIEW public.player_townhall_leaderboards AS
SELECT p.*, row_number() OVER (PARTITION BY townhall_level ORDER BY league_id DESC,trophies DESC,tag)::integer AS rank
FROM generate_series(7,18) th(level)
CROSS JOIN LATERAL (
  SELECT tag,name,townhall_level,trophies,league_id,league_group_tag,clan_tag
  FROM public.basic_player WHERE townhall_level=th.level AND townhall_level>=7
    AND league_id BETWEEN 105000001 AND 105000036
    AND league_id IS NOT NULL AND league_id<>105000000
  ORDER BY league_id DESC,trophies DESC,tag LIMIT 500
) p WITH NO DATA;
CREATE UNIQUE INDEX player_townhall_leaderboards_identity ON public.player_townhall_leaderboards(townhall_level,rank);

CREATE MATERIALIZED VIEW public.player_league_leaderboards AS
SELECT p.*, row_number() OVER (PARTITION BY league_id ORDER BY trophies DESC,tag)::integer AS rank
FROM generate_series(105000001,105000036) tiers(id)
CROSS JOIN LATERAL (
  SELECT tag,name,townhall_level,trophies,league_id,league_group_tag,clan_tag
  FROM public.basic_player WHERE league_id=tiers.id AND league_id IS NOT NULL AND league_id<>105000000
  ORDER BY trophies DESC,tag LIMIT 500
) p WITH NO DATA;
CREATE UNIQUE INDEX player_league_leaderboards_identity ON public.player_league_leaderboards(league_id,rank);

-- Small durable control records, not player history. Completion and batch progress
-- are committed with the work they describe; reset periods are Monday UTC dates.
CREATE TABLE public.tracking_scheduled_jobs (
  job text NOT NULL,
  period date NOT NULL,
  last_tag text NOT NULL DEFAULT '',
  completed_at timestamptz,
  PRIMARY KEY(job,period)
);

-- +goose Down
DROP TABLE public.tracking_scheduled_jobs;
DROP MATERIALIZED VIEW public.player_league_leaderboards;
DROP MATERIALIZED VIEW public.player_townhall_leaderboards;
