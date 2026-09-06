-- +goose Up
ALTER TABLE public.basic_clan
    ADD COLUMN capital_gold_total bigint DEFAULT 0 NOT NULL;

DROP MATERIALIZED VIEW public.clan_leaderboards;

CREATE MATERIALIZED VIEW public.clan_leaderboards AS
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

CREATE UNIQUE INDEX idx_clan_leaderboards_tag ON public.clan_leaderboards USING btree (tag);
CREATE INDEX idx_clan_leaderboards_donated_rank ON public.clan_leaderboards USING btree (donated_rank);
CREATE INDEX idx_clan_leaderboards_received_rank ON public.clan_leaderboards USING btree (received_rank);
CREATE INDEX idx_clan_leaderboards_war_wins_rank ON public.clan_leaderboards USING btree (war_wins_rank);
CREATE INDEX idx_clan_leaderboards_capital_gold_rank ON public.clan_leaderboards USING btree (capital_gold_rank);
CREATE INDEX idx_clan_leaderboards_war_win_streak_rank ON public.clan_leaderboards USING btree (war_win_streak_rank) WHERE (war_win_streak_rank IS NOT NULL);
CREATE INDEX idx_clan_leaderboards_location_donated_rank ON public.clan_leaderboards USING btree (location_id, location_donated_rank);
CREATE INDEX idx_clan_leaderboards_location_received_rank ON public.clan_leaderboards USING btree (location_id, location_received_rank);
CREATE INDEX idx_clan_leaderboards_location_war_wins_rank ON public.clan_leaderboards USING btree (location_id, location_war_wins_rank);
CREATE INDEX idx_clan_leaderboards_location_capital_gold_rank ON public.clan_leaderboards USING btree (location_id, location_capital_gold_rank);

REFRESH MATERIALIZED VIEW public.clan_leaderboards;

-- +goose Down
DROP MATERIALIZED VIEW public.clan_leaderboards;

ALTER TABLE public.basic_clan
    DROP COLUMN capital_gold_total;

CREATE MATERIALIZED VIEW public.clan_leaderboards AS
 SELECT tag,
    location_id,
    rank() OVER (ORDER BY troops_donated DESC, tag) AS donated_rank,
    rank() OVER (ORDER BY troops_received DESC, tag) AS received_rank,
    rank() OVER (ORDER BY war_wins DESC, tag) AS war_wins_rank,
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
    rank() OVER (PARTITION BY location_id ORDER BY war_wins DESC, tag) AS location_war_wins_rank
   FROM public.basic_clan c
  WITH NO DATA;

CREATE UNIQUE INDEX idx_clan_leaderboards_tag ON public.clan_leaderboards USING btree (tag);
CREATE INDEX idx_clan_leaderboards_donated_rank ON public.clan_leaderboards USING btree (donated_rank);
CREATE INDEX idx_clan_leaderboards_received_rank ON public.clan_leaderboards USING btree (received_rank);
CREATE INDEX idx_clan_leaderboards_war_wins_rank ON public.clan_leaderboards USING btree (war_wins_rank);
CREATE INDEX idx_clan_leaderboards_war_win_streak_rank ON public.clan_leaderboards USING btree (war_win_streak_rank) WHERE (war_win_streak_rank IS NOT NULL);
CREATE INDEX idx_clan_leaderboards_location_donated_rank ON public.clan_leaderboards USING btree (location_id, location_donated_rank);
CREATE INDEX idx_clan_leaderboards_location_received_rank ON public.clan_leaderboards USING btree (location_id, location_received_rank);
CREATE INDEX idx_clan_leaderboards_location_war_wins_rank ON public.clan_leaderboards USING btree (location_id, location_war_wins_rank);

REFRESH MATERIALIZED VIEW public.clan_leaderboards;
