-- +goose Up
ALTER TABLE competitive_matches
    ADD COLUMN observed_attacks jsonb CHECK (observed_attacks IS NULL OR jsonb_typeof(observed_attacks)='array');
COMMENT ON COLUMN competitive_matches.observed_attacks IS 'Replaceable per-account aggregates derived from canonical war archives and immutable registration ownership; NULL means not observed.';
-- +goose Down
-- +goose StatementBegin
DO $$ BEGIN RAISE EXCEPTION 'Observed competitive attack evidence requires a data-preserving forward migration'; END $$;
-- +goose StatementEnd
