-- +goose Up
ALTER TABLE public.user_saved_bases
    ADD COLUMN kind text,
    ADD CONSTRAINT user_saved_bases_kind_check CHECK (kind IN ('war','legend'));

DROP TRIGGER player_links_reset_base_slots ON public.player_links;
DROP FUNCTION public.reset_base_slots_on_link_change();
DROP TRIGGER user_base_slots_verified ON public.user_base_slots;
DROP FUNCTION public.require_verified_base_slot();
DROP TABLE public.user_base_slots;

-- Download identity belongs to the shared base. Each JSON object key is one
-- Discord user ID and its value is that user's immutable first-download time.
-- +goose StatementBegin
CREATE FUNCTION public.base_downloads_valid(downloads_value jsonb)
RETURNS boolean LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE AS $$
DECLARE
    item record;
    parsed_at timestamptz;
BEGIN
    IF jsonb_typeof(downloads_value) <> 'object' THEN
        RETURN false;
    END IF;
    FOR item IN SELECT entry.key,entry.value FROM jsonb_each(downloads_value) entry
    LOOP
        IF item.key !~ '^[0-9]+$'
            OR jsonb_typeof(item.value) <> 'string'
            OR item.value #>> '{}' !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}([.][0-9]{1,6})?(Z|[+-][0-9]{2}:[0-9]{2})$'
        THEN
            RETURN false;
        END IF;
        BEGIN
            parsed_at := (item.value #>> '{}')::timestamptz;
        EXCEPTION WHEN others THEN
            RETURN false;
        END;
    END LOOP;
    RETURN true;
END
$$;
-- +goose StatementEnd

DROP VIEW public.base_public_counts;
ALTER TABLE public.bases
    ADD COLUMN downloads jsonb NOT NULL DEFAULT '{}'::jsonb;
UPDATE public.bases base
SET downloads=migrated.downloads
FROM (
    SELECT base_id,jsonb_object_agg(user_id,to_jsonb(downloaded_at) ORDER BY user_id) AS downloads
    FROM public.base_downloaders
    GROUP BY base_id
) migrated
WHERE migrated.base_id=base.id;
ALTER TABLE public.bases
    ADD CONSTRAINT bases_downloads_check CHECK (public.base_downloads_valid(downloads));

-- Existing keys may neither disappear nor change value. New keys remain an
-- ordinary atomic jsonb_set operation, so repeat clicks preserve first time.
-- +goose StatementBegin
CREATE FUNCTION public.preserve_base_first_downloads()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM jsonb_each(OLD.downloads) prior
        WHERE NEW.downloads -> prior.key IS DISTINCT FROM prior.value
    ) THEN
        RAISE EXCEPTION 'existing base download identities and timestamps are immutable'
            USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END
$$;
-- +goose StatementEnd
CREATE TRIGGER bases_preserve_first_downloads
    BEFORE UPDATE OF downloads ON public.bases
    FOR EACH ROW EXECUTE FUNCTION public.preserve_base_first_downloads();

DROP TABLE public.base_downloaders;
CREATE VIEW public.base_public_counts AS
SELECT base.id AS base_id,
       (SELECT count(*) FROM jsonb_object_keys(base.downloads)) AS download_count,
       (SELECT count(*) FROM public.base_votes vote WHERE vote.base_id=base.id AND vote.vote=1) AS upvote_count,
       (SELECT count(*) FROM public.base_votes vote WHERE vote.base_id=base.id AND vote.vote=-1) AS downvote_count
FROM public.bases base;

COMMENT ON COLUMN public.user_saved_bases.kind IS
    'Optional user label: war or legend. NULL means the saved base is not labeled yet.';
COMMENT ON COLUMN public.bases.downloads IS
    'Discord user ID to immutable first-download ISO timestamp; independent of personal save retention.';

-- +goose Down
-- Removed numeric slot assignments cannot be reconstructed, so this migration
-- is intentionally forward-only.
-- +goose StatementBegin
DO $$
BEGIN
    RAISE EXCEPTION 'migration 019 is irreversible: removed personal base slots cannot be reconstructed';
END
$$;
-- +goose StatementEnd
