-- +goose Up
-- Restore the canonical descending, typed TH distribution validation from
-- the retired CWL aggregate for the retained participation summary.
-- +goose StatementBegin
CREATE FUNCTION public.cwl_participation_town_halls_valid(value jsonb)
RETURNS boolean LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE AS $$
DECLARE
    entry jsonb;
    previous_level integer := 21;
    level_value integer;
BEGIN
    IF jsonb_typeof(value) <> 'array' THEN RETURN false; END IF;
    FOR entry IN SELECT element FROM jsonb_array_elements(value) WITH ORDINALITY AS item(element, position) ORDER BY position LOOP
        IF jsonb_typeof(entry) <> 'object'
           OR (SELECT count(*) FROM jsonb_object_keys(entry)) <> 2
           OR NOT (entry ? 'level' AND entry ? 'count')
           OR jsonb_typeof(entry->'level') <> 'number'
           OR jsonb_typeof(entry->'count') <> 'number'
           OR entry->>'level' !~ '^[0-9]+$'
           OR entry->>'count' !~ '^[0-9]+$' THEN RETURN false; END IF;
        level_value := (entry->>'level')::integer;
        IF level_value NOT BETWEEN 1 AND 20
           OR (entry->>'count')::numeric > 9223372036854775807
           OR level_value >= previous_level THEN RETURN false; END IF;
        previous_level := level_value;
    END LOOP;
    RETURN true;
EXCEPTION WHEN numeric_value_out_of_range THEN RETURN false;
END
$$;
-- +goose StatementEnd

ALTER TABLE public.cwl_participation
    DROP CONSTRAINT cwl_participation_townhall_check,
    ADD CONSTRAINT cwl_participation_townhall_check
        CHECK (public.cwl_participation_town_halls_valid(townhall_counts));

-- +goose Down
-- Loosening validation could retain malformed analytics history.
-- +goose StatementBegin
DO $$ BEGIN RAISE EXCEPTION 'migration 042 is irreversible: CWL town-hall validation must be retained'; END $$;
-- +goose StatementEnd
