-- +goose Up
-- Keep top_200 for existing consumers while adding the product-facing top 100.
ALTER TABLE public.army_family_daily_stats
    DROP CONSTRAINT army_family_daily_stats_cohort_check,
    ADD CONSTRAINT army_family_daily_stats_cohort_check
        CHECK (cohort IN ('legend_i','top_1000','top_200','top_100'));

ALTER TABLE public.legend_daily_stats
    DROP CONSTRAINT legend_daily_stats_cohort_check,
    ADD CONSTRAINT legend_daily_stats_cohort_check
        CHECK (cohort IN ('legend_i','top_1000','top_200','top_100'));

-- +goose StatementBegin
CREATE FUNCTION public.equipment_pair_usage_triples_within_attack_count(value jsonb, attack_limit bigint)
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
        IF first_value >= second_value OR triples_value > uses_value OR uses_value > attack_limit
           OR hero_value < previous_hero
           OR (hero_value = previous_hero AND first_value < previous_first)
           OR (hero_value = previous_hero AND first_value = previous_first AND second_value <= previous_second)
        THEN RETURN false; END IF;
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
    ADD COLUMN troop_stats jsonb NOT NULL DEFAULT '[]'::jsonb,
    ADD COLUMN spell_stats jsonb NOT NULL DEFAULT '[]'::jsonb,
    ADD COLUMN siege_stats jsonb NOT NULL DEFAULT '[]'::jsonb,
    ADD COLUMN equipment_pair_stats jsonb NOT NULL DEFAULT '[]'::jsonb,
    ADD CONSTRAINT legend_daily_stats_troops_check
        CHECK (public.item_usage_triples_within_attack_count(troop_stats,attack_count)),
    ADD CONSTRAINT legend_daily_stats_spells_check
        CHECK (public.item_usage_triples_within_attack_count(spell_stats,attack_count)),
    ADD CONSTRAINT legend_daily_stats_siege_check
        CHECK (public.item_usage_triples_within_attack_count(siege_stats,attack_count)),
    ADD CONSTRAINT legend_daily_stats_equipment_pairs_check
        CHECK (public.equipment_pair_usage_triples_within_attack_count(equipment_pair_stats,attack_count));

COMMENT ON COLUMN public.legend_daily_stats.troop_stats IS
    'Per-attack presence counts for main-army troops; quantities do not multiply uses.';
COMMENT ON COLUMN public.legend_daily_stats.spell_stats IS
    'Per-attack presence counts for regular and Clan Castle spells combined by ID.';
COMMENT ON COLUMN public.legend_daily_stats.siege_stats IS
    'Per-attack presence counts for the canonical selected siege machine.';
COMMENT ON COLUMN public.legend_daily_stats.equipment_pair_stats IS
    'Per-attack counts for each hero and its sorted two-equipment loadout.';

-- +goose Down
-- Daily top-100 and item-combination history cannot be reconstructed after removal.
-- +goose StatementBegin
DO $$
BEGIN
    RAISE EXCEPTION 'migration 030 is irreversible: Legend daily metadata may contain retained history';
END
$$;
-- +goose StatementEnd
