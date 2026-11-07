-- +goose Up
-- Retain the historical table/endpoint names for rolling deployments. These
-- rows now audit provider calls; reserved_usd is no longer spend or admission.
ALTER TABLE public.roster_ai_step_budgets
    DROP CONSTRAINT roster_ai_step_budgets_reserved_usd_check,
    DROP CONSTRAINT roster_ai_step_budgets_check,
    ADD CONSTRAINT roster_ai_step_budgets_reserved_usd_check CHECK (reserved_usd >= 0),
    ADD CONSTRAINT roster_ai_step_budgets_actual_usd_check CHECK (actual_usd >= 0),
    ADD COLUMN outcome text NOT NULL DEFAULT 'pending'
        CHECK (outcome IN ('pending', 'completed', 'rejected', 'unknown')),
    ADD COLUMN provider_response_id text NULL,
    ADD COLUMN failure_code text NULL,
    ADD COLUMN updated_at timestamptz NOT NULL DEFAULT now();
UPDATE public.roster_ai_step_budgets
SET outcome = CASE WHEN settled_at IS NOT NULL THEN 'completed' ELSE 'unknown' END,
    failure_code = CASE WHEN settled_at IS NULL THEN 'legacy_missing_usage' ELSE NULL END;
COMMENT ON TABLE public.roster_ai_step_budgets IS 'Provider-call usage audit. Legacy estimates are retained for diagnosis only; no reservations affect admission. Unknown usage is not a zero-cost settlement.';
COMMENT ON COLUMN public.roster_ai_step_budgets.reserved_usd IS 'Legacy estimate only. New calls store zero. Excluded from all spending limits.';
-- +goose Down
-- Empty disposable databases can roll back for upgrade tests. Production call
-- records must never lose their diagnostics or regain unsafe hard-cap rules.
-- +goose StatementBegin
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM public.roster_ai_step_budgets) THEN
        RAISE EXCEPTION 'Preserve AI usage records; rollback requires an empty call audit';
    END IF;
END $$;
-- +goose StatementEnd
ALTER TABLE public.roster_ai_step_budgets
    DROP CONSTRAINT roster_ai_step_budgets_reserved_usd_check,
    DROP CONSTRAINT roster_ai_step_budgets_actual_usd_check,
    DROP COLUMN outcome,
    DROP COLUMN provider_response_id,
    DROP COLUMN failure_code,
    DROP COLUMN updated_at,
    ADD CONSTRAINT roster_ai_step_budgets_reserved_usd_check CHECK (reserved_usd > 0),
    ADD CONSTRAINT roster_ai_step_budgets_check CHECK (actual_usd >= 0 AND actual_usd <= reserved_usd);
COMMENT ON TABLE public.roster_ai_step_budgets IS 'Per-provider-call hard spend reservations. Unknown/aborted calls retain their reservation; no timeout may release potentially spent budget.';
COMMENT ON COLUMN public.roster_ai_step_budgets.reserved_usd IS NULL;
