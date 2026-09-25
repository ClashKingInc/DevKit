-- +goose Up
-- Siege selection and each hero's equipment pair are exclusive per attack.
-- Preserve the previously applied 030 migration and tighten its checks forward.
-- +goose StatementBegin
CREATE FUNCTION public.legend_siege_usage_within_attack_count(value jsonb, attack_limit bigint)
RETURNS boolean LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE AS $$
DECLARE
    entry jsonb;
    total_uses bigint := 0;
BEGIN
    IF attack_limit < 0 OR NOT public.item_usage_triples_valid(value) THEN RETURN false; END IF;
    FOR entry IN SELECT element FROM jsonb_array_elements(value) item(element) LOOP
        IF (entry->>'uses')::bigint > attack_limit - total_uses THEN RETURN false; END IF;
        total_uses := total_uses + (entry->>'uses')::bigint;
    END LOOP;
    RETURN true;
END
$$;
-- +goose StatementEnd

-- +goose StatementBegin
CREATE OR REPLACE FUNCTION public.equipment_pair_usage_triples_within_attack_count(value jsonb, attack_limit bigint)
RETURNS boolean LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE AS $$
DECLARE
    entry jsonb;
    previous_hero integer := -1;
    previous_first integer := -1;
    previous_second integer := -1;
    hero_value integer;
    first_value integer;
    second_value integer;
    uses_value bigint;
    triples_value bigint;
    hero_uses bigint := 0;
BEGIN
    IF attack_limit < 0 OR jsonb_typeof(value) <> 'array' THEN RETURN false; END IF;
    FOR entry IN SELECT element FROM jsonb_array_elements(value) WITH ORDINALITY AS item(element, position) ORDER BY position LOOP
        IF jsonb_typeof(entry) <> 'object' OR (SELECT count(*) FROM jsonb_object_keys(entry)) <> 4
           OR NOT (entry ? 'heroId' AND entry ? 'equipmentIds' AND entry ? 'uses' AND entry ? 'triples')
           OR jsonb_typeof(entry->'heroId') <> 'number' OR jsonb_typeof(entry->'equipmentIds') <> 'array'
           OR jsonb_array_length(entry->'equipmentIds') <> 2
           OR jsonb_typeof(entry->'equipmentIds'->0) <> 'number' OR jsonb_typeof(entry->'equipmentIds'->1) <> 'number'
           OR jsonb_typeof(entry->'uses') <> 'number' OR jsonb_typeof(entry->'triples') <> 'number'
           OR entry->>'heroId' !~ '^[0-9]+$' OR entry->'equipmentIds'->>0 !~ '^[0-9]+$'
           OR entry->'equipmentIds'->>1 !~ '^[0-9]+$' OR entry->>'uses' !~ '^[0-9]+$'
           OR entry->>'triples' !~ '^[0-9]+$'
           OR (entry->>'heroId')::numeric > 2147483647
           OR (entry->'equipmentIds'->>0)::numeric > 2147483647
           OR (entry->'equipmentIds'->>1)::numeric > 2147483647
           OR (entry->>'uses')::numeric > 9223372036854775807
           OR (entry->>'triples')::numeric > 9223372036854775807 THEN RETURN false; END IF;
        hero_value := (entry->>'heroId')::integer;
        first_value := (entry->'equipmentIds'->>0)::integer;
        second_value := (entry->'equipmentIds'->>1)::integer;
        uses_value := (entry->>'uses')::bigint;
        triples_value := (entry->>'triples')::bigint;
        IF hero_value <> previous_hero THEN hero_uses := 0; END IF;
        IF first_value >= second_value OR triples_value > uses_value
           OR uses_value > attack_limit - hero_uses
           OR hero_value < previous_hero
           OR (hero_value = previous_hero AND first_value < previous_first)
           OR (hero_value = previous_hero AND first_value = previous_first AND second_value <= previous_second)
        THEN RETURN false; END IF;
        hero_uses := hero_uses + uses_value;
        previous_hero := hero_value;
        previous_first := first_value;
        previous_second := second_value;
    END LOOP;
    RETURN true;
EXCEPTION WHEN numeric_value_out_of_range THEN RETURN false;
END
$$;
-- +goose StatementEnd

ALTER TABLE public.legend_daily_stats
    DROP CONSTRAINT legend_daily_stats_siege_check,
    ADD CONSTRAINT legend_daily_stats_siege_check
        CHECK (public.legend_siege_usage_within_attack_count(siege_stats,attack_count)),
    DROP CONSTRAINT legend_daily_stats_equipment_pairs_check,
    ADD CONSTRAINT legend_daily_stats_equipment_pairs_check
        CHECK (public.equipment_pair_usage_triples_within_attack_count(equipment_pair_stats,attack_count));

-- +goose Down
-- Loosening these checks could admit impossible retained history.
-- +goose StatementBegin
DO $$ BEGIN RAISE EXCEPTION 'migration 039 is irreversible: exclusive Legend usage constraints must be retained'; END $$;
-- +goose StatementEnd
