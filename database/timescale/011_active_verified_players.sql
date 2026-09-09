-- +goose Up
CREATE INDEX idx_player_links_verified_last_login
    ON public.player_links (last_login DESC, tag)
    WHERE is_verified = true AND last_login IS NOT NULL;

-- +goose Down
DROP INDEX public.idx_player_links_verified_last_login;
