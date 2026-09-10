-- +goose Up
-- Expand the army-family schema for normalized share-code identity while old
-- hash readers and writers are retired. The old aggregate tables retain their
-- original semantics; *_v2 tables use the shifted Legend-day contract.
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '5min';

-- +goose StatementBegin
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM public.battles_ranked
        WHERE direction = 'defense' AND looted_resources IS NOT NULL
    ) THEN
        RAISE EXCEPTION 'migration 015 requires clear_ranked_defense_loot to finish first';
    END IF;
END
$$;
-- +goose StatementEnd

ALTER TABLE public.battles_ranked
    ALTER COLUMN army_hash DROP NOT NULL,
    DROP CONSTRAINT battles_ranked_loot_check,
    ADD CONSTRAINT battles_ranked_loot_check CHECK (
        (direction = 'attack' AND looted_resources IS NOT NULL
            AND public.battle_looted_resources_valid(looted_resources))
        OR (direction = 'defense' AND looted_resources IS NULL)
    );
DROP INDEX public.idx_battles_ranked_attacks_time;
CREATE INDEX idx_battles_ranked_attacks_time
    ON public.battles_ranked (battle_mode, battle_time DESC)
    WHERE direction = 'attack';

-- +goose StatementBegin
DO $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM public.army_families family
        LEFT JOIN public.army_compositions composition
          ON (composition.army_hash, composition.normalized_share_code)
           = (family.anchor_army_hash, family.representative_share_code)
        WHERE composition.army_hash IS NULL
    ) THEN
        RAISE EXCEPTION 'army family conversion requires every representative composition';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM public.army_families
        WHERE char_length(regexp_replace(btrim(family_name), '[[:space:]]+', ' ', 'g')) > 120
    ) THEN
        RAISE EXCEPTION 'army family conversion found a name longer than 120 characters';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM public.army_families
        GROUP BY lower(regexp_replace(btrim(family_name), '[[:space:]]+', ' ', 'g'))
        HAVING count(*) > 1
    ) THEN
        RAISE EXCEPTION 'army family conversion found names that collide after normalization';
    END IF;
END
$$;
-- +goose StatementEnd

ALTER TABLE public.army_families
    ADD COLUMN family_id bigint GENERATED ALWAYS AS IDENTITY,
    ADD COLUMN name text,
    ADD COLUMN hero_ids integer[] NOT NULL DEFAULT '{}',
    ADD COLUMN equipment_ids integer[] NOT NULL DEFAULT '{}';

UPDATE public.army_families family
SET name = regexp_replace(btrim(family.family_name), '[[:space:]]+', ' ', 'g'),
    hero_ids = derived.hero_ids,
    equipment_ids = derived.equipment_ids
FROM (
    SELECT composition.army_hash,
           ARRAY(
               SELECT DISTINCT hero_id
               FROM unnest(composition.heroes) AS hero(hero_id)
               ORDER BY hero_id
           ) AS hero_ids,
           ARRAY(
               SELECT DISTINCT (equipment.value->>'equipmentId')::integer
               FROM jsonb_array_elements(composition.equipment) equipment(value)
               ORDER BY (equipment.value->>'equipmentId')::integer
           ) AS equipment_ids
    FROM public.army_compositions composition
) derived
WHERE family.anchor_army_hash = derived.army_hash;

ALTER TABLE public.army_families
    ALTER COLUMN family_name DROP NOT NULL,
    ALTER COLUMN source DROP NOT NULL,
    ADD CONSTRAINT army_families_representative_share_code_key UNIQUE (representative_share_code),
    ADD CONSTRAINT army_families_name_normalized_check CHECK (
        name IS NULL OR (
            name <> ''
            AND char_length(name) <= 120
            AND name = regexp_replace(btrim(name), '[[:space:]]+', ' ', 'g')
        )
    ),
    ADD CONSTRAINT army_families_hero_ids_check CHECK (public.army_hero_ids_valid(hero_ids)),
    ADD CONSTRAINT army_families_equipment_ids_check CHECK (public.army_hero_ids_valid(equipment_ids));
CREATE UNIQUE INDEX army_families_name_v2_unique
    ON public.army_families (lower(name))
    WHERE name IS NOT NULL;

-- Old hash-based inserts are translated forward. New code-based inserts may
-- leave every legacy identity/provenance column null; no hash or composition is
-- synthesized.
ALTER TABLE public.army_family_members
    DROP CONSTRAINT army_family_members_anchor_army_hash_fkey;
ALTER TABLE public.army_family_daily_stats
    DROP CONSTRAINT army_family_daily_stats_anchor_army_hash_fkey;
