-- +goose Up
ALTER TABLE public.tracking_domain_stats
    ALTER COLUMN target_count DROP DEFAULT,
    ALTER COLUMN target_count DROP NOT NULL,
    ALTER COLUMN target_cycle DROP DEFAULT,
    ALTER COLUMN target_cycle DROP NOT NULL,
    ALTER COLUMN target_processed DROP DEFAULT,
    ALTER COLUMN target_processed DROP NOT NULL;

-- +goose Down
UPDATE public.tracking_domain_stats
SET
    target_count = COALESCE(target_count, 0),
    target_cycle = COALESCE(target_cycle, 0),
    target_processed = COALESCE(target_processed, 0)
WHERE target_count IS NULL
   OR target_cycle IS NULL
   OR target_processed IS NULL;

ALTER TABLE public.tracking_domain_stats
    ALTER COLUMN target_count SET DEFAULT 0,
    ALTER COLUMN target_count SET NOT NULL,
    ALTER COLUMN target_cycle SET DEFAULT 0,
    ALTER COLUMN target_cycle SET NOT NULL,
    ALTER COLUMN target_processed SET DEFAULT 0,
    ALTER COLUMN target_processed SET NOT NULL;
