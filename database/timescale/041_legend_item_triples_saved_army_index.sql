-- +goose Up
-- Troops and spells can coexist in one attack, so each item's triple count
-- is bounded separately by the day's three-star count. Do not sum items.
-- +goose StatementBegin
CREATE FUNCTION public.legend_item_triples_within_star_count(value jsonb, triple_limit bigint)
RETURNS boolean LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE AS $$
DECLARE
    entry jsonb;
BEGIN
    IF triple_limit < 0 OR NOT public.item_usage_triples_valid(value) THEN RETURN false; END IF;
    FOR entry IN SELECT element FROM jsonb_array_elements(value) item(element) LOOP
        IF (entry->>'triples')::bigint > triple_limit THEN RETURN false; END IF;
    END LOOP;
    RETURN true;
EXCEPTION WHEN numeric_value_out_of_range THEN RETURN false;
END
$$;
-- +goose StatementEnd

ALTER TABLE public.legend_daily_stats
    DROP CONSTRAINT legend_daily_stats_troops_check,
    ADD CONSTRAINT legend_daily_stats_troops_check CHECK (
        public.item_usage_triples_within_attack_count(troop_stats,attack_count)
        AND public.legend_item_triples_within_star_count(troop_stats,three_star_count)),
    DROP CONSTRAINT legend_daily_stats_spells_check,
    ADD CONSTRAINT legend_daily_stats_spells_check CHECK (
        public.item_usage_triples_within_attack_count(spell_stats,attack_count)
        AND public.legend_item_triples_within_star_count(spell_stats,three_star_count));

-- The PK and recent-list index start with user_id; this reverse index makes
-- army_compositions(share_code) cascade checks indexable.
CREATE INDEX idx_user_saved_armies_share_code
    ON public.user_saved_armies (share_code,user_id);

-- +goose Down
-- Loosening the bound could admit impossible retained aggregate history.
-- +goose StatementBegin
DO $$ BEGIN RAISE EXCEPTION 'migration 041 is irreversible: Legend item triple bounds must be retained'; END $$;
-- +goose StatementEnd
