-- +goose Up
CREATE EXTENSION IF NOT EXISTS timescaledb;

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

--
-- Name: battlelogs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.battlelogs (
    battle_id uuid NOT NULL,
    player_tag text NOT NULL,
    player_th smallint NOT NULL,
    opponent_tag text NOT NULL,
    opponent_th smallint NOT NULL,
    battle_type text NOT NULL,
    attack boolean NOT NULL,
    stars smallint NOT NULL,
    destruction_percentage smallint NOT NULL,
    gold integer NOT NULL,
    elixir integer NOT NULL,
    dark_elixir integer NOT NULL,
    "timestamp" timestamp with time zone NOT NULL,
    army_items text[] NOT NULL,
    army_counts jsonb NOT NULL,
    player_name text NOT NULL,
    opponent_name text NOT NULL,
    duration integer NOT NULL,
    army_share_code text NOT NULL
);

SELECT create_hypertable(
    'battlelogs',
    'timestamp',
    chunk_time_interval => INTERVAL '1 day',
    create_default_indexes => FALSE,
    if_not_exists => TRUE
);

--
-- Name: basic_clan; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.basic_clan (
    tag text NOT NULL,
    name text NOT NULL,
    description text DEFAULT ''::text NOT NULL,
    clan_level integer DEFAULT 0 NOT NULL,
    location_id integer,
    cwl_league_id integer DEFAULT 48000000 NOT NULL,
    capital_league_id integer,
    public_war_log boolean NOT NULL,
    war_wins integer NOT NULL,
    war_win_streak integer DEFAULT 0 NOT NULL,
    clan_points integer DEFAULT 0 NOT NULL,
    member_count integer NOT NULL,
    badge_token text NOT NULL,
    troops_donated integer NOT NULL,
    troops_received integer NOT NULL,
    members jsonb DEFAULT '[]'::jsonb NOT NULL,
    last_active timestamp with time zone,
    last_war_at timestamp with time zone,
    builder_base_points integer DEFAULT 0 NOT NULL,
    capital_points integer DEFAULT 0 NOT NULL
);

--
-- Name: basic_player; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.basic_player (
    tag text NOT NULL,
    name text NOT NULL,
    league_id integer,
    clan_tag text,
    townhall_level integer NOT NULL,
    trophies integer DEFAULT 0 NOT NULL
);

--
-- Name: player_profile_details; Type: TABLE; Schema: public; Owner: -
--

-- One row means the player's full profile was fetched. Global progress
-- statistics use this table as their sample population instead of basic_player,
-- which also contains players whose detailed progress is unknown.
CREATE TABLE public.player_profile_details (
    player_tag text NOT NULL,
    townhall_level smallint NOT NULL,
    heroes jsonb DEFAULT '[]'::jsonb NOT NULL,
    equipment jsonb DEFAULT '[]'::jsonb NOT NULL,
    achievements jsonb DEFAULT '[]'::jsonb NOT NULL,
    observed_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT player_profile_details_heroes_array CHECK ((jsonb_typeof(heroes) = 'array'::text)),
    CONSTRAINT player_profile_details_equipment_array CHECK ((jsonb_typeof(equipment) = 'array'::text)),
    CONSTRAINT player_profile_details_achievements_array CHECK ((jsonb_typeof(achievements) = 'array'::text))
);

--
-- Name: join_leave_history; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.join_leave_history (
    "time" timestamp with time zone DEFAULT now() NOT NULL,
    type text NOT NULL,
    clan_tag text NOT NULL,
    player_tag text NOT NULL,
    townhall_level smallint DEFAULT 0 NOT NULL,
    player_name text,
    CONSTRAINT join_leave_history_type_check CHECK ((type = ANY (ARRAY['join'::text, 'leave'::text])))
);

SELECT create_hypertable(
    'join_leave_history',
    'time',
    chunk_time_interval => INTERVAL '3 months',
    create_default_indexes => FALSE,
    if_not_exists => TRUE
);

--
-- Name: legend_rankings_current; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.legend_rankings_current (
    player_tag text NOT NULL,
    rank integer NOT NULL,
    trophies integer DEFAULT 0 NOT NULL,
    player_name text DEFAULT ''::text NOT NULL,
    clan_tag text,
    clan_name text DEFAULT ''::text NOT NULL,
    data jsonb DEFAULT '{}'::jsonb NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);

--
-- Name: player_timers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.player_timers (
    id bigint GENERATED ALWAYS AS IDENTITY NOT NULL,
    player_tag text NOT NULL,
    event_type text NOT NULL,
    event_key text NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    CONSTRAINT player_timers_event_type_check CHECK ((event_type = ANY (ARRAY['war'::text, 'raid'::text])))
);

--
-- Name: war_archive_packs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.war_archive_packs (
    pack_id bigint GENERATED BY DEFAULT AS IDENTITY NOT NULL,
    source text DEFAULT 'live'::text NOT NULL,
    status text DEFAULT 'building'::text NOT NULL,
    war_count integer DEFAULT 0 NOT NULL,
    attack_count integer DEFAULT 0 NOT NULL,
    raw_bytes bigint DEFAULT 0 NOT NULL,
    compressed_bytes bigint DEFAULT 0 NOT NULL,
    first_end_time timestamp with time zone,
    last_end_time timestamp with time zone,
    checkpoint_key text,
    source_checkpoint text,
    stats jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    uploaded_at timestamp with time zone,
    CONSTRAINT war_archive_packs_source_check CHECK ((source = ANY (ARRAY['live'::text, 'migration'::text]))),
    CONSTRAINT war_archive_packs_status_check CHECK ((status = ANY (ARRAY['building'::text, 'uploaded'::text])))
);

--
-- Name: player_war_history; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.player_war_history (
    player_tag text NOT NULL,
    war_ids integer[] DEFAULT '{}'::integer[] NOT NULL
);

--
-- Name: wars; Type: TABLE; Schema: public; Owner: -
--

CREATE SEQUENCE public.war_id_seq AS integer;

