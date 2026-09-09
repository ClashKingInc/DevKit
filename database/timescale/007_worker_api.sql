-- +goose Up
-- Consolidated unapplied Worker/API schema. Production baseline is Goose 006.
-- Migrations 001-006 are immutable. This migration runs in one transaction.

-- Section: app_update_rollouts
CREATE TABLE public.app_update_channels (
    channel text NOT NULL,
    platform text NOT NULL,
    runtime_version text NOT NULL,
    active_version text,
    rollout_basis_points integer DEFAULT 0 NOT NULL,
    paused boolean DEFAULT false NOT NULL,
    rollout_from_basis_points integer,
    rollout_to_basis_points integer,
    rollout_starts_at timestamp with time zone,
    rollout_ends_at timestamp with time zone,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT app_update_channels_pkey PRIMARY KEY (channel, platform, runtime_version),
    CONSTRAINT app_update_channels_channel_check CHECK (channel IN ('beta', 'production')),
    CONSTRAINT app_update_channels_platform_check CHECK (platform IN ('ios', 'android')),
    CONSTRAINT app_update_channels_runtime_version_check
        CHECK (runtime_version = btrim(runtime_version) AND runtime_version <> '' AND length(runtime_version) <= 200),
    CONSTRAINT app_update_channels_active_version_check
        CHECK (active_version IS NULL OR (active_version = btrim(active_version) AND active_version <> '' AND length(active_version) <= 80)),
    CONSTRAINT app_update_channels_rollout_check CHECK (rollout_basis_points BETWEEN 0 AND 10000),
    CONSTRAINT app_update_channels_schedule_check CHECK (
        (rollout_from_basis_points IS NULL
            AND rollout_to_basis_points IS NULL
            AND rollout_starts_at IS NULL
            AND rollout_ends_at IS NULL)
        OR
        (rollout_from_basis_points BETWEEN 0 AND 10000
            AND rollout_to_basis_points BETWEEN 0 AND 10000
            AND rollout_starts_at IS NOT NULL
            AND rollout_ends_at IS NOT NULL
            AND rollout_ends_at > rollout_starts_at)
    )
);

CREATE TABLE public.app_update_installations (
    installation_hash bytea NOT NULL,
    channel text NOT NULL,
    platform text NOT NULL,
    runtime_version text NOT NULL,
    current_update_id uuid,
    first_seen_at timestamp with time zone DEFAULT now() NOT NULL,
    last_seen_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT app_update_installations_pkey PRIMARY KEY (installation_hash, channel, platform, runtime_version),
    CONSTRAINT app_update_installations_hash_check CHECK (octet_length(installation_hash) = 32),
    CONSTRAINT app_update_installations_channel_check CHECK (channel IN ('beta', 'production')),
    CONSTRAINT app_update_installations_platform_check CHECK (platform IN ('ios', 'android')),
    CONSTRAINT app_update_installations_runtime_version_check
        CHECK (runtime_version = btrim(runtime_version) AND runtime_version <> '' AND length(runtime_version) <= 200),
    CONSTRAINT app_update_installations_seen_check CHECK (last_seen_at >= first_seen_at)
);

CREATE INDEX idx_app_update_installations_adoption
    ON public.app_update_installations (channel, platform, runtime_version, current_update_id, last_seen_at DESC);


-- Section: discord_cache
CREATE SCHEMA IF NOT EXISTS discord_cache;

-- One writer owns an application's shard topology. Heartbeats are emitted only
-- after its ordered database-write barrier; old generations are never authority.
CREATE TABLE discord_cache.gateway_shards (
    application_id text NOT NULL,
    shard_id integer NOT NULL,
    shard_count integer NOT NULL,
    generation uuid NOT NULL,
    healthy boolean DEFAULT false NOT NULL,
    heartbeat_at timestamp with time zone DEFAULT now() NOT NULL,
    last_applied_sequence bigint,
    CONSTRAINT discord_cache_gateway_shards_pkey PRIMARY KEY (application_id, shard_id),
    CONSTRAINT discord_cache_gateway_shards_application_check CHECK (application_id ~ '^[0-9]+$'),
    CONSTRAINT discord_cache_gateway_shards_topology_check CHECK (shard_count > 0 AND shard_id >= 0 AND shard_id < shard_count),
    CONSTRAINT discord_cache_gateway_shards_sequence_check CHECK (last_applied_sequence IS NULL OR last_applied_sequence >= 0)
);

