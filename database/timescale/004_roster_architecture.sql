-- +goose Up

-- Roster signup questions are application-defined, but their persisted envelope
-- is deliberately strict: the account selector is implicit in roster_members,
-- so only the four configurable questions belong in this array.
-- +goose StatementBegin
CREATE OR REPLACE FUNCTION public.ck_valid_roster_signup_questions(value jsonb)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
STRICT
AS $$
DECLARE
    question jsonb;
    option_value jsonb;
    seen_ids text[] := ARRAY[]::text[];
    seen_orders integer[] := ARRAY[]::integer[];
    question_id text;
    question_order integer;
BEGIN
    IF jsonb_typeof(value) <> 'array' OR jsonb_array_length(value) > 4 THEN
        RETURN false;
    END IF;

    FOR question IN SELECT item FROM jsonb_array_elements(value) AS items(item)
    LOOP
        IF jsonb_typeof(question) <> 'object'
           OR jsonb_typeof(question -> 'id') IS DISTINCT FROM 'string'
           OR jsonb_typeof(question -> 'type') IS DISTINCT FROM 'string'
           OR jsonb_typeof(question -> 'label') IS DISTINCT FROM 'string'
           OR jsonb_typeof(question -> 'required') IS DISTINCT FROM 'boolean'
           OR jsonb_typeof(question -> 'options') IS DISTINCT FROM 'array'
           OR jsonb_typeof(question -> 'order') IS DISTINCT FROM 'number'
           OR (question ? 'ai_description'
               AND jsonb_typeof(question -> 'ai_description') IS DISTINCT FROM 'string') THEN
            RETURN false;
        END IF;

        question_id := question ->> 'id';
        IF question_id !~ '^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$'
           OR lower(question_id) = ANY (
               ARRAY['account', 'account_selector', 'player', 'player_selector']
           )
           OR question_id = ANY (seen_ids) THEN
            RETURN false;
        END IF;

        IF btrim(question ->> 'type') = ''
           OR lower(question ->> 'type') = ANY (
               ARRAY['account', 'account_selector', 'player', 'player_selector']
           )
           OR btrim(question ->> 'label') = ''
           OR (question ->> 'order') !~ '^[0-9]+$' THEN
            RETURN false;
        END IF;

        question_order := (question ->> 'order')::integer;
        IF question_order = ANY (seen_orders) THEN
            RETURN false;
        END IF;

        FOR option_value IN
            SELECT item FROM jsonb_array_elements(question -> 'options') AS options(item)
        LOOP
            IF jsonb_typeof(option_value) <> 'string'
               OR btrim(option_value #>> '{}') = '' THEN
                RETURN false;
            END IF;
        END LOOP;

        seen_ids := array_append(seen_ids, question_id);
        seen_orders := array_append(seen_orders, question_order);
    END LOOP;

    RETURN true;
END;
$$;
-- +goose StatementEnd

-- +goose StatementBegin
CREATE OR REPLACE FUNCTION public.ck_valid_roster_heroes(value jsonb)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
STRICT
AS $$
DECLARE
    hero jsonb;
BEGIN
    IF jsonb_typeof(value) <> 'array' THEN
        RETURN false;
    END IF;

    FOR hero IN SELECT item FROM jsonb_array_elements(value) AS heroes(item)
    LOOP
        IF jsonb_typeof(hero) <> 'object'
           OR jsonb_typeof(hero -> 'name') IS DISTINCT FROM 'string'
           OR btrim(hero ->> 'name') = ''
           OR jsonb_typeof(hero -> 'level') IS DISTINCT FROM 'number'
           OR (hero ->> 'level') !~ '^[0-9]+$'
           OR (hero ? 'id' AND jsonb_typeof(hero -> 'id') NOT IN ('number', 'string'))
           OR (hero ? 'max_level' AND (
               jsonb_typeof(hero -> 'max_level') <> 'number'
               OR (hero ->> 'max_level') !~ '^[0-9]+$'
               OR (hero ->> 'max_level')::integer < (hero ->> 'level')::integer
           ))
           OR (hero ? 'village' AND jsonb_typeof(hero -> 'village') <> 'string') THEN
            RETURN false;
        END IF;
    END LOOP;

    RETURN true;
END;
$$;
-- +goose StatementEnd

-- +goose StatementBegin
CREATE OR REPLACE FUNCTION public.ck_valid_roster_view_spec(value jsonb)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
STRICT
AS $$
DECLARE
    column_definition jsonb;
BEGIN
    IF jsonb_typeof(value) <> 'object'
       OR jsonb_typeof(value -> 'schemaVersion') IS DISTINCT FROM 'number'
       OR (value ->> 'schemaVersion') !~ '^[1-9][0-9]*$'
       OR jsonb_typeof(value -> 'columns') IS DISTINCT FROM 'array'
       OR jsonb_array_length(value -> 'columns') = 0
       OR value ? 'rosterIds'
       OR (value ? 'filters' AND jsonb_typeof(value -> 'filters') <> 'array')
       OR (value ? 'sort' AND jsonb_typeof(value -> 'sort') <> 'array')
       OR (value ? 'limit' AND (
           jsonb_typeof(value -> 'limit') <> 'number'
           OR (value ->> 'limit') !~ '^[1-9][0-9]*$'
       )) THEN
        RETURN false;
    END IF;

    FOR column_definition IN
        SELECT item FROM jsonb_array_elements(value -> 'columns') AS columns(item)
    LOOP
        IF jsonb_typeof(column_definition) <> 'object'
           OR jsonb_typeof(column_definition -> 'id') IS DISTINCT FROM 'string'
           OR btrim(column_definition ->> 'id') = ''
           OR jsonb_typeof(column_definition -> 'label') IS DISTINCT FROM 'string'
           OR btrim(column_definition ->> 'label') = ''
           OR jsonb_typeof(column_definition -> 'metricId') IS DISTINCT FROM 'string'
           OR btrim(column_definition ->> 'metricId') = '' THEN
            RETURN false;
        END IF;
    END LOOP;

    RETURN true;
END;
$$;
-- +goose StatementEnd

ALTER TABLE public.rosters
    ADD COLUMN IF NOT EXISTS signup_questions jsonb NOT NULL DEFAULT '[]'::jsonb;

ALTER TABLE public.rosters
    DROP CONSTRAINT IF EXISTS rosters_signup_questions_check,
    ADD CONSTRAINT rosters_signup_questions_check
        CHECK (public.ck_valid_roster_signup_questions(signup_questions));

COMMENT ON COLUMN public.rosters.signup_questions IS
    'At most four configurable question definitions. Each definition has a unique stable id and order plus type, label, required, options, and optional ai_description. The account selector is implicit and must not be stored here.';

-- Preserve organizational roster card groups. Remove only the superseded
-- signup-category model and its roster/group bindings.
DROP TABLE IF EXISTS public.roster_group_allowed_signup_categories;
DROP TABLE IF EXISTS public.roster_allowed_signup_categories;
DROP TABLE IF EXISTS public.roster_signup_categories;

ALTER TABLE public.rosters
    DROP COLUMN IF EXISTS default_signup_category;

ALTER TABLE public.roster_groups
    DROP COLUMN IF EXISTS default_signup_category;

ALTER TABLE public.roster_members
    ADD COLUMN IF NOT EXISTS signup_answers jsonb NOT NULL DEFAULT '{}'::jsonb,
    ADD COLUMN IF NOT EXISTS league_id integer,
    ADD COLUMN IF NOT EXISTS league_name text,
    ADD COLUMN IF NOT EXISTS heroes jsonb NOT NULL DEFAULT '[]'::jsonb,
    ADD COLUMN IF NOT EXISTS max_percent numeric(5, 2),
    ADD COLUMN IF NOT EXISTS max_percent_calc_version text,
    ADD COLUMN IF NOT EXISTS max_percent_calculated_at timestamp with time zone,
    ADD COLUMN IF NOT EXISTS discord_display_name text,
    ADD COLUMN IF NOT EXISTS refreshed_at timestamp with time zone,
    ADD COLUMN IF NOT EXISTS refresh_error text;

-- +goose StatementBegin
DO $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'roster_members'
          AND column_name = 'current_league'
    ) THEN
        EXECUTE $sql$
            UPDATE public.roster_members
            SET league_name = current_league
            WHERE league_name IS NULL
              AND COALESCE(btrim(current_league), '') <> ''
        $sql$;
    END IF;

    IF EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'roster_members'
          AND column_name = 'last_online'
          AND data_type = 'bigint'
    ) THEN
        EXECUTE $sql$
            ALTER TABLE public.roster_members
            ALTER COLUMN last_online TYPE timestamp with time zone
            USING CASE
                WHEN last_online IS NULL THEN NULL
                WHEN last_online > 100000000000 THEN to_timestamp(last_online::double precision / 1000.0)
                ELSE to_timestamp(last_online::double precision)
            END
        $sql$;
    END IF;