CREATE TABLE public.wars (
    war_id integer DEFAULT nextval('public.war_id_seq'::regclass) NOT NULL,
    clan_tag text NOT NULL,
    opponent_tag text NOT NULL,
    prep_time timestamp with time zone NOT NULL,
    start_time timestamp with time zone NOT NULL,
    end_time timestamp with time zone NOT NULL,
    size integer NOT NULL,
    attacks_per_member integer DEFAULT 1 NOT NULL,
    war_type text NOT NULL,
    state text NOT NULL,
    battle_modifier text DEFAULT 'none'::text NOT NULL,
    war_tag text,
    clan_name text DEFAULT ''::text NOT NULL,
    opponent_name text DEFAULT ''::text NOT NULL,
    clan_badge_token text DEFAULT ''::text NOT NULL,
    opponent_badge_token text DEFAULT ''::text NOT NULL,
    clan_level integer DEFAULT 0 NOT NULL,
    opponent_clan_level integer DEFAULT 0 NOT NULL,
    clan_attacks integer DEFAULT 0 NOT NULL,
    opponent_attacks integer DEFAULT 0 NOT NULL,
    clan_stars integer DEFAULT 0 NOT NULL,
    opponent_stars integer DEFAULT 0 NOT NULL,
    clan_destruction_percentage double precision DEFAULT 0 NOT NULL,
    opponent_destruction_percentage double precision DEFAULT 0 NOT NULL,
    archive_pack_id bigint,
    archive_offset bigint,
    archive_compressed_bytes integer,
    CONSTRAINT wars_archive_locator_check CHECK (((archive_pack_id IS NULL) AND (archive_offset IS NULL) AND (archive_compressed_bytes IS NULL)) OR ((archive_pack_id IS NOT NULL) AND (archive_offset IS NOT NULL) AND (archive_compressed_bytes IS NOT NULL) AND (archive_offset >= 0) AND (archive_compressed_bytes > 0))),
    CONSTRAINT wars_battle_modifier_check CHECK ((battle_modifier = ANY (ARRAY['none'::text, 'hardMode'::text, 'minusOne'::text, 'minusTwo'::text, 'minusThree'::text]))),
    CONSTRAINT wars_war_type_check CHECK ((war_type = ANY (ARRAY['random'::text, 'cwl'::text, 'friendly'::text])))
);

SELECT create_hypertable(
    'wars',
    'end_time',
    chunk_time_interval => INTERVAL '3 months',
    create_default_indexes => FALSE,
    if_not_exists => TRUE
);

--
-- Name: war_archive_pending; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.war_archive_pending (
    war_id integer NOT NULL,
    end_time timestamp with time zone NOT NULL,
    payload jsonb NOT NULL,
    pack_id bigint,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);

--
-- Name: api_global_counts; Type: MATERIALIZED VIEW; Schema: public; Owner: -
--

CREATE MATERIALIZED VIEW public.api_global_counts AS
 SELECT (1)::smallint AS id,
    ( SELECT count(DISTINCT player_timers.player_tag) AS count
           FROM public.player_timers
          WHERE ((player_timers.event_type = 'war'::text) AND (player_timers.expires_at >= now()))) AS players_in_war,
    ( SELECT count(DISTINCT wars.clan_tag) AS count
           FROM public.wars
          WHERE (wars.end_time >= now())) AS clans_in_war,
    ( SELECT count(*) AS count
           FROM public.join_leave_history) AS total_join_leaves,
    ( SELECT count(*) AS count
           FROM public.legend_rankings_current) AS players_in_legends,
    ( SELECT count(*) AS count
           FROM public.basic_player) AS player_count,
    ( SELECT count(*) AS count
           FROM public.basic_clan) AS clan_count,
    ( SELECT count(*) AS count
           FROM public.wars) AS wars_stored,
    now() AS refreshed_at
  WITH NO DATA;

--
-- Name: api_league_tier_counts; Type: MATERIALIZED VIEW; Schema: public; Owner: -
--

CREATE MATERIALIZED VIEW public.api_league_tier_counts AS
 SELECT COALESCE(league_id, 0) AS league_tier_id,
    count(*) AS player_count,
    now() AS refreshed_at
   FROM public.basic_player
  GROUP BY COALESCE(league_id, 0)
  WITH NO DATA;

--
-- Name: clan_change_history; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.clan_change_history (
    event_time timestamp with time zone DEFAULT now() NOT NULL,
    clan_tag text NOT NULL,
    change_type text NOT NULL,
    previous_value jsonb NOT NULL,
    current_value jsonb NOT NULL,
    CONSTRAINT clan_change_history_change_type_check CHECK ((change_type = ANY (ARRAY['description'::text, 'clan_level'::text, 'cwl_league_id'::text, 'capital_league_id'::text])))
);

SELECT create_hypertable(
    'clan_change_history',
    'event_time',
    chunk_time_interval => INTERVAL '7 days',
    create_default_indexes => FALSE,
    if_not_exists => TRUE
);

--
-- Name: clan_leaderboards; Type: MATERIALIZED VIEW; Schema: public; Owner: -
--

CREATE MATERIALIZED VIEW public.clan_leaderboards AS
 SELECT tag,
    location_id,
    rank() OVER (ORDER BY troops_donated DESC, tag) AS donated_rank,
    rank() OVER (ORDER BY troops_received DESC, tag) AS received_rank,
    rank() OVER (ORDER BY war_wins DESC, tag) AS war_wins_rank,
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
    rank() OVER (PARTITION BY location_id ORDER BY war_wins DESC, tag) AS location_war_wins_rank
   FROM public.basic_clan c
  WITH NO DATA;

--
-- Name: clan_rankings_current; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.clan_rankings_current (
    clan_tag text NOT NULL,
    ranking_type text NOT NULL,
    location_id text NOT NULL,
    rank integer NOT NULL,
    points integer NOT NULL,
    CONSTRAINT clan_rankings_current_location_id_check CHECK (((location_id = 'global'::text) OR (location_id ~ '^[0-9]+$'::text))),
    CONSTRAINT clan_rankings_current_ranking_type_check CHECK ((ranking_type = ANY (ARRAY['home'::text, 'builder_base'::text, 'capital'::text])))
);

--
-- Name: clan_records; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.clan_records (
    tag text NOT NULL,
    clan_points integer DEFAULT 0 NOT NULL,
    clan_points_at timestamp with time zone,
    war_win_streak integer DEFAULT 0 NOT NULL,
    war_win_streak_at timestamp with time zone
);

--
-- Name: cwl_group_clans; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.cwl_group_clans (
    cwl_id text NOT NULL,
    clan_tag text NOT NULL,
    name text DEFAULT ''::text NOT NULL,
    clan_level integer DEFAULT 0 NOT NULL,
    badge_token text DEFAULT ''::text NOT NULL,
    CONSTRAINT cwl_group_clans_badge_token_check CHECK ((badge_token !~ '/|\.png$'::text))
);

--
-- Name: cwl_group_members; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.cwl_group_members (
    cwl_id text NOT NULL,
    clan_tag text NOT NULL,
    name text DEFAULT ''::text NOT NULL,
    tag text NOT NULL,
    town_hall smallint DEFAULT 0 NOT NULL,
    CONSTRAINT cwl_group_members_town_hall_check CHECK ((town_hall >= 0))
);

--
-- Name: cwl_groups; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.cwl_groups (
    cwl_id text NOT NULL,
    season text NOT NULL,
    cwl_league_id integer,
    rounds jsonb NOT NULL,
    state text DEFAULT 'preparation'::text NOT NULL,
    war_size smallint,
    CONSTRAINT cwl_groups_id_format_check CHECK ((cwl_id ~ '^[A-Za-z0-9_-]{12}$'::text)),
    CONSTRAINT cwl_groups_state_check CHECK ((state = ANY (ARRAY['notInWar'::text, 'preparation'::text, 'inWar'::text, 'ended'::text])))
);

--
-- Name: cwl_league_history; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.cwl_league_history (
    clan_tag text NOT NULL,
    seasons jsonb NOT NULL,
    CONSTRAINT cwl_league_history_clan_tag_check CHECK ((clan_tag ~ '^#[0289PYLQGRJCUV]{3,15}$'::text)),
    CONSTRAINT cwl_league_history_seasons_object_check CHECK ((jsonb_typeof(seasons) = 'object'::text))
);

