-- +goose Up
-- Webhook IDs are durable identities; execution tokens are resolved with the bot.
-- Existing reminders are backfilled by reminder_webhooks.go before new delivery starts.
ALTER TABLE public.reminders
    ADD COLUMN webhook_id text;
COMMENT ON COLUMN public.reminders.webhook_id IS
    'Incoming webhook owned by ClashKing in the configured parent channel; no token stored here';

-- +goose Down
-- Stop the new API and delivery worker before rollback. Existing webhook objects
-- are shared with logs and other reminders and must not be deleted by rollback.
ALTER TABLE public.reminders
    DROP COLUMN webhook_id;
