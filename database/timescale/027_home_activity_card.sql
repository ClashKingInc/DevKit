-- +goose Up
-- Replace only the removed custom widgets. Preserve the original cards' order.
ALTER TABLE public.home_items DROP CONSTRAINT home_items_kind_check;
ALTER TABLE public.home_items DROP CONSTRAINT home_items_check;
DELETE FROM public.home_items WHERE kind NOT IN ('todo','ranked','upgrade');
WITH ordered AS (
    SELECT user_id, id, row_number() OVER (PARTITION BY user_id ORDER BY position)-1 AS slot
    FROM public.home_items
)
UPDATE public.home_items item SET position=ordered.slot
FROM ordered WHERE item.user_id=ordered.user_id AND item.id=ordered.id;
INSERT INTO public.home_items(user_id,id,kind,entity_tag,size,position)
SELECT user_id,'activity','activity',NULL,'wide',3 FROM public.home_layouts;
ALTER TABLE public.home_items ADD CONSTRAINT home_items_kind_check
    CHECK (kind IN ('todo','ranked','upgrade','activity'));
ALTER TABLE public.home_items ADD CONSTRAINT home_items_check
    CHECK (entity_tag IS NULL AND id=kind AND size='wide');
UPDATE public.home_layouts SET revision=revision+1,updated_at=now();

-- +goose Down
DELETE FROM public.home_items WHERE kind='activity';
ALTER TABLE public.home_items DROP CONSTRAINT home_items_kind_check;
ALTER TABLE public.home_items DROP CONSTRAINT home_items_check;
ALTER TABLE public.home_items ADD CONSTRAINT home_items_kind_check
    CHECK (kind IN ('todo','ranked','upgrade','ranked_player','legend_day','war_score','clan_donations','player_farming'));
ALTER TABLE public.home_items ADD CONSTRAINT home_items_check
    CHECK ((kind IN ('todo','ranked','upgrade') AND entity_tag IS NULL AND id=kind AND size='wide')
        OR (kind NOT IN ('todo','ranked','upgrade') AND entity_tag ~ '^#[0289PYLQGRJCUV]+$'));
UPDATE public.home_layouts SET revision=revision+1,updated_at=now();
