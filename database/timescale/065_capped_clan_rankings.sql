-- +goose Up
-- Each metric keeps its existing deterministic score/tag order. A clan remains
-- if any global top-100,000 or country top-1,000 ranking qualifies; unrelated
-- ranks are null so readers cannot expose an out-of-range placement.
SET LOCAL lock_timeout = '5s';
-- Build and populate beside the serving view. Only the final name swap needs
-- its exclusive lock; raw clan writes remain online during the calculation.
CREATE MATERIALIZED VIEW public.clan_leaderboards_replacement AS
WITH ranked AS (
SELECT tag,
    location_id,
    rank() OVER (ORDER BY troops_donated DESC, tag) AS donated_rank,
    rank() OVER (ORDER BY troops_received DESC, tag) AS received_rank,
    rank() OVER (ORDER BY war_wins DESC, tag) AS war_wins_rank,
    rank() OVER (ORDER BY capital_gold_total DESC, tag) AS capital_gold_rank,
        CASE
            WHEN (war_wins >= 50 AND war_win_streak > 0) THEN rank() OVER (ORDER BY
            CASE
                WHEN (war_wins >= 50 AND war_win_streak > 0) THEN war_win_streak
                ELSE NULL::integer
            END DESC NULLS LAST, tag)
            ELSE NULL::bigint
        END AS war_win_streak_rank,
    rank() OVER (PARTITION BY location_id ORDER BY troops_donated DESC, tag) AS location_donated_rank,
    rank() OVER (PARTITION BY location_id ORDER BY troops_received DESC, tag) AS location_received_rank,
    rank() OVER (PARTITION BY location_id ORDER BY war_wins DESC, tag) AS location_war_wins_rank,
    rank() OVER (PARTITION BY location_id ORDER BY capital_gold_total DESC, tag) AS location_capital_gold_rank
   FROM public.basic_clan c
)
SELECT tag,
       location_id,
       CASE WHEN donated_rank <= 100000 THEN donated_rank END AS donated_rank,
       CASE WHEN received_rank <= 100000 THEN received_rank END AS received_rank,
       CASE WHEN war_wins_rank <= 100000 THEN war_wins_rank END AS war_wins_rank,
       CASE WHEN capital_gold_rank <= 100000 THEN capital_gold_rank END AS capital_gold_rank,
       CASE WHEN war_win_streak_rank <= 100000 THEN war_win_streak_rank END AS war_win_streak_rank,
       CASE WHEN location_donated_rank <= 1000 THEN location_donated_rank END AS location_donated_rank,
       CASE WHEN location_received_rank <= 1000 THEN location_received_rank END AS location_received_rank,
       CASE WHEN location_war_wins_rank <= 1000 THEN location_war_wins_rank END AS location_war_wins_rank,
       CASE WHEN location_capital_gold_rank <= 1000 THEN location_capital_gold_rank END AS location_capital_gold_rank
FROM ranked
WHERE donated_rank <= 100000
   OR received_rank <= 100000
   OR war_wins_rank <= 100000
   OR capital_gold_rank <= 100000
   OR war_win_streak_rank <= 100000
   OR location_donated_rank <= 1000
   OR location_received_rank <= 1000
   OR location_war_wins_rank <= 1000
   OR location_capital_gold_rank <= 1000
WITH NO DATA;