--
-- Name: cwl_standings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.cwl_standings (
    cwl_id text NOT NULL,
    clan_tag text NOT NULL,
    season text NOT NULL,
    cwl_league_id integer NOT NULL,
    war_size smallint NOT NULL,
    stars integer DEFAULT 0 NOT NULL,
    destruction numeric(12,4) DEFAULT 0 NOT NULL,
    wins smallint DEFAULT 0 NOT NULL,
    losses smallint DEFAULT 0 NOT NULL,
    ties smallint DEFAULT 0 NOT NULL,
    wars_finished smallint DEFAULT 0 NOT NULL,
    total_clans_in_group smallint DEFAULT 0 NOT NULL,
    group_rank integer,
    global_rank integer,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT cwl_standings_nonnegative_check CHECK (((stars >= 0) AND (destruction >= (0)::numeric) AND (wins >= 0) AND (losses >= 0) AND (ties >= 0) AND (wars_finished >= 0) AND (total_clans_in_group >= 0))),
    CONSTRAINT cwl_standings_war_size_check CHECK ((war_size > 0))
);

--
-- Name: leaderboard_history_clan_builder_base; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.leaderboard_history_clan_builder_base (
    location_id text NOT NULL,
    date date NOT NULL,
    clan_tag text NOT NULL,
    clan_name text NOT NULL,
    clan_badge_token text NOT NULL,
    clan_level integer NOT NULL,
    builder_base_points integer CONSTRAINT leaderboard_history_clan_builder_b_builder_base_points_not_null NOT NULL,
    members integer NOT NULL,
    clan_location_id integer,
    rank integer NOT NULL,
    previous_rank integer,
    CONSTRAINT leaderboard_history_clan_builder_base_location_id_check CHECK (((location_id = 'global'::text) OR (location_id ~ '^[0-9]+$'::text))),
    CONSTRAINT leaderboard_history_clan_builder_base_text_check CHECK (((btrim(clan_tag) <> ''::text) AND (btrim(clan_name) <> ''::text) AND (btrim(clan_badge_token) <> ''::text))),
    CONSTRAINT leaderboard_history_clan_builder_base_values_check CHECK (((clan_level > 0) AND (builder_base_points >= 0) AND (members >= 0) AND (members <= 50) AND ((clan_location_id IS NULL) OR (clan_location_id > 0)) AND (rank > 0)))
);

--
-- Name: leaderboard_history_clan_capital; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.leaderboard_history_clan_capital (
    location_id text NOT NULL,
    date date NOT NULL,
    clan_tag text NOT NULL,
    clan_name text NOT NULL,
    clan_badge_token text NOT NULL,
    clan_level integer NOT NULL,
    capital_points integer NOT NULL,
    members integer NOT NULL,
    clan_location_id integer,
    rank integer NOT NULL,
    previous_rank integer,
    CONSTRAINT leaderboard_history_clan_capital_location_id_check CHECK (((location_id = 'global'::text) OR (location_id ~ '^[0-9]+$'::text))),
    CONSTRAINT leaderboard_history_clan_capital_text_check CHECK (((btrim(clan_tag) <> ''::text) AND (btrim(clan_name) <> ''::text) AND (btrim(clan_badge_token) <> ''::text))),
    CONSTRAINT leaderboard_history_clan_capital_values_check CHECK (((clan_level > 0) AND (capital_points >= 0) AND (members >= 0) AND (members <= 50) AND ((clan_location_id IS NULL) OR (clan_location_id > 0)) AND (rank > 0)))
);

--
-- Name: leaderboard_history_clan_home; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.leaderboard_history_clan_home (
    location_id text NOT NULL,
    date date NOT NULL,
    clan_tag text NOT NULL,
    clan_name text NOT NULL,
    clan_badge_token text NOT NULL,
    clan_level integer NOT NULL,
    clan_points integer NOT NULL,
    members integer NOT NULL,
    clan_location_id integer,
    rank integer NOT NULL,
    previous_rank integer,
    CONSTRAINT leaderboard_history_clan_home_location_id_check CHECK (((location_id = 'global'::text) OR (location_id ~ '^[0-9]+$'::text))),
    CONSTRAINT leaderboard_history_clan_home_text_check CHECK (((btrim(clan_tag) <> ''::text) AND (btrim(clan_name) <> ''::text) AND (btrim(clan_badge_token) <> ''::text))),
    CONSTRAINT leaderboard_history_clan_home_values_check CHECK (((clan_level > 0) AND (clan_points >= 0) AND (members >= 0) AND (members <= 50) AND ((clan_location_id IS NULL) OR (clan_location_id > 0)) AND (rank > 0)))
);

--
-- Name: leaderboard_history_player_builder_base; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.leaderboard_history_player_builder_base (
    location_id text NOT NULL,
    date date NOT NULL,
    player_tag text NOT NULL,
    player_name text NOT NULL,
    exp_level integer NOT NULL,
    builder_base_trophies integer CONSTRAINT leaderboard_history_player_build_builder_base_trophies_not_null NOT NULL,
    builder_base_battle_wins integer,
    rank integer NOT NULL,
    previous_rank integer,
    clan_tag text,
    clan_name text,
    clan_badge_token text,
    league_id integer,
    CONSTRAINT leaderboard_history_player_builder_base_clan_check CHECK ((((clan_tag IS NULL) AND (clan_name IS NULL) AND (clan_badge_token IS NULL)) OR ((clan_tag IS NOT NULL) AND (clan_name IS NOT NULL) AND (clan_badge_token IS NOT NULL) AND (btrim(clan_tag) <> ''::text) AND (btrim(clan_name) <> ''::text) AND (btrim(clan_badge_token) <> ''::text)))),
    CONSTRAINT leaderboard_history_player_builder_base_location_id_check CHECK (((location_id = 'global'::text) OR (location_id ~ '^[0-9]+$'::text))),
    CONSTRAINT leaderboard_history_player_builder_base_player_name_check CHECK (((btrim(player_tag) <> ''::text) AND (btrim(player_name) <> ''::text))),
    CONSTRAINT leaderboard_history_player_builder_base_values_check CHECK (((exp_level >= 0) AND (builder_base_trophies >= 0) AND ((builder_base_battle_wins IS NULL) OR (builder_base_battle_wins >= 0)) AND (rank > 0) AND ((league_id IS NULL) OR (league_id > 0))))
);