ALTER TABLE public.army_families
    DROP CONSTRAINT army_families_pkey,
    ADD CONSTRAINT army_families_anchor_army_hash_key UNIQUE (anchor_army_hash),
    ADD CONSTRAINT army_families_pkey PRIMARY KEY (family_id),
    ALTER COLUMN anchor_army_hash DROP NOT NULL;

ALTER TABLE public.army_family_members
    ADD CONSTRAINT army_family_members_anchor_army_hash_fkey
        FOREIGN KEY (anchor_army_hash) REFERENCES public.army_families(anchor_army_hash);
ALTER TABLE public.army_family_daily_stats
    ADD CONSTRAINT army_family_daily_stats_anchor_army_hash_fkey
        FOREIGN KEY (anchor_army_hash) REFERENCES public.army_families(anchor_army_hash);

-- +goose StatementBegin
CREATE FUNCTION public.prepare_compatible_army_family()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    composition public.army_compositions%ROWTYPE;
BEGIN
    IF NEW.representative_share_code IS NULL OR btrim(NEW.representative_share_code) = '' THEN
        RAISE EXCEPTION 'representative share code is required' USING ERRCODE = '23514';
    END IF;
    IF NEW.name IS NOT NULL THEN
        NEW.name := regexp_replace(btrim(NEW.name), '[[:space:]]+', ' ', 'g');
        IF NEW.name = '' THEN NEW.name := NULL; END IF;
    ELSIF NEW.family_name IS NOT NULL THEN
        NEW.name := regexp_replace(btrim(NEW.family_name), '[[:space:]]+', ' ', 'g');
    END IF;

    IF NEW.anchor_army_hash IS NOT NULL THEN
        SELECT * INTO composition
        FROM public.army_compositions
        WHERE army_hash = NEW.anchor_army_hash;
        IF composition.normalized_share_code IS DISTINCT FROM NEW.representative_share_code THEN
            RAISE EXCEPTION 'legacy army hash resolves to a different share code' USING ERRCODE = '23505';
        END IF;
        IF cardinality(NEW.hero_ids) = 0 THEN
            NEW.hero_ids := composition.heroes;
        END IF;
        IF cardinality(NEW.equipment_ids) = 0 THEN
            NEW.equipment_ids := ARRAY(
                SELECT DISTINCT (equipment.value->>'equipmentId')::integer
                FROM jsonb_array_elements(composition.equipment) equipment(value)
                ORDER BY (equipment.value->>'equipmentId')::integer
            );
        END IF;
    END IF;
    RETURN NEW;
END
$$;
-- +goose StatementEnd

CREATE TRIGGER army_families_compatibility_insert
    BEFORE INSERT ON public.army_families
    FOR EACH ROW EXECUTE FUNCTION public.prepare_compatible_army_family();

-- +goose StatementBegin
CREATE OR REPLACE FUNCTION public.protect_army_family_anchor()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'army family identities cannot be deleted' USING ERRCODE = 'integrity_constraint_violation';
    END IF;
    IF NEW.anchor_army_hash IS DISTINCT FROM OLD.anchor_army_hash
       OR NEW.family_id IS DISTINCT FROM OLD.family_id
       OR NEW.representative_share_code IS DISTINCT FROM OLD.representative_share_code
       OR NEW.hero_ids IS DISTINCT FROM OLD.hero_ids
       OR NEW.equipment_ids IS DISTINCT FROM OLD.equipment_ids THEN
        RAISE EXCEPTION 'army family identities and representatives cannot be changed'
            USING ERRCODE = 'integrity_constraint_violation';
    END IF;
    NEW.updated_at := clock_timestamp();
    RETURN NEW;
END
$$;
-- +goose StatementEnd

ALTER TABLE public.army_family_members
    ADD COLUMN share_code text,
    ADD COLUMN family_id bigint,
    ADD COLUMN troop_similarity numeric(5,4),
    ADD COLUMN spell_similarity numeric(5,4);

ALTER TABLE public.army_family_members DISABLE TRIGGER army_family_members_immutable;
UPDATE public.army_family_members member
SET share_code = composition.normalized_share_code,
    family_id = family.family_id,
    troop_similarity = member.troop_housing_similarity,
    spell_similarity = member.spell_capacity_similarity
FROM public.army_compositions composition,
     public.army_families family
WHERE composition.army_hash = member.army_hash
  AND family.anchor_army_hash = member.anchor_army_hash;
ALTER TABLE public.army_family_members ENABLE TRIGGER army_family_members_immutable;

