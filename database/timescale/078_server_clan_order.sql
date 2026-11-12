-- +goose Up
ALTER TABLE public.server_clans
    ADD COLUMN position integer NOT NULL DEFAULT 0
        CHECK (position >= 0);

-- Preserve the former name/tag order within each category on first deployment.
WITH ordered AS (
    SELECT scoped.server_id,
        scoped.tag,
        row_number() OVER (
            PARTITION BY scoped.server_id, scoped.category_id
            ORDER BY clan.name, scoped.tag
        ) - 1 AS position
    FROM public.server_clans AS scoped
    JOIN public.basic_clan AS clan ON clan.tag = scoped.tag
)
UPDATE public.server_clans AS scoped
SET position = ordered.position
FROM ordered
WHERE scoped.server_id = ordered.server_id
    AND scoped.tag = ordered.tag;

CREATE INDEX server_clans_category_order_idx
    ON public.server_clans (server_id, category_id, position, tag);

-- +goose Down
-- Only custom display ordering is lost; clans and their categories are retained.
DROP INDEX public.server_clans_category_order_idx;
ALTER TABLE public.server_clans
    DROP COLUMN position;
