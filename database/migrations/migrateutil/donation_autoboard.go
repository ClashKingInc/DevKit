package migrateutil

import (
	"context"
	"github.com/jackc/pgx/v5"
)

// ImportDonationAutoboard preserves a legacy log destination without recreating
// donation event delivery. Do not reuse old event message IDs as editable boards.
// Reimports retain an existing matching board rather than resetting its schedule.
func ImportDonationAutoboard(ctx context.Context, tx pgx.Tx, serverID, clanTag, webhookID, threadID string, disabled bool) error {
	var boardID string
	err := tx.QueryRow(ctx, `
        SELECT a.id::text FROM autoboards a
        WHERE a.server_id = $1 AND a.board_type = 'donations'
          AND a.webhook_id = $3 AND a.thread_id IS NOT DISTINCT FROM NULLIF($4, '')
          AND a.enabled = NOT $5 AND a.delivery_mode = 'refresh'
          AND a.target_scope = CASE WHEN $2 = '' THEN 'family' ELSE 'custom' END
          AND (SELECT array_agg(t.target ORDER BY t.target) FROM autoboard_targets t WHERE t.autoboard_id = a.id)
              IS NOT DISTINCT FROM CASE WHEN $2 = '' THEN NULL::text[] ELSE ARRAY[$2::text] END
        LIMIT 1
    `, serverID, clanTag, webhookID, threadID, disabled).Scan(&boardID)
	if err == nil {
		return nil
	}
	if err != pgx.ErrNoRows {
		return err
	}
	err = tx.QueryRow(ctx, `
        INSERT INTO autoboards (server_id, board_type, target_scope, delivery_mode, webhook_id,
            thread_id, enabled, interval_minutes, next_run_at, row_limit)
        VALUES ($1, 'donations', CASE WHEN $2 = '' THEN 'family' ELSE 'custom' END,
            'refresh', $3, NULLIF($4, ''), NOT $5, 1, CASE WHEN $5 THEN NULL ELSE now() END, 10)
        RETURNING id::text
    `, serverID, clanTag, webhookID, threadID, disabled).Scan(&boardID)
	if err != nil {
		return err
	}
	if clanTag != "" {
		_, err = tx.Exec(ctx, `INSERT INTO autoboard_targets (autoboard_id, target, position) VALUES ($1::uuid, $2, 0)`, boardID, clanTag)
	}
	return err
}