CREATE TABLE discord_cache.guilds (
    id text PRIMARY KEY,
    data jsonb NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    application_id text,
    shard_id integer,
    generation uuid,
    available boolean DEFAULT false NOT NULL,
    metadata_complete boolean DEFAULT false NOT NULL,
    members_complete boolean DEFAULT false NOT NULL,
    members_sync_token uuid,
    CONSTRAINT discord_cache_guilds_id_check CHECK (id <> ''),
    CONSTRAINT discord_cache_guilds_data_check CHECK (jsonb_typeof(data) = 'object'),
    CONSTRAINT discord_cache_guilds_shard_scope_check CHECK ((application_id IS NULL) = (shard_id IS NULL)),
    CONSTRAINT discord_cache_guilds_shard_fkey FOREIGN KEY (application_id, shard_id)
        REFERENCES discord_cache.gateway_shards(application_id, shard_id)
);

CREATE INDEX idx_discord_cache_guilds_shard ON discord_cache.guilds(application_id, shard_id);

CREATE TABLE discord_cache.channels (
    id text PRIMARY KEY,
    guild_id text,
    data jsonb NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT discord_cache_channels_id_check CHECK (id <> ''),
    CONSTRAINT discord_cache_channels_guild_id_check CHECK (guild_id IS NULL OR guild_id <> ''),
    CONSTRAINT discord_cache_channels_data_check CHECK (jsonb_typeof(data) = 'object')
);

CREATE INDEX idx_discord_cache_channels_guild
    ON discord_cache.channels (guild_id)
    WHERE guild_id IS NOT NULL;

CREATE TABLE discord_cache.users (
    id text PRIMARY KEY,
    data jsonb NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT discord_cache_users_id_check CHECK (id <> ''),
    CONSTRAINT discord_cache_users_data_check CHECK (jsonb_typeof(data) = 'object')
);

CREATE TABLE discord_cache.members (
    guild_id text NOT NULL,
    user_id text NOT NULL,
    data jsonb NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT discord_cache_members_pkey PRIMARY KEY (guild_id, user_id),
    CONSTRAINT discord_cache_members_guild_id_check CHECK (guild_id <> ''),
    CONSTRAINT discord_cache_members_user_id_check CHECK (user_id <> ''),
    CONSTRAINT discord_cache_members_data_check CHECK (jsonb_typeof(data) = 'object')
);

CREATE INDEX idx_discord_cache_members_user
    ON discord_cache.members (user_id);

CREATE TABLE discord_cache.roles (
    guild_id text NOT NULL,
    id text NOT NULL,
    data jsonb NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT discord_cache_roles_pkey PRIMARY KEY (guild_id, id),
    CONSTRAINT discord_cache_roles_guild_id_check CHECK (guild_id <> ''),
    CONSTRAINT discord_cache_roles_id_check CHECK (id <> ''),
    CONSTRAINT discord_cache_roles_data_check CHECK (jsonb_typeof(data) = 'object')
);

CREATE INDEX idx_discord_cache_roles_id
    ON discord_cache.roles (id);

CREATE TABLE discord_cache.application_emojis (
    application_id text NOT NULL,
    logical_name text NOT NULL,
    discord_id text NOT NULL,
    discord_name text NOT NULL,
    animated boolean DEFAULT false NOT NULL,
    source_key text NOT NULL,
    source_updated_at timestamp with time zone NOT NULL,
    synced_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT discord_cache_application_emojis_pkey PRIMARY KEY (application_id, logical_name),
    CONSTRAINT discord_cache_application_emojis_application_id_check CHECK (application_id <> ''),
    CONSTRAINT discord_cache_application_emojis_logical_name_check
        CHECK (logical_name = lower(logical_name) AND logical_name ~ '^[a-z0-9_]{1,32}$'),
    CONSTRAINT discord_cache_application_emojis_discord_id_check CHECK (discord_id <> ''),
    CONSTRAINT discord_cache_application_emojis_discord_name_check
        CHECK (discord_name = lower(discord_name) AND discord_name ~ '^[a-z0-9_]{1,32}$'),
    CONSTRAINT discord_cache_application_emojis_source_key_check CHECK (source_key <> '')
);

