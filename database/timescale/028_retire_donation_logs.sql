-- +goose Up
-- Preserve each destination before retiring event-by-event donation logs.
-- Do not reuse a log message_id: it is an event message, not an editable board.
-- +goose StatementBegin
DO $migration$
DECLARE
    old_log record;
    board_id uuid;
BEGIN
    FOR old_log IN SELECT * FROM public.server_logs WHERE type = 'donation_log'
    LOOP
        SELECT a.id INTO board_id
        FROM public.autoboards a
        WHERE a.server_id = old_log.server_id
          AND a.board_type = 'donations'
          AND a.webhook_id = old_log.webhook_id
          AND a.thread_id IS NOT DISTINCT FROM old_log.thread_id
          AND a.enabled = NOT old_log.disabled
          AND a.delivery_mode = 'refresh'
          AND a.target_scope = CASE WHEN old_log.clan_tag IS NULL THEN 'family' ELSE 'custom' END
          AND (SELECT array_agg(t.target ORDER BY t.target) FROM public.autoboard_targets t WHERE t.autoboard_id = a.id)
              IS NOT DISTINCT FROM CASE WHEN old_log.clan_tag IS NULL THEN NULL::text[] ELSE ARRAY[old_log.clan_tag] END
        LIMIT 1;
        IF board_id IS NULL THEN
            INSERT INTO public.autoboards (
                server_id,
                board_type,
                target_scope,
                delivery_mode,
                webhook_id,
                thread_id,
                enabled,
                interval_minutes,
                next_run_at,
                row_limit
            ) VALUES (
                old_log.server_id,
                'donations',
                CASE WHEN old_log.clan_tag IS NULL THEN 'family' ELSE 'custom' END,
                'refresh',
                old_log.webhook_id,
                old_log.thread_id,
                NOT old_log.disabled,
                1,
                CASE WHEN old_log.disabled THEN NULL ELSE now() END,
                10
            ) RETURNING id INTO board_id;
            IF old_log.clan_tag IS NOT NULL THEN
                INSERT INTO public.autoboard_targets (autoboard_id, target, position)
                VALUES (board_id, old_log.clan_tag, 0);
            END IF;
        END IF;
    END LOOP;
    DELETE FROM public.server_logs WHERE type = 'donation_log';
END
$migration$;
-- +goose StatementEnd
ALTER TABLE public.server_logs
    ADD CONSTRAINT server_logs_no_donation_log CHECK (type <> 'donation_log');

-- +goose Down
-- There is no lossless reverse mapping from edited boards to original logs.
-- Restore a pre-migration backup instead of reviving duplicate event delivery.
-- +goose StatementBegin
DO $migration$
BEGIN
    RAISE EXCEPTION 'Donation log retirement is forward-only; restore a pre-migration backup for rollback';
END
$migration$;
-- +goose StatementEnd
