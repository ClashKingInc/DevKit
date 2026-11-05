-- +goose Up
ALTER TABLE public.autoboards ADD COLUMN interval_seconds integer;
ALTER TABLE public.autoboards DROP CONSTRAINT autoboards_schedule_check;
-- Leave legacy rows minute-based. New clients may use seconds, but never let
-- the two representations disagree or allow a scheduled send to retain a message.
ALTER TABLE public.autoboards ADD CONSTRAINT autoboards_schedule_check CHECK (
    (delivery_mode = 'refresh'
        AND (interval_minutes > 0 OR interval_seconds >= 30)
        AND (interval_minutes IS NOT NULL OR interval_seconds IS NOT NULL)
        AND (interval_minutes IS NULL OR interval_minutes > 0)
        AND (interval_seconds IS NULL OR interval_seconds >= 30)
        AND (interval_minutes IS NULL OR interval_seconds IS NULL OR interval_minutes * 60 = interval_seconds)
        AND schedule_kind IS NULL AND schedule_time IS NULL
        AND schedule_weekdays IS NULL AND schedule_day_of_month IS NULL)
    OR (delivery_mode = 'send' AND interval_minutes IS NULL AND interval_seconds IS NULL
        AND message_id IS NULL AND schedule_kind IS NOT NULL AND schedule_time IS NOT NULL
        AND ((schedule_kind = 'daily' AND schedule_weekdays IS NULL AND schedule_day_of_month IS NULL)
            OR (schedule_kind = 'weekdays' AND cardinality(schedule_weekdays) BETWEEN 1 AND 7
                AND schedule_weekdays <@ ARRAY[1,2,3,4,5,6,7]::smallint[] AND schedule_day_of_month IS NULL)
            OR (schedule_kind = 'day_of_month' AND schedule_weekdays IS NULL AND schedule_day_of_month BETWEEN 1 AND 31)))
);

CREATE TABLE public.autoboard_farming_settings (
    autoboard_id uuid NOT NULL REFERENCES public.autoboards(id) ON DELETE CASCADE,
    window_mode text NOT NULL DEFAULT 'since_start',
    counting_from timestamptz NOT NULL DEFAULT now(),
    time_zone text NOT NULL DEFAULT 'UTC',
    PRIMARY KEY (autoboard_id),
    CHECK (window_mode IN ('since_start', 'calendar_month', 'game_season'))
);
COMMENT ON COLUMN public.autoboard_farming_settings.counting_from IS
    'Original board creation time. Retained even when changing windows, destinations, or enabled state.';

-- +goose StatementBegin
CREATE FUNCTION public.farming_summary(player_tags text[], range_start timestamptz, range_end timestamptz)
RETURNS TABLE (
    player_tag text,
    gold numeric,
    elixir numeric,
    dark_elixir numeric,
    total_loot numeric,
    attacks bigint,
    timed_attacks bigint,
    attack_seconds numeric,
    session_seconds numeric
)
LANGUAGE sql STABLE AS $function$
WITH observations AS (
    SELECT b.*, lag(b.battle_time) OVER (PARTITION BY b.player_tag ORDER BY b.battle_time) AS previous_at
    FROM public.battles_farming b
    WHERE b.player_tag = ANY(player_tags) AND b.battle_time >= range_start AND b.battle_time < range_end
), grouped AS (
    SELECT o.*, sum(CASE WHEN previous_at IS NULL OR battle_time - previous_at > interval '3 minutes'
        THEN 1 ELSE 0 END) OVER (PARTITION BY o.player_tag ORDER BY battle_time) AS session_number
    FROM observations o
), spans AS (
    SELECT g.player_tag, session_number,
        min(battle_time) AS starts_at,
        max(battle_time + make_interval(secs => GREATEST(COALESCE(duration_seconds,0),0))) AS ends_at
    FROM grouped g GROUP BY g.player_tag, session_number
), preceding AS (
    SELECT s.*, max(ends_at) OVER (PARTITION BY s.player_tag ORDER BY starts_at
        ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS prior_end
    FROM spans s
), session_totals AS (
    -- Subtract overlapping time when a long final attack crosses a session gap.
    SELECT s.player_tag, sum(GREATEST(0,extract(epoch FROM ends_at - GREATEST(starts_at,COALESCE(prior_end,starts_at))))) AS seconds
    FROM preceding s GROUP BY s.player_tag
), totals AS (
    SELECT g.player_tag,
        sum(COALESCE((looted_resources->>'gold')::numeric,0)) AS gold,
        sum(COALESCE((looted_resources->>'elixir')::numeric,0)) AS elixir,
        sum(COALESCE((looted_resources->>'darkElixir')::numeric,0)) AS dark_elixir,
        count(*) AS attacks,
        count(*) FILTER (WHERE duration_seconds > 0) AS timed_attacks,
        COALESCE(sum(duration_seconds) FILTER (WHERE duration_seconds > 0),0)::numeric AS attack_seconds
    FROM grouped g GROUP BY g.player_tag
)
SELECT t.player_tag,t.gold,t.elixir,t.dark_elixir,t.gold+t.elixir+t.dark_elixir,
    t.attacks,t.timed_attacks,t.attack_seconds,s.seconds
FROM totals t JOIN session_totals s ON s.player_tag=t.player_tag;
$function$;
-- +goose StatementEnd

-- +goose Down
-- Disable seconds-only boards rather than silently running them with a different cadence.
UPDATE public.autoboards SET enabled=false,interval_minutes=GREATEST(1,ceil(interval_seconds/60.0)::integer)
    WHERE interval_seconds IS NOT NULL AND interval_minutes IS NULL;
DROP FUNCTION public.farming_summary(text[],timestamptz,timestamptz);
DROP TABLE public.autoboard_farming_settings;
ALTER TABLE public.autoboards DROP CONSTRAINT autoboards_schedule_check;
ALTER TABLE public.autoboards DROP COLUMN interval_seconds;
ALTER TABLE public.autoboards ADD CONSTRAINT autoboards_schedule_check CHECK (
    (delivery_mode='refresh' AND interval_minutes IS NOT NULL AND interval_minutes>0
        AND schedule_kind IS NULL AND schedule_time IS NULL AND schedule_weekdays IS NULL AND schedule_day_of_month IS NULL)
    OR (delivery_mode='send' AND interval_minutes IS NULL AND message_id IS NULL
        AND schedule_kind IS NOT NULL AND schedule_time IS NOT NULL
        AND ((schedule_kind='daily' AND schedule_weekdays IS NULL AND schedule_day_of_month IS NULL)
        OR (schedule_kind='weekdays' AND cardinality(schedule_weekdays) BETWEEN 1 AND 7
            AND schedule_weekdays <@ ARRAY[1,2,3,4,5,6,7]::smallint[] AND schedule_day_of_month IS NULL)
        OR (schedule_kind='day_of_month' AND schedule_weekdays IS NULL AND schedule_day_of_month BETWEEN 1 AND 31)))
);