CREATE UNIQUE INDEX idx_discord_cache_application_emojis_discord_id
    ON discord_cache.application_emojis (application_id, discord_id);

-- Section: invalid_discord_destinations
-- Retain permanently invalid destinations for repair. Reasons are bounded,
-- sanitized classifications, never provider payloads or webhook credentials.
ALTER TABLE public.server_logs
    ADD COLUMN disabled_reason text,
    ADD CONSTRAINT server_logs_disabled_reason_check CHECK
        (disabled_reason IS NULL OR (length(disabled_reason) BETWEEN 1 AND 256 AND disabled_reason = btrim(disabled_reason)));

ALTER TABLE public.reminders
    ADD COLUMN disabled boolean DEFAULT false NOT NULL,
    ADD COLUMN disabled_reason text,
    ADD CONSTRAINT reminders_disabled_reason_check CHECK
        (disabled_reason IS NULL OR (length(disabled_reason) BETWEEN 1 AND 256 AND disabled_reason = btrim(disabled_reason)));

ALTER TABLE public.giveaways
    ADD COLUMN disabled boolean DEFAULT false NOT NULL,
    ADD COLUMN disabled_reason text,
    ADD CONSTRAINT giveaways_disabled_reason_check CHECK
        (disabled_reason IS NULL OR (length(disabled_reason) BETWEEN 1 AND 256 AND disabled_reason = btrim(disabled_reason)));

-- Section: clan_capital_gold
ALTER TABLE public.basic_clan
    ADD COLUMN capital_gold_total bigint DEFAULT 0 NOT NULL;

DROP MATERIALIZED VIEW public.clan_leaderboards;

CREATE MATERIALIZED VIEW public.clan_leaderboards AS
 SELECT tag,
    location_id,
    rank() OVER (ORDER BY troops_donated DESC, tag) AS donated_rank,
    rank() OVER (ORDER BY troops_received DESC, tag) AS received_rank,
    rank() OVER (ORDER BY war_wins DESC, tag) AS war_wins_rank,
    rank() OVER (ORDER BY capital_gold_total DESC, tag) AS capital_gold_rank,
        CASE
            WHEN (war_wins >= 50) THEN rank() OVER (ORDER BY
            CASE
                WHEN (war_wins >= 50) THEN war_win_streak
                ELSE NULL::integer
            END DESC NULLS LAST, tag)
            ELSE NULL::bigint
        END AS war_win_streak_rank,
    rank() OVER (PARTITION BY location_id ORDER BY troops_donated DESC, tag) AS location_donated_rank,
    rank() OVER (PARTITION BY location_id ORDER BY troops_received DESC, tag) AS location_received_rank,
    rank() OVER (PARTITION BY location_id ORDER BY war_wins DESC, tag) AS location_war_wins_rank,
    rank() OVER (PARTITION BY location_id ORDER BY capital_gold_total DESC, tag) AS location_capital_gold_rank
   FROM public.basic_clan c
  WITH NO DATA;

CREATE UNIQUE INDEX idx_clan_leaderboards_tag ON public.clan_leaderboards USING btree (tag);
CREATE INDEX idx_clan_leaderboards_donated_rank ON public.clan_leaderboards USING btree (donated_rank);
CREATE INDEX idx_clan_leaderboards_received_rank ON public.clan_leaderboards USING btree (received_rank);
CREATE INDEX idx_clan_leaderboards_war_wins_rank ON public.clan_leaderboards USING btree (war_wins_rank);
CREATE INDEX idx_clan_leaderboards_capital_gold_rank ON public.clan_leaderboards USING btree (capital_gold_rank);
CREATE INDEX idx_clan_leaderboards_war_win_streak_rank ON public.clan_leaderboards USING btree (war_win_streak_rank) WHERE (war_win_streak_rank IS NOT NULL);
CREATE INDEX idx_clan_leaderboards_location_donated_rank ON public.clan_leaderboards USING btree (location_id, location_donated_rank);
CREATE INDEX idx_clan_leaderboards_location_received_rank ON public.clan_leaderboards USING btree (location_id, location_received_rank);
CREATE INDEX idx_clan_leaderboards_location_war_wins_rank ON public.clan_leaderboards USING btree (location_id, location_war_wins_rank);
CREATE INDEX idx_clan_leaderboards_location_capital_gold_rank ON public.clan_leaderboards USING btree (location_id, location_capital_gold_rank);

