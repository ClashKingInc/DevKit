-- +goose Up
ALTER TABLE roster_discord_publications
  ADD COLUMN webhook_id text CHECK (webhook_id ~ '^[0-9]{1,20}$');

-- +goose Down
ALTER TABLE roster_discord_publications DROP COLUMN webhook_id;
