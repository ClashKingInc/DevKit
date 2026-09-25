-- +goose Up
-- Preserve applied 031 and 036 byte-for-byte; tighten their checks forward.
-- +goose StatementBegin
CREATE OR REPLACE FUNCTION public.pet_combo_usage_triples_within_attack_count(value jsonb, attack_limit bigint)
RETURNS boolean LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE AS $$
DECLARE
    entry jsonb;
    pet_id jsonb;
    previous_pet integer;
    current_combo integer[];
    previous_combo integer[];
    uses_value bigint;
    triples_value bigint;
    total_uses bigint := 0;
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
        current_combo := '{}'::integer[];
        FOR pet_id IN SELECT element FROM jsonb_array_elements(entry->'petIds') WITH ORDINALITY AS item(element, position) ORDER BY position LOOP
            IF jsonb_typeof(pet_id) <> 'number' OR pet_id #>> '{}' !~ '^[0-9]+$'
               OR (pet_id #>> '{}')::numeric > 2147483647
               OR (pet_id #>> '{}')::integer <= previous_pet THEN RETURN false; END IF;
            previous_pet := (pet_id #>> '{}')::integer;
            current_combo := array_append(current_combo, previous_pet);
        END LOOP;
        uses_value := (entry->>'uses')::bigint;
        triples_value := (entry->>'triples')::bigint;
        IF (previous_combo IS NOT NULL AND current_combo <= previous_combo)
           OR triples_value > uses_value OR uses_value > attack_limit - total_uses THEN RETURN false; END IF;
        previous_combo := current_combo;
        total_uses := total_uses + uses_value;
    END LOOP;
    RETURN true;
EXCEPTION WHEN numeric_value_out_of_range THEN RETURN false;
END
$$;
-- +goose StatementEnd

ALTER TABLE public.legend_daily_stats
    DROP CONSTRAINT legend_daily_stats_pet_combos_check,
    ADD CONSTRAINT legend_daily_stats_pet_combos_check
        CHECK (public.pet_combo_usage_triples_within_attack_count(pet_combo_stats,attack_count));

-- +goose StatementBegin
CREATE FUNCTION public.army_setup_siege_usage_within_attack_count(value jsonb, attack_limit bigint)
RETURNS boolean LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE AS $$
DECLARE
    entry jsonb;
    siege_id integer;
    previous_id integer := -1;
    attacks_value bigint;
    total_attacks bigint := 0;
BEGIN
    IF attack_limit < 0 OR jsonb_typeof(value) <> 'array' THEN RETURN false; END IF;
    FOR entry IN SELECT element FROM jsonb_array_elements(value) WITH ORDINALITY AS item(element, position) ORDER BY position LOOP
        IF jsonb_typeof(entry) <> 'object' OR (SELECT count(*) FROM jsonb_object_keys(entry)) <> 2
           OR NOT (entry ? 'id' AND entry ? 'attacks')
           OR jsonb_typeof(entry->'id') <> 'number' OR jsonb_typeof(entry->'attacks') <> 'number'
           OR entry->>'id' !~ '^[0-9]+$' OR entry->>'attacks' !~ '^[0-9]+$'
           OR (entry->>'id')::numeric > 2147483647
           OR (entry->>'attacks')::numeric > 9223372036854775807 THEN RETURN false; END IF;
        siege_id := (entry->>'id')::integer;
        attacks_value := (entry->>'attacks')::bigint;
        IF siege_id <= previous_id OR siege_id = 0 OR attacks_value > attack_limit - total_attacks THEN RETURN false; END IF;
        previous_id := siege_id;
        total_attacks := total_attacks + attacks_value;
    END LOOP;
    RETURN true;
EXCEPTION WHEN numeric_value_out_of_range THEN RETURN false;
END
$$;
-- +goose StatementEnd

ALTER TABLE public.army_setup_daily_stats
    ADD CONSTRAINT army_setup_daily_siege_usage_count_check
        CHECK (public.army_setup_siege_usage_within_attack_count(siege_usage,attack_count));

-- +goose Down
-- Reverting the stronger checks could admit impossible retained history.
-- +goose StatementBegin
DO $$ BEGIN RAISE EXCEPTION 'migration 038 is irreversible: daily analytics count constraints must be retained'; END $$;
-- +goose StatementEnd