REFRESH MATERIALIZED VIEW public.clan_leaderboards;


-- Section: app_update_rollback
ALTER TABLE public.app_update_channels
    ADD COLUMN rollback_target_version text,
    ADD CONSTRAINT app_update_channels_rollback_target_check CHECK (
        rollback_target_version IS NULL
        OR (
            active_version IS NOT NULL
            AND rollback_target_version = btrim(rollback_target_version)
            AND rollback_target_version <> ''
            AND rollback_target_version <> active_version
            AND length(rollback_target_version) <= 80
        )
    );


-- Section: billing_customer_operations
-- Commit an operation identity before customer creation; never generate a new
-- identity simply because an external request timed out. Retry/reconciliation
-- and immutable operation/result handling are enforced by the billing API.
CREATE TABLE public.billing_customer_operations (
    user_id text PRIMARY KEY REFERENCES public.auth_users(user_id) ON DELETE CASCADE,
    operation_id uuid NOT NULL UNIQUE DEFAULT gen_random_uuid(),
    created_at timestamptz NOT NULL DEFAULT now(),
    stripe_customer_id text UNIQUE,
    updated_at timestamptz NOT NULL DEFAULT now()
);

-- Existing preferences win. Adding with true backfills existing rows atomically;
-- changing the default only affects future subscriptions awaiting activation.
ALTER TABLE public.billing_subscriptions
    ADD COLUMN initial_assignment_applied boolean NOT NULL DEFAULT true;
ALTER TABLE public.billing_subscriptions
    ALTER COLUMN initial_assignment_applied SET DEFAULT false;


-- Section: server_link_token_policy
-- Links-only policy: OFF for existing and new servers unless explicitly enabled.
-- The API verifies a supplied token on each new server-scoped linking attempt;
-- previously verified ownership does not bypass this server policy.
ALTER TABLE public.servers
    ADD COLUMN require_api_token_when_linking boolean NOT NULL DEFAULT false;

COMMENT ON COLUMN public.servers.require_api_token_when_linking IS
    'Require a valid supplied player API token for each new server-scoped linking attempt, including an already verified owner. Does not gate signup or filter linked accounts. Exact committed retries replay the original attempt.';


-- Section: canonical_ticket_configuration
-- ticket_panels is the sole live configuration model. The normalized tables
-- remain as inert import evidence; this migration never reconstructs live JSON
-- from their incomplete copies.
LOCK TABLE public.ticket_panels, public.ticket_panel, public.ticket_panel_buttons, public.tickets IN ACCESS EXCLUSIVE MODE;

-- +goose StatementBegin
DO $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM public.ticket_panels p
        JOIN public.ticket_panel legacy USING (server_id, name)
        GROUP BY p.server_id, p.name
        HAVING count(*) > 1
    ) THEN
        RAISE EXCEPTION 'ticket panel identity is ambiguous: multiple normalized panels match one live JSON panel';
    END IF;
    IF EXISTS (
        SELECT 1 FROM public.ticket_panels
        WHERE jsonb_typeof(components) <> 'array' OR jsonb_typeof(data) <> 'object'
    ) THEN
        RAISE EXCEPTION 'ticket panel JSON configuration has an invalid top-level shape';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM public.ticket_panels p
        CROSS JOIN LATERAL jsonb_array_elements(p.components) component
        WHERE jsonb_typeof(component) <> 'object'
           OR jsonb_typeof(component->'custom_id') IS DISTINCT FROM 'string'
           OR component->>'custom_id' = ''
           OR (component ? 'id' AND (
                jsonb_typeof(component->'id') IS DISTINCT FROM 'string'
                OR component->>'id' !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
           ))
    ) THEN
        RAISE EXCEPTION 'ticket panel component is missing a valid custom_id or contains an invalid UUID id';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM public.ticket_panels p
        CROSS JOIN LATERAL jsonb_array_elements(p.components) component
        GROUP BY p.server_id, p.name, component->>'custom_id'
        HAVING count(*) > 1
    ) THEN
        RAISE EXCEPTION 'ticket panel contains duplicate component custom_id values';
    END IF;
END
$$;
-- +goose StatementEnd

