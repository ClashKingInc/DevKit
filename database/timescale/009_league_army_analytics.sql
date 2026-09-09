-- +goose Up
-- Durable league/Legend rollups and immutable army-family classification.

-- +goose StatementBegin
CREATE FUNCTION public.town_hall_distribution_valid(value jsonb)
RETURNS boolean LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE AS $$
DECLARE entry jsonb; previous_level integer := 21; level_value integer;
BEGIN
    IF jsonb_typeof(value) <> 'array' THEN RETURN false; END IF;
    FOR entry IN SELECT element FROM jsonb_array_elements(value) WITH ORDINALITY AS item(element, position) ORDER BY position LOOP
        IF jsonb_typeof(entry) <> 'object'
           OR (SELECT count(*) FROM jsonb_object_keys(entry)) <> 2
           OR NOT (entry ? 'level' AND entry ? 'count')
           OR jsonb_typeof(entry->'level') <> 'number' OR jsonb_typeof(entry->'count') <> 'number'
           OR entry->>'level' !~ '^[0-9]+$' OR entry->>'count' !~ '^[0-9]+$' THEN RETURN false; END IF;
        level_value := (entry->>'level')::integer;
        IF level_value NOT BETWEEN 1 AND 20 OR (entry->>'count')::numeric > 9223372036854775807
           OR level_value >= previous_level THEN RETURN false; END IF;
        previous_level := level_value;
    END LOOP;
    RETURN true;
EXCEPTION WHEN numeric_value_out_of_range THEN RETURN false;
END
$$;
-- +goose StatementEnd

-- +goose StatementBegin
CREATE FUNCTION public.item_usage_triples_valid(value jsonb)
RETURNS boolean LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE AS $$
DECLARE entry jsonb; previous_id integer := -1; id_value integer; uses_value bigint; triples_value bigint;
BEGIN
    IF jsonb_typeof(value) <> 'array' THEN RETURN false; END IF;
    FOR entry IN SELECT element FROM jsonb_array_elements(value) WITH ORDINALITY AS item(element, position) ORDER BY position LOOP
        IF jsonb_typeof(entry) <> 'object' OR (SELECT count(*) FROM jsonb_object_keys(entry)) <> 3
           OR NOT (entry ? 'id' AND entry ? 'uses' AND entry ? 'triples')
           OR jsonb_typeof(entry->'id') <> 'number' OR jsonb_typeof(entry->'uses') <> 'number' OR jsonb_typeof(entry->'triples') <> 'number'
           OR entry->>'id' !~ '^[0-9]+$' OR entry->>'uses' !~ '^[0-9]+$' OR entry->>'triples' !~ '^[0-9]+$'
           OR (entry->>'id')::numeric > 2147483647 OR (entry->>'uses')::numeric > 9223372036854775807
           OR (entry->>'triples')::numeric > 9223372036854775807 THEN RETURN false; END IF;
        id_value := (entry->>'id')::integer; uses_value := (entry->>'uses')::bigint; triples_value := (entry->>'triples')::bigint;
        IF id_value <= previous_id OR triples_value > uses_value THEN RETURN false; END IF;
        previous_id := id_value;
    END LOOP;
    RETURN true;
EXCEPTION WHEN numeric_value_out_of_range THEN RETURN false;
END
$$;
-- +goose StatementEnd

-- +goose StatementBegin
CREATE FUNCTION public.pet_hero_usage_triples_valid(value jsonb)
RETURNS boolean LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE AS $$
DECLARE entry jsonb; previous_pet integer := -1; previous_hero integer := -1; pet_value integer; hero_value integer; uses_value bigint; triples_value bigint;
BEGIN
    IF jsonb_typeof(value) <> 'array' THEN RETURN false; END IF;
    FOR entry IN SELECT element FROM jsonb_array_elements(value) WITH ORDINALITY AS item(element, position) ORDER BY position LOOP
        IF jsonb_typeof(entry) <> 'object' OR (SELECT count(*) FROM jsonb_object_keys(entry)) <> 4
           OR NOT (entry ? 'petId' AND entry ? 'heroId' AND entry ? 'uses' AND entry ? 'triples')
           OR jsonb_typeof(entry->'petId') <> 'number' OR jsonb_typeof(entry->'heroId') <> 'number'
           OR jsonb_typeof(entry->'uses') <> 'number' OR jsonb_typeof(entry->'triples') <> 'number'
           OR entry->>'petId' !~ '^[0-9]+$' OR entry->>'heroId' !~ '^[0-9]+$'
           OR entry->>'uses' !~ '^[0-9]+$' OR entry->>'triples' !~ '^[0-9]+$'
           OR (entry->>'petId')::numeric > 2147483647 OR (entry->>'heroId')::numeric > 2147483647
           OR (entry->>'uses')::numeric > 9223372036854775807 OR (entry->>'triples')::numeric > 9223372036854775807 THEN RETURN false; END IF;
        pet_value := (entry->>'petId')::integer; hero_value := (entry->>'heroId')::integer;
        uses_value := (entry->>'uses')::bigint; triples_value := (entry->>'triples')::bigint;
        IF (pet_value < previous_pet OR (pet_value = previous_pet AND hero_value <= previous_hero)) OR triples_value > uses_value THEN RETURN false; END IF;
        previous_pet := pet_value; previous_hero := hero_value;
    END LOOP;
    RETURN true;