-- +goose StatementBegin
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM public.army_family_members
        WHERE share_code IS NULL OR family_id IS NULL
           OR troop_similarity IS NULL OR spell_similarity IS NULL
    ) THEN
        RAISE EXCEPTION 'army family member conversion could not resolve a code or family';
    END IF;
END
$$;
-- +goose StatementEnd

ALTER TABLE public.army_family_members
    DROP CONSTRAINT army_family_members_pkey,
    ADD CONSTRAINT army_family_members_army_hash_key UNIQUE (army_hash),
    ADD CONSTRAINT army_family_members_pkey PRIMARY KEY (share_code),
    ALTER COLUMN army_hash DROP NOT NULL,
    ALTER COLUMN anchor_army_hash DROP NOT NULL,
    ALTER COLUMN troop_housing_similarity DROP NOT NULL,
    ALTER COLUMN spell_capacity_similarity DROP NOT NULL,
    ALTER COLUMN heroes_exact DROP NOT NULL,
    ALTER COLUMN equipment_difference_count DROP NOT NULL,
    ALTER COLUMN matching_version DROP NOT NULL,
    ALTER COLUMN family_id SET NOT NULL,
    ALTER COLUMN troop_similarity SET NOT NULL,
    ALTER COLUMN spell_similarity SET NOT NULL,
    ADD CONSTRAINT army_family_members_family_id_fkey
        FOREIGN KEY (family_id) REFERENCES public.army_families(family_id),
    ADD CONSTRAINT army_family_members_code_check CHECK (btrim(share_code) <> ''),
    ADD CONSTRAINT army_family_members_v2_similarity_check CHECK (
        troop_similarity BETWEEN 0.8600 AND 1
        AND spell_similarity BETWEEN 0.8000 AND 1
        AND equipment_similarity BETWEEN 0.7500 AND 1
    );
CREATE INDEX army_family_members_family_code_idx
    ON public.army_family_members (family_id, share_code);

-- +goose StatementBegin
CREATE FUNCTION public.prepare_compatible_army_family_member()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.share_code IS NULL AND NEW.army_hash IS NOT NULL THEN
        SELECT normalized_share_code INTO NEW.share_code
        FROM public.army_compositions
        WHERE army_hash = NEW.army_hash;
    END IF;
    IF NEW.family_id IS NULL AND NEW.anchor_army_hash IS NOT NULL THEN
        SELECT family_id INTO NEW.family_id
        FROM public.army_families
        WHERE anchor_army_hash = NEW.anchor_army_hash;
    END IF;
    NEW.troop_similarity := COALESCE(NEW.troop_similarity, NEW.troop_housing_similarity);
    NEW.spell_similarity := COALESCE(NEW.spell_similarity, NEW.spell_capacity_similarity);
    RETURN NEW;
END
$$;
-- +goose StatementEnd

CREATE TRIGGER army_family_members_compatibility_insert
    BEFORE INSERT ON public.army_family_members
    FOR EACH ROW EXECUTE FUNCTION public.prepare_compatible_army_family_member();

-- +goose StatementBegin
CREATE FUNCTION public.item_usage_triples_within_attack_count(value jsonb, attack_limit bigint)
RETURNS boolean LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE AS $$
DECLARE entry jsonb;
BEGIN
    IF attack_limit < 0 OR NOT public.item_usage_triples_valid(value) THEN RETURN false; END IF;
    FOR entry IN SELECT element FROM jsonb_array_elements(value) item(element) LOOP
        IF (entry->>'uses')::bigint > attack_limit THEN RETURN false; END IF;
    END LOOP;
    RETURN true;
END
$$;

CREATE FUNCTION public.pet_hero_usage_triples_within_attack_count(value jsonb, attack_limit bigint)
RETURNS boolean LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE AS $$
DECLARE entry jsonb;
BEGIN
    IF attack_limit < 0 OR NOT public.pet_hero_usage_triples_valid(value) THEN RETURN false; END IF;
    FOR entry IN SELECT element FROM jsonb_array_elements(value) item(element) LOOP
        IF (entry->>'uses')::bigint > attack_limit THEN RETURN false; END IF;
    END LOOP;
    RETURN true;
END
$$;
-- +goose StatementEnd