--
-- Name: leaderboard_history_player_home; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.leaderboard_history_player_home (
    location_id text NOT NULL,
    date date NOT NULL,
    player_tag text NOT NULL,
    player_name text NOT NULL,
    exp_level integer NOT NULL,
    trophies integer NOT NULL,
    attack_wins integer NOT NULL,
    defense_wins integer NOT NULL,
    rank integer NOT NULL,
    previous_rank integer,
    clan_tag text,
    clan_name text,
    clan_badge_token text,
    league_id integer,
    CONSTRAINT leaderboard_history_player_home_clan_check CHECK ((((clan_tag IS NULL) AND (clan_name IS NULL) AND (clan_badge_token IS NULL)) OR ((clan_tag IS NOT NULL) AND (clan_name IS NOT NULL) AND (clan_badge_token IS NOT NULL) AND (btrim(clan_tag) <> ''::text) AND (btrim(clan_name) <> ''::text) AND (btrim(clan_badge_token) <> ''::text)))),
    CONSTRAINT leaderboard_history_player_home_location_id_check CHECK (((location_id = 'global'::text) OR (location_id ~ '^[0-9]+$'::text))),
    CONSTRAINT leaderboard_history_player_home_player_name_check CHECK (((btrim(player_tag) <> ''::text) AND (btrim(player_name) <> ''::text))),
    CONSTRAINT leaderboard_history_player_home_values_check CHECK (((exp_level >= 0) AND (trophies >= 0) AND (attack_wins >= 0) AND (defense_wins >= 0) AND (rank > 0) AND ((league_id IS NULL) OR (league_id > 0))))
);

--
-- Name: legend_history; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.legend_history (
    season text NOT NULL,
    player_tag text NOT NULL,
    rank integer NOT NULL,
    trophies integer DEFAULT 0 NOT NULL,
    player_name text NOT NULL,
    exp_level integer NOT NULL,
    attack_wins integer NOT NULL,
    defense_wins integer NOT NULL,
    clan_tag text,
    clan_name text,
    clan_badge_token text,
    league_tier_id integer,
    CONSTRAINT legend_history_attack_wins_check CHECK ((attack_wins >= 0)),
    CONSTRAINT legend_history_clan_check CHECK ((((clan_tag IS NULL) AND (clan_name IS NULL) AND (clan_badge_token IS NULL)) OR ((btrim(clan_tag) <> ''::text) AND (btrim(clan_name) <> ''::text) AND (btrim(clan_badge_token) <> ''::text)))),
    CONSTRAINT legend_history_defense_wins_check CHECK ((defense_wins >= 0)),
    CONSTRAINT legend_history_exp_level_check CHECK ((exp_level >= 0)),
    CONSTRAINT legend_history_league_tier_id_check CHECK (((league_tier_id IS NULL) OR (league_tier_id > 0))),
    CONSTRAINT legend_history_player_name_check CHECK ((btrim(player_name) <> ''::text)),
    CONSTRAINT legend_history_rank_check CHECK ((rank > 0)),
    CONSTRAINT legend_history_trophies_check CHECK ((trophies >= 0))
);

--
-- Name: player_change_history; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.player_change_history (
    event_time timestamp with time zone DEFAULT now() CONSTRAINT player_profile_changes_event_time_not_null NOT NULL,
    player_tag text CONSTRAINT player_profile_changes_player_tag_not_null NOT NULL,
    clan_tag text DEFAULT ''::text CONSTRAINT player_profile_changes_clan_tag_not_null NOT NULL,
    townhall_level integer DEFAULT 0 CONSTRAINT player_profile_changes_townhall_level_not_null NOT NULL,
    change_type text CONSTRAINT player_profile_changes_change_type_not_null NOT NULL,
    previous_value jsonb,
    current_value jsonb
);

SELECT create_hypertable(
    'player_change_history',
    'event_time',
    chunk_time_interval => INTERVAL '7 days',
    create_default_indexes => FALSE,
    if_not_exists => TRUE
);

--
-- Name: player_online_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.player_online_events (
    seen_at timestamp with time zone DEFAULT now() NOT NULL,
    tag text NOT NULL,
    clan_tag text NOT NULL
);

SELECT create_hypertable(
    'player_online_events',
    'seen_at',
    chunk_time_interval => INTERVAL '3 months',
    create_default_indexes => FALSE,
    if_not_exists => TRUE
);

--
-- Name: player_rankings_current; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.player_rankings_current (
    player_tag text NOT NULL,
    ranking_type text NOT NULL,
    location_id text NOT NULL,
    rank integer,
    points integer,
    CONSTRAINT player_rankings_current_global_rank_check CHECK (((location_id <> 'global'::text) OR (rank IS NOT NULL))),
    CONSTRAINT player_rankings_current_location_id_check CHECK (((location_id = 'global'::text) OR (location_id ~ '^[0-9]+$'::text))),
    CONSTRAINT player_rankings_current_placement_check CHECK ((((rank IS NULL) AND (points IS NULL)) OR ((rank IS NOT NULL) AND (points IS NOT NULL) AND (rank > 0) AND (points >= 0)))),
    CONSTRAINT player_rankings_current_ranking_type_check CHECK ((ranking_type = ANY (ARRAY['home'::text, 'builder_base'::text])))
);

--
-- Name: player_stat_changes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.player_stat_changes (
    event_time timestamp with time zone NOT NULL,
    player_tag text NOT NULL,
    clan_tag text,
    stat_type text NOT NULL,
    previous_value bigint NOT NULL,
    current_value bigint NOT NULL,
    delta bigint NOT NULL,
    CONSTRAINT player_stat_changes_stat_type_check CHECK ((stat_type = ANY (ARRAY['donated'::text, 'received'::text, 'clan_games'::text, 'capital_gold_donated'::text, 'season_pass'::text]))),
    CONSTRAINT player_stat_changes_values_check CHECK (((previous_value >= 0) AND (current_value > previous_value) AND (delta = (current_value - previous_value))))
);

SELECT create_hypertable(
    'player_stat_changes',
    'event_time',
    chunk_time_interval => INTERVAL '7 days',
    create_default_indexes => FALSE,
    if_not_exists => TRUE
);

--
-- Name: ranked_league_group_members; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ranked_league_group_members (
    season_id bigint NOT NULL,
    group_tag text NOT NULL,
    league_tier_id integer NOT NULL,
    player_tag text NOT NULL,
    player_name text NOT NULL,
    clan_tag text,
    clan_name text,
    placement integer NOT NULL,
    league_trophies integer NOT NULL,
    attack_win_count integer NOT NULL,
    attack_lose_count integer NOT NULL,
    defense_win_count integer NOT NULL,
    defense_lose_count integer NOT NULL
);

--
-- Name: townhall_counts; Type: MATERIALIZED VIEW; Schema: public; Owner: -
--

CREATE MATERIALIZED VIEW public.townhall_counts AS
 SELECT townhall_level AS level,
    count(*) AS total_count
   FROM public.basic_player
  GROUP BY townhall_level
  WITH NO DATA;

--
-- Name: townhall_stats_daily; Type: MATERIALIZED VIEW; Schema: public; Owner: -
--

CREATE MATERIALIZED VIEW public.townhall_stats_daily
WITH (timescaledb.continuous) AS
SELECT
    time_bucket('1 day', "timestamp") AS day_start,
    player_th,
    battle_type,
    count(*) AS attacks,
    count(*) FILTER (WHERE stars = 0) AS zero_stars,
    count(*) FILTER (WHERE stars = 1) AS one_stars,
    count(*) FILTER (WHERE stars = 2) AS two_stars,
    count(*) FILTER (WHERE stars = 3) AS three_stars
