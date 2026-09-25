-- +goose Up
-- Tracking omits the zero sentinel when no siege was selected. A retained
-- selected-siege bucket must therefore have a positive canonical ID.
-- +goose StatementBegin
CREATE FUNCTION public.legend_selected_siege_ids_valid(value jsonb)
RETURNS boolean LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE AS $$
DECLARE
    entry jsonb;
BEGIN
    IF NOT public.item_usage_triples_valid(value) THEN RETURN false; END IF;
    FOR entry IN SELECT element FROM jsonb_array_elements(value) item(element) LOOP
        IF (entry->>'id')::integer = 0 THEN RETURN false; END IF;
    END LOOP;
    RETURN true;
END
$$;
-- +goose StatementEnd

ALTER TABLE public.legend_daily_stats
    DROP CONSTRAINT legend_daily_stats_siege_check,
    ADD CONSTRAINT legend_daily_stats_siege_check CHECK (
        public.legend_selected_siege_ids_valid(siege_stats)
        AND public.legend_siege_usage_within_attack_count(siege_stats,attack_count)
        AND public.legend_exclusive_triples_within_star_count(siege_stats,three_star_count,false));

-- +goose Down
-- Loosening selected-siege identity validation could retain invalid history.
-- +goose StatementBegin
DO $$ BEGIN RAISE EXCEPTION 'migration 043 is irreversible: selected-siege IDs must remain positive'; END $$;
-- +goose StatementEnd