EXCEPTION WHEN numeric_value_out_of_range THEN RETURN false;
END
$$;
-- +goose StatementEnd

CREATE TABLE public.league_hitrate_stats (
    period_kind text NOT NULL,
    period_start timestamptz NOT NULL,
    league_tier_id integer NOT NULL,
    town_hall smallint NOT NULL,
    attack_count bigint NOT NULL,
    zero_star_count bigint NOT NULL,
    one_star_count bigint NOT NULL,
    two_star_count bigint NOT NULL,
    three_star_count bigint NOT NULL,
    refreshed_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (period_kind, period_start, league_tier_id, town_hall),
    CONSTRAINT league_hitrate_period_kind_check CHECK (period_kind IN ('ranked_season','legend_day')),
    CONSTRAINT league_hitrate_tier_check CHECK (league_tier_id > 0),
    CONSTRAINT league_hitrate_town_hall_check CHECK (town_hall BETWEEN 1 AND 20),
    CONSTRAINT league_hitrate_counts_check CHECK (attack_count >= 0 AND zero_star_count >= 0 AND one_star_count >= 0 AND two_star_count >= 0 AND three_star_count >= 0 AND attack_count = zero_star_count + one_star_count + two_star_count + three_star_count)
);

CREATE TABLE public.ranked_league_tier_stats (
    season_id bigint NOT NULL,
    league_tier_id integer NOT NULL,
    group_count bigint NOT NULL,
    distinct_player_count bigint NOT NULL,
    participating_player_count bigint NOT NULL,
    trophy_p10 integer,
    trophy_p25 integer,
    trophy_p50 integer,
    trophy_p75 integer,
    trophy_p90 integer,
    town_halls jsonb NOT NULL DEFAULT '[]'::jsonb,
    average_group_first_last_trophy_range numeric,
    average_first_second_trophy_gap numeric,
    refreshed_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (season_id, league_tier_id),
    CONSTRAINT ranked_league_tier_stats_identity_check CHECK (season_id > 0 AND league_tier_id > 0),
    CONSTRAINT ranked_league_tier_stats_counts_check CHECK (group_count >= 0 AND distinct_player_count >= 0 AND participating_player_count >= 0 AND participating_player_count <= distinct_player_count),
    CONSTRAINT ranked_league_tier_stats_percentiles_check CHECK (
        (trophy_p10 IS NULL AND trophy_p25 IS NULL AND trophy_p50 IS NULL AND trophy_p75 IS NULL AND trophy_p90 IS NULL)
        OR (trophy_p10 >= 0 AND trophy_p25 IS NOT NULL AND trophy_p50 IS NOT NULL AND trophy_p75 IS NOT NULL AND trophy_p90 IS NOT NULL
            AND trophy_p10 <= trophy_p25 AND trophy_p25 <= trophy_p50 AND trophy_p50 <= trophy_p75 AND trophy_p75 <= trophy_p90)
    ),
    CONSTRAINT ranked_league_tier_stats_town_halls_check CHECK (public.town_hall_distribution_valid(town_halls)),
    CONSTRAINT ranked_league_tier_stats_ranges_check CHECK ((average_group_first_last_trophy_range IS NULL OR average_group_first_last_trophy_range >= 0) AND (average_first_second_trophy_gap IS NULL OR average_first_second_trophy_gap >= 0))
);