CREATE UNIQUE INDEX idx_clan_leaderboards_replacement_tag ON public.clan_leaderboards_replacement USING btree (tag);
CREATE INDEX idx_clan_leaderboards_replacement_donated_rank ON public.clan_leaderboards_replacement USING btree (donated_rank) WHERE (donated_rank IS NOT NULL);
CREATE INDEX idx_clan_leaderboards_replacement_received_rank ON public.clan_leaderboards_replacement USING btree (received_rank) WHERE (received_rank IS NOT NULL);
CREATE INDEX idx_clan_leaderboards_replacement_war_wins_rank ON public.clan_leaderboards_replacement USING btree (war_wins_rank) WHERE (war_wins_rank IS NOT NULL);
CREATE INDEX idx_clan_leaderboards_replacement_capital_gold_rank ON public.clan_leaderboards_replacement USING btree (capital_gold_rank) WHERE (capital_gold_rank IS NOT NULL);
CREATE INDEX idx_clan_leaderboards_replacement_war_win_streak_rank ON public.clan_leaderboards_replacement USING btree (war_win_streak_rank) WHERE (war_win_streak_rank IS NOT NULL);
CREATE INDEX idx_clan_leaderboards_replacement_location_donated_rank ON public.clan_leaderboards_replacement USING btree (location_id, location_donated_rank) WHERE (location_donated_rank IS NOT NULL);
CREATE INDEX idx_clan_leaderboards_replacement_location_received_rank ON public.clan_leaderboards_replacement USING btree (location_id, location_received_rank) WHERE (location_received_rank IS NOT NULL);
CREATE INDEX idx_clan_leaderboards_replacement_location_war_wins_rank ON public.clan_leaderboards_replacement USING btree (location_id, location_war_wins_rank) WHERE (location_war_wins_rank IS NOT NULL);
CREATE INDEX idx_clan_leaderboards_replacement_location_capital_gold_rank ON public.clan_leaderboards_replacement USING btree (location_id, location_capital_gold_rank) WHERE (location_capital_gold_rank IS NOT NULL);

REFRESH MATERIALIZED VIEW public.clan_leaderboards_replacement;
DROP MATERIALIZED VIEW public.clan_leaderboards;
ALTER MATERIALIZED VIEW public.clan_leaderboards_replacement RENAME TO clan_leaderboards;
ALTER INDEX public.idx_clan_leaderboards_replacement_tag RENAME TO idx_clan_leaderboards_tag;
ALTER INDEX public.idx_clan_leaderboards_replacement_donated_rank RENAME TO idx_clan_leaderboards_donated_rank;
ALTER INDEX public.idx_clan_leaderboards_replacement_received_rank RENAME TO idx_clan_leaderboards_received_rank;
ALTER INDEX public.idx_clan_leaderboards_replacement_war_wins_rank RENAME TO idx_clan_leaderboards_war_wins_rank;
ALTER INDEX public.idx_clan_leaderboards_replacement_capital_gold_rank RENAME TO idx_clan_leaderboards_capital_gold_rank;
ALTER INDEX public.idx_clan_leaderboards_replacement_war_win_streak_rank RENAME TO idx_clan_leaderboards_war_win_streak_rank;
ALTER INDEX public.idx_clan_leaderboards_replacement_location_donated_rank RENAME TO idx_clan_leaderboards_location_donated_rank;
ALTER INDEX public.idx_clan_leaderboards_replacement_location_received_rank RENAME TO idx_clan_leaderboards_location_received_rank;
ALTER INDEX public.idx_clan_leaderboards_replacement_location_war_wins_rank RENAME TO idx_clan_leaderboards_location_war_wins_rank;
ALTER INDEX public.idx_clan_leaderboards_replacement_location_capital_gold_rank RENAME TO idx_clan_leaderboards_location_capital_gold_rank;


-- +goose Down
-- Recompute the original unrestricted derived view from current retained clans.
SET LOCAL lock_timeout = '5s';
-- Build and populate beside the serving view. Only the final name swap needs
-- its exclusive lock; raw clan writes remain online during the calculation.
CREATE MATERIALIZED VIEW public.clan_leaderboards_replacement AS
SELECT tag,
    location_id,
    rank() OVER (ORDER BY troops_donated DESC, tag) AS donated_rank,
    rank() OVER (ORDER BY troops_received DESC, tag) AS received_rank,
    rank() OVER (ORDER BY war_wins DESC, tag) AS war_wins_rank,
    rank() OVER (ORDER BY capital_gold_total DESC, tag) AS capital_gold_rank,
        CASE
            WHEN (war_wins >= 50) THEN rank() OVER (ORDER BY
            CASE
                WHEN (war_wins >= 50) THEN war_win_streak
                ELSE NULL::integer
            END DESC NULLS LAST, tag)
            ELSE NULL::bigint
        END AS war_win_streak_rank,
    rank() OVER (PARTITION BY location_id ORDER BY troops_donated DESC, tag) AS location_donated_rank,
    rank() OVER (PARTITION BY location_id ORDER BY troops_received DESC, tag) AS location_received_rank,
    rank() OVER (PARTITION BY location_id ORDER BY war_wins DESC, tag) AS location_war_wins_rank,
    rank() OVER (PARTITION BY location_id ORDER BY capital_gold_total DESC, tag) AS location_capital_gold_rank
   FROM public.basic_clan c
