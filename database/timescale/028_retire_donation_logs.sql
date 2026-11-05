-- +goose Up
-- Donation event logs are retired without creating replacement AutoBoards.
-- Keep separately configured AutoBoards and Discord webhooks untouched.
DELETE FROM public.server_logs WHERE type = 'donation_log';
ALTER TABLE public.server_logs
    ADD CONSTRAINT server_logs_no_donation_log CHECK (type <> 'donation_log');

-- +goose Down
-- Deleted destinations cannot be reconstructed from the remaining state.
-- Restore a pre-migration backup if these retired settings must be recovered.
-- +goose StatementBegin
DO $migration$
BEGIN
    RAISE EXCEPTION 'Donation log retirement is forward-only; restore a pre-migration backup for rollback';
END
$migration$;
-- +goose StatementEnd
