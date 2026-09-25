-- +goose Up
ALTER TABLE rosters ALTER COLUMN max_signups SET DEFAULT 50;

-- +goose Down
ALTER TABLE rosters ALTER COLUMN max_signups DROP DEFAULT;
