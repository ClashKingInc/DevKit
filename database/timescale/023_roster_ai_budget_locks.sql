-- +goose Up
-- One stable identity coordinates context authorization and usage settlement
-- across every server and sponsor. Month boundaries never replace this row.
CREATE TABLE public.roster_ai_budget_locks (
    scope text NOT NULL,
    CONSTRAINT roster_ai_budget_locks_pkey PRIMARY KEY (scope),
    CONSTRAINT roster_ai_budget_locks_nonempty_check CHECK (scope <> '')
);
INSERT INTO public.roster_ai_budget_locks(scope) VALUES ('global-monthly');

-- +goose Down
-- +goose StatementBegin
DO $$
BEGIN
    RAISE EXCEPTION 'migration 023 is irreversible because budget coordination must remain stable while context and settlement writers depend on it';
END
$$;
-- +goose StatementEnd
