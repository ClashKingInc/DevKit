-- +goose Up
ALTER TABLE rosters ADD COLUMN embed_color integer CHECK (embed_color BETWEEN 0 AND 16777215);
COMMENT ON COLUMN rosters.embed_color IS 'Optional Discord embed color override; NULL inherits the server embed color.';

-- +goose Down
ALTER TABLE rosters DROP COLUMN embed_color;