CREATE TABLE public.legend_daily_stats (
    day date NOT NULL,
    league_tier_id integer NOT NULL,
    town_hall smallint NOT NULL,
    attack_count bigint NOT NULL,
    distinct_player_count bigint NOT NULL,
    perfect_320_player_count bigint NOT NULL,
    zero_star_count bigint NOT NULL,
    one_star_count bigint NOT NULL,
    two_star_count bigint NOT NULL,
    three_star_count bigint NOT NULL,
    destruction_percentage_sum bigint NOT NULL,
    duration_seconds_sum bigint NOT NULL,
    hero_stats jsonb NOT NULL DEFAULT '[]'::jsonb,
    pet_stats jsonb NOT NULL DEFAULT '[]'::jsonb,
    equipment_stats jsonb NOT NULL DEFAULT '[]'::jsonb,
    pet_hero_assignments jsonb NOT NULL DEFAULT '[]'::jsonb,
    refreshed_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (day, league_tier_id, town_hall),
    CONSTRAINT legend_daily_stats_identity_check CHECK (league_tier_id > 0 AND town_hall BETWEEN 1 AND 20),
    CONSTRAINT legend_daily_stats_counts_check CHECK (attack_count >= 0 AND distinct_player_count >= 0 AND perfect_320_player_count >= 0 AND perfect_320_player_count <= distinct_player_count AND zero_star_count >= 0 AND one_star_count >= 0 AND two_star_count >= 0 AND three_star_count >= 0 AND attack_count = zero_star_count + one_star_count + two_star_count + three_star_count),
    CONSTRAINT legend_daily_stats_sums_check CHECK (destruction_percentage_sum BETWEEN 0 AND attack_count * 100 AND duration_seconds_sum >= 0),
    CONSTRAINT legend_daily_stats_heroes_check CHECK (public.item_usage_triples_valid(hero_stats)),
    CONSTRAINT legend_daily_stats_pets_check CHECK (public.item_usage_triples_valid(pet_stats)),
    CONSTRAINT legend_daily_stats_equipment_check CHECK (public.item_usage_triples_valid(equipment_stats)),
    CONSTRAINT legend_daily_stats_pet_hero_check CHECK (public.pet_hero_usage_triples_valid(pet_hero_assignments))
);

CREATE TABLE public.army_families (
    anchor_army_hash bytea NOT NULL,
    representative_share_code text NOT NULL,
    family_name text NOT NULL,
    source text NOT NULL,
    named_by_subject text,
    naming_model text,
    naming_prompt_version text,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (anchor_army_hash),
    FOREIGN KEY (anchor_army_hash, representative_share_code) REFERENCES public.army_compositions(army_hash, normalized_share_code),
    CONSTRAINT army_families_name_check CHECK (btrim(family_name) <> ''),
    CONSTRAINT army_families_source_check CHECK (source IN ('ai','admin','fallback')),
    CONSTRAINT army_families_provenance_check CHECK (
        (source = 'ai' AND named_by_subject IS NULL AND naming_model IS NOT NULL AND btrim(naming_model) <> '' AND naming_prompt_version IS NOT NULL AND btrim(naming_prompt_version) <> '')
        OR (source = 'admin' AND named_by_subject IS NOT NULL AND btrim(named_by_subject) <> '' AND naming_model IS NULL AND naming_prompt_version IS NULL)
        OR (source = 'fallback' AND named_by_subject IS NULL AND naming_model IS NULL AND naming_prompt_version IS NULL)
    )
);
CREATE UNIQUE INDEX army_families_name_unique ON public.army_families (lower(family_name));

CREATE TABLE public.army_family_members (
    army_hash bytea PRIMARY KEY REFERENCES public.army_compositions(army_hash),
    anchor_army_hash bytea NOT NULL REFERENCES public.army_families(anchor_army_hash),
    troop_housing_similarity numeric(5,4) NOT NULL,
    spell_capacity_similarity numeric(5,4) NOT NULL,
    heroes_exact boolean NOT NULL,
    equipment_similarity numeric(5,4) NOT NULL,
    equipment_difference_count smallint NOT NULL,
    matching_version text NOT NULL,
    assigned_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT army_family_members_similarity_check CHECK (troop_housing_similarity BETWEEN 0.8600 AND 1 AND spell_capacity_similarity BETWEEN 0.8000 AND 1 AND heroes_exact AND equipment_similarity BETWEEN 0.7500 AND 1 AND equipment_difference_count BETWEEN 0 AND 2),
    CONSTRAINT army_family_members_version_check CHECK (btrim(matching_version) <> '')
);

