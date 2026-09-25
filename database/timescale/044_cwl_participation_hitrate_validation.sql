-- +goose Up
-- Manually rebuilt same-TH observations use a canonical descending set of
-- integer town-hall buckets, never an arbitrary JSON array.
-- +goose StatementBegin
CREATE FUNCTION public.cwl_participation_hitrates_valid(value jsonb)
RETURNS boolean LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE AS $$
DECLARE
    entry jsonb;
    previous_level integer := 21;
    level_value integer;
    attempts bigint;
    triples bigint;
BEGIN
    IF jsonb_typeof(value) <> 'array' THEN RETURN false; END IF;
    FOR entry IN SELECT element FROM jsonb_array_elements(value) WITH ORDINALITY AS item(element, position) ORDER BY position LOOP
        IF jsonb_typeof(entry) <> 'object'
           OR (SELECT count(*) FROM jsonb_object_keys(entry)) <> 3
           OR NOT (entry ? 'level' AND entry ? 'attacks' AND entry ? 'three_stars')
           OR jsonb_typeof(entry->'level') <> 'number'
           OR jsonb_typeof(entry->'attacks') <> 'number'
           OR jsonb_typeof(entry->'three_stars') <> 'number'
           OR entry->>'level' !~ '^[0-9]+$'
           OR entry->>'attacks' !~ '^[0-9]+$'
           OR entry->>'three_stars' !~ '^[0-9]+$'
           OR (entry->>'attacks')::numeric > 9223372036854775807
           OR (entry->>'three_stars')::numeric > 9223372036854775807 THEN RETURN false; END IF;
        level_value := (entry->>'level')::integer;
        attempts := (entry->>'attacks')::bigint;
        triples := (entry->>'three_stars')::bigint;
        IF level_value NOT BETWEEN 1 AND 20 OR level_value >= previous_level
           OR triples > attempts THEN RETURN false; END IF;
        previous_level := level_value;
    END LOOP;
    RETURN true;
EXCEPTION WHEN numeric_value_out_of_range THEN RETURN false;
END
$$;
-- +goose StatementEnd

ALTER TABLE public.cwl_participation
    DROP CONSTRAINT cwl_participation_hitrates_check,
    ADD CONSTRAINT cwl_participation_hitrates_check CHECK (
        same_th_hitrates IS NULL OR public.cwl_participation_hitrates_valid(same_th_hitrates));

-- +goose Down
-- Loosening retained CWL summary validation could admit malformed history.
-- +goose StatementBegin
DO $$ BEGIN RAISE EXCEPTION 'migration 044 is irreversible: CWL hit-rate validation must be retained'; END $$;
-- +goose StatementEnd