WITH NO DATA;

CREATE UNIQUE INDEX idx_clan_leaderboards_replacement_tag ON public.clan_leaderboards_replacement USING btree (tag);
CREATE INDEX idx_clan_leaderboards_replacement_donated_rank ON public.clan_leaderboards_replacement USING btree (donated_rank);
CREATE INDEX idx_clan_leaderboards_replacement_received_rank ON public.clan_leaderboards_replacement USING btree (received_rank);
CREATE INDEX idx_clan_leaderboards_replacement_war_wins_rank ON public.clan_leaderboards_replacement USING btree (war_wins_rank);
CREATE INDEX idx_clan_leaderboards_replacement_capital_gold_rank ON public.clan_leaderboards_replacement USING btree (capital_gold_rank);
CREATE INDEX idx_clan_leaderboards_replacement_war_win_streak_rank ON public.clan_leaderboards_replacement USING btree (war_win_streak_rank) WHERE (war_win_streak_rank IS NOT NULL);
CREATE INDEX idx_clan_leaderboards_replacement_location_donated_rank ON public.clan_leaderboards_replacement USING btree (location_id, location_donated_rank);
CREATE INDEX idx_clan_leaderboards_replacement_location_received_rank ON public.clan_leaderboards_replacement USING btree (location_id, location_received_rank);
CREATE INDEX idx_clan_leaderboards_replacement_location_war_wins_rank ON public.clan_leaderboards_replacement USING btree (location_id, location_war_wins_rank);
CREATE INDEX idx_clan_leaderboards_replacement_location_capital_gold_rank ON public.clan_leaderboards_replacement USING btree (location_id, location_capital_gold_rank);

REFRESH MATERIALIZED VIEW public.clan_leaderboards_replacement;
DROP MATERIALIZED VIEW public.clan_leaderboards;
ALTER MATERIALIZED VIEW public.clan_leaderboards_replacement RENAME TO clan_leaderboards;
ALTER INDEX public.idx_clan_leaderboards_replacement_tag RENAME TO idx_clan_leaderboards_tag;
ALTER INDEX public.idx_clan_leaderboards_replacement_donated_rank RENAME TO idx_clan_leaderboards_donated_rank;
ALTER INDEX public.idx_clan_leaderboards_replacement_received_rank RENAME TO idx_clan_leaderboards_received_rank;
ALTER INDEX public.idx_clan_leaderboards_replacement_war_wins_rank RENAME TO idx_clan_leaderboards_war_wins_rank;
ALTER INDEX public.idx_clan_leaderboards_replacement_capital_gold_rank RENAME TO idx_clan_leaderboards_capital_gold_rank;
ALTER INDEX public.idx_clan_leaderboards_replacement_war_win_streak_rank RENAME TO idx_clan_leaderboards_war_win_streak_rank;
ALTER INDEX public.idx_clan_leaderboards_replacement_location_donated_rank RENAME TO idx_clan_leaderboards_location_donated_rank;
ALTER INDEX public.idx_clan_leaderboards_replacement_location_received_rank RENAME TO idx_clan_leaderboards_location_received_rank;
ALTER INDEX public.idx_clan_leaderboards_replacement_location_war_wins_rank RENAME TO idx_clan_leaderboards_location_war_wins_rank;
ALTER INDEX public.idx_clan_leaderboards_replacement_location_capital_gold_rank RENAME TO idx_clan_leaderboards_location_capital_gold_rank;