ALTER TABLE public.ticket_panels
    ADD COLUMN id uuid,
    ADD COLUMN archived_at timestamptz;

UPDATE public.ticket_panels live
SET id = COALESCE((
    SELECT legacy.id
    FROM public.ticket_panel legacy
    WHERE legacy.server_id = live.server_id AND legacy.name = live.name
), uuidv7());

ALTER TABLE public.ticket_panels ALTER COLUMN id SET NOT NULL;
ALTER TABLE public.ticket_panels ALTER COLUMN id SET DEFAULT uuidv7();
ALTER TABLE public.ticket_panels DROP CONSTRAINT ticket_panels_pkey;
ALTER TABLE public.ticket_panels ADD CONSTRAINT ticket_panels_pkey PRIMARY KEY (id);
ALTER TABLE public.ticket_panels ADD CONSTRAINT ticket_panels_id_server_id_key UNIQUE (id, server_id);
CREATE UNIQUE INDEX ticket_panels_active_server_name_key ON public.ticket_panels (server_id, name)
    WHERE archived_at IS NULL;
CREATE INDEX idx_ticket_panels_server_archive_name ON public.ticket_panels (server_id, archived_at, name);

-- Preserve every normalized identity that may be referenced by ticket history,
-- but never promote its partial configuration copy to a live panel.
INSERT INTO public.ticket_panels (id, server_id, name, components, data, created_at, updated_at, archived_at)
SELECT legacy.id, legacy.server_id, legacy.name, '[]'::jsonb, '{}'::jsonb,
       legacy.created_at, legacy.created_at, now()
FROM public.ticket_panel legacy
WHERE NOT EXISTS (SELECT 1 FROM public.ticket_panels canonical WHERE canonical.id = legacy.id);

-- Freeze one UUID per JSON component. Reuse the imported button UUID only when
-- the panel and custom_id identify exactly that legacy row.
CREATE TEMP TABLE ticket_component_identity (
    panel_id uuid NOT NULL,
    ordinal bigint NOT NULL,
    legacy_custom_id text NOT NULL,
    custom_id text NOT NULL,
    button_id uuid NOT NULL,
    PRIMARY KEY (panel_id, ordinal),
    UNIQUE (panel_id, custom_id),
    UNIQUE (button_id)
) ON COMMIT DROP;

WITH identity_candidates AS (
    SELECT panel.id AS panel_id, component.ordinality, component.value->>'custom_id' AS legacy_custom_id,
           COALESCE(legacy.id,
               CASE WHEN component.value ? 'id' THEN (component.value->>'id')::uuid END,
               uuidv7()) AS button_id
    FROM public.ticket_panels panel
    CROSS JOIN LATERAL jsonb_array_elements(panel.components) WITH ORDINALITY component(value, ordinality)
    LEFT JOIN public.ticket_panel_buttons legacy
      ON legacy.panel_id = panel.id AND legacy.custom_id = component.value->>'custom_id'
    WHERE panel.archived_at IS NULL
)
INSERT INTO ticket_component_identity (panel_id, ordinal, legacy_custom_id, custom_id, button_id)
SELECT panel_id, ordinality, legacy_custom_id,
       legacy_custom_id,
       button_id
FROM identity_candidates;

-- +goose StatementBegin
DO $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM public.ticket_panels panel
        JOIN ticket_component_identity identity ON identity.panel_id = panel.id
        JOIN LATERAL jsonb_array_elements(panel.components) WITH ORDINALITY component(value, ordinality)
          ON component.ordinality = identity.ordinal
        JOIN public.ticket_panel_buttons legacy
          ON legacy.panel_id = panel.id AND legacy.custom_id = identity.legacy_custom_id
        WHERE component.value ? 'id' AND (component.value->>'id')::uuid <> legacy.id
    ) THEN
        RAISE EXCEPTION 'ticket button identity is ambiguous: JSON and normalized UUIDs disagree';
    END IF;
END
$$;
-- +goose StatementEnd

