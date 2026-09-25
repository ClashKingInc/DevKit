-- +goose Up
-- Pet combos were added after migration 030 had already been exercised locally,
-- so they remain a forward-only schema addition.
-- +goose StatementBegin
CREATE FUNCTION public.pet_combo_usage_triples_within_attack_count(value jsonb, attack_limit bigint)
RETURNS boolean LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE AS $$
DECLARE
    entry jsonb;
    pet_id jsonb;
    previous_pet integer;
    uses_value bigint;
    triples_value bigint;
BEGIN
    IF attack_limit < 0 OR jsonb_typeof(value) <> 'array' THEN RETURN false; END IF;
    FOR entry IN SELECT element FROM jsonb_array_elements(value) WITH ORDINALITY AS item(element, position) ORDER BY position LOOP
        IF jsonb_typeof(entry) <> 'object' OR (SELECT count(*) FROM jsonb_object_keys(entry)) <> 3
           OR NOT (entry ? 'petIds' AND entry ? 'uses' AND entry ? 'triples')
           OR jsonb_typeof(entry->'petIds') <> 'array' OR jsonb_array_length(entry->'petIds') = 0
           OR jsonb_typeof(entry->'uses') <> 'number' OR jsonb_typeof(entry->'triples') <> 'number'
           OR entry->>'uses' !~ '^[0-9]+$' OR entry->>'triples' !~ '^[0-9]+$'
           OR (entry->>'uses')::numeric > 9223372036854775807
           OR (entry->>'triples')::numeric > 9223372036854775807 THEN RETURN false; END IF;
        previous_pet := -1;
        FOR pet_id IN SELECT element FROM jsonb_array_elements(entry->'petIds') WITH ORDINALITY AS item(element, position) ORDER BY position LOOP
            IF jsonb_typeof(pet_id) <> 'number' OR pet_id #>> '{}' !~ '^[0-9]+$'
               OR (pet_id #>> '{}')::numeric > 2147483647
               OR (pet_id #>> '{}')::integer <= previous_pet THEN RETURN false; END IF;
            previous_pet := (pet_id #>> '{}')::integer;
        END LOOP;
        uses_value := (entry->>'uses')::bigint;
        triples_value := (entry->>'triples')::bigint;
        IF triples_value > uses_value OR uses_value > attack_limit THEN RETURN false; END IF;
    END LOOP;
    RETURN true;
EXCEPTION WHEN numeric_value_out_of_range THEN RETURN false;
END
$$;
-- +goose StatementEnd

ALTER TABLE public.legend_daily_stats
    ADD COLUMN pet_combo_stats jsonb NOT NULL DEFAULT '[]'::jsonb,
    ADD CONSTRAINT legend_daily_stats_pet_combos_check
        CHECK (public.pet_combo_usage_triples_within_attack_count(pet_combo_stats,attack_count));

COMMENT ON COLUMN public.legend_daily_stats.pet_combo_stats IS
    'Per-attack counts for each non-empty sorted unique whole set of assigned pets.';

-- +goose Down
-- Pet-combo daily history cannot be reconstructed after removal.
-- +goose StatementBegin
DO $$ BEGIN RAISE EXCEPTION 'migration 031 is irreversible: Legend pet-combo history may exist'; END $$;
-- +goose StatementEnd