FROM public.battlelogs
WHERE attack = true
  AND player_th = opponent_th
  AND battle_type IN ('ranked', 'legend')
GROUP BY day_start, player_th, battle_type
WITH NO DATA;

SELECT add_continuous_aggregate_policy(
    'townhall_stats_daily',
    start_offset => INTERVAL '7 days',
    end_offset => INTERVAL '15 minutes',
    schedule_interval => INTERVAL '1 hour'
);

--
-- Name: tracking_domain_stats; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tracking_domain_stats (
    interval_start timestamp with time zone NOT NULL,
    interval_end timestamp with time zone NOT NULL,
    run_id bigint NOT NULL,
    script text NOT NULL,
    name text NOT NULL,
    last_success timestamp with time zone,
    last_error text,
    requests bigint NOT NULL,
    writes bigint NOT NULL,
    errors bigint NOT NULL,
    request_latency_ms double precision NOT NULL,
    queue_depth integer NOT NULL,
    healthy boolean NOT NULL,
    last_ready_change timestamp with time zone,
    processing_count bigint NOT NULL,
    total_process_time_ms double precision NOT NULL,
    store_batches bigint NOT NULL,
    store_rows_requested bigint NOT NULL,
    store_rows_affected bigint NOT NULL,
    store_duration_ms double precision NOT NULL,
    target_count integer DEFAULT 0 NOT NULL,
    target_cycle bigint DEFAULT 0 NOT NULL,
    target_processed integer DEFAULT 0 NOT NULL
);

SELECT create_hypertable(
    'tracking_domain_stats',
    'interval_end',
    chunk_time_interval => INTERVAL '1 day',
    create_default_indexes => FALSE,
    if_not_exists => TRUE
);

--
-- Name: tracking_process_stats; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tracking_process_stats (
    interval_start timestamp with time zone NOT NULL,
    interval_end timestamp with time zone NOT NULL,
    run_id bigint NOT NULL,
    script text NOT NULL,
    process_started_at timestamp with time zone NOT NULL,
    uptime_ms double precision NOT NULL,
    goroutines integer NOT NULL,
    alloc_bytes bigint NOT NULL,
    heap_objects bigint NOT NULL,
    gc_cycles bigint NOT NULL
);

SELECT create_hypertable(
    'tracking_process_stats',
    'interval_end',
    chunk_time_interval => INTERVAL '1 day',
    create_default_indexes => FALSE,
    if_not_exists => TRUE
);

--
-- Name: tracking_stats_run_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.tracking_stats_run_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;

--
-- Name: tracking_sync_cursors; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tracking_sync_cursors (
    name text NOT NULL,
    cursor_time timestamp with time zone NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);

--
-- Name: war_league_counts; Type: MATERIALIZED VIEW; Schema: public; Owner: -
--

CREATE MATERIALIZED VIEW public.war_league_counts AS
 SELECT cwl_league_id,
    count(*) AS clan_count
   FROM public.basic_clan c
  GROUP BY cwl_league_id
  WITH NO DATA;

--
-- Name: war_schedule; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.war_schedule (
    schedule_key text NOT NULL,
    war_id integer DEFAULT nextval('public.war_id_seq'::regclass) NOT NULL,
    source_clan_tag text NOT NULL,
    opponent_tag text NOT NULL,
    prep_time timestamp with time zone NOT NULL,
    end_time timestamp with time zone NOT NULL,
    next_run_at timestamp with time zone NOT NULL,
    war_type text DEFAULT ''::text NOT NULL,
    war_tag text
);

--
-- Name: war_reminder_jobs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.war_reminder_jobs (
    schedule_key text NOT NULL,
    minutes_remaining integer NOT NULL,
    run_at timestamp with time zone NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT war_reminder_jobs_minutes_check CHECK ((minutes_remaining > 0))
);

--
-- Name: basic_clan basic_clan_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.basic_clan
    ADD CONSTRAINT basic_clan_pkey PRIMARY KEY (tag);

--
-- Name: basic_player basic_player_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.basic_player
    ADD CONSTRAINT basic_player_pkey PRIMARY KEY (tag);

ALTER TABLE public.player_profile_details
    ADD CONSTRAINT player_profile_details_pkey PRIMARY KEY (player_tag);

ALTER TABLE public.player_profile_details
    ADD CONSTRAINT player_profile_details_player_tag_fkey FOREIGN KEY (player_tag) REFERENCES public.basic_player(tag) ON DELETE CASCADE;

--
-- Name: battlelogs battlelogs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.battlelogs
    ADD CONSTRAINT battlelogs_pkey PRIMARY KEY (battle_id, "timestamp");

--
-- Name: clan_rankings_current clan_rankings_current_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.clan_rankings_current
    ADD CONSTRAINT clan_rankings_current_pkey PRIMARY KEY (clan_tag, ranking_type, location_id);

--
-- Name: clan_records clan_records_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.clan_records
    ADD CONSTRAINT clan_records_pkey PRIMARY KEY (tag);

--
-- Name: player_timers player_timers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.player_timers
    ADD CONSTRAINT player_timers_pkey PRIMARY KEY (id);

ALTER TABLE public.player_timers
    ADD CONSTRAINT player_timers_player_event_key_key UNIQUE (player_tag, event_type, event_key);

ALTER TABLE public.cwl_groups
    ADD CONSTRAINT cwl_groups_pkey PRIMARY KEY (cwl_id);

ALTER TABLE public.cwl_group_clans
    ADD CONSTRAINT cwl_group_clans_pkey PRIMARY KEY (cwl_id, clan_tag);

ALTER TABLE public.cwl_group_members
    ADD CONSTRAINT cwl_group_members_pkey PRIMARY KEY (tag, cwl_id);

ALTER TABLE public.cwl_group_clans
    ADD CONSTRAINT cwl_group_clans_cwl_id_fkey FOREIGN KEY (cwl_id) REFERENCES public.cwl_groups(cwl_id) ON DELETE CASCADE;

ALTER TABLE public.cwl_group_members
    ADD CONSTRAINT cwl_group_members_group_clan_fkey FOREIGN KEY (cwl_id, clan_tag) REFERENCES public.cwl_group_clans(cwl_id, clan_tag) ON DELETE CASCADE;

ALTER TABLE public.cwl_standings
    ADD CONSTRAINT cwl_standings_group_clan_fkey FOREIGN KEY (cwl_id, clan_tag) REFERENCES public.cwl_group_clans(cwl_id, clan_tag) ON DELETE CASCADE;

--
-- Name: cwl_league_history cwl_league_history_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.cwl_league_history
    ADD CONSTRAINT cwl_league_history_pkey PRIMARY KEY (clan_tag);

--
-- Name: cwl_standings cwl_standings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.cwl_standings
    ADD CONSTRAINT cwl_standings_pkey PRIMARY KEY (cwl_id, clan_tag);

--
-- Name: leaderboard_history_clan_builder_base leaderboard_history_clan_builder_base_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.leaderboard_history_clan_builder_base
    ADD CONSTRAINT leaderboard_history_clan_builder_base_pkey PRIMARY KEY (location_id, date, clan_tag);

