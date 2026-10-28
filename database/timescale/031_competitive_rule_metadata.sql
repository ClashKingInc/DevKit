-- +goose Up
ALTER TABLE competitive_tournaments
    ADD COLUMN rules_metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
    ADD CONSTRAINT competitive_rules_metadata_object CHECK (jsonb_typeof(rules_metadata)='object'),
    ADD CONSTRAINT competitive_rules_metadata_keys CHECK (rules_metadata - ARRAY['prizeDescription','rulebookUrl','visibility'] = '{}'::jsonb),
    ADD CONSTRAINT competitive_rules_visibility CHECK (COALESCE(rules_metadata->>'visibility','public') IN ('public','unlisted')),
    ADD CONSTRAINT competitive_rules_prize CHECK (NOT rules_metadata ? 'prizeDescription' OR (jsonb_typeof(rules_metadata->'prizeDescription')='string' AND length(rules_metadata->>'prizeDescription') <= 1000)),
    ADD CONSTRAINT competitive_rules_rulebook CHECK (NOT rules_metadata ? 'rulebookUrl' OR (jsonb_typeof(rules_metadata->'rulebookUrl')='string' AND rules_metadata->>'rulebookUrl' LIKE 'https://%' AND length(rules_metadata->>'rulebookUrl') <= 2048));
COMMENT ON COLUMN competitive_tournaments.rules_metadata IS 'Informational prizes and HTTPS rulebook links; unlisted events remain accessible by direct link but are excluded from public discovery. No entry fees or payments.';
-- +goose Down
-- +goose StatementBegin
DO $$ BEGIN RAISE EXCEPTION 'Tournament rules and visibility require a data-preserving forward migration'; END $$;
-- +goose StatementEnd
