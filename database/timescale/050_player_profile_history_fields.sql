-- +goose Up
-- Existing IDs 1..12 remain unchanged. These scalar observations do not carry item IDs.
ALTER TABLE public.player_change_history
    DROP CONSTRAINT player_change_history_change_type_check;
ALTER TABLE public.player_change_history
    ADD CONSTRAINT player_change_history_change_type_check
    CHECK (change_type BETWEEN 1 AND 15);
COMMENT ON COLUMN public.player_change_history.change_type IS
    '1 troop, 2 boost, 3 hero, 4 spell, 5 pet, 6 equipment, 7 town hall, 8 best trophies, 9 best builder trophies, 10 experience, 11 war preference, 12 name, 13 league tier, 14 war stars, 15 clan capital contributions';

-- +goose Down
-- Fail rather than deleting recorded history if the new writer has already run.
ALTER TABLE public.player_change_history
    DROP CONSTRAINT player_change_history_change_type_check;
ALTER TABLE public.player_change_history
    ADD CONSTRAINT player_change_history_change_type_check
    CHECK (change_type BETWEEN 1 AND 12);
COMMENT ON COLUMN public.player_change_history.change_type IS NULL;