CREATE TABLE public.army_family_daily_stats (
    anchor_army_hash bytea NOT NULL REFERENCES public.army_families(anchor_army_hash),
    day date NOT NULL,
    attack_count bigint NOT NULL,
    distinct_player_count bigint NOT NULL,
    zero_star_count bigint NOT NULL,
    one_star_count bigint NOT NULL,
    two_star_count bigint NOT NULL,
    three_star_count bigint NOT NULL,
    destruction_percentage_sum bigint NOT NULL,
    duration_seconds_sum bigint NOT NULL,
    refreshed_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (anchor_army_hash, day),
    CONSTRAINT army_family_daily_stats_counts_check CHECK (attack_count >= 0 AND distinct_player_count >= 0 AND zero_star_count >= 0 AND one_star_count >= 0 AND two_star_count >= 0 AND three_star_count >= 0 AND attack_count = zero_star_count + one_star_count + two_star_count + three_star_count),
    CONSTRAINT army_family_daily_stats_sums_check CHECK (destruction_percentage_sum BETWEEN 0 AND attack_count * 100 AND duration_seconds_sum >= 0)
);

-- +goose StatementBegin
CREATE FUNCTION public.reject_army_identity_mutation()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION '% is immutable and cannot be %', TG_TABLE_NAME, lower(TG_OP)
        USING ERRCODE = 'integrity_constraint_violation';
END
$$;
-- +goose StatementEnd

-- +goose StatementBegin
CREATE FUNCTION public.protect_army_family_anchor()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'army family anchors cannot be deleted' USING ERRCODE = 'integrity_constraint_violation';
    END IF;
    IF NEW.anchor_army_hash <> OLD.anchor_army_hash
       OR NEW.representative_share_code <> OLD.representative_share_code THEN
        RAISE EXCEPTION 'army family anchors cannot be changed' USING ERRCODE = 'integrity_constraint_violation';
    END IF;
    NEW.updated_at := clock_timestamp();
    RETURN NEW;
END
$$;
-- +goose StatementEnd

CREATE TRIGGER army_compositions_immutable BEFORE UPDATE OR DELETE ON public.army_compositions FOR EACH ROW EXECUTE FUNCTION public.reject_army_identity_mutation();
CREATE TRIGGER army_compositions_no_truncate BEFORE TRUNCATE ON public.army_compositions FOR EACH STATEMENT EXECUTE FUNCTION public.reject_army_identity_mutation();
CREATE TRIGGER army_families_protect_anchor BEFORE UPDATE OR DELETE ON public.army_families FOR EACH ROW EXECUTE FUNCTION public.protect_army_family_anchor();
CREATE TRIGGER army_families_no_truncate BEFORE TRUNCATE ON public.army_families FOR EACH STATEMENT EXECUTE FUNCTION public.reject_army_identity_mutation();
CREATE TRIGGER army_family_members_immutable BEFORE UPDATE OR DELETE ON public.army_family_members FOR EACH ROW EXECUTE FUNCTION public.reject_army_identity_mutation();
CREATE TRIGGER army_family_members_no_truncate BEFORE TRUNCATE ON public.army_family_members FOR EACH STATEMENT EXECUTE FUNCTION public.reject_army_identity_mutation();

-- +goose Down
DROP TABLE public.army_family_daily_stats;
DROP TRIGGER army_family_members_no_truncate ON public.army_family_members;
DROP TRIGGER army_family_members_immutable ON public.army_family_members;
DROP TABLE public.army_family_members;
DROP TRIGGER army_families_no_truncate ON public.army_families;
DROP TRIGGER army_families_protect_anchor ON public.army_families;
DROP TABLE public.army_families;
DROP TRIGGER army_compositions_no_truncate ON public.army_compositions;
DROP TRIGGER army_compositions_immutable ON public.army_compositions;
DROP FUNCTION public.reject_army_identity_mutation();
DROP FUNCTION public.protect_army_family_anchor();
DROP TABLE public.legend_daily_stats;
DROP TABLE public.ranked_league_tier_stats;
DROP TABLE public.league_hitrate_stats;
DROP FUNCTION public.pet_hero_usage_triples_valid(jsonb);
DROP FUNCTION public.item_usage_triples_valid(jsonb);
DROP FUNCTION public.town_hall_distribution_valid(jsonb);
