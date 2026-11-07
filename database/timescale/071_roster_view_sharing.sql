-- +goose Up
-- A share copies the reusable view program, never its roster membership/data.
-- Snapshot the program when sharing so the recipient confirms a stable recipe.
CREATE TABLE public.roster_view_shares (
    share_id text PRIMARY KEY DEFAULT rtrim(translate(encode(public.gen_random_bytes(12), 'base64'), '+/', '-_'), '='),
    source_view_id uuid NOT NULL REFERENCES public.roster_views(id) ON DELETE CASCADE,
    source_server_id text NOT NULL REFERENCES public.servers(id) ON DELETE CASCADE,
    shared_by_discord_user_id text NOT NULL CHECK (shared_by_discord_user_id ~ '^[0-9]+$'),
    description text NOT NULL DEFAULT '' CHECK (char_length(description) <= 300),
    name text NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 80),
    source_code text NOT NULL CHECK (length(btrim(source_code)) BETWEEN 1 AND 65536),
    source_version smallint NOT NULL CHECK (source_version > 0),
    created_at timestamptz NOT NULL DEFAULT now(),
    CHECK (share_id ~ '^[A-Za-z0-9_-]{16}$')
);
CREATE INDEX roster_view_shares_source ON public.roster_view_shares(source_view_id);
ALTER TABLE public.roster_views ADD COLUMN imported_from_share_id text NULL;
ALTER TABLE public.roster_views ADD COLUMN description text NOT NULL DEFAULT '' CHECK (char_length(description) <= 300);
-- An explicit retry (including concurrent clicks) returns the existing copy.
CREATE UNIQUE INDEX roster_views_import_once ON public.roster_views(server_id, imported_from_share_id);
-- +goose Down
-- +goose StatementBegin
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM public.roster_view_shares)
        OR EXISTS (SELECT 1 FROM public.roster_views WHERE imported_from_share_id IS NOT NULL OR description <> '') THEN
        RAISE EXCEPTION 'Preserve shared and imported views before rollback';
    END IF;
END $$;
-- +goose StatementEnd
DROP INDEX public.roster_views_import_once;
ALTER TABLE public.roster_views DROP COLUMN imported_from_share_id;
ALTER TABLE public.roster_views DROP COLUMN description;
DROP TABLE public.roster_view_shares;
