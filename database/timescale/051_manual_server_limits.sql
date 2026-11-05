-- +goose Up
ALTER TABLE public.servers
    ADD COLUMN clan_limit integer NOT NULL DEFAULT 10 CHECK (clan_limit BETWEEN 0 AND 10000),
    ADD COLUMN ai_monthly_limit_usd numeric(18,8) NOT NULL DEFAULT 0.05 CHECK (ai_monthly_limit_usd BETWEEN 0 AND 10000);
ALTER TABLE public.servers ALTER COLUMN autoboard_limit SET DEFAULT 5;
-- Replace the SQL zero default and former UI ten default; retain boards and other overrides.
UPDATE public.servers SET autoboard_limit = 5 WHERE autoboard_limit IN (0, 10);
ALTER TABLE public.roster_ai_usage ADD COLUMN budget_month date;
UPDATE public.roster_ai_usage SET budget_month = date_trunc('month', created_at AT TIME ZONE 'UTC')::date;
ALTER TABLE public.roster_ai_usage ALTER COLUMN budget_month SET NOT NULL;
ALTER TABLE public.roster_ai_usage ALTER COLUMN budget_month SET DEFAULT date_trunc('month', now() AT TIME ZONE 'UTC')::date;
CREATE TABLE public.roster_ai_step_budgets (
    usage_id uuid NOT NULL REFERENCES public.roster_ai_usage(id) ON DELETE CASCADE,
    step integer NOT NULL CHECK (step BETWEEN 0 AND 7),
    input_token_limit bigint NOT NULL CHECK (input_token_limit BETWEEN 1 AND 1000000),
    output_token_limit bigint NOT NULL CHECK (output_token_limit BETWEEN 1 AND 64000),
    reserved_usd numeric(18,8) NOT NULL CHECK (reserved_usd > 0),
    actual_usd numeric(18,8) NULL CHECK (actual_usd >= 0 AND actual_usd <= reserved_usd),
    usage jsonb NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    settled_at timestamptz NULL,
    PRIMARY KEY (usage_id, step),
    CHECK ((settled_at IS NULL AND actual_usd IS NULL AND usage IS NULL)
        OR (settled_at IS NOT NULL AND actual_usd IS NOT NULL AND usage IS NOT NULL))
);
CREATE INDEX roster_ai_usage_server_month ON public.roster_ai_usage (server_id, budget_month);
COMMENT ON TABLE public.roster_ai_step_budgets IS 'Per-provider-call hard spend reservations. Unknown/aborted calls retain their reservation; no timeout may release potentially spent budget.';
-- +goose Down
-- Refuse rollback once budgeted calls exist: never silently lose spend records.
-- +goose StatementBegin
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM public.roster_ai_step_budgets) THEN
        RAISE EXCEPTION 'Retain AI step spend records before rolling back manual limits';
    END IF;
END $$;
-- +goose StatementEnd
DROP TABLE public.roster_ai_step_budgets;
DROP INDEX public.roster_ai_usage_server_month;
ALTER TABLE public.roster_ai_usage DROP COLUMN budget_month;
ALTER TABLE public.servers DROP COLUMN clan_limit, DROP COLUMN ai_monthly_limit_usd;
ALTER TABLE public.servers ALTER COLUMN autoboard_limit SET DEFAULT 0;
