-- +goose Up
ALTER TABLE public.servers
    ALTER COLUMN ai_monthly_limit_usd SET DEFAULT 0.10;

-- Raise the old standard allowance. Preserve every different manual override.
UPDATE public.servers
SET ai_monthly_limit_usd = 0.10
WHERE ai_monthly_limit_usd = 0.05;

-- +goose Down
-- Restore only the default: existing 10-cent values may be manual overrides.
-- Do not silently lower an allowance that a server has started using.
ALTER TABLE public.servers
    ALTER COLUMN ai_monthly_limit_usd SET DEFAULT 0.05;