END;
$$;
-- +goose StatementEnd

ALTER TABLE public.roster_members
    DROP COLUMN IF EXISTS substitute,
    DROP COLUMN IF EXISTS signup_group,
    DROP COLUMN IF EXISTS hero_levels,
    DROP COLUMN IF EXISTS current_league,
    DROP COLUMN IF EXISTS last_updated,
    DROP COLUMN IF EXISTS error_details;

ALTER TABLE public.roster_members
    DROP CONSTRAINT IF EXISTS roster_members_signup_answers_check,
    DROP CONSTRAINT IF EXISTS roster_members_league_check,
    DROP CONSTRAINT IF EXISTS roster_members_heroes_check,
    DROP CONSTRAINT IF EXISTS roster_members_max_percent_check,
    DROP CONSTRAINT IF EXISTS roster_members_refresh_error_check,
    ADD CONSTRAINT roster_members_signup_answers_check
        CHECK (jsonb_typeof(signup_answers) = 'object'),
    ADD CONSTRAINT roster_members_league_check CHECK (
        (league_id IS NULL OR league_id > 0)
        AND (league_name IS NULL OR btrim(league_name) <> '')
        AND (league_id IS NULL OR league_name IS NOT NULL)
    ),
    ADD CONSTRAINT roster_members_heroes_check
        CHECK (public.ck_valid_roster_heroes(heroes)),
    ADD CONSTRAINT roster_members_max_percent_check CHECK (
        (max_percent IS NULL
         AND max_percent_calc_version IS NULL
         AND max_percent_calculated_at IS NULL)
        OR (max_percent BETWEEN 0 AND 100
            AND COALESCE(btrim(max_percent_calc_version), '') <> ''
            AND max_percent_calculated_at IS NOT NULL)
    ),
    ADD CONSTRAINT roster_members_refresh_error_check CHECK (
        refresh_error IS NULL OR char_length(refresh_error) <= 2000
    );