--
-- Name: leaderboard_history_clan_capital leaderboard_history_clan_capital_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.leaderboard_history_clan_capital
    ADD CONSTRAINT leaderboard_history_clan_capital_pkey PRIMARY KEY (location_id, date, clan_tag);

--
-- Name: leaderboard_history_clan_home leaderboard_history_clan_home_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.leaderboard_history_clan_home
    ADD CONSTRAINT leaderboard_history_clan_home_pkey PRIMARY KEY (location_id, date, clan_tag);

--
-- Name: leaderboard_history_player_builder_base leaderboard_history_player_builder_base_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.leaderboard_history_player_builder_base
    ADD CONSTRAINT leaderboard_history_player_builder_base_pkey PRIMARY KEY (location_id, date, player_tag);

--
-- Name: leaderboard_history_player_home leaderboard_history_player_home_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.leaderboard_history_player_home
    ADD CONSTRAINT leaderboard_history_player_home_pkey PRIMARY KEY (location_id, date, player_tag);

--
-- Name: legend_history legend_history_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.legend_history
    ADD CONSTRAINT legend_history_pkey PRIMARY KEY (player_tag, season);

--
-- Name: legend_rankings_current legend_rankings_current_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.legend_rankings_current
    ADD CONSTRAINT legend_rankings_current_pkey PRIMARY KEY (player_tag);

--
-- Name: player_rankings_current player_rankings_current_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.player_rankings_current
    ADD CONSTRAINT player_rankings_current_pkey PRIMARY KEY (player_tag, ranking_type, location_id);

--
-- Name: ranked_league_group_members ranked_league_group_members_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.ranked_league_group_members
    ADD CONSTRAINT ranked_league_group_members_pkey PRIMARY KEY (season_id, group_tag, player_tag);

--
-- Name: tracking_sync_cursors tracking_sync_cursors_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.tracking_sync_cursors
    ADD CONSTRAINT tracking_sync_cursors_pkey PRIMARY KEY (name);

--
-- Name: war_archive_packs war_archive_packs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.war_archive_packs
    ADD CONSTRAINT war_archive_packs_pkey PRIMARY KEY (pack_id);

--
-- Name: war_archive_pending war_archive_pending_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.war_archive_pending
    ADD CONSTRAINT war_archive_pending_pkey PRIMARY KEY (war_id, end_time);

--
-- Name: player_war_history player_war_history_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.player_war_history
    ADD CONSTRAINT player_war_history_pkey PRIMARY KEY (player_tag);

--
-- Name: war_schedule war_schedule_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.war_schedule
    ADD CONSTRAINT war_schedule_pkey PRIMARY KEY (schedule_key);

--
-- Name: war_schedule war_schedule_war_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.war_schedule
    ADD CONSTRAINT war_schedule_war_id_key UNIQUE (war_id);

ALTER TABLE public.war_reminder_jobs
    ADD CONSTRAINT war_reminder_jobs_pkey PRIMARY KEY (schedule_key, minutes_remaining);

--
-- Name: wars wars_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE public.wars
    ADD CONSTRAINT wars_pkey PRIMARY KEY (war_id, end_time);

ALTER SEQUENCE public.war_id_seq OWNED BY public.wars.war_id;

ALTER TABLE public.war_archive_pending
    ADD CONSTRAINT war_archive_pending_war_fkey FOREIGN KEY (war_id, end_time) REFERENCES public.wars(war_id, end_time) ON DELETE CASCADE;

ALTER TABLE public.war_archive_pending
    ADD CONSTRAINT war_archive_pending_pack_fkey FOREIGN KEY (pack_id) REFERENCES public.war_archive_packs(pack_id) ON DELETE SET NULL;

--
-- Name: api_global_counts_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX api_global_counts_id_idx ON public.api_global_counts USING btree (id);

--
-- Name: api_league_tier_counts_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX api_league_tier_counts_id_idx ON public.api_league_tier_counts USING btree (league_tier_id);

--
-- Name: battlelogs_battle_time_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX battlelogs_battle_time_idx ON public.battlelogs USING btree ("timestamp" DESC);

--
-- Name: clan_change_history_event_time_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX clan_change_history_event_time_idx ON public.clan_change_history USING btree (event_time DESC);

--
-- Name: idx_basic_clan_last_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_basic_clan_last_active ON public.basic_clan USING btree (last_active);

CREATE INDEX idx_basic_clan_last_war_at ON public.basic_clan USING btree (last_war_at DESC) WHERE (public_war_log = true);

--
-- Name: idx_basic_clan_member_count; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_basic_clan_member_count ON public.basic_clan USING btree (member_count);

--
-- Name: idx_basic_player_league_trophies; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_basic_player_league_trophies ON public.basic_player USING btree (league_id, trophies DESC) WHERE ((league_id IS NOT NULL) AND (league_id <> 105000000));

--
-- Name: idx_basic_player_townhall_league_trophies; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_basic_player_townhall_league_trophies ON public.basic_player USING btree (townhall_level, league_id DESC, trophies DESC) WHERE ((townhall_level >= 7) AND (league_id IS NOT NULL) AND (league_id <> 105000000));

-- There are deliberately no GIN indexes on the JSON. The global aggregates are
-- occasional batch scans, while a JSON index would make every profile change
-- heavier and would not help a scan that expands every player's arrays.
CREATE INDEX idx_player_profile_details_townhall ON public.player_profile_details USING btree (townhall_level);

--
-- Name: idx_battlelogs_army_counts; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_battlelogs_army_counts ON public.battlelogs USING gin (army_counts) WHERE ((attack = true) AND (player_th = opponent_th) AND (battle_type = ANY (ARRAY['ranked'::text, 'legend'::text])));

--
-- Name: idx_battlelogs_army_items; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_battlelogs_army_items ON public.battlelogs USING gin (army_items) WHERE ((attack = true) AND (player_th = opponent_th) AND (battle_type = ANY (ARRAY['ranked'::text, 'legend'::text])));

--
-- Name: idx_battlelogs_dynamic_search_main; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_battlelogs_dynamic_search_main ON public.battlelogs USING btree (player_th, battle_type, "timestamp" DESC) WHERE ((attack = true) AND (player_th = opponent_th) AND (battle_type = ANY (ARRAY['ranked'::text, 'legend'::text])));

--
-- Name: idx_battlelogs_player_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_battlelogs_player_time ON public.battlelogs USING btree (player_tag, "timestamp" DESC);

--
-- Name: idx_battlelogs_ranked_legend_th_type_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_battlelogs_ranked_legend_th_type_time ON public.battlelogs USING btree (player_th, opponent_th, battle_type, "timestamp" DESC) WHERE (battle_type = ANY (ARRAY['ranked'::text, 'legend'::text]));

--
-- Name: idx_clan_change_history_clan_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_clan_change_history_clan_time ON public.clan_change_history USING btree (clan_tag, event_time DESC);

--
-- Name: idx_clan_change_history_type_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_clan_change_history_type_time ON public.clan_change_history USING btree (change_type, event_time DESC);

