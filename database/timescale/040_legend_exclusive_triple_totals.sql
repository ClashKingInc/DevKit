-- +goose Up
-- Whole pet sets and selected siege are exclusive per attack. Equipment-pair
-- choices are exclusive for each hero, so their triples cannot exceed the
-- row's three-star count in the corresponding exclusive group.
-- +goose StatementBegin
CREATE FUNCTION public.legend_exclusive_triples_within_star_count(value jsonb, triple_limit bigint, per_hero boolean)
RETURNS boolean LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE AS $$
DECLARE
    entry jsonb;
    hero_id integer;
    previous_hero integer := -1;
    triples_value bigint;
    total_triples bigint := 0;
BEGIN
    IF triple_limit < 0 OR jsonb_typeof(value) <> 'array' THEN RETURN false; END IF;
    FOR entry IN SELECT element FROM jsonb_array_elements(value) WITH ORDINALITY AS item(element, position) ORDER BY position LOOP
        IF jsonb_typeof(entry) <> 'object' OR NOT entry ? 'triples'
           OR jsonb_typeof(entry->'triples') <> 'number' OR entry->>'triples' !~ '^[0-9]+$'
           OR (entry->>'triples')::numeric > 9223372036854775807 THEN RETURN false; END IF;
        IF per_hero THEN
            IF NOT entry ? 'heroId' OR jsonb_typeof(entry->'heroId') <> 'number'
               OR entry->>'heroId' !~ '^[0-9]+$'
               OR (entry->>'heroId')::numeric > 2147483647 THEN RETURN false; END IF;
            hero_id := (entry->>'heroId')::integer;
            IF hero_id <> previous_hero THEN total_triples := 0; END IF;
            previous_hero := hero_id;
        END IF;
        triples_value := (entry->>'triples')::bigint;
        IF triples_value > triple_limit - total_triples THEN RETURN false; END IF;
        total_triples := total_triples + triples_value;
    END LOOP;
    RETURN true;
EXCEPTION WHEN numeric_value_out_of_range THEN RETURN false;
END
$$;
-- +goose StatementEnd

ALTER TABLE public.legend_daily_stats
    DROP CONSTRAINT legend_daily_stats_pet_combos_check,
    ADD CONSTRAINT legend_daily_stats_pet_combos_check CHECK (
        public.pet_combo_usage_triples_within_attack_count(pet_combo_stats,attack_count)
        AND public.legend_exclusive_triples_within_star_count(pet_combo_stats,three_star_count,false)),
    DROP CONSTRAINT legend_daily_stats_siege_check,
    ADD CONSTRAINT legend_daily_stats_siege_check CHECK (
        public.legend_siege_usage_within_attack_count(siege_stats,attack_count)
        AND public.legend_exclusive_triples_within_star_count(siege_stats,three_star_count,false)),
    DROP CONSTRAINT legend_daily_stats_equipment_pairs_check,
    ADD CONSTRAINT legend_daily_stats_equipment_pairs_check CHECK (
        public.equipment_pair_usage_triples_within_attack_count(equipment_pair_stats,attack_count)
        AND public.legend_exclusive_triples_within_star_count(equipment_pair_stats,three_star_count,true));

-- +goose Down
-- The stronger star totals cannot be rolled back without admitting impossible history.
-- +goose StatementBegin
DO $$ BEGIN RAISE EXCEPTION 'migration 040 is irreversible: exclusive triple checks must be retained'; END $$;
-- +goose StatementEnd