CREATE TABLE public.army_family_daily_stats_v2 (
    family_id bigint NOT NULL REFERENCES public.army_families(family_id),
    day date NOT NULL,
    attack_count bigint NOT NULL,
    distinct_player_count bigint NOT NULL,
    zero_star_count bigint NOT NULL,
    one_star_count bigint NOT NULL,
    two_star_count bigint NOT NULL,
    three_star_count bigint NOT NULL,
    destruction_percentage_sum bigint NOT NULL,
    duration_seconds_sum bigint NOT NULL,
    duration_count bigint NOT NULL,
    PRIMARY KEY (family_id, day),
    CONSTRAINT army_family_daily_stats_v2_counts_check CHECK (
        attack_count >= 0 AND distinct_player_count >= 0
        AND zero_star_count >= 0 AND one_star_count >= 0
        AND two_star_count >= 0 AND three_star_count >= 0
        AND attack_count = zero_star_count + one_star_count + two_star_count + three_star_count
    ),
    CONSTRAINT army_family_daily_stats_v2_sums_check CHECK (
        destruction_percentage_sum BETWEEN 0 AND attack_count * 100
        AND duration_seconds_sum >= 0
        AND duration_count BETWEEN 0 AND attack_count
    )
);
CREATE INDEX army_family_daily_stats_v2_day_idx
    ON public.army_family_daily_stats_v2 (day, family_id);

CREATE TABLE public.legend_daily_stats_v2 (
    day date PRIMARY KEY,
    attack_count bigint NOT NULL,
    distinct_player_count bigint NOT NULL,
    perfect_320_player_count bigint NOT NULL,
    zero_star_count bigint NOT NULL,
    one_star_count bigint NOT NULL,
    two_star_count bigint NOT NULL,
    three_star_count bigint NOT NULL,
    destruction_percentage_sum bigint NOT NULL,
    duration_seconds_sum bigint NOT NULL,
    duration_count bigint NOT NULL,
    hero_stats jsonb NOT NULL DEFAULT '[]',
    pet_stats jsonb NOT NULL DEFAULT '[]',
    equipment_stats jsonb NOT NULL DEFAULT '[]',
    pet_hero_assignments jsonb NOT NULL DEFAULT '[]',
    CONSTRAINT legend_daily_stats_v2_counts_check CHECK (
        attack_count >= 0 AND distinct_player_count >= 0
        AND perfect_320_player_count BETWEEN 0 AND distinct_player_count
        AND zero_star_count >= 0 AND one_star_count >= 0
        AND two_star_count >= 0 AND three_star_count >= 0
        AND attack_count = zero_star_count + one_star_count + two_star_count + three_star_count
    ),
    CONSTRAINT legend_daily_stats_v2_sums_check CHECK (
        destruction_percentage_sum BETWEEN 0 AND attack_count * 100
        AND duration_seconds_sum >= 0
        AND duration_count BETWEEN 0 AND attack_count
    ),
    CONSTRAINT legend_daily_stats_v2_heroes_check CHECK (
        public.item_usage_triples_within_attack_count(hero_stats, attack_count)
    ),
    CONSTRAINT legend_daily_stats_v2_pets_check CHECK (
        public.item_usage_triples_within_attack_count(pet_stats, attack_count)
    ),
    CONSTRAINT legend_daily_stats_v2_equipment_check CHECK (
        public.item_usage_triples_within_attack_count(equipment_stats, attack_count)
    ),
    CONSTRAINT legend_daily_stats_v2_pet_hero_check CHECK (
        public.pet_hero_usage_triples_within_attack_count(pet_hero_assignments, attack_count)
    )
);

COMMENT ON TABLE public.army_family_daily_stats_v2 IS
    'Replacement family totals for half-open 05:10 UTC Legend days; populated from Legend attack rows only.';
COMMENT ON TABLE public.legend_daily_stats_v2 IS
    'Replacement global totals for half-open 05:10 UTC Legend days; populated from Legend attack rows only.';
COMMENT ON COLUMN public.army_families.family_id IS
    'Stable numeric family identity; serialize as a decimal string in JSON.';
COMMENT ON COLUMN public.army_family_members.share_code IS
    'Canonical normalized exact-army identity.';

-- +goose Down
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '5min';

-- +goose StatementBegin
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM public.army_family_daily_stats_v2)
       OR EXISTS (SELECT 1 FROM public.legend_daily_stats_v2) THEN
        RAISE EXCEPTION 'migration 015 rollback refused: replacement daily aggregates contain data';
    END IF;
    IF EXISTS (
        SELECT 1 FROM public.army_families
        WHERE family_name IS NULL OR source IS NULL
           OR name IS DISTINCT FROM regexp_replace(btrim(family_name), '[[:space:]]+', ' ', 'g')
    ) THEN
        RAISE EXCEPTION 'migration 015 rollback refused: family rows require v2 fields';
    END IF;
    IF EXISTS (
        SELECT 1 FROM public.army_family_members
        WHERE army_hash IS NULL OR anchor_army_hash IS NULL
           OR troop_housing_similarity IS NULL OR spell_capacity_similarity IS NULL
           OR heroes_exact IS NULL OR equipment_difference_count IS NULL
           OR matching_version IS NULL
    ) THEN
        RAISE EXCEPTION 'migration 015 rollback refused: member rows require v2 fields';
    END IF;
    IF EXISTS (
        SELECT 1 FROM public.battles_ranked
        WHERE army_hash IS NULL
    ) THEN
        RAISE EXCEPTION 'migration 015 rollback refused: raw battles without legacy hashes exist';
    END IF;