--
-- Name: idx_clan_leaderboards_donated_rank; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_clan_leaderboards_donated_rank ON public.clan_leaderboards USING btree (donated_rank);

--
-- Name: idx_clan_leaderboards_location_donated_rank; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_clan_leaderboards_location_donated_rank ON public.clan_leaderboards USING btree (location_id, location_donated_rank);

--
-- Name: idx_clan_leaderboards_location_received_rank; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_clan_leaderboards_location_received_rank ON public.clan_leaderboards USING btree (location_id, location_received_rank);

--
-- Name: idx_clan_leaderboards_location_war_wins_rank; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_clan_leaderboards_location_war_wins_rank ON public.clan_leaderboards USING btree (location_id, location_war_wins_rank);

--
-- Name: idx_clan_leaderboards_received_rank; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_clan_leaderboards_received_rank ON public.clan_leaderboards USING btree (received_rank);

--
-- Name: idx_clan_leaderboards_tag; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_clan_leaderboards_tag ON public.clan_leaderboards USING btree (tag);

--
-- Name: idx_clan_leaderboards_war_win_streak_rank; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_clan_leaderboards_war_win_streak_rank ON public.clan_leaderboards USING btree (war_win_streak_rank) WHERE (war_win_streak_rank IS NOT NULL);

--
-- Name: idx_clan_leaderboards_war_wins_rank; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_clan_leaderboards_war_wins_rank ON public.clan_leaderboards USING btree (war_wins_rank);

--
-- Name: idx_clan_rankings_current_scope_rank; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_clan_rankings_current_scope_rank ON public.clan_rankings_current USING btree (ranking_type, location_id, rank);

--
-- Name: idx_player_timers_expires_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_player_timers_expires_at ON public.player_timers USING btree (expires_at);

--
-- Name: idx_player_timers_player_tag; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_player_timers_player_tag ON public.player_timers USING btree (player_tag);

CREATE INDEX idx_player_timers_event ON public.player_timers USING btree (event_type, event_key);

CREATE INDEX idx_cwl_groups_season_league ON public.cwl_groups USING btree (season, cwl_league_id);

CREATE INDEX idx_cwl_groups_season_league_size ON public.cwl_groups USING btree (season, cwl_league_id, war_size);

CREATE INDEX idx_cwl_group_clans_clan_cwl ON public.cwl_group_clans USING btree (clan_tag, cwl_id DESC);

CREATE INDEX idx_cwl_group_members_cwl_id ON public.cwl_group_members USING btree (cwl_id);

--
-- Name: idx_cwl_standings_clan_season; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_cwl_standings_clan_season ON public.cwl_standings USING btree (clan_tag, season DESC);

--
-- Name: idx_cwl_standings_global_rank; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_cwl_standings_global_rank ON public.cwl_standings USING btree (season, cwl_league_id, war_size, global_rank);

--
-- Name: idx_cwl_standings_group_rank; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_cwl_standings_group_rank ON public.cwl_standings USING btree (cwl_id, group_rank);

--
-- Name: idx_join_leave_history_clan_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_join_leave_history_clan_time ON public.join_leave_history USING btree (clan_tag, "time" DESC);

--
-- Name: idx_join_leave_history_player; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_join_leave_history_player ON public.join_leave_history USING btree (player_tag);

--
-- Name: idx_leaderboard_history_clan_builder_base_clan; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_leaderboard_history_clan_builder_base_clan ON public.leaderboard_history_clan_builder_base USING btree (clan_tag);

--
-- Name: idx_leaderboard_history_clan_capital_clan; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_leaderboard_history_clan_capital_clan ON public.leaderboard_history_clan_capital USING btree (clan_tag);

--
-- Name: idx_leaderboard_history_clan_home_clan; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_leaderboard_history_clan_home_clan ON public.leaderboard_history_clan_home USING btree (clan_tag);

--
-- Name: idx_leaderboard_history_player_builder_base_player; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_leaderboard_history_player_builder_base_player ON public.leaderboard_history_player_builder_base USING btree (player_tag);

--
-- Name: idx_leaderboard_history_player_home_player; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_leaderboard_history_player_home_player ON public.leaderboard_history_player_home USING btree (player_tag);

--
-- Name: idx_legend_history_clan_season; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_legend_history_clan_season ON public.legend_history USING btree (clan_tag, season DESC) WHERE (clan_tag IS NOT NULL);

--
-- Name: idx_legend_history_season_rank; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_legend_history_season_rank ON public.legend_history USING btree (season, rank);

--
-- Name: idx_legend_rankings_current_rank; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_legend_rankings_current_rank ON public.legend_rankings_current USING btree (rank);

--
-- Name: idx_player_change_history_player_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_player_change_history_player_time ON public.player_change_history USING btree (player_tag, event_time DESC);

--
-- Name: idx_player_change_history_type_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_player_change_history_type_time ON public.player_change_history USING btree (change_type, event_time DESC);

--
-- Name: idx_player_online_events_clan_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_player_online_events_clan_time ON public.player_online_events USING btree (clan_tag, seen_at DESC);

--
-- Name: idx_player_online_events_player_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_player_online_events_player_time ON public.player_online_events USING btree (tag, seen_at DESC);

--
-- Name: idx_player_rankings_current_numeric_location; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX idx_player_rankings_current_numeric_location ON public.player_rankings_current USING btree (player_tag, ranking_type) WHERE (location_id <> 'global'::text);

--
-- Name: idx_player_rankings_current_scope_rank; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_player_rankings_current_scope_rank ON public.player_rankings_current USING btree (ranking_type, location_id, rank) WHERE (rank IS NOT NULL);

--
-- Name: idx_player_stat_changes_clan_type_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_player_stat_changes_clan_type_time ON public.player_stat_changes USING btree (clan_tag, stat_type, event_time DESC) WHERE (clan_tag IS NOT NULL);

--
-- Name: idx_player_stat_changes_player_type_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_player_stat_changes_player_type_time ON public.player_stat_changes USING btree (player_tag, stat_type, event_time DESC);

--
-- Name: idx_ranked_group_members_group_placement; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ranked_group_members_group_placement ON public.ranked_league_group_members USING btree (season_id, group_tag, placement);

--
-- Name: idx_ranked_group_members_player_season; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ranked_group_members_player_season ON public.ranked_league_group_members USING btree (player_tag, season_id DESC);

--
-- Name: idx_ranked_group_members_season_tier_group; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ranked_group_members_season_tier_group ON public.ranked_league_group_members USING btree (season_id, league_tier_id, group_tag);

--
-- Name: idx_tracking_domain_stats_health_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_tracking_domain_stats_health_time ON public.tracking_domain_stats USING btree (healthy, interval_end DESC) WHERE (healthy = false);

--
-- Name: idx_tracking_domain_stats_name_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_tracking_domain_stats_name_time ON public.tracking_domain_stats USING btree (name, interval_end DESC);

--
-- Name: idx_tracking_domain_stats_run_name_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_tracking_domain_stats_run_name_time ON public.tracking_domain_stats USING btree (run_id, name, interval_end DESC);

