-- +goose Up
ALTER TABLE public.servers ADD COLUMN custom_autoboard_interval_enabled boolean NOT NULL DEFAULT false;
ALTER TABLE public.autoboard_farming_settings ADD COLUMN rolling_days integer NOT NULL DEFAULT 30 CHECK (rolling_days BETWEEN 1 AND 180);
ALTER TABLE public.autoboard_farming_settings DROP CONSTRAINT autoboard_farming_settings_window_mode_check;
ALTER TABLE public.autoboard_farming_settings ADD CONSTRAINT autoboard_farming_settings_window_mode_check CHECK (window_mode IN ('since_start', 'calendar_month', 'game_season', 'rolling_days'));
UPDATE public.autoboards SET interval_seconds = CASE WHEN board_type='farming' THEN 300 ELSE NULL END, interval_minutes = CASE WHEN board_type='farming' THEN NULL ELSE 5 END WHERE delivery_mode='refresh';
-- +goose Down
UPDATE public.autoboard_farming_settings SET window_mode='game_season' WHERE window_mode='rolling_days';
ALTER TABLE public.autoboard_farming_settings DROP CONSTRAINT autoboard_farming_settings_window_mode_check;
ALTER TABLE public.autoboard_farming_settings ADD CONSTRAINT autoboard_farming_settings_window_mode_check CHECK (window_mode IN ('since_start', 'calendar_month', 'game_season'));
ALTER TABLE public.autoboard_farming_settings DROP COLUMN rolling_days;
ALTER TABLE public.servers DROP COLUMN custom_autoboard_interval_enabled;
