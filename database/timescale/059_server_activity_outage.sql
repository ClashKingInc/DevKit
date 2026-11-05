-- +goose Up
-- Preserve each server's pre-outage inactivity gap. The latest imported command
-- is the data anchor, not a claimed exact shutdown time. Map it to the first v2
-- Bot deployment; retain all newer activity and unknown (NULL) activity.
CREATE TABLE public.server_activity_outage_adjustments (
    server_id text PRIMARY KEY REFERENCES public.servers(id) ON DELETE CASCADE,
    previous_last_command_at timestamptz NOT NULL,
    adjusted_last_command_at timestamptz NOT NULL,
    recorded_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT server_activity_outage_forward_check CHECK (
        adjusted_last_command_at > previous_last_command_at
    )
);

WITH candidates AS (
    SELECT id, last_command_at
    FROM public.servers
    WHERE last_command_at <= '2026-08-25 20:34:38+00'::timestamptz
    FOR UPDATE
), recorded AS (
    INSERT INTO public.server_activity_outage_adjustments (
        server_id,
        previous_last_command_at,
        adjusted_last_command_at
    )
    SELECT id, last_command_at,
        last_command_at + (
            '2026-11-05 18:29:58.483442+00'::timestamptz
            - '2026-08-25 20:34:38+00'::timestamptz
        )
    FROM candidates
    ON CONFLICT (server_id) DO NOTHING
    RETURNING server_id, previous_last_command_at, adjusted_last_command_at
)
UPDATE public.servers AS server
SET last_command_at = recorded.adjusted_last_command_at,
    updated_at = now()
FROM recorded
WHERE server.id = recorded.server_id
  AND server.last_command_at = recorded.previous_last_command_at;

-- +goose Down
-- A real command after the adjustment must never be rewound during rollback.
UPDATE public.servers AS server
SET last_command_at = audit.previous_last_command_at,
    updated_at = now()
FROM public.server_activity_outage_adjustments AS audit
WHERE server.id = audit.server_id
  AND server.last_command_at = audit.adjusted_last_command_at;
DROP TABLE public.server_activity_outage_adjustments;
