-- +goose Up
-- Keep existing autoboards. Donation logs are an optional, independent stream
-- of positive poll deltas; the original server_logs type constraint allows it.
ALTER TABLE public.server_logs
    DROP CONSTRAINT server_logs_no_donation_log;

-- Migration 055 also removed the type from the shared allowlist. Extend that
-- current definition so Reddit user feeds and other later types stay valid.
-- +goose StatementBegin
DO $$
DECLARE definition text;
BEGIN
    SELECT pg_get_constraintdef(oid) INTO definition
    FROM pg_constraint
    WHERE conrelid = 'public.server_logs'::regclass
        AND conname = 'server_logs_type_check';
    IF position('donation_log' IN definition) = 0 THEN
        ALTER TABLE public.server_logs DROP CONSTRAINT server_logs_type_check;
        EXECUTE 'ALTER TABLE public.server_logs ADD CONSTRAINT server_logs_type_check ' ||
            replace(definition, '''join_log''::text', '''join_log''::text, ''donation_log''::text');
    END IF;
END $$;
-- +goose StatementEnd


-- +goose Down
-- Do not delete restored destinations during rollback. The old runtime ignores
-- donation events; NOT VALID retains these rows while blocking new donation logs.
ALTER TABLE public.server_logs
    ADD CONSTRAINT server_logs_no_donation_log
        CHECK (type <> 'donation_log') NOT VALID;
