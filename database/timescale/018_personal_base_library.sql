-- +goose Up
-- A saved row is the authenticated user's durable reference to an existing
-- shared base. Download and explicit-save flows both upsert this same identity;
-- no layout payload is copied into a user-owned table.
CREATE TABLE public.user_saved_bases (
    user_id text NOT NULL REFERENCES public.auth_users(user_id) ON DELETE CASCADE,
    base_id bigint NOT NULL REFERENCES public.bases(id) ON DELETE CASCADE,
    saved_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id,base_id)
);
CREATE INDEX idx_user_saved_bases_recent
    ON public.user_saved_bases (user_id,saved_at DESC,base_id DESC);

-- Slots are per verified linked game account. Reassigning a slot is an upsert
-- on the primary key; clearing it is a delete. A base may occupy one War and
-- one Legend slot for the same account, but cannot be duplicated within a kind.
CREATE TABLE public.user_base_slots (
    user_id text NOT NULL,
    player_tag text NOT NULL,
    slot_kind text NOT NULL,
    slot_number smallint NOT NULL,
    base_id bigint NOT NULL,
    assigned_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id,player_tag,slot_kind,slot_number),
    UNIQUE (user_id,player_tag,slot_kind,base_id),
    FOREIGN KEY (user_id,base_id)
        REFERENCES public.user_saved_bases(user_id,base_id) ON DELETE CASCADE,
    FOREIGN KEY (player_tag,user_id)
        REFERENCES public.player_links(tag,user_id) ON DELETE CASCADE,
    CONSTRAINT user_base_slots_kind_check CHECK (slot_kind IN ('war','legend')),
    CONSTRAINT user_base_slots_number_check CHECK (slot_number BETWEEN 1 AND 3)
);

-- +goose StatementBegin
CREATE FUNCTION public.require_verified_base_slot()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM public.player_links
        WHERE tag=NEW.player_tag AND user_id=NEW.user_id AND is_verified
    ) THEN
        RAISE EXCEPTION 'base slot requires a currently verified owned link'
            USING ERRCODE='23514';
    END IF;
    NEW.assigned_at := clock_timestamp();
    RETURN NEW;
END
$$;
-- +goose StatementEnd
CREATE TRIGGER user_base_slots_verified
    BEFORE INSERT OR UPDATE ON public.user_base_slots
    FOR EACH ROW EXECUTE FUNCTION public.require_verified_base_slot();

-- The composite ownership FK prevents a transfer while old slots exist. Clear
-- them before ownership or verification changes so a new owner never inherits
-- another user's assignments.
-- +goose StatementBegin
CREATE FUNCTION public.reset_base_slots_on_link_change()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.user_id IS DISTINCT FROM OLD.user_id OR NEW.is_verified IS DISTINCT FROM OLD.is_verified THEN
        DELETE FROM public.user_base_slots
        WHERE player_tag=OLD.tag AND user_id=OLD.user_id;
    END IF;
    RETURN NEW;
END
$$;
-- +goose StatementEnd
CREATE TRIGGER player_links_reset_base_slots
    BEFORE UPDATE OF user_id,is_verified ON public.player_links
    FOR EACH ROW EXECUTE FUNCTION public.reset_base_slots_on_link_change();

COMMENT ON TABLE public.user_saved_bases IS
    'Authenticated-user references to shared bases. Downloads and explicit saves use one durable identity.';
COMMENT ON TABLE public.user_base_slots IS
    'War and Legend slots 1-3 for currently verified player links; slot rows never own base payloads.';

-- +goose Down
DROP TRIGGER player_links_reset_base_slots ON public.player_links;
DROP FUNCTION public.reset_base_slots_on_link_change();
DROP TRIGGER user_base_slots_verified ON public.user_base_slots;
DROP FUNCTION public.require_verified_base_slot();
DROP TABLE public.user_base_slots;
DROP TABLE public.user_saved_bases;
