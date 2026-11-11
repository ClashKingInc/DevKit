-- +goose Up
-- Reuse the existing signed-interaction receipt so a replayed leave click can
-- never remove an entry made later by a fresh join interaction.
ALTER TABLE giveaway_entry_receipts
    DROP CONSTRAINT giveaway_entry_receipts_outcome_check,
    ADD CONSTRAINT giveaway_entry_receipts_outcome_check
        CHECK (outcome IN ('entered', 'already_entered', 'left', 'already_left'));

-- +goose Down
-- Validation deliberately blocks rollback while withdrawal receipts remain.
-- Do not delete replay-protection records merely to make an old check pass.
ALTER TABLE giveaway_entry_receipts
    DROP CONSTRAINT giveaway_entry_receipts_outcome_check,
    ADD CONSTRAINT giveaway_entry_receipts_outcome_check
        CHECK (outcome IN ('entered', 'already_entered'));