COMMENT ON COLUMN public.roster_members.signup_answers IS
    'Answers keyed by the stable IDs in rosters.signup_questions. The selected account is represented by this roster member row, not duplicated in the answer object.';
COMMENT ON COLUMN public.roster_members.heroes IS
    'Player snapshot hero array. Each object requires name and level and may include stable id, max_level, and village.';
COMMENT ON COLUMN public.roster_members.max_percent IS
    'Versioned calculated progression percentage. Writers must update calc version and calculated timestamp in the same statement.';
COMMENT ON COLUMN public.roster_members.refreshed_at IS
    'Database-visible time at which this player snapshot was last refreshed from its authoritative sources.';
COMMENT ON COLUMN public.roster_members.refresh_error IS
    'Most recent refresh failure summary; never store raw upstream payloads or credentials.';

-- +goose StatementBegin
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conrelid = 'public.rosters'::regclass
          AND conname = 'rosters_id_server_id_key'
    ) THEN
        ALTER TABLE public.rosters
            ADD CONSTRAINT rosters_id_server_id_key UNIQUE (id, server_id);
    END IF;
END;
$$;
-- +goose StatementEnd

CREATE TABLE IF NOT EXISTS public.roster_views (
    id uuid DEFAULT uuidv7() NOT NULL,
    server_id text NOT NULL,
    name text NOT NULL,
    intent text NOT NULL,
    spec_version smallint NOT NULL,
    spec jsonb NOT NULL,
    original_prompt text,
    provenance jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_by_discord_user_id text NOT NULL,
    data_watermark timestamp with time zone,
    created_at timestamp with time zone NOT NULL DEFAULT now(),
    updated_at timestamp with time zone NOT NULL DEFAULT now(),
    CONSTRAINT roster_views_pkey PRIMARY KEY (id),
    CONSTRAINT roster_views_id_server_id_key UNIQUE (id, server_id),
    CONSTRAINT roster_views_server_id_name_key UNIQUE (server_id, name),
    CONSTRAINT roster_views_server_id_fkey
        FOREIGN KEY (server_id) REFERENCES public.servers(id) ON DELETE CASCADE,
    CONSTRAINT roster_views_name_check CHECK (btrim(name) <> ''),
    CONSTRAINT roster_views_intent_check CHECK (btrim(intent) <> ''),
    CONSTRAINT roster_views_spec_version_check CHECK (spec_version > 0),
    CONSTRAINT roster_views_spec_check CHECK (
        public.ck_valid_roster_view_spec(spec)
        AND spec_version::text = spec ->> 'schemaVersion'
    ),
    CONSTRAINT roster_views_provenance_check CHECK (jsonb_typeof(provenance) = 'object'),
    CONSTRAINT roster_views_creator_check CHECK (btrim(created_by_discord_user_id) <> ''),
    CONSTRAINT roster_views_timestamps_check CHECK (updated_at >= created_at)
);