-- Add stable internal button IDs without changing published Discord custom IDs
-- or their existing settings keys.
WITH rewritten AS (
    SELECT panel.id AS panel_id,
           jsonb_agg(jsonb_set(component.value, '{id}', to_jsonb(identity.button_id::text), true)
                     ORDER BY component.ordinality) AS components
    FROM public.ticket_panels panel
    JOIN ticket_component_identity identity ON identity.panel_id = panel.id
    JOIN LATERAL jsonb_array_elements(panel.components) WITH ORDINALITY component(value, ordinality)
      ON component.ordinality = identity.ordinal
    GROUP BY panel.id
)
UPDATE public.ticket_panels panel SET components = rewritten.components
FROM rewritten WHERE panel.id = rewritten.panel_id;

-- +goose StatementBegin
CREATE FUNCTION public.ticket_panel_configuration_valid(panel_id uuid, panel_components jsonb, panel_data jsonb)
RETURNS boolean LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE AS $$
DECLARE
    component jsonb;
    component_id text;
    custom_id text;
    ids text[] := '{}';
    custom_ids text[] := '{}';
BEGIN
    IF jsonb_typeof(panel_components) <> 'array' OR jsonb_typeof(panel_data) <> 'object' THEN
        RETURN false;
    END IF;
    FOR component IN SELECT value FROM jsonb_array_elements(panel_components) LOOP
        IF jsonb_typeof(component) <> 'object'
           OR jsonb_typeof(component->'id') IS DISTINCT FROM 'string'
           OR jsonb_typeof(component->'custom_id') IS DISTINCT FROM 'string' THEN
            RETURN false;
        END IF;
        component_id := component->>'id';
        custom_id := component->>'custom_id';
        IF custom_id = ''
           OR component_id !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
           OR component_id = ANY(ids) OR custom_id = ANY(custom_ids) THEN
            RETURN false;
        END IF;
        ids := array_append(ids, component_id);
        custom_ids := array_append(custom_ids, custom_id);
    END LOOP;
    RETURN true;
END
$$;
-- +goose StatementEnd

ALTER TABLE public.ticket_panels ADD CONSTRAINT ticket_panels_configuration_check
    CHECK (public.ticket_panel_configuration_valid(id, components, data));

-- +goose StatementBegin
CREATE FUNCTION public.guard_canonical_ticket_panel() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'ticket panel identities are archived, not deleted' USING ERRCODE = '23514';
    END IF;
    IF ROW(NEW.id, NEW.server_id, NEW.created_at)
       IS DISTINCT FROM ROW(OLD.id, OLD.server_id, OLD.created_at) THEN
        RAISE EXCEPTION 'ticket panel identity is immutable' USING ERRCODE = '23514';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM jsonb_array_elements(OLD.components) old_component
        JOIN jsonb_array_elements(NEW.components) new_component
          ON old_component->>'custom_id' = new_component->>'custom_id'
        WHERE old_component->>'id' IS DISTINCT FROM new_component->>'id'
    ) OR EXISTS (
        SELECT 1
        FROM jsonb_array_elements(OLD.components) old_component
        JOIN jsonb_array_elements(NEW.components) new_component
          ON old_component->>'id' = new_component->>'id'
        WHERE old_component->>'custom_id' IS DISTINCT FROM new_component->>'custom_id'
    ) THEN
        RAISE EXCEPTION 'ticket button identity is immutable' USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END
$$;
-- +goose StatementEnd
CREATE TRIGGER guard_canonical_ticket_panel
    BEFORE UPDATE OR DELETE ON public.ticket_panels
    FOR EACH ROW EXECUTE FUNCTION public.guard_canonical_ticket_panel();

ALTER TABLE public.tickets DROP CONSTRAINT tickets_panel_id_fkey;
ALTER TABLE public.tickets ADD CONSTRAINT tickets_panel_id_fkey
    FOREIGN KEY (panel_id, server_id) REFERENCES public.ticket_panels(id, server_id) ON DELETE RESTRICT;

COMMENT ON TABLE public.ticket_panels IS 'Canonical ticket panel configuration; archived rows retain stable history identities.';
COMMENT ON TABLE public.ticket_panel IS 'Deprecated imported ticket panel copy; not a live configuration source after migration 007.';
COMMENT ON TABLE public.ticket_panel_buttons IS 'Deprecated imported ticket button copy; not a live configuration source after migration 007.';


-- +goose Down
-- +goose StatementBegin
DO $$
BEGIN
    RAISE EXCEPTION 'migration 007 is irreversible: retain coordination identities, billing state and enabled linking policies; use a reviewed forward migration';
END
$$;
-- +goose StatementEnd
