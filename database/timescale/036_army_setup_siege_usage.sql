-- +goose Up
-- Per-observation counts, measured from normalized CC siege on each attack.
-- Entries need not sum to attack_count because some codes have no siege.
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
    ADD COLUMN siege_usage jsonb NOT NULL DEFAULT '[]'::jsonb
        CHECK (public.army_setup_siege_usage_within_attack_count(siege_usage,attack_count));
COMMENT ON COLUMN public.army_setup_daily_stats.siege_usage IS
    'Observed normalized Clan Castle siege counts [{id,attacks}] for this day, cohort and group or variant; not inferred from the representative code.';

-- +goose Down
ALTER TABLE public.army_setup_daily_stats DROP COLUMN siege_usage;
DROP FUNCTION public.army_setup_siege_usage_within_attack_count(jsonb,bigint);
