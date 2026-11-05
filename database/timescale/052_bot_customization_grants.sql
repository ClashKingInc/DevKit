-- +goose Up
-- Customization requires an explicit per-server Admin grant. Existing profile
-- values are retained; neither a grant nor revocation writes to Discord.
ALTER TABLE public.servers
    ADD COLUMN bot_customization_enabled boolean NOT NULL DEFAULT false;
COMMENT ON COLUMN public.servers.bot_customization_enabled IS
    'Admin-granted bot profile customization; normal server permissions are also required.';

-- +goose Down
ALTER TABLE public.servers
    DROP COLUMN bot_customization_enabled;
