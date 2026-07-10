-- +goose Up
ALTER TABLE public.wars
    ALTER COLUMN battle_modifier SET DEFAULT 'none';

ALTER TABLE public.war_attacks
    ALTER COLUMN battle_modifier SET DEFAULT 'none';

UPDATE public.wars
SET battle_modifier = 'none'
WHERE battle_modifier IS NULL OR btrim(battle_modifier) = '';

UPDATE public.war_attacks
SET battle_modifier = 'none'
WHERE battle_modifier IS NULL OR btrim(battle_modifier) = '';

-- +goose Down
ALTER TABLE public.wars
    ALTER COLUMN battle_modifier SET DEFAULT '';

ALTER TABLE public.war_attacks
    ALTER COLUMN battle_modifier SET DEFAULT '';
