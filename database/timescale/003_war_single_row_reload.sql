-- +goose Up
CREATE EXTENSION IF NOT EXISTS timescaledb;

-- +goose StatementBegin
DO $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'basic_clan'
          AND column_name = 'badge_url'
    ) AND NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'basic_clan'
          AND column_name = 'badge_token'
    ) THEN
        ALTER TABLE public.basic_clan RENAME COLUMN badge_url TO badge_token;
    ELSIF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'basic_clan'
          AND column_name = 'badge_token'
    ) THEN
        ALTER TABLE public.basic_clan
            ADD COLUMN badge_token text DEFAULT ''::text NOT NULL;
    END IF;
END $$;
-- +goose StatementEnd

DROP TABLE IF EXISTS public.war_members CASCADE;
DROP TABLE IF EXISTS public.war_missed_attacks CASCADE;
DROP TABLE IF EXISTS public.war_attacks CASCADE;
DROP TABLE IF EXISTS public.wars CASCADE;

CREATE TABLE public.wars (
    war_id text NOT NULL,
    clan_tag text NOT NULL,
    opponent_tag text NOT NULL,
    prep_time timestamp with time zone NOT NULL,
    start_time timestamp with time zone,
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
    CONSTRAINT wars_pkey PRIMARY KEY (war_id),
    CONSTRAINT wars_war_type_check CHECK (war_type = ANY (ARRAY['random'::text, 'cwl'::text, 'friendly'::text]))
);

CREATE TABLE public.war_attacks (
    war_id text NOT NULL,
    war_end_time timestamp with time zone NOT NULL,
    war_type text NOT NULL,
    war_size integer NOT NULL,
    attacking_clan_tag text NOT NULL,
    defending_clan_tag text NOT NULL,
    attacker_tag text NOT NULL,
    attacker_name text DEFAULT ''::text NOT NULL,
    defender_tag text NOT NULL,
    defender_name text DEFAULT ''::text NOT NULL,
    attacker_townhall smallint NOT NULL,
    defender_townhall smallint NOT NULL,
    attacker_map_position smallint NOT NULL,
    defender_map_position smallint NOT NULL,
    stars smallint NOT NULL,
    destruction_percentage smallint NOT NULL,
    duration integer NOT NULL,
    attack_order integer NOT NULL,
    battle_modifier text DEFAULT 'none'::text NOT NULL
);

SELECT create_hypertable(
    'war_attacks',
    'war_end_time',
    chunk_time_interval => INTERVAL '3 months',
    create_default_indexes => FALSE,
    if_not_exists => TRUE
);

ALTER TABLE public.war_attacks
    ADD CONSTRAINT war_attacks_pkey PRIMARY KEY (war_id, war_end_time, attacker_tag, defender_tag, attack_order);

CREATE TABLE public.war_members (
    war_id text NOT NULL,
    war_end_time timestamp with time zone NOT NULL,
    clan_tag text NOT NULL,
    opponent_tag text NOT NULL,
    player_tag text NOT NULL,
    player_name text DEFAULT ''::text NOT NULL,
    townhall_level smallint NOT NULL,
    map_position smallint NOT NULL
);

SELECT create_hypertable(
    'war_members',
    'war_end_time',
    chunk_time_interval => INTERVAL '3 months',
    create_default_indexes => FALSE,
    if_not_exists => TRUE
);

ALTER TABLE public.war_members
    ADD CONSTRAINT war_members_pkey PRIMARY KEY (war_id, war_end_time, clan_tag, player_tag);

CREATE TABLE public.war_missed_attacks (
    war_id text NOT NULL,
    war_end_time timestamp with time zone NOT NULL,
    clan_tag text NOT NULL,
    opponent_tag text NOT NULL,
    player_tag text NOT NULL,
    player_name text DEFAULT ''::text NOT NULL,
    townhall_level smallint NOT NULL,
    map_position smallint NOT NULL,
    expected_attacks smallint NOT NULL,
    attack_count smallint NOT NULL,
    missed_attacks smallint NOT NULL
);

SELECT create_hypertable(
    'war_missed_attacks',
    'war_end_time',
    chunk_time_interval => INTERVAL '3 months',
    create_default_indexes => FALSE,
    if_not_exists => TRUE
);

ALTER TABLE public.war_missed_attacks
    ADD CONSTRAINT war_missed_attacks_pkey PRIMARY KEY (war_id, war_end_time, player_tag);

CREATE INDEX idx_wars_clan_end_time ON public.wars USING btree (clan_tag, end_time DESC);
CREATE INDEX idx_wars_opponent_end_time ON public.wars USING btree (opponent_tag, end_time DESC);
CREATE INDEX idx_wars_war_tag ON public.wars USING btree (war_tag) WHERE war_tag IS NOT NULL;
CREATE INDEX idx_war_attacks_player_time ON public.war_attacks USING btree (attacker_tag, war_end_time DESC);
CREATE INDEX idx_war_attacks_clan_time ON public.war_attacks USING btree (attacking_clan_tag, war_end_time DESC);
CREATE INDEX idx_war_attacks_hitrate ON public.war_attacks USING btree (attacker_townhall, defender_townhall, war_type, war_end_time DESC);
CREATE INDEX idx_war_members_player_time ON public.war_members USING btree (player_tag, war_end_time DESC);
CREATE INDEX idx_war_missed_attacks_player_time ON public.war_missed_attacks USING btree (player_tag, war_end_time DESC);
CREATE INDEX idx_war_missed_attacks_clan_time ON public.war_missed_attacks USING btree (clan_tag, war_end_time DESC);

-- +goose Down
DROP TABLE IF EXISTS public.war_members CASCADE;
DROP TABLE IF EXISTS public.war_missed_attacks CASCADE;
DROP TABLE IF EXISTS public.war_attacks CASCADE;
DROP TABLE IF EXISTS public.wars CASCADE;
