-- +goose Up
-- One ended regular war can continue a streak with zero, one, or two
-- same-Town-Hall triples. Different-Town-Hall hits are neutral, not resets.
ALTER TABLE public.war_triple_streak_results
    ADD COLUMN credited_triples smallint NOT NULL DEFAULT 2
    CHECK (credited_triples BETWEEN 0 AND 2);
COMMENT ON COLUMN public.war_triple_streak_results.qualified IS
    'True when the regular war continues the streak; false for a missed hit or failed same-TH attack.';
COMMENT ON COLUMN public.war_triple_streak_results.credited_triples IS
    'Number of same-TH triples in this war. Ignored when qualified is false. Defaults to 2 for legacy all-or-nothing outcomes.';
ALTER TABLE public.war_triple_streaks
    DROP CONSTRAINT war_triple_streaks_streak_check;
ALTER TABLE public.war_triple_streaks
    ADD CONSTRAINT war_triple_streaks_streak_check CHECK (streak >= 0);

-- +goose Down
-- Refuse to silently truncate a valid odd streak during rollback.
ALTER TABLE public.war_triple_streaks
    DROP CONSTRAINT war_triple_streaks_streak_check;
ALTER TABLE public.war_triple_streaks
    ADD CONSTRAINT war_triple_streaks_streak_check CHECK (streak >= 0 AND streak % 2 = 0);
ALTER TABLE public.war_triple_streak_results
    DROP COLUMN credited_triples;
COMMENT ON COLUMN public.war_triple_streak_results.qualified IS NULL;
