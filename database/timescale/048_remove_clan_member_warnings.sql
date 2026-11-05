-- +goose Up
-- This feature is excluded from V2. Keep prior migration history intact while
-- removing its stored configuration from the final schema.
DROP TABLE public.server_clan_member_warnings;

-- +goose Down
-- Rollback restores structure only; removed warning configuration is not recreated.
-- Settings only: alerts use the existing best-effort clan event stream. No
-- per-delivery ledger is required. Removing a linked clan removes its alert.
CREATE TABLE public.server_clan_member_warnings (
    server_id text NOT NULL,
    clan_tag text NOT NULL,
    channel_id text NOT NULL,
    below_count smallint,
    above_count smallint,
    role_id text,
    updated_at timestamp with time zone NOT NULL DEFAULT now(),
    PRIMARY KEY (server_id, clan_tag),
    FOREIGN KEY (clan_tag, server_id)
        REFERENCES public.server_clans (tag, server_id) ON DELETE CASCADE,
    CONSTRAINT clan_member_warning_destination CHECK (
        channel_id ~ '^[0-9]{15,20}$'
        AND (role_id IS NULL OR role_id ~ '^[0-9]{15,20}$')
    ),
    CONSTRAINT clan_member_warning_thresholds CHECK (
        (below_count IS NOT NULL OR above_count IS NOT NULL)
        AND (below_count IS NULL OR below_count BETWEEN 1 AND 50)
        AND (above_count IS NULL OR above_count BETWEEN 0 AND 49)
        AND (below_count IS NULL OR above_count IS NULL OR below_count <= above_count)
    )
);

COMMENT ON TABLE public.server_clan_member_warnings IS
    'Clan-linked warning configuration. Strict crossings below/above the limits alert; remaining outside a limit does not repeatedly alert.';

