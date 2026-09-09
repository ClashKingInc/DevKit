-- +goose Up
-- Compact battle history and immutable normalized army identities.

ALTER TABLE public.basic_player
    ADD COLUMN league_group_tag text,
    ADD COLUMN league_season_id bigint;

-- +goose StatementBegin
CREATE FUNCTION public.battle_looted_resources_valid(value jsonb)
RETURNS boolean LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE AS $$
DECLARE
    resource_value jsonb;
BEGIN
    IF jsonb_typeof(value) <> 'object'
       OR EXISTS (SELECT 1 FROM jsonb_object_keys(value) AS key
                  WHERE key NOT IN ('gold','elixir','darkElixir')) THEN
        RETURN false;
    END IF;
    FOR resource_value IN SELECT item.value FROM jsonb_each(value) AS item LOOP
        IF jsonb_typeof(resource_value) <> 'number'
           OR resource_value #>> '{}' !~ '^[0-9]+$'
           OR (resource_value #>> '{}')::numeric > 2147483647 THEN RETURN false; END IF;
    END LOOP;
    RETURN true;
EXCEPTION WHEN numeric_value_out_of_range THEN RETURN false;
END
$$;
-- +goose StatementEnd

-- +goose StatementBegin
CREATE FUNCTION public.army_component_rows_valid(value jsonb, component_kind text)
RETURNS boolean LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE AS $$
DECLARE
    entry jsonb;
    previous_id integer := -1;
    previous_clan_castle boolean;
    current_id integer;
    current_clan_castle boolean;
    expected_keys integer;
BEGIN
    IF component_kind NOT IN ('troop','clan_castle_troop','spell','equipment','pet')
       OR jsonb_typeof(value) <> 'array' THEN RETURN false; END IF;
    expected_keys := CASE WHEN component_kind = 'spell' THEN 3 ELSE 2 END;
    FOR entry IN SELECT element FROM jsonb_array_elements(value) WITH ORDINALITY
                 AS item(element, position) ORDER BY position LOOP
        IF jsonb_typeof(entry) <> 'object'
           OR (SELECT count(*) FROM jsonb_object_keys(entry)) <> expected_keys
           THEN RETURN false; END IF;
        IF component_kind IN ('troop','clan_castle_troop','spell') THEN
            IF NOT (entry ? 'id' AND entry ? 'quantity')
               OR jsonb_typeof(entry->'id') <> 'number' OR jsonb_typeof(entry->'quantity') <> 'number'
               OR entry->>'id' !~ '^[0-9]+$' OR entry->>'quantity' !~ '^[1-9][0-9]*$'
               OR (entry->>'id')::numeric > 2147483647 OR (entry->>'quantity')::numeric > 32767 THEN RETURN false; END IF;
            IF component_kind = 'spell' AND (NOT entry ? 'clanCastle' OR jsonb_typeof(entry->'clanCastle') <> 'boolean') THEN RETURN false; END IF;
            current_id := (entry->>'id')::integer;
            IF component_kind = 'spell' THEN current_clan_castle := (entry->>'clanCastle')::boolean; END IF;
        ELSIF component_kind = 'equipment' THEN
            IF NOT (entry ? 'equipmentId' AND entry ? 'heroId') OR jsonb_typeof(entry->'equipmentId') <> 'number' OR jsonb_typeof(entry->'heroId') <> 'number' OR entry->>'equipmentId' !~ '^[0-9]+$' OR entry->>'heroId' !~ '^[0-9]+$'
               OR (entry->>'equipmentId')::numeric > 2147483647 OR (entry->>'heroId')::numeric > 2147483647 THEN RETURN false; END IF;
            current_id := (entry->>'equipmentId')::integer;
        ELSE
            IF NOT (entry ? 'petId' AND entry ? 'heroId') OR jsonb_typeof(entry->'petId') <> 'number' OR jsonb_typeof(entry->'heroId') <> 'number' OR entry->>'petId' !~ '^[0-9]+$' OR entry->>'heroId' !~ '^[0-9]+$'
               OR (entry->>'petId')::numeric > 2147483647 OR (entry->>'heroId')::numeric > 2147483647 THEN RETURN false; END IF;
            current_id := (entry->>'petId')::integer;
        END IF;
        IF component_kind = 'spell' THEN
            IF current_id < previous_id OR (current_id = previous_id AND current_clan_castle <= previous_clan_castle) THEN RETURN false; END IF;
            previous_clan_castle := current_clan_castle;
        ELSIF current_id <= previous_id THEN RETURN false;
        END IF;
        previous_id := current_id;
    END LOOP;
    RETURN true;
EXCEPTION WHEN numeric_value_out_of_range THEN RETURN false;
END
$$;
-- +goose StatementEnd

-- +goose StatementBegin
CREATE FUNCTION public.army_hero_ids_valid(value integer[])
RETURNS boolean LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE AS $$
DECLARE item_index integer;
BEGIN
    IF cardinality(value) = 0 THEN RETURN true; END IF;
    IF array_ndims(value) <> 1 OR array_lower(value, 1) <> 1 THEN RETURN false; END IF;
    FOR item_index IN 1..cardinality(value) LOOP
        IF value[item_index] IS NULL OR value[item_index] < 0
           OR (item_index > 1 AND value[item_index] <= value[item_index - 1]) THEN RETURN false; END IF;
    END LOOP;
    RETURN true;
END
$$;
-- +goose StatementEnd

CREATE TABLE public.army_compositions (
    army_hash bytea NOT NULL,
    normalized_share_code text NOT NULL,
    main_troops jsonb NOT NULL DEFAULT '[]'::jsonb,
    clan_castle_troops jsonb NOT NULL DEFAULT '[]'::jsonb,
    spells jsonb NOT NULL DEFAULT '[]'::jsonb,
    heroes integer[] NOT NULL DEFAULT '{}'::integer[],
    equipment jsonb NOT NULL DEFAULT '[]'::jsonb,
    pet_assignments jsonb NOT NULL DEFAULT '[]'::jsonb,
    siege_machine_id integer,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (army_hash),
    UNIQUE (normalized_share_code),
    UNIQUE (army_hash, normalized_share_code),
    CONSTRAINT army_compositions_hash_length CHECK (octet_length(army_hash) = 32),
    CONSTRAINT army_compositions_share_code_check CHECK (btrim(normalized_share_code) <> ''),
    CONSTRAINT army_compositions_main_troops_check CHECK (public.army_component_rows_valid(main_troops,'troop')),
    CONSTRAINT army_compositions_clan_castle_troops_check CHECK (public.army_component_rows_valid(clan_castle_troops,'clan_castle_troop')),
    CONSTRAINT army_compositions_spells_check CHECK (public.army_component_rows_valid(spells,'spell')),
    CONSTRAINT army_compositions_heroes_check CHECK (public.army_hero_ids_valid(heroes)),
    CONSTRAINT army_compositions_equipment_check CHECK (public.army_component_rows_valid(equipment,'equipment')),
    CONSTRAINT army_compositions_pets_check CHECK (public.army_component_rows_valid(pet_assignments,'pet')),
    CONSTRAINT army_compositions_siege_check CHECK (siege_machine_id IS NULL OR siege_machine_id >= 0)
);

CREATE TABLE public.battles_farming (
    player_tag text NOT NULL,
    battle_time timestamptz NOT NULL,
    stars smallint NOT NULL,
    destruction_percentage smallint NOT NULL,
    duration_seconds integer,
    looted_resources jsonb NOT NULL DEFAULT '{}'::jsonb,
    share_code text,
    PRIMARY KEY (player_tag, battle_time),
    CONSTRAINT battles_farming_player_tag_check CHECK (player_tag ~ '^#[0289PYLQGRJCUV]{1,15}$'),
    CONSTRAINT battles_farming_stars_check CHECK (stars BETWEEN 0 AND 3),
    CONSTRAINT battles_farming_destruction_check CHECK (destruction_percentage BETWEEN 0 AND 100),
    CONSTRAINT battles_farming_duration_check CHECK (duration_seconds IS NULL OR duration_seconds >= 0),
    CONSTRAINT battles_farming_loot_check CHECK (public.battle_looted_resources_valid(looted_resources)),
    CONSTRAINT battles_farming_share_code_check CHECK (share_code IS NULL OR btrim(share_code) <> '')
);
SELECT create_hypertable('battles_farming','battle_time', chunk_time_interval => INTERVAL '30 days', create_default_indexes => FALSE, if_not_exists => TRUE);
ALTER TABLE public.battles_farming SET (timescaledb.compress, timescaledb.compress_orderby = 'battle_time DESC', timescaledb.compress_segmentby = 'player_tag');
SELECT add_compression_policy('battles_farming', compress_after => INTERVAL '30 days', if_not_exists => TRUE);
SELECT add_retention_policy('battles_farming', drop_after => INTERVAL '1 year', if_not_exists => TRUE);

-- One physical attack is stored twice for player history. Aggregate readers
-- count only direction='attack', so the defense perspective never doubles it.
CREATE TABLE public.battles_ranked (
    player_tag text NOT NULL,
    opponent_tag text NOT NULL,
    battle_time timestamptz NOT NULL,
    direction text NOT NULL,
    battle_mode text NOT NULL,
    player_town_hall smallint NOT NULL,
    opponent_town_hall smallint NOT NULL,
    stars smallint NOT NULL,
    destruction_percentage smallint NOT NULL,
    duration_seconds integer,
    looted_resources jsonb NOT NULL DEFAULT '{}'::jsonb,
    share_code text,
    army_hash bytea NOT NULL REFERENCES public.army_compositions(army_hash),
    PRIMARY KEY (player_tag, battle_time, battle_mode, direction, opponent_tag),
    CONSTRAINT battles_ranked_player_tag_check CHECK (player_tag ~ '^#[0289PYLQGRJCUV]{1,15}$'),
    CONSTRAINT battles_ranked_opponent_tag_check CHECK (opponent_tag ~ '^#[0289PYLQGRJCUV]{1,15}$'),
    CONSTRAINT battles_ranked_distinct_players_check CHECK (player_tag <> opponent_tag),
    CONSTRAINT battles_ranked_direction_check CHECK (direction IN ('attack','defense')),
    CONSTRAINT battles_ranked_mode_check CHECK (battle_mode IN ('ranked','legend')),
    CONSTRAINT battles_ranked_player_th_check CHECK (player_town_hall BETWEEN 1 AND 20),
    CONSTRAINT battles_ranked_opponent_th_check CHECK (opponent_town_hall BETWEEN 1 AND 20),
    CONSTRAINT battles_ranked_stars_check CHECK (stars BETWEEN 0 AND 3),
    CONSTRAINT battles_ranked_destruction_check CHECK (destruction_percentage BETWEEN 0 AND 100),
    CONSTRAINT battles_ranked_duration_check CHECK (duration_seconds IS NULL OR duration_seconds >= 0),
    CONSTRAINT battles_ranked_loot_check CHECK (public.battle_looted_resources_valid(looted_resources)),
    CONSTRAINT battles_ranked_share_code_check CHECK (share_code IS NULL OR btrim(share_code) <> ''),
    CONSTRAINT battles_ranked_army_hash_length CHECK (octet_length(army_hash) = 32),
    CONSTRAINT battles_ranked_share_code_hash_fkey FOREIGN KEY (army_hash, share_code)
        REFERENCES public.army_compositions(army_hash, normalized_share_code)
);
SELECT create_hypertable('battles_ranked','battle_time', chunk_time_interval => INTERVAL '7 days', create_default_indexes => FALSE, if_not_exists => TRUE);
CREATE INDEX idx_battles_ranked_player_time ON public.battles_ranked (player_tag, battle_time DESC);
CREATE INDEX idx_battles_ranked_player_mode_time ON public.battles_ranked (player_tag, battle_mode, battle_time DESC);
CREATE INDEX idx_battles_ranked_player_direction_time ON public.battles_ranked (player_tag, direction, battle_time DESC);
CREATE INDEX idx_battles_ranked_attacks_time ON public.battles_ranked (battle_mode, battle_time DESC, player_town_hall, opponent_town_hall, army_hash) WHERE direction = 'attack';
ALTER TABLE public.battles_ranked SET (timescaledb.compress, timescaledb.compress_orderby = 'battle_time DESC', timescaledb.compress_segmentby = 'player_tag,battle_mode,direction');
SELECT add_compression_policy('battles_ranked', compress_after => INTERVAL '30 days', if_not_exists => TRUE);
SELECT add_retention_policy('battles_ranked', drop_after => INTERVAL '1 year', if_not_exists => TRUE);

-- The source group response has no durable group data beyond its member rows.
ALTER TABLE public.ranked_league_group_members RENAME COLUMN attack_lose_count TO attack_loss_count;
ALTER TABLE public.ranked_league_group_members RENAME COLUMN defense_lose_count TO defense_loss_count;
ALTER TABLE public.ranked_league_group_members
    ALTER COLUMN attack_win_count SET DEFAULT 0,
    ALTER COLUMN attack_loss_count SET DEFAULT 0,
    ALTER COLUMN defense_win_count SET DEFAULT 0,
    ALTER COLUMN defense_loss_count SET DEFAULT 0,
    ADD COLUMN town_hall smallint,
    ADD COLUMN maximum_battle_count smallint NOT NULL DEFAULT 0,
    ADD COLUMN attack_star_count integer NOT NULL DEFAULT 0,
    ADD COLUMN defense_star_count integer NOT NULL DEFAULT 0,
    ADD COLUMN registered_attack_count integer NOT NULL DEFAULT 0,
    ADD COLUMN registered_defense_count integer NOT NULL DEFAULT 0,
    ADD COLUMN observed_attack_count integer NOT NULL DEFAULT 0,
    ADD COLUMN observed_defense_count integer NOT NULL DEFAULT 0,
    DROP COLUMN clan_tag,
    DROP COLUMN clan_name;

-- Preserve the official totals from existing group snapshots. The migration
-- does not claim any corresponding battle observations; ingestion can replace
-- those zeroes as it reconciles the retained rows with captured battle data.
UPDATE public.ranked_league_group_members
SET registered_attack_count = attack_win_count + attack_loss_count,
    registered_defense_count = defense_win_count + defense_loss_count;

ALTER TABLE public.ranked_league_group_members
    ADD COLUMN missing_real_attacks integer GENERATED ALWAYS AS (GREATEST(registered_attack_count - observed_attack_count, 0)) STORED,
    ADD COLUMN missing_real_defenses integer GENERATED ALWAYS AS (GREATEST(registered_defense_count - observed_defense_count, 0)) STORED,
    ADD COLUMN attacks_complete boolean GENERATED ALWAYS AS (observed_attack_count >= registered_attack_count) STORED,
    ADD COLUMN defenses_complete boolean GENERATED ALWAYS AS (observed_defense_count >= registered_defense_count) STORED,
    ADD CONSTRAINT ranked_group_members_group_tag_check CHECK (group_tag ~ '^#[0289PYLQGRJCUV]{1,15}$' OR group_tag = '#0'),
    ADD CONSTRAINT ranked_group_members_player_tag_check CHECK (player_tag ~ '^#[0289PYLQGRJCUV]{1,15}$'),
    ADD CONSTRAINT ranked_group_members_town_hall_check CHECK (town_hall IS NULL OR town_hall BETWEEN 1 AND 20),
    ADD CONSTRAINT ranked_group_members_tier_check CHECK (league_tier_id > 0),
    ADD CONSTRAINT ranked_group_members_counts_check CHECK (placement > 0 AND league_trophies >= 0 AND maximum_battle_count >= 0 AND attack_win_count >= 0 AND attack_loss_count >= 0 AND attack_star_count >= 0 AND defense_win_count >= 0 AND defense_loss_count >= 0 AND defense_star_count >= 0 AND registered_attack_count >= 0 AND registered_defense_count >= 0 AND observed_attack_count >= 0 AND observed_defense_count >= 0);

-- The previous key allowed one player to remain under multiple corrected group
-- tags in a season and did not record observation time. Retain the snapshot
-- with the most reported battles; stable tie-breakers make every upgrade choose
-- the same row without inventing or combining counters from different groups.
WITH ranked_memberships AS (
    SELECT ctid,
        row_number() OVER (
            PARTITION BY season_id, player_tag
            ORDER BY
                attack_win_count::bigint + attack_loss_count::bigint
                    + defense_win_count::bigint + defense_loss_count::bigint DESC,
                league_trophies DESC,
                league_tier_id DESC,
                placement ASC,
                group_tag ASC
        ) AS preference
    FROM public.ranked_league_group_members
)
DELETE FROM public.ranked_league_group_members AS membership
USING ranked_memberships AS ranked
WHERE membership.ctid = ranked.ctid AND ranked.preference > 1;

ALTER TABLE public.ranked_league_group_members
    ADD CONSTRAINT ranked_group_members_season_player_key UNIQUE (season_id, player_tag);

-- +goose Down
ALTER TABLE public.ranked_league_group_members
    DROP CONSTRAINT ranked_group_members_season_player_key,
    DROP CONSTRAINT ranked_group_members_counts_check,
    DROP CONSTRAINT ranked_group_members_tier_check,
    DROP CONSTRAINT ranked_group_members_town_hall_check,
    DROP CONSTRAINT ranked_group_members_player_tag_check,
    DROP CONSTRAINT ranked_group_members_group_tag_check,
    ADD COLUMN clan_name text,
    ADD COLUMN clan_tag text,
    DROP COLUMN defenses_complete,
    DROP COLUMN attacks_complete,
    DROP COLUMN missing_real_defenses,
    DROP COLUMN missing_real_attacks,
    DROP COLUMN observed_defense_count,
    DROP COLUMN observed_attack_count,
    DROP COLUMN registered_defense_count,
    DROP COLUMN registered_attack_count,
    DROP COLUMN defense_star_count,
    DROP COLUMN attack_star_count,
    DROP COLUMN maximum_battle_count,
    DROP COLUMN town_hall,
    ALTER COLUMN defense_loss_count DROP DEFAULT,
    ALTER COLUMN defense_win_count DROP DEFAULT,
    ALTER COLUMN attack_loss_count DROP DEFAULT,
    ALTER COLUMN attack_win_count DROP DEFAULT;
ALTER TABLE public.ranked_league_group_members RENAME COLUMN defense_loss_count TO defense_lose_count;
ALTER TABLE public.ranked_league_group_members RENAME COLUMN attack_loss_count TO attack_lose_count;
SELECT remove_retention_policy('battles_ranked', if_exists => TRUE);
SELECT remove_compression_policy('battles_ranked', if_exists => TRUE);
DROP TABLE public.battles_ranked;
SELECT remove_retention_policy('battles_farming', if_exists => TRUE);
SELECT remove_compression_policy('battles_farming', if_exists => TRUE);
DROP TABLE public.battles_farming;
DROP TABLE public.army_compositions;
DROP FUNCTION public.army_hero_ids_valid(integer[]);
DROP FUNCTION public.army_component_rows_valid(jsonb,text);
DROP FUNCTION public.battle_looted_resources_valid(jsonb);
ALTER TABLE public.basic_player DROP COLUMN league_season_id, DROP COLUMN league_group_tag;