--
-- Name: idx_tracking_domain_stats_script_name_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_tracking_domain_stats_script_name_time ON public.tracking_domain_stats USING btree (script, name, interval_end DESC);

--
-- Name: idx_tracking_process_stats_run_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_tracking_process_stats_run_time ON public.tracking_process_stats USING btree (run_id, interval_end DESC);

--
-- Name: idx_tracking_process_stats_script_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_tracking_process_stats_script_time ON public.tracking_process_stats USING btree (script, interval_end DESC);

--
-- Name: idx_war_archive_pending_unclaimed; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_war_archive_pending_unclaimed ON public.war_archive_pending USING btree (created_at, war_id) WHERE (pack_id IS NULL);

--
-- Name: idx_war_archive_pending_pack; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_war_archive_pending_pack ON public.war_archive_pending USING btree (pack_id, war_id) WHERE (pack_id IS NOT NULL);

CREATE UNIQUE INDEX idx_war_archive_packs_migration_checkpoint
    ON public.war_archive_packs USING btree (checkpoint_key, source_checkpoint)
    WHERE ((source = 'migration'::text) AND (checkpoint_key IS NOT NULL) AND (source_checkpoint IS NOT NULL));

--
-- Name: idx_war_schedule_next_run; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_war_schedule_next_run ON public.war_schedule USING btree (next_run_at);

--
-- Name: idx_war_schedule_source_opponent; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_war_schedule_source_opponent ON public.war_schedule USING btree (source_clan_tag, opponent_tag);

CREATE INDEX idx_war_schedule_opponent ON public.war_schedule USING btree (opponent_tag);

CREATE INDEX idx_war_schedule_war_tag ON public.war_schedule USING btree (war_tag) WHERE (war_tag IS NOT NULL);

CREATE INDEX idx_war_reminder_jobs_run_at ON public.war_reminder_jobs USING btree (run_at);

ALTER TABLE public.war_reminder_jobs
    ADD CONSTRAINT war_reminder_jobs_schedule_key_fkey FOREIGN KEY (schedule_key) REFERENCES public.war_schedule(schedule_key) ON DELETE CASCADE;

--
-- Name: idx_wars_clan_end_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_wars_clan_end_time ON public.wars USING btree (clan_tag, end_time DESC);

--
-- Name: idx_wars_opponent_end_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_wars_opponent_end_time ON public.wars USING btree (opponent_tag, end_time DESC);

--
-- Name: idx_wars_war_tag; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_wars_war_tag ON public.wars USING btree (war_tag) WHERE (war_tag IS NOT NULL);

--
-- Name: player_change_history_event_time_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX player_change_history_event_time_idx ON public.player_change_history USING btree (event_time DESC);

--
-- Name: townhall_counts_level_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX townhall_counts_level_idx ON public.townhall_counts USING btree (level);

--
-- Name: tracking_domain_stats_interval_end_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tracking_domain_stats_interval_end_idx ON public.tracking_domain_stats USING btree (interval_end DESC);

--
-- Name: tracking_process_stats_interval_end_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX tracking_process_stats_interval_end_idx ON public.tracking_process_stats USING btree (interval_end DESC);

ALTER TABLE public.battlelogs SET (
    timescaledb.compress,
    timescaledb.compress_orderby = 'timestamp DESC',
    timescaledb.compress_segmentby = 'player_tag'
);

SELECT add_compression_policy(
    'battlelogs',
    compress_after => INTERVAL '35 days',
    if_not_exists => TRUE
);

SELECT add_retention_policy('tracking_process_stats', INTERVAL '14 days', if_not_exists => TRUE);
SELECT add_retention_policy('tracking_domain_stats', INTERVAL '14 days', if_not_exists => TRUE);

-- +goose Down
DROP MATERIALIZED VIEW IF EXISTS public.api_global_counts CASCADE;
DROP MATERIALIZED VIEW IF EXISTS public.api_league_tier_counts CASCADE;
DROP MATERIALIZED VIEW IF EXISTS public.clan_leaderboards CASCADE;
DROP MATERIALIZED VIEW IF EXISTS public.townhall_counts CASCADE;
DROP MATERIALIZED VIEW IF EXISTS public.townhall_stats_daily CASCADE;
DROP MATERIALIZED VIEW IF EXISTS public.war_league_counts CASCADE;
DROP TABLE IF EXISTS public.basic_clan CASCADE;
DROP TABLE IF EXISTS public.player_profile_details CASCADE;
DROP TABLE IF EXISTS public.basic_player CASCADE;
DROP TABLE IF EXISTS public.battlelogs CASCADE;
DROP TABLE IF EXISTS public.clan_change_history CASCADE;
DROP TABLE IF EXISTS public.clan_rankings_current CASCADE;
DROP TABLE IF EXISTS public.clan_records CASCADE;
DROP TABLE IF EXISTS public.player_timers CASCADE;
DROP TABLE IF EXISTS public.cwl_group_clans CASCADE;
DROP TABLE IF EXISTS public.cwl_group_members CASCADE;
DROP TABLE IF EXISTS public.cwl_groups CASCADE;
DROP TABLE IF EXISTS public.cwl_league_history CASCADE;
DROP TABLE IF EXISTS public.cwl_standings CASCADE;
DROP TABLE IF EXISTS public.join_leave_history CASCADE;
DROP TABLE IF EXISTS public.leaderboard_history_clan_builder_base CASCADE;
DROP TABLE IF EXISTS public.leaderboard_history_clan_capital CASCADE;
DROP TABLE IF EXISTS public.leaderboard_history_clan_home CASCADE;
DROP TABLE IF EXISTS public.leaderboard_history_player_builder_base CASCADE;
DROP TABLE IF EXISTS public.leaderboard_history_player_home CASCADE;
DROP TABLE IF EXISTS public.legend_history CASCADE;
DROP TABLE IF EXISTS public.legend_rankings_current CASCADE;
DROP TABLE IF EXISTS public.player_change_history CASCADE;
DROP TABLE IF EXISTS public.player_online_events CASCADE;
DROP TABLE IF EXISTS public.player_rankings_current CASCADE;
DROP TABLE IF EXISTS public.player_stat_changes CASCADE;
DROP TABLE IF EXISTS public.ranked_league_group_members CASCADE;
DROP TABLE IF EXISTS public.tracking_domain_stats CASCADE;
DROP TABLE IF EXISTS public.tracking_process_stats CASCADE;
DROP TABLE IF EXISTS public.tracking_sync_cursors CASCADE;
DROP TABLE IF EXISTS public.player_war_history CASCADE;
DROP TABLE IF EXISTS public.war_archive_pending CASCADE;
DROP TABLE IF EXISTS public.war_reminder_jobs CASCADE;
DROP TABLE IF EXISTS public.war_schedule CASCADE;
DROP TABLE IF EXISTS public.wars CASCADE;
DROP TABLE IF EXISTS public.war_archive_packs CASCADE;
DROP SEQUENCE IF EXISTS public.war_id_seq CASCADE;
DROP SEQUENCE IF EXISTS public.tracking_stats_run_id_seq CASCADE;
