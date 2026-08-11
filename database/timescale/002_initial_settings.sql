-- +goose Up
CREATE EXTENSION IF NOT EXISTS pgcrypto;

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SET search_path = public;
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

-- +goose StatementBegin
--
-- Name: ck_valid_roster_signup_questions(jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.ck_valid_roster_signup_questions(value jsonb) RETURNS boolean
    LANGUAGE plpgsql IMMUTABLE STRICT
    AS $_$
DECLARE
    question jsonb;
    option_value jsonb;
    seen_ids text[] := ARRAY[]::text[];
    seen_orders integer[] := ARRAY[]::integer[];
    question_id text;
    question_type text;
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
           OR question ? 'ai_description' THEN
            RETURN false;
        END IF;

        question_id := question ->> 'id';
        question_type := question ->> 'type';
        IF question_id !~ '^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$'
           OR lower(question_id) = ANY (ARRAY['account', 'account_selector', 'player', 'player_selector'])
           OR question_id = ANY (seen_ids)
           OR question_type <> ALL (ARRAY['text', 'boolean', 'single_select'])
           OR btrim(question ->> 'label') = ''
           OR (question ->> 'order') !~ '^[0-9]+$' THEN
            RETURN false;
        END IF;

        IF question_type = 'single_select' AND jsonb_array_length(question -> 'options') = 0 THEN
            RETURN false;
        END IF;
        IF question_type <> 'single_select' AND jsonb_array_length(question -> 'options') <> 0 THEN
            RETURN false;
        END IF;

        question_order := (question ->> 'order')::integer;
        IF question_order = ANY (seen_orders) THEN
            RETURN false;
        END IF;
        FOR option_value IN SELECT item FROM jsonb_array_elements(question -> 'options') AS options(item)
        LOOP
            IF jsonb_typeof(option_value) <> 'string' OR btrim(option_value #>> '{}') = '' THEN
                RETURN false;
            END IF;
        END LOOP;
        seen_ids := array_append(seen_ids, question_id);
        seen_orders := array_append(seen_orders, question_order);
    END LOOP;
    RETURN true;
END;
$_$;
-- +goose StatementEnd

-- +goose StatementBegin
--
-- Name: ck_validate_autoboard_target_scope(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.ck_validate_autoboard_target_scope() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    checked_autoboard_id uuid;
    checked_scope text;
    target_count bigint;
BEGIN
    IF TG_TABLE_NAME = 'autoboards' THEN
        checked_autoboard_id := COALESCE(NEW.id, OLD.id);
    ELSE
        checked_autoboard_id := COALESCE(NEW.autoboard_id, OLD.autoboard_id);
    END IF;

    SELECT target_scope
    INTO checked_scope
    FROM public.autoboards
    WHERE id = checked_autoboard_id;

    IF NOT FOUND THEN
        RETURN NULL;
    END IF;

    SELECT count(*)
    INTO target_count
    FROM public.autoboard_targets
    WHERE autoboard_id = checked_autoboard_id;

    IF checked_scope = 'family' AND target_count <> 0 THEN
        RAISE EXCEPTION 'family autoboard % cannot have target rows', checked_autoboard_id
            USING ERRCODE = 'check_violation';
    END IF;
    IF checked_scope = 'custom' AND target_count = 0 THEN
        RAISE EXCEPTION 'custom autoboard % requires at least one target row', checked_autoboard_id
            USING ERRCODE = 'check_violation';
    END IF;

    RETURN NULL;
END
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;
-- +goose StatementEnd

--
-- Name: achievement_player_awards; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.achievement_player_awards (
    achievement_id text NOT NULL,
    player_tag text NOT NULL,
    occurrence_key text DEFAULT 'lifetime'::text NOT NULL,
    earned_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT achievement_player_awards_achievement_id_check CHECK ((achievement_id <> ''::text)),
    CONSTRAINT achievement_player_awards_occurrence_key_check CHECK ((occurrence_key <> ''::text))
);

--
-- Name: admin_audit_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.admin_audit_events (
    id uuid DEFAULT uuidv7() NOT NULL,
    actor text NOT NULL,
    action text NOT NULL,
    resource_type text NOT NULL,
    resource_id text DEFAULT ''::text NOT NULL,
    summary text DEFAULT ''::text NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    ip_address text DEFAULT ''::text NOT NULL,
    user_agent text DEFAULT ''::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);

--
-- Name: admin_campaign_delivery_attempts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.admin_campaign_delivery_attempts (
    id uuid DEFAULT uuidv7() NOT NULL,
    campaign_id uuid NOT NULL,
    scheduled_for date NOT NULL,
    eligible_count integer DEFAULT 0 NOT NULL,
    sent_count integer DEFAULT 0 NOT NULL,
    skipped_count integer DEFAULT 0 NOT NULL,
    status text NOT NULL,
    attempted_at timestamp with time zone DEFAULT now() NOT NULL
);

--
-- Name: admin_feature_flags; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.admin_feature_flags (
    flag_key text NOT NULL,
    name text NOT NULL,
    description text DEFAULT ''::text NOT NULL,
    enabled boolean DEFAULT false NOT NULL,
    rollout_percentage integer DEFAULT 0 NOT NULL,
    min_app_version text DEFAULT ''::text NOT NULL,
    platforms text[] DEFAULT '{ios,android}'::text[] NOT NULL,
    owner_name text DEFAULT 'Product'::text NOT NULL,
    public_exposure text DEFAULT 'safe'::text NOT NULL,
    starts_at timestamp with time zone,
    ends_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT admin_feature_flags_exposure_check CHECK ((public_exposure = ANY (ARRAY['safe'::text, 'sensitive'::text]))),
    CONSTRAINT admin_feature_flags_rollout_check CHECK (((rollout_percentage >= 0) AND (rollout_percentage <= 100)))
);

--
-- Name: admin_kpi_daily; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.admin_kpi_daily (
    snapshot_date date NOT NULL,
    devices_total integer DEFAULT 0 NOT NULL,
    devices_production integer DEFAULT 0 NOT NULL,
    devices_sandbox integer DEFAULT 0 NOT NULL,
    devices_opted_in integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);

--
-- Name: admin_notification_campaigns; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.admin_notification_campaigns (
    id uuid DEFAULT uuidv7() NOT NULL,
    campaign_key text NOT NULL,
    title text NOT NULL,
    body text NOT NULL,
    target_route text,
    platforms text[] DEFAULT '{ios,android,web}'::text[] NOT NULL,
    target_locales text[] DEFAULT '{}'::text[] NOT NULL,
    translations jsonb DEFAULT '{}'::jsonb NOT NULL,
    status text DEFAULT 'draft'::text NOT NULL,
    trigger_type text DEFAULT 'manual'::text NOT NULL,
    day_of_month integer,
    send_at timestamp with time zone,
    send_time text DEFAULT '09:00'::text,
    last_sent_at timestamp with time zone,
    created_by text DEFAULT ''::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT admin_notification_campaign_day_check CHECK (((day_of_month IS NULL) OR ((day_of_month >= 1) AND (day_of_month <= 28)))),
    CONSTRAINT admin_notification_campaign_locales_check CHECK ((target_locales IS NOT NULL)),
    CONSTRAINT admin_notification_campaign_send_time_check CHECK (((send_time IS NULL) OR (send_time ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'::text))),
    CONSTRAINT admin_notification_campaign_status_check CHECK ((status = ANY (ARRAY['draft'::text, 'scheduled'::text, 'sent'::text, 'paused'::text]))),
    CONSTRAINT admin_notification_campaign_trigger_check CHECK ((trigger_type = ANY (ARRAY['manual'::text, 'monthly'::text])))
);

--
-- Name: admin_post_delivery_attempts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.admin_post_delivery_attempts (
    id uuid DEFAULT uuidv7() NOT NULL,
    post_id uuid NOT NULL,
    attempt_number integer NOT NULL,
    trigger text NOT NULL,
    eligible_count integer DEFAULT 0 NOT NULL,
    sent_count integer DEFAULT 0 NOT NULL,
    skipped_count integer DEFAULT 0 NOT NULL,
    status text NOT NULL,
    error_summary text DEFAULT ''::text NOT NULL,
    attempted_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT admin_post_delivery_status_check CHECK ((status = ANY (ARRAY['queued'::text, 'processing'::text, 'sent'::text, 'partial'::text, 'failed'::text, 'no_audience'::text]))),
    CONSTRAINT admin_post_delivery_trigger_check CHECK ((trigger = ANY (ARRAY['publish'::text, 'retry'::text, 'manual'::text])))
);

--
-- Name: admin_post_revisions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.admin_post_revisions (
    id uuid DEFAULT uuidv7() NOT NULL,
    post_id uuid NOT NULL,
    revision_number integer NOT NULL,
    snapshot jsonb NOT NULL,
    created_by text DEFAULT ''::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);

--
-- Name: admin_posts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.admin_posts (
    id uuid DEFAULT uuidv7() NOT NULL,
    slug text NOT NULL,
    title text NOT NULL,
    summary text NOT NULL,
    hero_image_url text,
    body_blocks jsonb DEFAULT '[]'::jsonb NOT NULL,
    translations jsonb DEFAULT '{}'::jsonb NOT NULL,
    presentation_type text DEFAULT 'article'::text NOT NULL,
    story_url text,
    story_version integer DEFAULT 1 NOT NULL,
    story_history text[] DEFAULT '{}'::text[] NOT NULL,
    revision_number integer DEFAULT 1 NOT NULL,
    show_on_home boolean DEFAULT true NOT NULL,
    pinned_on_home boolean DEFAULT false NOT NULL,
    target_route text,
    platforms text[] DEFAULT '{ios,android,web}'::text[] NOT NULL,
    dismissible boolean DEFAULT true NOT NULL,
    priority integer DEFAULT 10 NOT NULL,
    status text DEFAULT 'draft'::text NOT NULL,
    starts_at timestamp with time zone,
    ends_at timestamp with time zone,
    also_push_on_publish boolean DEFAULT false NOT NULL,
    push_title text,
    push_body text,
    published_at timestamp with time zone,
    push_sent_at timestamp with time zone,
    created_by text DEFAULT ''::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT admin_posts_pinned_requires_home_check CHECK (((NOT pinned_on_home) OR show_on_home)),
    CONSTRAINT admin_posts_presentation_type_check CHECK ((presentation_type = ANY (ARRAY['article'::text, 'story'::text]))),
    CONSTRAINT admin_posts_status_check CHECK ((status = ANY (ARRAY['draft'::text, 'scheduled'::text, 'live'::text, 'expired'::text, 'archived'::text]))),
    CONSTRAINT admin_posts_story_url_check CHECK (((presentation_type <> 'story'::text) OR ((story_url IS NOT NULL) AND (story_url ~~ 'https://%'::text)))),
    CONSTRAINT admin_posts_story_version_check CHECK ((story_version >= 1))
);

--
-- Name: admin_sessions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.admin_sessions (
    id uuid DEFAULT uuidv7() NOT NULL,
    user_id uuid NOT NULL,
    token_hash text NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    last_seen_at timestamp with time zone DEFAULT now() NOT NULL,
    revoked_at timestamp with time zone,
    ip_address text DEFAULT ''::text NOT NULL,
    user_agent text DEFAULT ''::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);

--
-- Name: admin_users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.admin_users (
    id uuid DEFAULT uuidv7() NOT NULL,
    discord_user_id text NOT NULL,
    username text NOT NULL,
    display_name text NOT NULL,
    avatar_url text DEFAULT ''::text NOT NULL,
    role text DEFAULT 'owner'::text NOT NULL,
    active boolean DEFAULT true NOT NULL,
    last_login_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT admin_users_role_check CHECK ((role = ANY (ARRAY['owner'::text, 'admin'::text])))
);

--
-- Name: app_announcements; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.app_announcements (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    title text NOT NULL,
    subtitle text NOT NULL,
    body text DEFAULT ''::text NOT NULL,
    status text DEFAULT 'draft'::text NOT NULL,
    target text DEFAULT 'all'::text NOT NULL,
    banner_image_url text,
    html_object_key text,
    html_url text,
    starts_at timestamp with time zone NOT NULL,
    ends_at timestamp with time zone,
    min_app_version text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT app_announcements_status_check CHECK ((status = ANY (ARRAY['draft'::text, 'scheduled'::text, 'published'::text, 'archived'::text]))),
    CONSTRAINT app_announcements_target_check CHECK ((target = ANY (ARRAY['all'::text, 'ios'::text, 'android'::text])))
);

--
-- Name: audit_history; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.audit_history (
    id uuid DEFAULT uuidv7() NOT NULL,
    resource_id uuid,
    resource_type text NOT NULL,
    description text NOT NULL,
    user_id text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);

--
-- Name: auth_discord_tokens; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.auth_discord_tokens (
    user_id text NOT NULL,
    device_id text DEFAULT ''::text NOT NULL,
    access_token_ciphertext text NOT NULL,
    refresh_token_ciphertext text,
    expires_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);

--
-- Name: auth_email_verifications; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.auth_email_verifications (
    email_hash text NOT NULL,
    verification_code_hash text NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    username text NOT NULL,
    password_hash text NOT NULL,
    device_id text NOT NULL
);

--
-- Name: auth_password_reset_tokens; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.auth_password_reset_tokens (
    email_hash text NOT NULL,
    reset_code_hash text NOT NULL,
    user_id text,
    expires_at timestamp with time zone NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);

--
-- Name: auth_refresh_tokens; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.auth_refresh_tokens (
    token_hash text NOT NULL,
    user_id text NOT NULL,
    device_id text DEFAULT ''::text NOT NULL,
    expires_at timestamp with time zone NOT NULL
);

--
-- Name: auth_users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.auth_users (
    user_id text NOT NULL,
    provider text NOT NULL,
    email_hash text,
    username text,
    password_hash text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT auth_users_provider_check CHECK ((provider = ANY (ARRAY['discord'::text, 'email'::text]))),
    CONSTRAINT auth_users_provider_fields_check CHECK ((((provider = 'discord'::text) AND (email_hash IS NULL) AND (username IS NULL) AND (password_hash IS NULL)) OR ((provider = 'email'::text) AND (email_hash IS NOT NULL) AND (username IS NOT NULL) AND (password_hash IS NOT NULL))))
);

--
-- Name: autoboard_targets; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.autoboard_targets (
    autoboard_id uuid NOT NULL,
    "position" integer NOT NULL,
    target text NOT NULL,
    CONSTRAINT autoboard_targets_position_check CHECK (("position" >= 0)),
    CONSTRAINT autoboard_targets_target_check CHECK ((btrim(target) <> ''::text))
);

--
-- Name: autoboards; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.autoboards (
    id uuid DEFAULT uuidv7() NOT NULL,
    server_id text NOT NULL,
    board_type text NOT NULL,
    target_scope text NOT NULL,
    delivery_mode text NOT NULL,
    webhook_id text NOT NULL,
    thread_id text,
    message_id text,
    enabled boolean DEFAULT true NOT NULL,
    interval_minutes integer,
    schedule_kind text,
    schedule_time time without time zone,
    schedule_weekdays smallint[],
    schedule_day_of_month smallint,
    next_run_at timestamp with time zone,
    last_run_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT autoboards_board_type_check CHECK ((btrim(board_type) <> ''::text)),
    CONSTRAINT autoboards_delivery_mode_check CHECK ((delivery_mode = ANY (ARRAY['refresh'::text, 'send'::text]))),
    CONSTRAINT autoboards_due_state_check CHECK (((NOT enabled) OR (next_run_at IS NOT NULL))),
    CONSTRAINT autoboards_message_id_check CHECK (((message_id IS NULL) OR (btrim(message_id) <> ''::text))),
    CONSTRAINT autoboards_schedule_check CHECK ((((delivery_mode = 'refresh'::text) AND (interval_minutes IS NOT NULL) AND (interval_minutes > 0) AND (schedule_kind IS NULL) AND (schedule_time IS NULL) AND (schedule_weekdays IS NULL) AND (schedule_day_of_month IS NULL)) OR ((delivery_mode = 'send'::text) AND (interval_minutes IS NULL) AND (message_id IS NULL) AND (schedule_kind IS NOT NULL) AND (schedule_time IS NOT NULL) AND (((schedule_kind = 'daily'::text) AND (schedule_weekdays IS NULL) AND (schedule_day_of_month IS NULL)) OR ((schedule_kind = 'weekdays'::text) AND ((cardinality(schedule_weekdays) >= 1) AND (cardinality(schedule_weekdays) <= 7)) AND (schedule_weekdays <@ ARRAY[(1)::smallint, (2)::smallint, (3)::smallint, (4)::smallint, (5)::smallint, (6)::smallint, (7)::smallint]) AND (schedule_day_of_month IS NULL)) OR ((schedule_kind = 'day_of_month'::text) AND (schedule_weekdays IS NULL) AND ((schedule_day_of_month >= 1) AND (schedule_day_of_month <= 31))))))),
    CONSTRAINT autoboards_target_scope_check CHECK ((target_scope = ANY (ARRAY['family'::text, 'custom'::text]))),
    CONSTRAINT autoboards_thread_id_check CHECK (((thread_id IS NULL) OR (btrim(thread_id) <> ''::text))),
    CONSTRAINT autoboards_webhook_id_check CHECK ((btrim(webhook_id) <> ''::text))
);

--
-- Name: bases; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.bases (
    id uuid DEFAULT uuidv7() NOT NULL,
    message_id text NOT NULL,
    base_link text NOT NULL,
    downloaders text[] DEFAULT '{}'::text[] NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    server_id text,
    channel_id text,
    images text[] DEFAULT '{}'::text[] NOT NULL,
    description text DEFAULT ''::text NOT NULL,
    upvoter_ids text[] DEFAULT '{}'::text[] NOT NULL,
    downvoter_ids text[] DEFAULT '{}'::text[] NOT NULL,
    CONSTRAINT bases_description_length_check CHECK ((char_length(description) <= 1000)),
    CONSTRAINT bases_images_count_check CHECK ((cardinality(images) <= 4)),
    CONSTRAINT bases_message_location_pair_check CHECK (((server_id IS NULL) = (channel_id IS NULL))),
    CONSTRAINT bases_voter_ids_no_overlap_check CHECK ((NOT (upvoter_ids && downvoter_ids)))
);

--
-- Name: billing_customers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.billing_customers (
    user_id text NOT NULL,
    stripe_customer_id text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);

--
-- Name: billing_subscriptions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.billing_subscriptions (
    user_id text NOT NULL,
    provider text DEFAULT 'stripe'::text NOT NULL,
    provider_subscription_id text NOT NULL,
    provider_price_id text,
    status text NOT NULL,
    current_period_end timestamp with time zone,
    cancel_at_period_end boolean DEFAULT false NOT NULL,
    raw jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT billing_subscriptions_provider_check CHECK ((provider = 'stripe'::text))
);

--
-- Name: billing_webhook_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.billing_webhook_events (
    provider text NOT NULL,
    event_id text NOT NULL,
    event_type text NOT NULL,
    payload jsonb NOT NULL,
    processed_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT billing_webhook_events_provider_check CHECK ((provider = 'stripe'::text))
);

--
-- Name: cwl_bonus_recipients; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.cwl_bonus_recipients (
    season text NOT NULL,
    clan_tag text NOT NULL,
    player_tag text NOT NULL,
    medal_count smallint NOT NULL,
    CONSTRAINT cwl_bonus_recipients_medal_count_check CHECK ((medal_count >= 0)),
    CONSTRAINT cwl_bonus_recipients_season_check CHECK ((season ~ '^[0-9]{4}-(0[1-9]|1[0-2])(-(0[1-9]|[12][0-9]|3[01]))?$'::text)),
    CONSTRAINT cwl_bonus_recipients_tags_check CHECK (((btrim(clan_tag) <> ''::text) AND (btrim(player_tag) <> ''::text)))
);

--
-- Name: TABLE cwl_bonus_recipients; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.cwl_bonus_recipients IS 'Selected CWL bonus recipients keyed by season, clan, and player. Medal count is snapshotted because game rewards may change.';

--
-- Name: dashboard_access_audit; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.dashboard_access_audit (
    id uuid DEFAULT uuidv7() NOT NULL,
    server_id text NOT NULL,
    actor_user_id text,
    action text DEFAULT 'replace_grants'::text NOT NULL,
    before_grants jsonb DEFAULT '[]'::jsonb NOT NULL,
    after_grants jsonb DEFAULT '[]'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);

--
-- Name: dashboard_role_grants; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.dashboard_role_grants (
    server_id text NOT NULL,
    role_id text NOT NULL,
    section text NOT NULL,
    access_level text NOT NULL,
    created_by_user_id text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT dashboard_role_grants_access_level_check CHECK ((access_level = ANY (ARRAY['view'::text, 'manage'::text]))),
    CONSTRAINT dashboard_role_grants_section_check CHECK ((section = ANY (ARRAY['settings'::text, 'family_settings'::text, 'logs'::text, 'clans'::text, 'rosters'::text, 'links'::text, 'moderation'::text, 'roles'::text, 'reminders'::text, 'autoboards'::text, 'giveaways'::text, 'panels'::text, 'tickets'::text, 'embeds'::text, 'wars'::text, 'leaderboards'::text])))
);

--
-- Name: giveaways; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.giveaways (
    id text NOT NULL,
    server_id text NOT NULL,
    prize text NOT NULL,
    channel_id text,
    status text NOT NULL,
    start_time timestamp with time zone NOT NULL,
    end_time timestamp with time zone NOT NULL,
    winners integer NOT NULL,
    mentions text[] DEFAULT '{}'::text[] NOT NULL,
    text_above_embed text DEFAULT ''::text NOT NULL,
    text_in_embed text DEFAULT ''::text NOT NULL,
    text_on_end text DEFAULT ''::text NOT NULL,
    image_url text,
    profile_picture_required boolean DEFAULT false NOT NULL,
    coc_account_required boolean DEFAULT false NOT NULL,
    roles_mode text DEFAULT 'none'::text NOT NULL,
    roles text[] DEFAULT '{}'::text[] NOT NULL,
    boosters jsonb DEFAULT '[]'::jsonb NOT NULL,
    entries jsonb DEFAULT '[]'::jsonb NOT NULL,
    winners_list jsonb DEFAULT '[]'::jsonb NOT NULL,
    updated boolean DEFAULT false NOT NULL,
    message_id text,
    event_pending text,
    event_pending_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT giveaways_status_check CHECK ((status = ANY (ARRAY['scheduled'::text, 'ongoing'::text, 'ended'::text])))
);

--
-- Name: mobile_notification_accounts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.mobile_notification_accounts (
    user_id text NOT NULL,
    player_tag text NOT NULL,
    source text NOT NULL,
    active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT mobile_notification_accounts_source_check CHECK ((source = ANY (ARRAY['verified'::text, 'bookmarked'::text])))
);

--
-- Name: mobile_notification_deliveries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.mobile_notification_deliveries (
    user_id text NOT NULL,
    notification_key text NOT NULL,
    delivered_at timestamp with time zone DEFAULT now() NOT NULL
);

--
-- Name: mobile_push_devices; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.mobile_push_devices (
    user_id text NOT NULL,
    device_id text NOT NULL,
    platform text NOT NULL,
    provider text NOT NULL,
    environment text DEFAULT 'production'::text NOT NULL,
    token_ciphertext text NOT NULL,
    token_hash text NOT NULL,
    app_version text DEFAULT ''::text NOT NULL,
    enabled boolean DEFAULT true NOT NULL,
    last_seen_at timestamp with time zone DEFAULT now() NOT NULL,
    authorization_status text DEFAULT 'not_determined'::text NOT NULL,
    locale text DEFAULT ''::text NOT NULL,
    legend_attacks_enabled boolean DEFAULT false NOT NULL,
    legend_defenses_enabled boolean DEFAULT false NOT NULL,
    war_attacks_enabled boolean DEFAULT false NOT NULL,
    war_state_enabled boolean DEFAULT false NOT NULL,
    war_reminders_enabled boolean DEFAULT false NOT NULL,
    events_enabled boolean DEFAULT false NOT NULL,
    announcements_enabled boolean DEFAULT false NOT NULL,
    monthly_support_enabled boolean DEFAULT false NOT NULL,
    reminder_timings integer[] DEFAULT '{}'::integer[] NOT NULL,
    CONSTRAINT mobile_push_devices_authorization_status_check CHECK ((authorization_status = ANY (ARRAY['authorized'::text, 'provisional'::text, 'denied'::text, 'not_determined'::text]))),
    CONSTRAINT mobile_push_devices_environment_check CHECK ((environment = ANY (ARRAY['sandbox'::text, 'production'::text]))),
    CONSTRAINT mobile_push_devices_platform_check CHECK ((platform = ANY (ARRAY['ios'::text, 'android'::text]))),
    CONSTRAINT mobile_push_devices_provider_check CHECK ((provider = 'fcm'::text)),
    CONSTRAINT mobile_push_devices_reminder_timings_check CHECK (((cardinality(reminder_timings) <= 3) AND (array_position(reminder_timings, NULL::integer) IS NULL) AND (0 < ALL (reminder_timings)) AND (2820 >= ALL (reminder_timings))))
);

--
-- Name: player_links; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.player_links (
    tag text NOT NULL,
    is_main boolean DEFAULT false NOT NULL,
    order_index integer DEFAULT 0 NOT NULL,
    is_verified boolean DEFAULT false NOT NULL,
    source text NOT NULL,
    added_at timestamp with time zone DEFAULT now() NOT NULL,
    user_id text,
    verified_at timestamp with time zone,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    hidden boolean DEFAULT false NOT NULL,
    last_login timestamp with time zone,
    CONSTRAINT player_links_hidden_requires_verification CHECK (((NOT hidden) OR is_verified))
);

--
-- Name: player_links_settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.player_links_settings (
    tag text NOT NULL,
    server_id text NOT NULL,
    is_main boolean DEFAULT false NOT NULL
);

--
-- Name: player_upgrade_preferences; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.player_upgrade_preferences (
    player_tag text NOT NULL,
    preferences jsonb DEFAULT '{}'::jsonb NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT player_upgrade_preferences_object_check CHECK ((jsonb_typeof(preferences) = 'object'::text))
);

--
-- Name: player_upgrades; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.player_upgrades (
    player_tag text NOT NULL,
    data jsonb DEFAULT '{}'::jsonb NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT player_upgrades_data_object_check CHECK ((jsonb_typeof(data) = 'object'::text))
);

--
-- Name: reminders; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.reminders (
    id uuid DEFAULT uuidv7() NOT NULL,
    server_id text NOT NULL,
    type integer NOT NULL,
    clan_tag text NOT NULL,
    webhook_token text NOT NULL,
    thread_id text,
    minutes_remaining integer NOT NULL,
    custom_text text DEFAULT ''::text NOT NULL,
    clan_roles integer DEFAULT 0 NOT NULL,
    townhalls integer[],
    war_types integer DEFAULT 0 NOT NULL,
    trigger_threshold integer,
    type_name text,
    channel_id text,
    trigger_time text,
    roles text[] DEFAULT '{}'::text[] NOT NULL,
    war_type_names text[] DEFAULT '{}'::text[] NOT NULL,
    point_threshold jsonb,
    attack_threshold jsonb,
    roster_id text,
    ping_type text,
    data jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);

--
-- Name: roster_ai_usage; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.roster_ai_usage (
    id uuid DEFAULT uuidv7() NOT NULL,
    server_id text NOT NULL,
    roster_id uuid,
    view_id uuid,
    discord_user_id text NOT NULL,
    operation text NOT NULL,
    provider text NOT NULL,
    model text NOT NULL,
    provider_request_id text,
    input_tokens bigint DEFAULT 0 NOT NULL,
    cached_input_tokens bigint DEFAULT 0 NOT NULL,
    output_tokens bigint DEFAULT 0 NOT NULL,
    reasoning_tokens bigint DEFAULT 0 NOT NULL,
    total_tokens bigint DEFAULT 0 NOT NULL,
    input_cost_usd numeric(18,8) DEFAULT 0 NOT NULL,
    output_cost_usd numeric(18,8) DEFAULT 0 NOT NULL,
    total_cost_usd numeric(18,8) DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    cache_write_tokens bigint DEFAULT 0 NOT NULL,
    CONSTRAINT roster_ai_usage_cost_check CHECK (((input_cost_usd >= (0)::numeric) AND (output_cost_usd >= (0)::numeric) AND (total_cost_usd = (input_cost_usd + output_cost_usd)))),
    CONSTRAINT roster_ai_usage_identity_check CHECK (((btrim(discord_user_id) <> ''::text) AND (btrim(operation) <> ''::text) AND (btrim(provider) <> ''::text) AND (btrim(model) <> ''::text) AND ((provider_request_id IS NULL) OR (btrim(provider_request_id) <> ''::text)))),
    CONSTRAINT roster_ai_usage_tokens_check CHECK (((input_tokens >= 0) AND (cached_input_tokens >= 0) AND (cache_write_tokens >= 0) AND ((cached_input_tokens + cache_write_tokens) <= input_tokens) AND (output_tokens >= 0) AND ((reasoning_tokens >= 0) AND (reasoning_tokens <= output_tokens)) AND (total_tokens = (input_tokens + output_tokens))))
);

--
-- Name: TABLE roster_ai_usage; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.roster_ai_usage IS 'AI request accounting with provider token usage and exact USD cost components. Prompt/response bodies are intentionally not retained.';

--
-- Name: COLUMN roster_ai_usage.cache_write_tokens; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.roster_ai_usage.cache_write_tokens IS 'Input tokens written to the explicit prompt cache and billed at the model cache-write rate.';

--
-- Name: roster_ai_usage_credits; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.roster_ai_usage_credits (
    usage_id uuid NOT NULL,
    user_id text NOT NULL,
    amount_usd numeric(18,8) NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT roster_ai_usage_credits_amount_check CHECK ((amount_usd >= (0)::numeric))
);

--
-- Name: roster_ai_usage_sponsors; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.roster_ai_usage_sponsors (
    usage_id uuid NOT NULL,
    user_id text NOT NULL,
    "position" integer NOT NULL,
    CONSTRAINT roster_ai_usage_sponsors_position_check CHECK (("position" >= 0))
);

--
-- Name: roster_automation_rules; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.roster_automation_rules (
    automation_id text NOT NULL,
    server_id text NOT NULL,
    group_id text,
    enabled boolean DEFAULT true NOT NULL,
    trigger_type text DEFAULT ''::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    action_type text DEFAULT ''::text NOT NULL,
    offset_seconds integer DEFAULT 0 NOT NULL,
    discord_channel_id text,
    ping_type text,
    executed boolean DEFAULT false NOT NULL,
    executed_at bigint,
    last_triggered_at bigint,
    execution_status text,
    last_missed_at bigint,
    roster_id uuid
);

--
-- Name: roster_groups; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.roster_groups (
    id uuid DEFAULT uuidv7() NOT NULL,
    server_id text NOT NULL,
    name text NOT NULL,
    group_id text,
    description text DEFAULT ''::text NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    alias text,
    max_accounts_per_user integer,
    min_signups integer
);

--
-- Name: roster_members; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.roster_members (
    tag text NOT NULL,
    roster_id uuid NOT NULL,
    name text DEFAULT ''::text NOT NULL,
    townhall integer DEFAULT 0 NOT NULL,
    discord_user_id text,
    discord_username text,
    discord_avatar_url text,
    current_clan_name text,
    current_clan_tag text,
    war_preference boolean,
    trophies integer,
    hitrate double precision,
    last_online timestamp with time zone,
    added_at bigint,
    is_in_family boolean,
    member_status text,
    "position" integer DEFAULT 0 NOT NULL,
    signup_answers jsonb DEFAULT '{}'::jsonb NOT NULL,
    league_id integer,
    league_name text,
    hero_level_sum integer DEFAULT 0 NOT NULL,
    max_percent numeric(5,2),
    refreshed_at timestamp with time zone,
    CONSTRAINT roster_members_hero_level_sum_check CHECK ((hero_level_sum >= 0)),
    CONSTRAINT roster_members_league_check CHECK ((((league_id IS NULL) OR (league_id > 0)) AND ((league_name IS NULL) OR (btrim(league_name) <> ''::text)) AND ((league_id IS NULL) OR (league_name IS NOT NULL)))),
    CONSTRAINT roster_members_max_percent_check CHECK (((max_percent IS NULL) OR ((max_percent >= (0)::numeric) AND (max_percent <= (100)::numeric)))),
    CONSTRAINT roster_members_signup_answers_check CHECK ((jsonb_typeof(signup_answers) = 'object'::text))
);

--
-- Name: COLUMN roster_members.signup_answers; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.roster_members.signup_answers IS 'Answers keyed by the stable IDs in rosters.signup_questions. The selected account is represented by this roster member row, not duplicated in the answer object.';

--
-- Name: COLUMN roster_members.hero_level_sum; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.roster_members.hero_level_sum IS 'Sum of the current levels of the player home-village heroes. Individual hero data is not retained in roster storage.';

--
-- Name: COLUMN roster_members.max_percent; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.roster_members.max_percent IS 'Latest calculated progression percentage from 0 through 100.';

--
-- Name: COLUMN roster_members.refreshed_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.roster_members.refreshed_at IS 'Database-visible time at which this player snapshot was last refreshed from its authoritative sources.';

--
-- Name: roster_views; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.roster_views (
    id uuid DEFAULT uuidv7() NOT NULL,
    share_id text DEFAULT rtrim(translate(encode(public.gen_random_bytes(8), 'base64'::text), '+/'::text, '-_'::text), '='::text) NOT NULL,
    server_id text NOT NULL,
    name text NOT NULL,
    source_code text NOT NULL,
    source_version smallint DEFAULT 1 NOT NULL,
    created_by_discord_user_id text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT roster_views_creator_check CHECK ((btrim(created_by_discord_user_id) <> ''::text)),
    CONSTRAINT roster_views_name_check CHECK ((btrim(name) <> ''::text)),
    CONSTRAINT roster_views_share_id_check CHECK ((share_id ~ '^[A-Za-z0-9_-]{10,16}$'::text)),
    CONSTRAINT roster_views_source_code_check CHECK (((btrim(source_code) <> ''::text) AND (length(source_code) <= 65536))),
    CONSTRAINT roster_views_source_version_check CHECK ((source_version > 0)),
    CONSTRAINT roster_views_timestamps_check CHECK ((updated_at >= created_at))
);

--
-- Name: TABLE roster_views; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.roster_views IS 'Server-scoped reusable roster-view programs. Runtime columns, rows, filters, sort, highlights, and roster selection are generated on demand and are not persisted.';

--
-- Name: COLUMN roster_views.share_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.roster_views.share_id IS 'Compact URL-safe authenticated share-link identifier; it is not an authorization secret.';

--
-- Name: COLUMN roster_views.source_code; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.roster_views.source_code IS 'Authoritative TypeScript-compatible sandbox program used to materialize the view against the currently selected rosters.';

--
-- Name: COLUMN roster_views.source_version; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.roster_views.source_version IS 'Version of the saved view-program contract.';

--
-- Name: rosters; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.rosters (
    id uuid DEFAULT uuidv7() NOT NULL,
    server_id text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    group_id text,
    clan_tag text,
    alias text DEFAULT ''::text NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    description text,
    roster_type text DEFAULT 'clan'::text NOT NULL,
    signup_scope text DEFAULT 'clan-only'::text NOT NULL,
    min_townhall integer,
    max_townhall integer,
    min_signups integer,
    max_accounts_per_user integer,
    image_url text,
    event_start_time bigint,
    recurrence_days integer,
    recurrence_day_of_month integer,
    signup_questions jsonb DEFAULT '[]'::jsonb NOT NULL,
    public_share_id text,
    public_enabled boolean DEFAULT false NOT NULL,
    last_refreshed_at timestamp with time zone,
    refresh_started_at timestamp with time zone,
    roster_role_id text,
    revision bigint DEFAULT 1 NOT NULL,
    display_column_ids text[] DEFAULT '{}'::text[] NOT NULL,
    sort_configuration jsonb DEFAULT '[]'::jsonb NOT NULL,
    webhook_id text,
    message_id text,
    CONSTRAINT rosters_discord_message_check CHECK ((((webhook_id IS NULL) AND (message_id IS NULL)) OR ((webhook_id ~ '^[0-9]+$'::text) AND (message_id ~ '^[0-9]+$'::text)))),
    CONSTRAINT rosters_display_column_ids_check CHECK (((array_position(display_column_ids, NULL::text) IS NULL) AND (cardinality(display_column_ids) <= 24))),
    CONSTRAINT rosters_public_enabled_check CHECK (((NOT public_enabled) OR (public_share_id IS NOT NULL))),
    CONSTRAINT rosters_public_share_id_check CHECK (((public_share_id IS NULL) OR (public_share_id ~ '^[A-Za-z0-9_-]{16,64}$'::text))),
    CONSTRAINT rosters_revision_check CHECK ((revision >= 1)),
    CONSTRAINT rosters_roster_role_id_check CHECK (((roster_role_id IS NULL) OR (roster_role_id ~ '^[0-9]+$'::text))),
    CONSTRAINT rosters_signup_questions_check CHECK (public.ck_valid_roster_signup_questions(signup_questions)),
    CONSTRAINT rosters_sort_configuration_check CHECK (((jsonb_typeof(sort_configuration) = 'array'::text) AND (jsonb_array_length(sort_configuration) <= 5)))
);

--
-- Name: COLUMN rosters.id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.rosters.id IS 'Canonical roster identifier used by API routes, dashboard URLs, saved views, bindings, and related tables.';

--
-- Name: COLUMN rosters.signup_questions; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.rosters.signup_questions IS 'At most four roster questions with stable IDs. Supported types are text, boolean, and single_select.';

--
-- Name: COLUMN rosters.refresh_started_at; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.rosters.refresh_started_at IS 'Start of the current or most recent refresh attempt; API refresh transactions use it with last_refreshed_at for the shared cooldown and stale-attempt recovery.';

--
-- Name: COLUMN rosters.revision; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.rosters.revision IS 'Monotonic roster data revision used to reject stale transient membership proposals.';

--
-- Name: COLUMN rosters.display_column_ids; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.rosters.display_column_ids IS 'Ordered stable column IDs rendered by the roster UI; labels are localized in application code.';

--
-- Name: COLUMN rosters.sort_configuration; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.rosters.sort_configuration IS 'Ordered objects containing stable columnId and asc or desc direction.';

--
-- Name: COLUMN rosters.webhook_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.rosters.webhook_id IS 'Discord webhook identifier for the roster single bound message. No webhook secret is stored.';

--
-- Name: COLUMN rosters.message_id; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.rosters.message_id IS 'Discord message identifier paired with webhook_id for the roster single bound message.';

--
-- Name: server_autoeval_triggers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.server_autoeval_triggers (
    server_id text NOT NULL,
    trigger text NOT NULL,
    "position" integer DEFAULT 0 NOT NULL
);

--
-- Name: server_bans; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.server_bans (
    server_id text NOT NULL,
    player_tag text NOT NULL,
    player_name text DEFAULT ''::text NOT NULL,
    reason text DEFAULT ''::text NOT NULL,
    added_by text DEFAULT ''::text NOT NULL,
    edited_by jsonb DEFAULT '[]'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    image text
);

--
-- Name: server_clan_categories; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.server_clan_categories (
    id uuid DEFAULT uuidv7() NOT NULL,
    server_id text NOT NULL,
    name text NOT NULL,
    "position" integer NOT NULL,
    CONSTRAINT server_clan_categories_position_check CHECK (("position" >= 0))
);

--
-- Name: server_clans; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.server_clans (
    tag text NOT NULL,
    server_id text NOT NULL,
    category_id uuid,
    abbreviation text DEFAULT ''::text NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    added_at timestamp with time zone DEFAULT now() NOT NULL
);

--
-- Name: server_countdowns; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.server_countdowns (
    server_id text CONSTRAINT countdowns_server_id_not_null NOT NULL,
    clan_tag text,
    channel_id text CONSTRAINT countdowns_channel_id_not_null NOT NULL,
    type text CONSTRAINT countdowns_type_not_null NOT NULL,
    updated_at timestamp with time zone DEFAULT now() CONSTRAINT countdowns_updated_at_not_null NOT NULL,
    CONSTRAINT countdowns_scope_check CHECK ((((type = ANY (ARRAY['war_score'::text, 'war_timer'::text])) AND (clan_tag IS NOT NULL)) OR ((type <> ALL (ARRAY['war_score'::text, 'war_timer'::text])) AND (clan_tag IS NULL)))),
    CONSTRAINT countdowns_type_check CHECK ((type = ANY (ARRAY['clan_games_timer'::text, 'cwl_timer'::text, 'raid_weekend_timer'::text, 'season_end_timer'::text, 'season_day_timer'::text, 'war_score'::text, 'war_timer'::text])))
);

--
-- Name: server_custom_embeds; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.server_custom_embeds (
    server_id text CONSTRAINT custom_embeds_server_id_not_null NOT NULL,
    name text CONSTRAINT custom_embeds_name_not_null NOT NULL,
    data jsonb DEFAULT '{}'::jsonb CONSTRAINT custom_embeds_data_not_null NOT NULL,
    created_at timestamp with time zone DEFAULT now() CONSTRAINT custom_embeds_created_at_not_null NOT NULL,
    updated_at timestamp with time zone DEFAULT now() CONSTRAINT custom_embeds_updated_at_not_null NOT NULL
);

--
-- Name: server_logs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.server_logs (
    server_id text CONSTRAINT server_logs_server_id_not_null1 NOT NULL,
    clan_tag text,
    type text NOT NULL,
    webhook_id text NOT NULL,
    thread_id text,
    active_war_id text,
    active_raid_id text,
    message_id text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    disabled boolean DEFAULT false NOT NULL,
    CONSTRAINT server_logs_new_type_scope_check CHECK ((((type = 'ban_alert'::text) AND (clan_tag IS NOT NULL)) OR ((type = 'reddit_feed'::text) AND (clan_tag IS NULL)) OR (type <> ALL (ARRAY['ban_alert'::text, 'reddit_feed'::text])))),
    CONSTRAINT server_logs_type_check CHECK ((type = ANY (ARRAY['join_log'::text, 'leave_log'::text, 'donation_log'::text, 'clan_achievement_log'::text, 'clan_requirements_log'::text, 'clan_description_log'::text, 'war_log'::text, 'war_panel'::text, 'cwl_lineup_change_log'::text, 'capital_donations'::text, 'capital_attacks'::text, 'raid_panel'::text, 'capital_weekly_summary'::text, 'role_change'::text, 'troop_upgrade'::text, 'super_troop_boost'::text, 'th_upgrade'::text, 'league_change'::text, 'spell_upgrade'::text, 'hero_upgrade'::text, 'hero_equipment_upgrade'::text, 'name_change'::text, 'legend_log_attacks'::text, 'legend_log_defenses'::text, 'ban_alert'::text, 'reddit_feed'::text]))),
    CONSTRAINT server_logs_webhook_id_check CHECK ((btrim(webhook_id) <> ''::text))
);

--
-- Name: server_roles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.server_roles (
    id uuid DEFAULT uuidv7() CONSTRAINT role_rules_id_not_null NOT NULL,
    server_id text CONSTRAINT role_rules_server_id_not_null NOT NULL,
    clan_tag text,
    type text CONSTRAINT role_rules_type_not_null NOT NULL,
    option text CONSTRAINT role_rules_option_not_null NOT NULL,
    role_id text CONSTRAINT role_rules_role_id_not_null NOT NULL,
    mode text DEFAULT 'both'::text CONSTRAINT role_rules_mode_not_null NOT NULL,
    created_at timestamp with time zone DEFAULT now() CONSTRAINT role_rules_created_at_not_null NOT NULL,
    updated_at timestamp with time zone DEFAULT now() CONSTRAINT role_rules_updated_at_not_null NOT NULL,
    CONSTRAINT server_roles_mode_check CHECK ((mode = ANY (ARRAY['add'::text, 'remove'::text, 'both'::text]))),
    CONSTRAINT server_roles_option_check CHECK ((btrim(option) <> ''::text)),
    CONSTRAINT server_roles_role_id_check CHECK ((btrim(role_id) <> ''::text)),
    CONSTRAINT server_roles_scope_check CHECK (((clan_tag IS NULL) OR (type = 'clan_role'::text))),
    CONSTRAINT server_roles_supported_option_check CHECK ((((type <> 'family'::text) OR ((clan_tag IS NULL) AND (option = ANY (ARRAY['family'::text, 'not_family'::text])))) AND ((type <> 'clan_role'::text) OR ((option = ANY (ARRAY['member'::text, 'elder'::text, 'co_leader'::text, 'leader'::text])) AND (NOT ((clan_tag IS NULL) AND (option = 'member'::text))))))),
    CONSTRAINT server_roles_type_check CHECK ((type = ANY (ARRAY['townhall'::text, 'builderhall'::text, 'league'::text, 'builder_league'::text, 'clan_role'::text, 'clan_category'::text, 'family'::text, 'achievement'::text, 'status'::text])))
);

--
-- Name: server_welcome_panel_buttons; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.server_welcome_panel_buttons (
    server_id text NOT NULL,
    button_name text NOT NULL,
    "position" integer DEFAULT 0 NOT NULL
);

--
-- Name: server_welcome_panels; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.server_welcome_panels (
    server_id text NOT NULL,
    embed_name text,
    button_color text DEFAULT 'Grey'::text NOT NULL,
    welcome_channel_id text,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);

--
-- Name: servers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.servers (
    id text CONSTRAINT servers_id_not_null1 NOT NULL,
    name text CONSTRAINT servers_name_not_null1 NOT NULL,
    joined_at timestamp with time zone DEFAULT now() CONSTRAINT servers_joined_at_not_null1 NOT NULL,
    left_at timestamp with time zone,
    embed_color text,
    nickname_rule text,
    non_family_nickname_rule text,
    change_nickname boolean DEFAULT true NOT NULL,
    flair_non_family boolean DEFAULT true NOT NULL,
    auto_eval_nickname boolean DEFAULT false NOT NULL,
    autoeval_log_channel_id text,
    autoeval_enabled boolean DEFAULT false NOT NULL,
    full_whitelist_role_id text,
    autoboard_limit integer DEFAULT 0 NOT NULL,
    tied_stats_only boolean DEFAULT true NOT NULL,
    family_label text DEFAULT ''::text NOT NULL,
    link_parse_clan boolean DEFAULT true NOT NULL,
    link_parse_army boolean DEFAULT true NOT NULL,
    link_parse_player boolean DEFAULT true NOT NULL,
    link_parse_base boolean DEFAULT true NOT NULL,
    link_parse_show boolean DEFAULT true NOT NULL,
    updated_at timestamp with time zone DEFAULT now() CONSTRAINT servers_updated_at_not_null1 NOT NULL,
    last_command_at timestamp with time zone
);

--
-- Name: short_links; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.short_links (
    id text NOT NULL,
    url text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);

--
-- Name: strikes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.strikes (
    id text NOT NULL,
    server_id text NOT NULL,
    tag text NOT NULL,
    date_created timestamp with time zone NOT NULL,
    reason text NOT NULL,
    added_by text NOT NULL,
    strike_weight integer,
    rollover_date timestamp with time zone,
    image text
);

--
-- Name: subscription_entitlements; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.subscription_entitlements (
    user_id text NOT NULL,
    active boolean DEFAULT false NOT NULL,
    bookmark_notifications_limit integer DEFAULT 0 NOT NULL,
    roster_assistant_monthly_credit_usd numeric(18,8) DEFAULT 0 CONSTRAINT subscription_entitlements_roster_assistant_monthly_cre_not_null NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT subscription_entitlements_bookmark_limit_check CHECK ((bookmark_notifications_limit >= 0)),
    CONSTRAINT subscription_entitlements_roster_credit_check CHECK ((roster_assistant_monthly_credit_usd >= (0)::numeric))
);

--
-- Name: subscription_roster_assignments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.subscription_roster_assignments (
    user_id text NOT NULL,
    server_id text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);

--
-- Name: ticket_panel; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ticket_panel (
    id uuid DEFAULT uuidv7() NOT NULL,
    server_id text NOT NULL,
    name text NOT NULL,
    description text NOT NULL,
    parent_channel_id text,
    open_category_id text,
    closed_category_id text,
    log_channel_id text,
    naming_convention text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    embed_server_id text,
    embed_name text,
    sleep_category_id text,
    status_change_log_channel_id text,
    button_click_log_channel_id text,
    ticket_close_log_channel_id text,
    CONSTRAINT ticket_panel_embed_scope_check CHECK ((((embed_server_id IS NULL) AND (embed_name IS NULL)) OR ((embed_server_id = server_id) AND (embed_name IS NOT NULL))))
);

--
-- Name: ticket_panel_buttons; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ticket_panel_buttons (
    id uuid DEFAULT uuidv7() NOT NULL,
    panel_id uuid NOT NULL,
    questions character varying(200)[] DEFAULT '{}'::character varying[] NOT NULL,
    staff_roles text[] DEFAULT '{}'::text[] NOT NULL,
    roles_add_on_open text[] DEFAULT '{}'::text[] NOT NULL,
    roles_remove_on_open text[] DEFAULT '{}'::text[] NOT NULL,
    roles_add_on_close text[] DEFAULT '{}'::text[] NOT NULL,
    roles_remove_on_close text[] DEFAULT '{}'::text[] NOT NULL,
    allow_account_apply integer DEFAULT 0 NOT NULL,
    min_townhall_level integer,
    max_townhall_level integer,
    staff_private_thread boolean DEFAULT false NOT NULL,
    send_player_info_to_channel boolean DEFAULT false NOT NULL,
    send_player_info_to_private_thread boolean DEFAULT false CONSTRAINT ticket_panel_buttons_send_player_info_to_private_threa_not_null NOT NULL,
    auto_transcript boolean DEFAULT true NOT NULL,
    staff_to_ping text[] DEFAULT '{}'::text[],
    parent_channel_id text,
    open_category_id text,
    closed_category_id text,
    log_channel_id text,
    naming_convention text,
    server_id text NOT NULL,
    open_message_embed_server_id text,
    open_message_embed_name text,
    custom_id text,
    label text,
    style smallint,
    emoji text,
    CONSTRAINT ticket_panel_buttons_embed_scope_check CHECK ((((open_message_embed_server_id IS NULL) AND (open_message_embed_name IS NULL)) OR ((open_message_embed_server_id = server_id) AND (open_message_embed_name IS NOT NULL)))),
    CONSTRAINT ticket_panel_buttons_questions_check CHECK ((cardinality(questions) <= 5)),
    CONSTRAINT ticket_panel_buttons_style_check CHECK (((style IS NULL) OR ((style >= 1) AND (style <= 5))))
);

--
-- Name: ticket_panel_staff_permissions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ticket_panel_staff_permissions (
    panel_id uuid NOT NULL,
    role_id text NOT NULL,
    permissions integer NOT NULL
);

--
-- Name: ticket_panels; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ticket_panels (
    server_id text NOT NULL,
    name text NOT NULL,
    components jsonb DEFAULT '[]'::jsonb NOT NULL,
    data jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);

--
-- Name: tickets; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tickets (
    id uuid DEFAULT uuidv7() NOT NULL,
    server_id text NOT NULL,
    channel_id text NOT NULL,
    is_thread boolean DEFAULT false NOT NULL,
    status_id integer DEFAULT 0 NOT NULL,
    number integer NOT NULL,
    panel_id uuid NOT NULL,
    applicant_accounts text[] DEFAULT '{}'::text[] NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    closed_at timestamp with time zone,
    applicant_user_id text,
    thread_id text,
    status text DEFAULT 'open'::text NOT NULL,
    naming_convention text,
    assigned_clan_tag text,
    opted_in_user_ids text[] DEFAULT '{}'::text[] NOT NULL,
    CONSTRAINT tickets_status_check CHECK ((status = ANY (ARRAY['open'::text, 'sleep'::text, 'closed'::text, 'delete'::text])))
);

--
-- Name: tickets_number_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.tickets_number_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;

--
-- Name: tickets_number_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.tickets_number_seq OWNED BY public.tickets.number;

--
-- Name: user_bookmarks; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_bookmarks (
    user_id text NOT NULL,
    entity_type text NOT NULL,
    tag text NOT NULL,
    order_index integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT user_bookmarks_entity_type_check CHECK ((entity_type = ANY (ARRAY['player'::text, 'clan'::text])))
);

--
-- Name: user_recent_searches; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_recent_searches (
    user_id text NOT NULL,
    entity_type text NOT NULL,
    tag text NOT NULL,
    data jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT user_recent_searches_entity_type_check CHECK ((entity_type = ANY (ARRAY['player'::text, 'clan'::text])))
);

SELECT create_hypertable(
    'user_recent_searches',
    'created_at',
    chunk_time_interval => INTERVAL '7 days',
    create_default_indexes => FALSE,
    if_not_exists => TRUE
);

--
-- Name: user_settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_settings (
    user_id text NOT NULL,
    search jsonb DEFAULT '{}'::jsonb NOT NULL,
    app jsonb DEFAULT '{}'::jsonb NOT NULL,
    data jsonb DEFAULT '{}'::jsonb NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);

--
-- Name: tickets number; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE public.tickets ALTER COLUMN number SET DEFAULT nextval('public.tickets_number_seq'::regclass);

--
-- Name: achievement_player_awards achievement_player_awards_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.achievement_player_awards
    ADD CONSTRAINT achievement_player_awards_pkey PRIMARY KEY (achievement_id, player_tag, occurrence_key);

--
-- Name: admin_audit_events admin_audit_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.admin_audit_events
    ADD CONSTRAINT admin_audit_events_pkey PRIMARY KEY (id);

--
-- Name: admin_campaign_delivery_attempts admin_campaign_delivery_attempts_campaign_id_scheduled_for_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.admin_campaign_delivery_attempts
    ADD CONSTRAINT admin_campaign_delivery_attempts_campaign_id_scheduled_for_key UNIQUE (campaign_id, scheduled_for);

--
-- Name: admin_campaign_delivery_attempts admin_campaign_delivery_attempts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.admin_campaign_delivery_attempts
    ADD CONSTRAINT admin_campaign_delivery_attempts_pkey PRIMARY KEY (id);

--
-- Name: admin_feature_flags admin_feature_flags_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.admin_feature_flags
    ADD CONSTRAINT admin_feature_flags_pkey PRIMARY KEY (flag_key);

-- Subscription checkout is fail-closed for the first production release.
-- The API resolves this flag per web user, and the admin panel owns changes.
INSERT INTO public.admin_feature_flags (
    flag_key, name, description, enabled, rollout_percentage,
    platforms, owner_name, public_exposure
) VALUES (
    'subscription_support',
    'Subscription checkout',
    'Allow eligible dashboard users to start a Stripe subscription checkout.',
    false,
    100,
    ARRAY['web']::text[],
    'Product',
    'safe'
);

--
-- Name: admin_kpi_daily admin_kpi_daily_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.admin_kpi_daily
    ADD CONSTRAINT admin_kpi_daily_pkey PRIMARY KEY (snapshot_date);

--
-- Name: admin_notification_campaigns admin_notification_campaigns_campaign_key_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.admin_notification_campaigns
    ADD CONSTRAINT admin_notification_campaigns_campaign_key_key UNIQUE (campaign_key);

--
-- Name: admin_notification_campaigns admin_notification_campaigns_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.admin_notification_campaigns
    ADD CONSTRAINT admin_notification_campaigns_pkey PRIMARY KEY (id);

--
-- Name: admin_post_delivery_attempts admin_post_delivery_attempts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.admin_post_delivery_attempts
    ADD CONSTRAINT admin_post_delivery_attempts_pkey PRIMARY KEY (id);

--
-- Name: admin_post_delivery_attempts admin_post_delivery_attempts_post_id_attempt_number_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.admin_post_delivery_attempts
    ADD CONSTRAINT admin_post_delivery_attempts_post_id_attempt_number_key UNIQUE (post_id, attempt_number);

--
-- Name: admin_post_revisions admin_post_revisions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.admin_post_revisions
    ADD CONSTRAINT admin_post_revisions_pkey PRIMARY KEY (id);

--
-- Name: admin_post_revisions admin_post_revisions_post_id_revision_number_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.admin_post_revisions
    ADD CONSTRAINT admin_post_revisions_post_id_revision_number_key UNIQUE (post_id, revision_number);

--
-- Name: admin_posts admin_posts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.admin_posts
    ADD CONSTRAINT admin_posts_pkey PRIMARY KEY (id);

--
-- Name: admin_posts admin_posts_slug_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.admin_posts
    ADD CONSTRAINT admin_posts_slug_key UNIQUE (slug);

--
-- Name: admin_sessions admin_sessions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.admin_sessions
    ADD CONSTRAINT admin_sessions_pkey PRIMARY KEY (id);

--
-- Name: admin_sessions admin_sessions_token_hash_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.admin_sessions
    ADD CONSTRAINT admin_sessions_token_hash_key UNIQUE (token_hash);

--
-- Name: admin_users admin_users_discord_user_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.admin_users
    ADD CONSTRAINT admin_users_discord_user_id_key UNIQUE (discord_user_id);

--
-- Name: admin_users admin_users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.admin_users
    ADD CONSTRAINT admin_users_pkey PRIMARY KEY (id);

--
-- Name: app_announcements app_announcements_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.app_announcements
    ADD CONSTRAINT app_announcements_pkey PRIMARY KEY (id);

--
-- Name: audit_history audit_history_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.audit_history
    ADD CONSTRAINT audit_history_pkey PRIMARY KEY (id);

--
-- Name: auth_discord_tokens auth_discord_tokens_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.auth_discord_tokens
    ADD CONSTRAINT auth_discord_tokens_pkey PRIMARY KEY (user_id, device_id);

--
-- Name: auth_email_verifications auth_email_verifications_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.auth_email_verifications
    ADD CONSTRAINT auth_email_verifications_pkey PRIMARY KEY (email_hash);

--
-- Name: auth_password_reset_tokens auth_password_reset_tokens_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.auth_password_reset_tokens
    ADD CONSTRAINT auth_password_reset_tokens_pkey PRIMARY KEY (email_hash);

--
-- Name: auth_refresh_tokens auth_refresh_tokens_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.auth_refresh_tokens
    ADD CONSTRAINT auth_refresh_tokens_pkey PRIMARY KEY (token_hash);

--
-- Name: auth_users auth_users_email_hash_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.auth_users
    ADD CONSTRAINT auth_users_email_hash_key UNIQUE (email_hash);

--
-- Name: auth_users auth_users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.auth_users
    ADD CONSTRAINT auth_users_pkey PRIMARY KEY (user_id);

--
-- Name: autoboard_targets autoboard_targets_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.autoboard_targets
    ADD CONSTRAINT autoboard_targets_pkey PRIMARY KEY (autoboard_id, target);

--
-- Name: autoboard_targets autoboard_targets_position_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.autoboard_targets
    ADD CONSTRAINT autoboard_targets_position_key UNIQUE (autoboard_id, "position");

--
-- Name: autoboards autoboards_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.autoboards
    ADD CONSTRAINT autoboards_pkey PRIMARY KEY (id);

--
-- Name: bases bases_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.bases
    ADD CONSTRAINT bases_pkey PRIMARY KEY (id);

--
-- Name: billing_customers billing_customers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.billing_customers
    ADD CONSTRAINT billing_customers_pkey PRIMARY KEY (user_id);

--
-- Name: billing_customers billing_customers_stripe_customer_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.billing_customers
    ADD CONSTRAINT billing_customers_stripe_customer_id_key UNIQUE (stripe_customer_id);

--
-- Name: billing_subscriptions billing_subscriptions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.billing_subscriptions
    ADD CONSTRAINT billing_subscriptions_pkey PRIMARY KEY (user_id);

--
-- Name: billing_subscriptions billing_subscriptions_provider_subscription_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.billing_subscriptions
    ADD CONSTRAINT billing_subscriptions_provider_subscription_id_key UNIQUE (provider_subscription_id);

--
-- Name: billing_webhook_events billing_webhook_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.billing_webhook_events
    ADD CONSTRAINT billing_webhook_events_pkey PRIMARY KEY (provider, event_id);

--
-- Name: server_countdowns countdowns_server_id_clan_tag_type_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.server_countdowns
    ADD CONSTRAINT countdowns_server_id_clan_tag_type_key UNIQUE NULLS NOT DISTINCT (server_id, clan_tag, type);

--
-- Name: server_custom_embeds custom_embeds_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.server_custom_embeds
    ADD CONSTRAINT custom_embeds_pkey PRIMARY KEY (server_id, name);

--
-- Name: cwl_bonus_recipients cwl_bonus_recipients_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.cwl_bonus_recipients
    ADD CONSTRAINT cwl_bonus_recipients_pkey PRIMARY KEY (season, clan_tag, player_tag);

--
-- Name: dashboard_access_audit dashboard_access_audit_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.dashboard_access_audit
    ADD CONSTRAINT dashboard_access_audit_pkey PRIMARY KEY (id);

--
-- Name: dashboard_role_grants dashboard_role_grants_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.dashboard_role_grants
    ADD CONSTRAINT dashboard_role_grants_pkey PRIMARY KEY (server_id, role_id, section);

--
-- Name: giveaways giveaways_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.giveaways
    ADD CONSTRAINT giveaways_pkey PRIMARY KEY (id);

--
-- Name: mobile_notification_accounts mobile_notification_accounts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.mobile_notification_accounts
    ADD CONSTRAINT mobile_notification_accounts_pkey PRIMARY KEY (user_id, player_tag);

--
-- Name: mobile_notification_deliveries mobile_notification_deliveries_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.mobile_notification_deliveries
    ADD CONSTRAINT mobile_notification_deliveries_pkey PRIMARY KEY (user_id, notification_key);

--
-- Name: mobile_push_devices mobile_push_devices_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.mobile_push_devices
    ADD CONSTRAINT mobile_push_devices_pkey PRIMARY KEY (user_id, device_id, provider, environment);

--
-- Name: mobile_push_devices mobile_push_devices_token_hash_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.mobile_push_devices
    ADD CONSTRAINT mobile_push_devices_token_hash_key UNIQUE (token_hash);

--
-- Name: player_links player_links_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.player_links
    ADD CONSTRAINT player_links_pkey PRIMARY KEY (tag);

--
-- Name: player_links_settings player_links_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.player_links_settings
    ADD CONSTRAINT player_links_settings_pkey PRIMARY KEY (tag, server_id);

--
-- Name: player_upgrade_preferences player_upgrade_preferences_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.player_upgrade_preferences
    ADD CONSTRAINT player_upgrade_preferences_pkey PRIMARY KEY (player_tag);

--
-- Name: player_upgrades player_upgrades_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.player_upgrades
    ADD CONSTRAINT player_upgrades_pkey PRIMARY KEY (player_tag);

--
-- Name: reminders reminders_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.reminders
    ADD CONSTRAINT reminders_pkey PRIMARY KEY (id);

--
-- Name: roster_ai_usage_credits roster_ai_usage_credits_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.roster_ai_usage_credits
    ADD CONSTRAINT roster_ai_usage_credits_pkey PRIMARY KEY (usage_id, user_id);

--
-- Name: roster_ai_usage roster_ai_usage_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.roster_ai_usage
    ADD CONSTRAINT roster_ai_usage_pkey PRIMARY KEY (id);

--
-- Name: roster_ai_usage_sponsors roster_ai_usage_sponsors_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.roster_ai_usage_sponsors
    ADD CONSTRAINT roster_ai_usage_sponsors_pkey PRIMARY KEY (usage_id, user_id);

--
-- Name: roster_ai_usage_sponsors roster_ai_usage_sponsors_position_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.roster_ai_usage_sponsors
    ADD CONSTRAINT roster_ai_usage_sponsors_position_key UNIQUE (usage_id, "position");

--
-- Name: roster_automation_rules roster_automation_rules_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.roster_automation_rules
    ADD CONSTRAINT roster_automation_rules_pkey PRIMARY KEY (automation_id);

--
-- Name: roster_groups roster_groups_group_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.roster_groups
    ADD CONSTRAINT roster_groups_group_id_key UNIQUE (group_id);

--
-- Name: roster_groups roster_groups_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.roster_groups
    ADD CONSTRAINT roster_groups_pkey PRIMARY KEY (id);

--
-- Name: roster_groups roster_groups_server_id_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.roster_groups
    ADD CONSTRAINT roster_groups_server_id_name_key UNIQUE (server_id, name);

--
-- Name: roster_members roster_members_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.roster_members
    ADD CONSTRAINT roster_members_pkey PRIMARY KEY (tag, roster_id);

--
-- Name: roster_views roster_views_id_server_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.roster_views
    ADD CONSTRAINT roster_views_id_server_id_key UNIQUE (id, server_id);

--
-- Name: roster_views roster_views_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.roster_views
    ADD CONSTRAINT roster_views_pkey PRIMARY KEY (id);

--
-- Name: roster_views roster_views_server_id_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.roster_views
    ADD CONSTRAINT roster_views_server_id_name_key UNIQUE (server_id, name);

--
-- Name: roster_views roster_views_share_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.roster_views
    ADD CONSTRAINT roster_views_share_id_key UNIQUE (share_id);

--
-- Name: rosters rosters_id_server_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.rosters
    ADD CONSTRAINT rosters_id_server_id_key UNIQUE (id, server_id);

--
-- Name: rosters rosters_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.rosters
    ADD CONSTRAINT rosters_pkey PRIMARY KEY (id);

--
-- Name: server_autoeval_triggers server_autoeval_triggers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.server_autoeval_triggers
    ADD CONSTRAINT server_autoeval_triggers_pkey PRIMARY KEY (server_id, trigger);

--
-- Name: server_bans server_bans_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.server_bans
    ADD CONSTRAINT server_bans_pkey PRIMARY KEY (server_id, player_tag);

--
-- Name: server_clan_categories server_clan_categories_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.server_clan_categories
    ADD CONSTRAINT server_clan_categories_pkey PRIMARY KEY (id);

--
-- Name: server_clan_categories server_clan_categories_server_id_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.server_clan_categories
    ADD CONSTRAINT server_clan_categories_server_id_name_key UNIQUE (server_id, name);

--
-- Name: server_clan_categories server_clan_categories_server_id_position_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.server_clan_categories
    ADD CONSTRAINT server_clan_categories_server_id_position_key UNIQUE (server_id, "position") DEFERRABLE;

--
-- Name: server_clans server_clans_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.server_clans
    ADD CONSTRAINT server_clans_pkey PRIMARY KEY (tag, server_id);

--
-- Name: server_logs server_logs_scope_type_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.server_logs
    ADD CONSTRAINT server_logs_scope_type_key UNIQUE NULLS NOT DISTINCT (server_id, clan_tag, type);

--
-- Name: server_roles server_roles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.server_roles
    ADD CONSTRAINT server_roles_pkey PRIMARY KEY (id);

--
-- Name: server_roles server_roles_server_id_clan_tag_type_option_role_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.server_roles
    ADD CONSTRAINT server_roles_server_id_clan_tag_type_option_role_id_key UNIQUE NULLS NOT DISTINCT (server_id, clan_tag, type, option, role_id);

--
-- Name: server_welcome_panel_buttons server_welcome_panel_buttons_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.server_welcome_panel_buttons
    ADD CONSTRAINT server_welcome_panel_buttons_pkey PRIMARY KEY (server_id, button_name);

--
-- Name: server_welcome_panels server_welcome_panels_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.server_welcome_panels
    ADD CONSTRAINT server_welcome_panels_pkey PRIMARY KEY (server_id);

--
-- Name: servers servers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.servers
    ADD CONSTRAINT servers_pkey PRIMARY KEY (id);

--
-- Name: short_links short_links_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.short_links
    ADD CONSTRAINT short_links_pkey PRIMARY KEY (id);

--
-- Name: strikes strikes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.strikes
    ADD CONSTRAINT strikes_pkey PRIMARY KEY (id, server_id);

--
-- Name: subscription_entitlements subscription_entitlements_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.subscription_entitlements
    ADD CONSTRAINT subscription_entitlements_pkey PRIMARY KEY (user_id);

--
-- Name: subscription_roster_assignments subscription_roster_assignments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.subscription_roster_assignments
    ADD CONSTRAINT subscription_roster_assignments_pkey PRIMARY KEY (user_id);

--
-- Name: ticket_panel_buttons ticket_panel_buttons_panel_custom_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.ticket_panel_buttons
    ADD CONSTRAINT ticket_panel_buttons_panel_custom_id_key UNIQUE (panel_id, custom_id);

--
-- Name: ticket_panel_buttons ticket_panel_buttons_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.ticket_panel_buttons
    ADD CONSTRAINT ticket_panel_buttons_pkey PRIMARY KEY (id);

--
-- Name: ticket_panel ticket_panel_id_server_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.ticket_panel
    ADD CONSTRAINT ticket_panel_id_server_id_key UNIQUE (id, server_id);

--
-- Name: ticket_panel ticket_panel_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.ticket_panel
    ADD CONSTRAINT ticket_panel_pkey PRIMARY KEY (id);

--
-- Name: ticket_panel_staff_permissions ticket_panel_staff_permissions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.ticket_panel_staff_permissions
    ADD CONSTRAINT ticket_panel_staff_permissions_pkey PRIMARY KEY (panel_id, role_id);

--
-- Name: ticket_panels ticket_panels_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.ticket_panels
    ADD CONSTRAINT ticket_panels_pkey PRIMARY KEY (server_id, name);

--
-- Name: tickets tickets_channel_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.tickets
    ADD CONSTRAINT tickets_channel_id_key UNIQUE (channel_id);

--
-- Name: tickets tickets_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.tickets
    ADD CONSTRAINT tickets_pkey PRIMARY KEY (id);

--
-- Name: user_bookmarks user_bookmarks_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.user_bookmarks
    ADD CONSTRAINT user_bookmarks_pkey PRIMARY KEY (user_id, entity_type, tag);

--
-- Name: user_recent_searches user_recent_searches_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.user_recent_searches
    ADD CONSTRAINT user_recent_searches_pkey PRIMARY KEY (user_id, entity_type, tag, created_at);

--
-- Name: user_settings user_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.user_settings
    ADD CONSTRAINT user_settings_pkey PRIMARY KEY (user_id);

--
-- Name: dashboard_access_audit_server_created_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX dashboard_access_audit_server_created_idx ON public.dashboard_access_audit USING btree (server_id, created_at DESC);

--
-- Name: dashboard_role_grants_role_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX dashboard_role_grants_role_idx ON public.dashboard_role_grants USING btree (role_id);

--
-- Name: dashboard_role_grants_server_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX dashboard_role_grants_server_idx ON public.dashboard_role_grants USING btree (server_id);

--
-- Name: idx_achievement_player_awards_player_tag; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_achievement_player_awards_player_tag ON public.achievement_player_awards USING btree (player_tag);

--
-- Name: idx_admin_audit_events_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_admin_audit_events_created ON public.admin_audit_events USING btree (created_at DESC);

--
-- Name: idx_admin_audit_events_resource; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_admin_audit_events_resource ON public.admin_audit_events USING btree (resource_type, resource_id, created_at DESC);

--
-- Name: idx_admin_feature_flags_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_admin_feature_flags_active ON public.admin_feature_flags USING btree (enabled, starts_at, ends_at);

--
-- Name: idx_admin_notification_campaigns_due; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_admin_notification_campaigns_due ON public.admin_notification_campaigns USING btree (status, trigger_type, send_at, day_of_month, send_time);

--
-- Name: idx_admin_notification_campaigns_target_locales; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_admin_notification_campaigns_target_locales ON public.admin_notification_campaigns USING gin (target_locales);

--
-- Name: idx_admin_post_delivery_attempts_post; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_admin_post_delivery_attempts_post ON public.admin_post_delivery_attempts USING btree (post_id, attempt_number DESC);

--
-- Name: idx_admin_post_revisions_post; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_admin_post_revisions_post ON public.admin_post_revisions USING btree (post_id, revision_number DESC);

--
-- Name: idx_admin_posts_home_selection; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_admin_posts_home_selection ON public.admin_posts USING btree (pinned_on_home DESC, priority DESC, published_at DESC) WHERE ((status = 'live'::text) AND (show_on_home = true));

--
-- Name: idx_admin_posts_starts_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_admin_posts_starts_at ON public.admin_posts USING btree (starts_at) WHERE (status = 'scheduled'::text);

--
-- Name: idx_admin_posts_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_admin_posts_status ON public.admin_posts USING btree (status);

--
-- Name: idx_admin_sessions_user_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_admin_sessions_user_active ON public.admin_sessions USING btree (user_id, expires_at DESC) WHERE (revoked_at IS NULL);

--
-- Name: idx_app_announcements_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_app_announcements_active ON public.app_announcements USING btree (status, target, starts_at, ends_at);

--
-- Name: idx_app_announcements_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_app_announcements_created ON public.app_announcements USING btree (created_at DESC);

--
-- Name: idx_auth_discord_tokens_expires_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_auth_discord_tokens_expires_at ON public.auth_discord_tokens USING btree (expires_at);

--
-- Name: idx_auth_email_verifications_expires_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_auth_email_verifications_expires_at ON public.auth_email_verifications USING btree (expires_at);

--
-- Name: idx_auth_password_reset_tokens_expires_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_auth_password_reset_tokens_expires_at ON public.auth_password_reset_tokens USING btree (expires_at);

--
-- Name: idx_auth_refresh_tokens_expires_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_auth_refresh_tokens_expires_at ON public.auth_refresh_tokens USING btree (expires_at);

--
-- Name: idx_auth_refresh_tokens_user_device; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_auth_refresh_tokens_user_device ON public.auth_refresh_tokens USING btree (user_id, device_id);

--
-- Name: idx_autoboards_refresh_due; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_autoboards_refresh_due ON public.autoboards USING btree (next_run_at, id) WHERE (enabled AND (delivery_mode = 'refresh'::text));

--
-- Name: idx_autoboards_send_due; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_autoboards_send_due ON public.autoboards USING btree (next_run_at, id) WHERE (enabled AND (delivery_mode = 'send'::text));

--
-- Name: idx_autoboards_server_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_autoboards_server_created ON public.autoboards USING btree (server_id, created_at, id);

--
-- Name: idx_countdowns_server; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_countdowns_server ON public.server_countdowns USING btree (server_id, type);

--
-- Name: idx_cwl_bonus_recipients_player; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_cwl_bonus_recipients_player ON public.cwl_bonus_recipients USING btree (player_tag, season DESC);

--
-- Name: idx_giveaways_due_end; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_giveaways_due_end ON public.giveaways USING btree (end_time) WHERE (status = 'ongoing'::text);

--
-- Name: idx_giveaways_due_start; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_giveaways_due_start ON public.giveaways USING btree (start_time) WHERE (status = 'scheduled'::text);

--
-- Name: idx_giveaways_end_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_giveaways_end_time ON public.giveaways USING btree (end_time);

--
-- Name: idx_giveaways_entries_gin; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_giveaways_entries_gin ON public.giveaways USING gin (entries);

--
-- Name: idx_giveaways_pending_event; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_giveaways_pending_event ON public.giveaways USING btree (event_pending_at) WHERE (event_pending IS NOT NULL);

--
-- Name: idx_giveaways_server_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_giveaways_server_status ON public.giveaways USING btree (server_id, status);

--
-- Name: idx_mobile_notification_accounts_delivery; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_mobile_notification_accounts_delivery ON public.mobile_notification_accounts USING btree (player_tag, user_id) WHERE (active = true);

--
-- Name: idx_mobile_notification_accounts_player; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_mobile_notification_accounts_player ON public.mobile_notification_accounts USING btree (player_tag, user_id);

--
-- Name: idx_mobile_notification_deliveries_delivered_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_mobile_notification_deliveries_delivered_at ON public.mobile_notification_deliveries USING btree (delivered_at);

--
-- Name: idx_mobile_push_devices_announcements; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_mobile_push_devices_announcements ON public.mobile_push_devices USING btree (environment, user_id, device_id) WHERE ((enabled = true) AND (announcements_enabled = true));

--
-- Name: idx_mobile_push_devices_delivery; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_mobile_push_devices_delivery ON public.mobile_push_devices USING btree (provider, environment, authorization_status) WHERE (enabled = true);

--
-- Name: idx_player_links_user_order; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_player_links_user_order ON public.player_links USING btree (user_id, order_index) WHERE (user_id IS NOT NULL);

--
-- Name: idx_reminders_server_type_name; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_reminders_server_type_name ON public.reminders USING btree (server_id, type_name);

--
-- Name: idx_roster_ai_usage_credits_user_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_roster_ai_usage_credits_user_created ON public.roster_ai_usage_credits USING btree (user_id, created_at DESC);

--
-- Name: idx_roster_ai_usage_provider_request; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_roster_ai_usage_provider_request ON public.roster_ai_usage USING btree (provider, provider_request_id) WHERE (provider_request_id IS NOT NULL);

--
-- Name: idx_roster_ai_usage_server_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_roster_ai_usage_server_created ON public.roster_ai_usage USING btree (server_id, created_at DESC);

--
-- Name: idx_roster_ai_usage_user_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_roster_ai_usage_user_created ON public.roster_ai_usage USING btree (discord_user_id, created_at DESC);

--
-- Name: idx_roster_automation_rules_server_group; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_roster_automation_rules_server_group ON public.roster_automation_rules USING btree (server_id, group_id);

--
-- Name: idx_roster_groups_server; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_roster_groups_server ON public.roster_groups USING btree (server_id);

--
-- Name: idx_roster_views_server_updated; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_roster_views_server_updated ON public.roster_views USING btree (server_id, updated_at DESC);

--
-- Name: idx_rosters_discord_message; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_rosters_discord_message ON public.rosters USING btree (webhook_id, message_id) WHERE ((webhook_id IS NOT NULL) AND (message_id IS NOT NULL));

--
-- Name: idx_rosters_public_share_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_rosters_public_share_id ON public.rosters USING btree (public_share_id) WHERE (public_share_id IS NOT NULL);

--
-- Name: idx_rosters_server_clan; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rosters_server_clan ON public.rosters USING btree (server_id, clan_tag);

--
-- Name: idx_rosters_server_group; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rosters_server_group ON public.rosters USING btree (server_id, group_id);

--
-- Name: idx_server_bans_player_tag; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_server_bans_player_tag ON public.server_bans USING btree (player_tag);

--
-- Name: idx_server_logs_scope; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_server_logs_scope ON public.server_logs USING btree (server_id, clan_tag, type);

--
-- Name: idx_server_logs_webhook; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_server_logs_webhook ON public.server_logs USING btree (webhook_id);

--
-- Name: idx_server_roles_clan; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_server_roles_clan ON public.server_roles USING btree (server_id, clan_tag) WHERE (clan_tag IS NOT NULL);

--
-- Name: idx_server_roles_server_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_server_roles_server_type ON public.server_roles USING btree (server_id, type);

--
-- Name: idx_servers_last_command_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_servers_last_command_at ON public.servers USING btree (last_command_at);

--
-- Name: idx_strikes_server_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_strikes_server_id ON public.strikes USING btree (server_id);

--
-- Name: idx_strikes_tag; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_strikes_tag ON public.strikes USING btree (tag);

--
-- Name: idx_subscription_roster_assignments_server; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_subscription_roster_assignments_server ON public.subscription_roster_assignments USING btree (server_id);

--
-- Name: idx_ticket_panels_components_gin; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ticket_panels_components_gin ON public.ticket_panels USING gin (components);

--
-- Name: idx_user_bookmarks_order; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_user_bookmarks_order ON public.user_bookmarks USING btree (user_id, entity_type, order_index);

--
-- Name: idx_user_recent_searches_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_user_recent_searches_created ON public.user_recent_searches USING btree (user_id, entity_type, created_at DESC);

--
-- Name: idx_user_recent_searches_expiry; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_user_recent_searches_expiry ON public.user_recent_searches USING btree (created_at);

--
-- Name: idx_user_settings_search_gin; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_user_settings_search_gin ON public.user_settings USING gin (search);

--
-- Name: autoboard_targets autoboard_targets_scope_trigger; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER autoboard_targets_scope_trigger AFTER INSERT OR DELETE OR UPDATE ON public.autoboard_targets DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.ck_validate_autoboard_target_scope();

--
-- Name: autoboards autoboards_target_scope_trigger; Type: TRIGGER; Schema: public; Owner: -
--

CREATE CONSTRAINT TRIGGER autoboards_target_scope_trigger AFTER INSERT OR UPDATE OF target_scope ON public.autoboards DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.ck_validate_autoboard_target_scope();

--
-- Name: achievement_player_awards achievement_player_awards_player_tag_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.achievement_player_awards
    ADD CONSTRAINT achievement_player_awards_player_tag_fkey FOREIGN KEY (player_tag) REFERENCES public.player_links(tag) ON DELETE CASCADE;

--
-- Name: admin_campaign_delivery_attempts admin_campaign_delivery_attempts_campaign_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.admin_campaign_delivery_attempts
    ADD CONSTRAINT admin_campaign_delivery_attempts_campaign_id_fkey FOREIGN KEY (campaign_id) REFERENCES public.admin_notification_campaigns(id) ON DELETE CASCADE;

--
-- Name: admin_post_delivery_attempts admin_post_delivery_attempts_post_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.admin_post_delivery_attempts
    ADD CONSTRAINT admin_post_delivery_attempts_post_id_fkey FOREIGN KEY (post_id) REFERENCES public.admin_posts(id) ON DELETE CASCADE;

--
-- Name: admin_post_revisions admin_post_revisions_post_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.admin_post_revisions
    ADD CONSTRAINT admin_post_revisions_post_id_fkey FOREIGN KEY (post_id) REFERENCES public.admin_posts(id) ON DELETE CASCADE;

--
-- Name: admin_sessions admin_sessions_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.admin_sessions
    ADD CONSTRAINT admin_sessions_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.admin_users(id) ON DELETE CASCADE;

--
-- Name: auth_discord_tokens auth_discord_tokens_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.auth_discord_tokens
    ADD CONSTRAINT auth_discord_tokens_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.auth_users(user_id) ON DELETE CASCADE;

--
-- Name: auth_refresh_tokens auth_refresh_tokens_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.auth_refresh_tokens
    ADD CONSTRAINT auth_refresh_tokens_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.auth_users(user_id) ON DELETE CASCADE;

--
-- Name: autoboard_targets autoboard_targets_autoboard_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.autoboard_targets
    ADD CONSTRAINT autoboard_targets_autoboard_id_fkey FOREIGN KEY (autoboard_id) REFERENCES public.autoboards(id) ON DELETE CASCADE;

--
-- Name: autoboards autoboards_server_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.autoboards
    ADD CONSTRAINT autoboards_server_id_fkey FOREIGN KEY (server_id) REFERENCES public.servers(id) ON DELETE CASCADE;

--
-- Name: billing_customers billing_customers_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.billing_customers
    ADD CONSTRAINT billing_customers_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.auth_users(user_id) ON DELETE CASCADE;

--
-- Name: billing_subscriptions billing_subscriptions_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.billing_subscriptions
    ADD CONSTRAINT billing_subscriptions_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.billing_customers(user_id) ON DELETE CASCADE;

--
-- Name: server_countdowns countdowns_clan_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.server_countdowns
    ADD CONSTRAINT countdowns_clan_fkey FOREIGN KEY (clan_tag, server_id) REFERENCES public.server_clans(tag, server_id) ON DELETE CASCADE;

--
-- Name: server_countdowns countdowns_server_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.server_countdowns
    ADD CONSTRAINT countdowns_server_id_fkey FOREIGN KEY (server_id) REFERENCES public.servers(id) ON DELETE CASCADE;

--
-- Name: dashboard_access_audit dashboard_access_audit_actor_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.dashboard_access_audit
    ADD CONSTRAINT dashboard_access_audit_actor_user_id_fkey FOREIGN KEY (actor_user_id) REFERENCES public.auth_users(user_id) ON DELETE SET NULL;

--
-- Name: dashboard_access_audit dashboard_access_audit_server_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.dashboard_access_audit
    ADD CONSTRAINT dashboard_access_audit_server_id_fkey FOREIGN KEY (server_id) REFERENCES public.servers(id) ON DELETE CASCADE;

--
-- Name: dashboard_role_grants dashboard_role_grants_created_by_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.dashboard_role_grants
    ADD CONSTRAINT dashboard_role_grants_created_by_user_id_fkey FOREIGN KEY (created_by_user_id) REFERENCES public.auth_users(user_id) ON DELETE SET NULL;

--
-- Name: dashboard_role_grants dashboard_role_grants_server_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.dashboard_role_grants
    ADD CONSTRAINT dashboard_role_grants_server_id_fkey FOREIGN KEY (server_id) REFERENCES public.servers(id) ON DELETE CASCADE;

--
-- Name: giveaways giveaways_server_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.giveaways
    ADD CONSTRAINT giveaways_server_id_fkey FOREIGN KEY (server_id) REFERENCES public.servers(id) ON DELETE CASCADE;

--
-- Name: mobile_notification_deliveries mobile_notification_deliveries_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.mobile_notification_deliveries
    ADD CONSTRAINT mobile_notification_deliveries_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.auth_users(user_id) ON DELETE CASCADE;

--
-- Name: player_links_settings player_links_settings_server_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.player_links_settings
    ADD CONSTRAINT player_links_settings_server_id_fkey FOREIGN KEY (server_id) REFERENCES public.servers(id) ON DELETE CASCADE;

--
-- Name: player_links_settings player_links_settings_tag_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.player_links_settings
    ADD CONSTRAINT player_links_settings_tag_fkey FOREIGN KEY (tag) REFERENCES public.player_links(tag) ON DELETE CASCADE;

--
-- Name: player_upgrade_preferences player_upgrade_preferences_player_tag_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.player_upgrade_preferences
    ADD CONSTRAINT player_upgrade_preferences_player_tag_fkey FOREIGN KEY (player_tag) REFERENCES public.player_links(tag) ON DELETE CASCADE;

--
-- Name: player_upgrades player_upgrades_player_tag_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.player_upgrades
    ADD CONSTRAINT player_upgrades_player_tag_fkey FOREIGN KEY (player_tag) REFERENCES public.player_links(tag) ON DELETE CASCADE;

--
-- Name: reminders reminders_server_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.reminders
    ADD CONSTRAINT reminders_server_id_fkey FOREIGN KEY (server_id) REFERENCES public.servers(id) ON DELETE CASCADE;

--
-- Name: roster_ai_usage_credits roster_ai_usage_credits_usage_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.roster_ai_usage_credits
    ADD CONSTRAINT roster_ai_usage_credits_usage_id_fkey FOREIGN KEY (usage_id) REFERENCES public.roster_ai_usage(id) ON DELETE CASCADE;

--
-- Name: roster_ai_usage_credits roster_ai_usage_credits_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.roster_ai_usage_credits
    ADD CONSTRAINT roster_ai_usage_credits_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.subscription_entitlements(user_id) ON DELETE CASCADE;

--
-- Name: roster_ai_usage roster_ai_usage_roster_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.roster_ai_usage
    ADD CONSTRAINT roster_ai_usage_roster_fkey FOREIGN KEY (roster_id, server_id) REFERENCES public.rosters(id, server_id) ON DELETE SET NULL (roster_id);

--
-- Name: roster_ai_usage roster_ai_usage_server_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.roster_ai_usage
    ADD CONSTRAINT roster_ai_usage_server_fkey FOREIGN KEY (server_id) REFERENCES public.servers(id) ON DELETE CASCADE;

--
-- Name: roster_ai_usage_sponsors roster_ai_usage_sponsors_usage_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.roster_ai_usage_sponsors
    ADD CONSTRAINT roster_ai_usage_sponsors_usage_id_fkey FOREIGN KEY (usage_id) REFERENCES public.roster_ai_usage(id) ON DELETE CASCADE;

--
-- Name: roster_ai_usage_sponsors roster_ai_usage_sponsors_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.roster_ai_usage_sponsors
    ADD CONSTRAINT roster_ai_usage_sponsors_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.subscription_entitlements(user_id) ON DELETE CASCADE;

--
-- Name: roster_ai_usage roster_ai_usage_view_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.roster_ai_usage
    ADD CONSTRAINT roster_ai_usage_view_fkey FOREIGN KEY (view_id, server_id) REFERENCES public.roster_views(id, server_id) ON DELETE SET NULL (view_id);

--
-- Name: roster_automation_rules roster_automation_rules_roster_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.roster_automation_rules
    ADD CONSTRAINT roster_automation_rules_roster_id_fkey FOREIGN KEY (roster_id) REFERENCES public.rosters(id) ON DELETE CASCADE;

--
-- Name: roster_groups roster_groups_server_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.roster_groups
    ADD CONSTRAINT roster_groups_server_id_fkey FOREIGN KEY (server_id) REFERENCES public.servers(id) ON DELETE CASCADE;

--
-- Name: roster_members roster_members_roster_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.roster_members
    ADD CONSTRAINT roster_members_roster_id_fkey FOREIGN KEY (roster_id) REFERENCES public.rosters(id) ON DELETE CASCADE;

--
-- Name: roster_views roster_views_server_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.roster_views
    ADD CONSTRAINT roster_views_server_id_fkey FOREIGN KEY (server_id) REFERENCES public.servers(id) ON DELETE CASCADE;

--
-- Name: rosters rosters_server_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.rosters
    ADD CONSTRAINT rosters_server_id_fkey FOREIGN KEY (server_id) REFERENCES public.servers(id) ON DELETE CASCADE;

--
-- Name: server_autoeval_triggers server_autoeval_triggers_server_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.server_autoeval_triggers
    ADD CONSTRAINT server_autoeval_triggers_server_id_fkey FOREIGN KEY (server_id) REFERENCES public.servers(id) ON DELETE CASCADE;

--
-- Name: server_clan_categories server_clan_categories_server_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.server_clan_categories
    ADD CONSTRAINT server_clan_categories_server_id_fkey FOREIGN KEY (server_id) REFERENCES public.servers(id) ON DELETE CASCADE;

--
-- Name: server_clans server_clans_basic_clan_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.server_clans
    ADD CONSTRAINT server_clans_basic_clan_fkey FOREIGN KEY (tag) REFERENCES public.basic_clan(tag) ON DELETE CASCADE;

--
-- Name: server_clans server_clans_category_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.server_clans
    ADD CONSTRAINT server_clans_category_id_fkey FOREIGN KEY (category_id) REFERENCES public.server_clan_categories(id) ON DELETE SET NULL;

--
-- Name: server_clans server_clans_server_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.server_clans
    ADD CONSTRAINT server_clans_server_id_fkey FOREIGN KEY (server_id) REFERENCES public.servers(id) ON DELETE CASCADE;

--
-- Name: server_logs server_logs_clan_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.server_logs
    ADD CONSTRAINT server_logs_clan_fkey FOREIGN KEY (clan_tag, server_id) REFERENCES public.server_clans(tag, server_id) ON DELETE CASCADE;

--
-- Name: server_logs server_logs_server_id_fkey1; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.server_logs
    ADD CONSTRAINT server_logs_server_id_fkey1 FOREIGN KEY (server_id) REFERENCES public.servers(id) ON DELETE CASCADE;

--
-- Name: server_roles server_roles_clan_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.server_roles
    ADD CONSTRAINT server_roles_clan_fkey FOREIGN KEY (clan_tag, server_id) REFERENCES public.server_clans(tag, server_id) ON DELETE CASCADE;

--
-- Name: server_roles server_roles_server_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.server_roles
    ADD CONSTRAINT server_roles_server_id_fkey FOREIGN KEY (server_id) REFERENCES public.servers(id) ON DELETE CASCADE;

--
-- Name: server_welcome_panel_buttons server_welcome_panel_buttons_server_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.server_welcome_panel_buttons
    ADD CONSTRAINT server_welcome_panel_buttons_server_id_fkey FOREIGN KEY (server_id) REFERENCES public.server_welcome_panels(server_id) ON DELETE CASCADE;

--
-- Name: server_welcome_panels server_welcome_panels_server_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.server_welcome_panels
    ADD CONSTRAINT server_welcome_panels_server_id_fkey FOREIGN KEY (server_id) REFERENCES public.servers(id) ON DELETE CASCADE;

--
-- Name: strikes strikes_server_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.strikes
    ADD CONSTRAINT strikes_server_id_fkey FOREIGN KEY (server_id) REFERENCES public.servers(id) ON DELETE CASCADE;

--
-- Name: subscription_entitlements subscription_entitlements_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.subscription_entitlements
    ADD CONSTRAINT subscription_entitlements_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.auth_users(user_id) ON DELETE CASCADE;

--
-- Name: subscription_roster_assignments subscription_roster_assignments_server_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.subscription_roster_assignments
    ADD CONSTRAINT subscription_roster_assignments_server_id_fkey FOREIGN KEY (server_id) REFERENCES public.servers(id) ON DELETE CASCADE;

--
-- Name: subscription_roster_assignments subscription_roster_assignments_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.subscription_roster_assignments
    ADD CONSTRAINT subscription_roster_assignments_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.subscription_entitlements(user_id) ON DELETE CASCADE;

--
-- Name: ticket_panel_buttons ticket_panel_buttons_open_message_embed_template_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.ticket_panel_buttons
    ADD CONSTRAINT ticket_panel_buttons_open_message_embed_template_fkey FOREIGN KEY (open_message_embed_server_id, open_message_embed_name) REFERENCES public.server_custom_embeds(server_id, name) ON DELETE SET NULL;

--
-- Name: ticket_panel_buttons ticket_panel_buttons_panel_server_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.ticket_panel_buttons
    ADD CONSTRAINT ticket_panel_buttons_panel_server_fkey FOREIGN KEY (panel_id, server_id) REFERENCES public.ticket_panel(id, server_id) ON DELETE CASCADE;

--
-- Name: ticket_panel ticket_panel_embed_template_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.ticket_panel
    ADD CONSTRAINT ticket_panel_embed_template_fkey FOREIGN KEY (embed_server_id, embed_name) REFERENCES public.server_custom_embeds(server_id, name) ON DELETE SET NULL;

--
-- Name: ticket_panel ticket_panel_server_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.ticket_panel
    ADD CONSTRAINT ticket_panel_server_id_fkey FOREIGN KEY (server_id) REFERENCES public.servers(id) ON DELETE CASCADE;

--
-- Name: ticket_panel_staff_permissions ticket_panel_staff_permissions_panel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.ticket_panel_staff_permissions
    ADD CONSTRAINT ticket_panel_staff_permissions_panel_id_fkey FOREIGN KEY (panel_id) REFERENCES public.ticket_panel(id) ON DELETE CASCADE;

--
-- Name: tickets tickets_panel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.tickets
    ADD CONSTRAINT tickets_panel_id_fkey FOREIGN KEY (panel_id) REFERENCES public.ticket_panel(id) ON DELETE CASCADE;

--
-- Name: tickets tickets_server_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.tickets
    ADD CONSTRAINT tickets_server_id_fkey FOREIGN KEY (server_id) REFERENCES public.servers(id) ON DELETE CASCADE;

SELECT add_retention_policy('user_recent_searches', INTERVAL '90 days', if_not_exists => TRUE);

-- +goose Down
DROP TABLE IF EXISTS public.achievement_player_awards CASCADE;
DROP TABLE IF EXISTS public.admin_audit_events CASCADE;
DROP TABLE IF EXISTS public.admin_campaign_delivery_attempts CASCADE;
DROP TABLE IF EXISTS public.admin_feature_flags CASCADE;
DROP TABLE IF EXISTS public.admin_kpi_daily CASCADE;
DROP TABLE IF EXISTS public.admin_notification_campaigns CASCADE;
DROP TABLE IF EXISTS public.admin_post_delivery_attempts CASCADE;
DROP TABLE IF EXISTS public.admin_post_revisions CASCADE;
DROP TABLE IF EXISTS public.admin_posts CASCADE;
DROP TABLE IF EXISTS public.admin_sessions CASCADE;
DROP TABLE IF EXISTS public.admin_users CASCADE;
DROP TABLE IF EXISTS public.app_announcements CASCADE;
DROP TABLE IF EXISTS public.audit_history CASCADE;
DROP TABLE IF EXISTS public.auth_discord_tokens CASCADE;
DROP TABLE IF EXISTS public.auth_email_verifications CASCADE;
DROP TABLE IF EXISTS public.auth_password_reset_tokens CASCADE;
DROP TABLE IF EXISTS public.auth_refresh_tokens CASCADE;
DROP TABLE IF EXISTS public.auth_users CASCADE;
DROP TABLE IF EXISTS public.autoboard_targets CASCADE;
DROP TABLE IF EXISTS public.autoboards CASCADE;
DROP TABLE IF EXISTS public.bases CASCADE;
DROP TABLE IF EXISTS public.billing_customers CASCADE;
DROP TABLE IF EXISTS public.billing_subscriptions CASCADE;
DROP TABLE IF EXISTS public.billing_webhook_events CASCADE;
DROP TABLE IF EXISTS public.cwl_bonus_recipients CASCADE;
DROP TABLE IF EXISTS public.dashboard_access_audit CASCADE;
DROP TABLE IF EXISTS public.dashboard_role_grants CASCADE;
DROP TABLE IF EXISTS public.giveaways CASCADE;
DROP TABLE IF EXISTS public.mobile_notification_accounts CASCADE;
DROP TABLE IF EXISTS public.mobile_notification_deliveries CASCADE;
DROP TABLE IF EXISTS public.mobile_push_devices CASCADE;
DROP TABLE IF EXISTS public.player_links CASCADE;
DROP TABLE IF EXISTS public.player_links_settings CASCADE;
DROP TABLE IF EXISTS public.player_upgrade_preferences CASCADE;
DROP TABLE IF EXISTS public.player_upgrades CASCADE;
DROP TABLE IF EXISTS public.reminders CASCADE;
DROP TABLE IF EXISTS public.roster_ai_usage CASCADE;
DROP TABLE IF EXISTS public.roster_ai_usage_credits CASCADE;
DROP TABLE IF EXISTS public.roster_ai_usage_sponsors CASCADE;
DROP TABLE IF EXISTS public.roster_automation_rules CASCADE;
DROP TABLE IF EXISTS public.roster_groups CASCADE;
DROP TABLE IF EXISTS public.roster_members CASCADE;
DROP TABLE IF EXISTS public.roster_views CASCADE;
DROP TABLE IF EXISTS public.rosters CASCADE;
DROP TABLE IF EXISTS public.server_autoeval_triggers CASCADE;
DROP TABLE IF EXISTS public.server_bans CASCADE;
DROP TABLE IF EXISTS public.server_clan_categories CASCADE;
DROP TABLE IF EXISTS public.server_clans CASCADE;
DROP TABLE IF EXISTS public.server_countdowns CASCADE;
DROP TABLE IF EXISTS public.server_custom_embeds CASCADE;
DROP TABLE IF EXISTS public.server_logs CASCADE;
DROP TABLE IF EXISTS public.server_roles CASCADE;
DROP TABLE IF EXISTS public.server_welcome_panel_buttons CASCADE;
DROP TABLE IF EXISTS public.server_welcome_panels CASCADE;
DROP TABLE IF EXISTS public.servers CASCADE;
DROP TABLE IF EXISTS public.short_links CASCADE;
DROP TABLE IF EXISTS public.strikes CASCADE;
DROP TABLE IF EXISTS public.subscription_entitlements CASCADE;
DROP TABLE IF EXISTS public.subscription_roster_assignments CASCADE;
DROP TABLE IF EXISTS public.ticket_panel CASCADE;
DROP TABLE IF EXISTS public.ticket_panel_buttons CASCADE;
DROP TABLE IF EXISTS public.ticket_panel_staff_permissions CASCADE;
DROP TABLE IF EXISTS public.ticket_panels CASCADE;
DROP TABLE IF EXISTS public.tickets CASCADE;
DROP TABLE IF EXISTS public.user_bookmarks CASCADE;
DROP TABLE IF EXISTS public.user_recent_searches CASCADE;
DROP TABLE IF EXISTS public.user_settings CASCADE;
DROP SEQUENCE IF EXISTS public.tickets_number_seq CASCADE;
DROP FUNCTION IF EXISTS public.ck_validate_autoboard_target_scope();
DROP FUNCTION IF EXISTS public.ck_valid_roster_signup_questions(jsonb);