CREATE INDEX IF NOT EXISTS idx_roster_views_server_updated
    ON public.roster_views (server_id, updated_at DESC);

COMMENT ON TABLE public.roster_views IS
    'Server-scoped saved roster projections. spec_version must match spec.schemaVersion; the typed spec stores columns, filters, sort, and limit while roster references remain normalized.';
COMMENT ON COLUMN public.roster_views.original_prompt IS
    'Original user prompt when a view was generated or materially revised; nullable for fully manual views.';
COMMENT ON COLUMN public.roster_views.provenance IS
    'Structured generation/edit provenance only. Do not store credentials or raw private model traces.';
COMMENT ON COLUMN public.roster_views.data_watermark IS
    'Newest source snapshot included by the last successful materialization/render, independent of updated_at configuration changes.';

CREATE TABLE IF NOT EXISTS public.roster_view_rosters (
    view_id uuid NOT NULL,
    roster_id uuid NOT NULL,
    server_id text NOT NULL,
    position integer NOT NULL DEFAULT 0,
    CONSTRAINT roster_view_rosters_pkey PRIMARY KEY (view_id, roster_id),
    CONSTRAINT roster_view_rosters_view_position_key UNIQUE (view_id, position),
    CONSTRAINT roster_view_rosters_position_check CHECK (position >= 0),
    CONSTRAINT roster_view_rosters_view_fkey
        FOREIGN KEY (view_id, server_id)
        REFERENCES public.roster_views(id, server_id) ON DELETE CASCADE,
    CONSTRAINT roster_view_rosters_roster_fkey
        FOREIGN KEY (roster_id, server_id)
        REFERENCES public.rosters(id, server_id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_roster_view_rosters_roster
    ON public.roster_view_rosters (roster_id, view_id);

COMMENT ON TABLE public.roster_view_rosters IS
    'Normalized roster references for integrity, reverse lookup, stable ordering, and same-server enforcement; roster IDs are not duplicated inside view specs.';

CREATE TABLE IF NOT EXISTS public.roster_live_posts (
    id uuid DEFAULT uuidv7() NOT NULL,
    view_id uuid NOT NULL,
    server_id text NOT NULL,
    channel_id text NOT NULL,
    webhook_id text NOT NULL,
    webhook_token_ciphertext bytea,
    webhook_secret_ref text,
    message_id text NOT NULL,
    last_render_hash text,
    update_state text NOT NULL DEFAULT 'pending',
    last_update_attempt_at timestamp with time zone,
    last_updated_at timestamp with time zone,
    last_update_error text,
    created_at timestamp with time zone NOT NULL DEFAULT now(),
    updated_at timestamp with time zone NOT NULL DEFAULT now(),
    CONSTRAINT roster_live_posts_pkey PRIMARY KEY (id),
    CONSTRAINT roster_live_posts_message_key UNIQUE (server_id, channel_id, message_id),
    CONSTRAINT roster_live_posts_view_fkey
        FOREIGN KEY (view_id, server_id)
        REFERENCES public.roster_views(id, server_id) ON DELETE CASCADE,
    CONSTRAINT roster_live_posts_ids_check CHECK (
        btrim(channel_id) <> '' AND btrim(webhook_id) <> '' AND btrim(message_id) <> ''
    ),
    CONSTRAINT roster_live_posts_secret_check CHECK (
        (webhook_token_ciphertext IS NOT NULL AND octet_length(webhook_token_ciphertext) > 0
         AND webhook_secret_ref IS NULL)
        OR (webhook_token_ciphertext IS NULL
            AND COALESCE(btrim(webhook_secret_ref), '') <> '')
    ),
    CONSTRAINT roster_live_posts_hash_check CHECK (
        last_render_hash IS NULL OR last_render_hash ~ '^[0-9a-f]{64}$'
    ),
    CONSTRAINT roster_live_posts_update_state_check CHECK (
        update_state = ANY (ARRAY['pending'::text, 'updating'::text, 'succeeded'::text, 'failed'::text])
    ),
    CONSTRAINT roster_live_posts_timestamps_check CHECK (
        updated_at >= created_at
        AND (last_updated_at IS NULL OR last_update_attempt_at IS NOT NULL)
        AND (update_state <> 'succeeded' OR last_updated_at IS NOT NULL)
        AND (update_state <> 'failed' OR COALESCE(btrim(last_update_error), '') <> '')
    )
);

CREATE INDEX IF NOT EXISTS idx_roster_live_posts_view
    ON public.roster_live_posts (view_id, updated_at DESC);
CREATE INDEX IF NOT EXISTS idx_roster_live_posts_update_state
    ON public.roster_live_posts (update_state, last_update_attempt_at);

COMMENT ON TABLE public.roster_live_posts IS
    'Discord live-message bindings for saved roster views. A binding stores either an application-encrypted webhook token envelope or a secret-manager reference, never plaintext.';
COMMENT ON COLUMN public.roster_live_posts.webhook_token_ciphertext IS
    'Opaque application-encrypted webhook token envelope. The database cannot prove encryption; API writers must encrypt before insert.';
COMMENT ON COLUMN public.roster_live_posts.last_render_hash IS
    'Lowercase hexadecimal SHA-256 of the canonical rendered payload, used to skip unchanged Discord edits.';

CREATE TABLE IF NOT EXISTS public.cwl_bonus_award_rules (
    ruleset_version text NOT NULL,
    league_id integer NOT NULL,
    war_size smallint NOT NULL,
    effective_from_season text NOT NULL,
    effective_through_season text,
    base_award_slots smallint NOT NULL,
    documented_by_discord_user_id text NOT NULL,
    documented_at timestamp with time zone NOT NULL DEFAULT now(),
    CONSTRAINT cwl_bonus_award_rules_pkey
        PRIMARY KEY (ruleset_version, league_id, war_size),
    CONSTRAINT cwl_bonus_award_rules_version_check
        CHECK (btrim(ruleset_version) <> ''),
    CONSTRAINT cwl_bonus_award_rules_scope_check
        CHECK (league_id > 0 AND war_size > 0 AND base_award_slots >= 0),
    CONSTRAINT cwl_bonus_award_rules_seasons_check CHECK (
        effective_from_season ~ '^[0-9]{4}-(0[1-9]|1[0-2])$'
        AND (effective_through_season IS NULL OR (
            effective_through_season ~ '^[0-9]{4}-(0[1-9]|1[0-2])$'
            AND effective_through_season >= effective_from_season
        ))
    ),
    CONSTRAINT cwl_bonus_award_rules_actor_check
        CHECK (btrim(documented_by_discord_user_id) <> '')
);

CREATE INDEX IF NOT EXISTS idx_cwl_bonus_award_rules_effective
    ON public.cwl_bonus_award_rules
    (league_id, war_size, effective_from_season, effective_through_season);

CREATE TABLE IF NOT EXISTS public.cwl_bonus_award_submissions (
    id uuid DEFAULT uuidv7() NOT NULL,
    server_id text NOT NULL,
    season text NOT NULL,
    clan_tag text NOT NULL,
    clan_name text NOT NULL,
    revision integer NOT NULL,
    supersedes_id uuid,
    ruleset_version text NOT NULL,
    league_id integer NOT NULL,
    league_name text NOT NULL,
    war_size smallint NOT NULL,
    final_placement smallint NOT NULL,
    wars_won smallint NOT NULL,
    base_award_slots smallint NOT NULL,
    award_slot_count smallint NOT NULL,
    override_reason text,
    correction_reason text,
    idempotency_key text NOT NULL,
    submitted_by_discord_user_id text NOT NULL,
    submitted_at timestamp with time zone NOT NULL DEFAULT now(),
    CONSTRAINT cwl_bonus_award_submissions_pkey PRIMARY KEY (id),
    CONSTRAINT cwl_bonus_award_submissions_server_id_fkey
        FOREIGN KEY (server_id) REFERENCES public.servers(id) ON DELETE RESTRICT,
    CONSTRAINT cwl_bonus_award_submissions_supersedes_fkey
        FOREIGN KEY (supersedes_id)
        REFERENCES public.cwl_bonus_award_submissions(id) ON DELETE RESTRICT,
    CONSTRAINT cwl_bonus_award_submissions_rules_fkey
        FOREIGN KEY (ruleset_version, league_id, war_size)
        REFERENCES public.cwl_bonus_award_rules(ruleset_version, league_id, war_size)
        ON DELETE RESTRICT,
    CONSTRAINT cwl_bonus_award_submissions_revision_key
        UNIQUE (server_id, season, clan_tag, revision),
    CONSTRAINT cwl_bonus_award_submissions_supersedes_key UNIQUE (supersedes_id),
    CONSTRAINT cwl_bonus_award_submissions_idempotency_key
        UNIQUE (server_id, idempotency_key),
    CONSTRAINT cwl_bonus_award_submissions_season_check
        CHECK (season ~ '^[0-9]{4}-(0[1-9]|1[0-2])$'),
    CONSTRAINT cwl_bonus_award_submissions_clan_check
        CHECK (btrim(clan_tag) <> '' AND btrim(clan_name) <> ''),
    CONSTRAINT cwl_bonus_award_submissions_snapshot_check CHECK (
        league_id > 0
        AND btrim(league_name) <> ''
        AND war_size > 0
        AND final_placement > 0
        AND wars_won >= 0
        AND base_award_slots >= 0
        AND award_slot_count >= 0
    ),
    CONSTRAINT cwl_bonus_award_submissions_formula_check CHECK (
        (award_slot_count = base_award_slots + wars_won AND override_reason IS NULL)
        OR (award_slot_count <> base_award_slots + wars_won
            AND COALESCE(btrim(override_reason), '') <> '')
    ),
    CONSTRAINT cwl_bonus_award_submissions_correction_check CHECK (
        (revision = 1 AND supersedes_id IS NULL AND correction_reason IS NULL)
        OR (revision > 1 AND supersedes_id IS NOT NULL
            AND COALESCE(btrim(correction_reason), '') <> '')
    ),
    CONSTRAINT cwl_bonus_award_submissions_audit_check CHECK (
        btrim(ruleset_version) <> ''
        AND btrim(idempotency_key) <> ''
        AND btrim(submitted_by_discord_user_id) <> ''
    )
);

CREATE INDEX IF NOT EXISTS idx_cwl_bonus_award_submissions_server_season
    ON public.cwl_bonus_award_submissions
    (server_id, season DESC, clan_tag, revision DESC);
CREATE INDEX IF NOT EXISTS idx_cwl_bonus_award_submissions_clan_season
    ON public.cwl_bonus_award_submissions (clan_tag, season DESC, revision DESC);

CREATE TABLE IF NOT EXISTS public.cwl_bonus_award_recipients (
    submission_id uuid NOT NULL,
    player_tag text NOT NULL,
    player_name text NOT NULL,
    position smallint NOT NULL,
    selected_by_discord_user_id text NOT NULL,
    selected_at timestamp with time zone NOT NULL DEFAULT now(),
    CONSTRAINT cwl_bonus_award_recipients_pkey
        PRIMARY KEY (submission_id, player_tag),
    CONSTRAINT cwl_bonus_award_recipients_position_key
        UNIQUE (submission_id, position),
    CONSTRAINT cwl_bonus_award_recipients_submission_fkey
        FOREIGN KEY (submission_id)
        REFERENCES public.cwl_bonus_award_submissions(id) ON DELETE RESTRICT,
    CONSTRAINT cwl_bonus_award_recipients_player_check
        CHECK (btrim(player_tag) <> '' AND btrim(player_name) <> ''),
    CONSTRAINT cwl_bonus_award_recipients_position_check CHECK (position > 0),
    CONSTRAINT cwl_bonus_award_recipients_actor_check
        CHECK (btrim(selected_by_discord_user_id) <> '')
);

CREATE INDEX IF NOT EXISTS idx_cwl_bonus_award_recipients_player
    ON public.cwl_bonus_award_recipients (player_tag, selected_at DESC);

-- +goose StatementBegin
CREATE OR REPLACE FUNCTION public.ck_validate_cwl_bonus_submission()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    rule public.cwl_bonus_award_rules%ROWTYPE;
    prior public.cwl_bonus_award_submissions%ROWTYPE;
BEGIN
    SELECT * INTO rule
    FROM public.cwl_bonus_award_rules
    WHERE ruleset_version = NEW.ruleset_version
      AND league_id = NEW.league_id
      AND war_size = NEW.war_size;

    IF NOT FOUND
       OR NEW.season < rule.effective_from_season
       OR (rule.effective_through_season IS NOT NULL
           AND NEW.season > rule.effective_through_season)
       OR NEW.base_award_slots <> rule.base_award_slots THEN
        RAISE EXCEPTION 'CWL bonus submission does not match its effective ruleset';
    END IF;

    IF NEW.supersedes_id IS NOT NULL THEN
        SELECT * INTO prior
        FROM public.cwl_bonus_award_submissions
        WHERE id = NEW.supersedes_id;

        IF NOT FOUND
           OR prior.server_id <> NEW.server_id
           OR prior.season <> NEW.season
           OR prior.clan_tag <> NEW.clan_tag
           OR prior.revision <> NEW.revision - 1 THEN
            RAISE EXCEPTION 'CWL bonus correction must supersede the immediately prior revision for the same server, season, and clan';
        END IF;
    END IF;

    RETURN NEW;
END;
$$;
-- +goose StatementEnd

-- +goose StatementBegin
CREATE OR REPLACE FUNCTION public.ck_validate_cwl_bonus_recipient()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    allowed_count integer;
    existing_count integer;
    submission_created_in_this_transaction boolean;
BEGIN
    SELECT award_slot_count, xmin::text = pg_current_xact_id()::text
    INTO allowed_count, submission_created_in_this_transaction
    FROM public.cwl_bonus_award_submissions
    WHERE id = NEW.submission_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'CWL bonus submission does not exist';
    END IF;

    SELECT count(*) INTO existing_count
    FROM public.cwl_bonus_award_recipients
    WHERE submission_id = NEW.submission_id;

    IF NOT submission_created_in_this_transaction THEN
        RAISE EXCEPTION 'CWL bonus recipients must be inserted in the same transaction as their immutable submission';
    END IF;

    IF NEW.position > allowed_count OR existing_count >= allowed_count THEN
        RAISE EXCEPTION 'CWL bonus recipient exceeds the snapshotted award slot count';
    END IF;

    RETURN NEW;
END;
$$;
-- +goose StatementEnd

-- +goose StatementBegin
CREATE OR REPLACE FUNCTION public.ck_reject_cwl_bonus_mutation()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION 'CWL bonus award ledger rows are immutable; append a corrected submission revision';
END;
$$;
-- +goose StatementEnd

DROP TRIGGER IF EXISTS cwl_bonus_award_submissions_validate
    ON public.cwl_bonus_award_submissions;
CREATE TRIGGER cwl_bonus_award_submissions_validate
BEFORE INSERT ON public.cwl_bonus_award_submissions
FOR EACH ROW EXECUTE FUNCTION public.ck_validate_cwl_bonus_submission();

DROP TRIGGER IF EXISTS cwl_bonus_award_recipients_validate
    ON public.cwl_bonus_award_recipients;
CREATE TRIGGER cwl_bonus_award_recipients_validate
BEFORE INSERT ON public.cwl_bonus_award_recipients
FOR EACH ROW EXECUTE FUNCTION public.ck_validate_cwl_bonus_recipient();

DROP TRIGGER IF EXISTS cwl_bonus_award_rules_immutable
    ON public.cwl_bonus_award_rules;
CREATE TRIGGER cwl_bonus_award_rules_immutable
BEFORE UPDATE OR DELETE ON public.cwl_bonus_award_rules
FOR EACH ROW EXECUTE FUNCTION public.ck_reject_cwl_bonus_mutation();

DROP TRIGGER IF EXISTS cwl_bonus_award_submissions_immutable
    ON public.cwl_bonus_award_submissions;
CREATE TRIGGER cwl_bonus_award_submissions_immutable
BEFORE UPDATE OR DELETE ON public.cwl_bonus_award_submissions
FOR EACH ROW EXECUTE FUNCTION public.ck_reject_cwl_bonus_mutation();

DROP TRIGGER IF EXISTS cwl_bonus_award_recipients_immutable
    ON public.cwl_bonus_award_recipients;
CREATE TRIGGER cwl_bonus_award_recipients_immutable
BEFORE UPDATE OR DELETE ON public.cwl_bonus_award_recipients
FOR EACH ROW EXECUTE FUNCTION public.ck_reject_cwl_bonus_mutation();

COMMENT ON TABLE public.cwl_bonus_award_rules IS
    'Immutable effective-dated league/war-size base award slots. A changed formula is a new ruleset version, never an in-place update.';
COMMENT ON TABLE public.cwl_bonus_award_submissions IS
    'Immutable server-scoped revision ledger. Award slots snapshot the effective base plus wars won unless an explicit override reason is recorded; final placement is completion evidence only.';
COMMENT ON TABLE public.cwl_bonus_award_recipients IS
    'Immutable normalized recipients inserted in the same transaction as one award submission revision. Corrections append a new submission and recipient set.';

-- Validation queries for an applied environment:
-- SELECT count(*) FROM public.rosters
-- WHERE NOT public.ck_valid_roster_signup_questions(signup_questions);
-- SELECT count(*) FROM public.roster_members
-- WHERE jsonb_typeof(signup_answers) <> 'object'
--    OR NOT public.ck_valid_roster_heroes(heroes);
-- SELECT view_id FROM public.roster_view_rosters
-- GROUP BY view_id HAVING count(*) <> count(DISTINCT roster_id);
-- SELECT s.id, s.award_slot_count, count(r.player_tag) AS recipients
-- FROM public.cwl_bonus_award_submissions s
-- LEFT JOIN public.cwl_bonus_award_recipients r ON r.submission_id = s.id
-- GROUP BY s.id HAVING count(r.player_tag) > s.award_slot_count;
-- SELECT s.id FROM public.cwl_bonus_award_submissions s
-- LEFT JOIN public.cwl_bonus_award_rules rules
--   ON rules.ruleset_version = s.ruleset_version
--  AND rules.league_id = s.league_id AND rules.war_size = s.war_size
-- WHERE rules.ruleset_version IS NULL OR s.base_award_slots <> rules.base_award_slots
--    OR s.season < rules.effective_from_season
--    OR (rules.effective_through_season IS NOT NULL
--        AND s.season > rules.effective_through_season);

-- +goose Down

-- This migration deliberately removes signup-category/substitute data and
-- changes last_online from an epoch integer to timestamptz. A mechanical Down
-- would manufacture empty legacy contracts and imply recoverability that does
-- not exist. Restore from a pre-migration backup if the architecture must be
-- rolled back.
-- +goose StatementBegin
DO $$
BEGIN
    RAISE EXCEPTION 'migration 004 is irreversible; restore a pre-migration backup';
END;
$$;
-- +goose StatementEnd
