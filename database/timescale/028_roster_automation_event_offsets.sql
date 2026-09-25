-- +goose Up
ALTER TABLE roster_automation_rules ADD COLUMN event_offset_days integer CHECK (event_offset_days BETWEEN -365 AND 365);
COMMENT ON COLUMN roster_automation_rules.event_offset_days IS 'Signed days from each target roster event start. NULL preserves legacy fixed-date rules.';

-- +goose Down
ALTER TABLE roster_automation_rules DROP COLUMN event_offset_days;