END
$$;
-- +goose StatementEnd

DROP TABLE public.legend_daily_stats_v2;
DROP TABLE public.army_family_daily_stats_v2;
DROP FUNCTION public.pet_hero_usage_triples_within_attack_count(jsonb, bigint);
DROP FUNCTION public.item_usage_triples_within_attack_count(jsonb, bigint);

DROP TRIGGER army_family_members_compatibility_insert ON public.army_family_members;
DROP FUNCTION public.prepare_compatible_army_family_member();
DROP INDEX public.army_family_members_family_code_idx;
ALTER TABLE public.army_family_members
    DROP CONSTRAINT army_family_members_v2_similarity_check,
    DROP CONSTRAINT army_family_members_code_check,
    DROP CONSTRAINT army_family_members_family_id_fkey,
    DROP CONSTRAINT army_family_members_pkey,
    DROP CONSTRAINT army_family_members_army_hash_key,
    ADD CONSTRAINT army_family_members_pkey PRIMARY KEY (army_hash),
    ALTER COLUMN matching_version SET NOT NULL,
    ALTER COLUMN equipment_difference_count SET NOT NULL,
    ALTER COLUMN heroes_exact SET NOT NULL,
    ALTER COLUMN spell_capacity_similarity SET NOT NULL,
    ALTER COLUMN troop_housing_similarity SET NOT NULL,
    ALTER COLUMN anchor_army_hash SET NOT NULL,
    ALTER COLUMN army_hash SET NOT NULL,
    DROP COLUMN spell_similarity,
    DROP COLUMN troop_similarity,
    DROP COLUMN family_id,
    DROP COLUMN share_code;

DROP TRIGGER army_families_compatibility_insert ON public.army_families;
DROP FUNCTION public.prepare_compatible_army_family();

ALTER TABLE public.army_family_members
    DROP CONSTRAINT army_family_members_anchor_army_hash_fkey;
ALTER TABLE public.army_family_daily_stats
    DROP CONSTRAINT army_family_daily_stats_anchor_army_hash_fkey;

DROP INDEX public.army_families_name_v2_unique;
ALTER TABLE public.army_families
    DROP CONSTRAINT army_families_equipment_ids_check,
    DROP CONSTRAINT army_families_hero_ids_check,
    DROP CONSTRAINT army_families_name_normalized_check,
    DROP CONSTRAINT army_families_representative_share_code_key,
    DROP CONSTRAINT army_families_pkey,
    DROP CONSTRAINT army_families_anchor_army_hash_key,
    ADD CONSTRAINT army_families_pkey PRIMARY KEY (anchor_army_hash),
    DROP COLUMN equipment_ids,
    DROP COLUMN hero_ids,
    DROP COLUMN name,
    DROP COLUMN family_id,
    ALTER COLUMN anchor_army_hash SET NOT NULL,
    ALTER COLUMN source SET NOT NULL,
    ALTER COLUMN family_name SET NOT NULL;

ALTER TABLE public.army_family_members
    ADD CONSTRAINT army_family_members_anchor_army_hash_fkey
        FOREIGN KEY (anchor_army_hash) REFERENCES public.army_families(anchor_army_hash);
ALTER TABLE public.army_family_daily_stats
    ADD CONSTRAINT army_family_daily_stats_anchor_army_hash_fkey
        FOREIGN KEY (anchor_army_hash) REFERENCES public.army_families(anchor_army_hash);

-- +goose StatementBegin
CREATE OR REPLACE FUNCTION public.protect_army_family_anchor()
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
DROP INDEX public.idx_battles_ranked_attacks_time;
CREATE INDEX idx_battles_ranked_attacks_time
    ON public.battles_ranked (battle_mode, battle_time DESC, player_town_hall, opponent_town_hall, army_hash)
    WHERE direction = 'attack';
ALTER TABLE public.battles_ranked
    DROP CONSTRAINT battles_ranked_loot_check,
    ALTER COLUMN army_hash SET NOT NULL,
    ADD CONSTRAINT battles_ranked_loot_check
        CHECK (public.battle_looted_resources_valid(looted_resources));
