-- +goose Up
-- Legacy imports used JSON null for absent collections. The API consumes arrays;
-- canonicalize only absence, preserving every existing entrant and winner.
UPDATE public.giveaways SET entries = '[]'::jsonb WHERE entries = 'null'::jsonb;
UPDATE public.giveaways SET winners_list = '[]'::jsonb WHERE winners_list = 'null'::jsonb;
ALTER TABLE public.giveaways
    ADD CONSTRAINT giveaways_entries_array_check CHECK (jsonb_typeof(entries) = 'array'),
    ADD CONSTRAINT giveaways_winners_array_check CHECK (jsonb_typeof(winners_list) = 'array');

-- +goose Down
-- Empty arrays remain valid for the previous API. Do not invent which empty
-- collections were originally JSON null or discard entrants added since upgrade.
ALTER TABLE public.giveaways
    DROP CONSTRAINT giveaways_entries_array_check,
    DROP CONSTRAINT giveaways_winners_array_check;
