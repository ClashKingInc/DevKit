-- +goose Up
-- Consolidated unpublished release extension. Published migrations 001..021 are unchanged.
-- SHA-256 manifest: ../migration_history/unpublished-022-060/manifest.json
-- Original SQL snapshots are external recovery artifacts, not active migrations.

-- Source: 022_personal_army_library.sql
-- Personal base grouping is derived from the Town Hall encoded in base_link.
-- Keep the saved-base identity and timestamp while removing the obsolete label.
ALTER TABLE public.user_saved_bases
    DROP CONSTRAINT user_saved_bases_kind_check,
    DROP COLUMN kind;

-- A personal army is a user-owned reference to one canonical composition.
-- Removing the save never removes the shared composition or retained history.
CREATE TABLE public.user_saved_armies (
    user_id text NOT NULL REFERENCES public.auth_users(user_id) ON DELETE CASCADE,
    share_code text NOT NULL REFERENCES public.army_compositions(share_code) ON DELETE CASCADE,
    saved_at timestamptz NOT NULL DEFAULT now(),
    name text CHECK (name IS NULL OR (char_length(name) BETWEEN 1 AND 100 AND name = btrim(name))),
    notes text CHECK (notes IS NULL OR char_length(notes) <= 450),
    PRIMARY KEY (user_id,share_code)
);
CREATE INDEX idx_user_saved_armies_recent
    ON public.user_saved_armies (user_id,saved_at DESC,share_code);

COMMENT ON TABLE public.user_saved_armies IS
    'Authenticated-user references to canonical army compositions; share_code is the durable identity.';
COMMENT ON COLUMN public.user_saved_armies.name IS
    'Per-user display name, not part of the shared immutable army composition.';

-- Source: 023_roster_signup_scope.sql
-- Preserve existing restrictions while giving new rosters an open signup scope.
UPDATE public.rosters SET signup_scope = 'family-only' WHERE signup_scope = 'family-wide';
ALTER TABLE public.rosters
    ALTER COLUMN signup_scope SET DEFAULT 'anyone',
    ADD CONSTRAINT rosters_signup_scope_check
        CHECK (signup_scope IN ('clan-only', 'family-only', 'anyone'));

COMMENT ON COLUMN public.rosters.signup_scope IS
    'Clan eligibility for self-signup: selected clan, any server-linked clan, or anyone. Account verification and other signup limits still apply.';

-- Source: 024_roster_admission_settings.sql
ALTER TABLE rosters
  ADD COLUMN max_signups integer CHECK (max_signups BETWEEN 1 AND 500),
  ADD COLUMN require_verified boolean NOT NULL DEFAULT false,
  ADD COLUMN hero_red_percent smallint NOT NULL DEFAULT 50,
  ADD COLUMN hero_yellow_percent smallint NOT NULL DEFAULT 75,
  ADD COLUMN hero_green_percent smallint NOT NULL DEFAULT 90,
  ADD CONSTRAINT roster_hero_gradient_bounds CHECK (
    0 <= hero_red_percent AND hero_red_percent < hero_yellow_percent
    AND hero_yellow_percent < hero_green_percent AND hero_green_percent <= 100
  );

-- Source: 025_roster_discord_publications.sql
-- A bot-authored channel message is not a webhook. Keep its delivery target
-- separate from the legacy webhook destination used by older automations.
CREATE TABLE roster_discord_publications (
  roster_id uuid PRIMARY KEY REFERENCES rosters(id) ON DELETE CASCADE,
  channel_id text NOT NULL CHECK (channel_id ~ '^[0-9]{1,20}$'),
  message_id text NOT NULL CHECK (message_id ~ '^[0-9]{1,20}$'),
  mode text NOT NULL CHECK (mode IN ('signup', 'post')),
  dashboard_url text NOT NULL,
  join_label text NOT NULL CHECK (length(join_label) BETWEEN 1 AND 80),
  remove_label text NOT NULL CHECK (length(remove_label) BETWEEN 1 AND 80),
  view_label text NOT NULL CHECK (length(view_label) BETWEEN 1 AND 80),
  needs_sync boolean NOT NULL DEFAULT false,
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(channel_id, message_id)
);

-- Source: 026_roster_publication_webhooks.sql
ALTER TABLE roster_discord_publications
  ADD COLUMN webhook_id text CHECK (webhook_id ~ '^[0-9]{1,20}$');

-- Source: 027_roster_embed_color.sql
ALTER TABLE rosters ADD COLUMN embed_color integer CHECK (embed_color BETWEEN 0 AND 16777215);
COMMENT ON COLUMN rosters.embed_color IS 'Optional Discord embed color override; NULL inherits the server embed color.';

-- Source: 028_roster_automation_event_offsets.sql
ALTER TABLE roster_automation_rules ADD COLUMN event_offset_days integer CHECK (event_offset_days BETWEEN -365 AND 365);
COMMENT ON COLUMN roster_automation_rules.event_offset_days IS 'Signed days from each target roster event start. NULL preserves legacy fixed-date rules.';

-- Source: 029_roster_default_capacity.sql
ALTER TABLE rosters ALTER COLUMN max_signups SET DEFAULT 50;

-- Source: 030_legend_daily_metadata.sql
-- Keep top_200 for existing consumers while adding the product-facing top 100.
ALTER TABLE public.army_family_daily_stats
    DROP CONSTRAINT army_family_daily_stats_cohort_check,
    ADD CONSTRAINT army_family_daily_stats_cohort_check
        CHECK (cohort IN ('legend_i','top_1000','top_200','top_100'));

ALTER TABLE public.legend_daily_stats
    DROP CONSTRAINT legend_daily_stats_cohort_check,
    ADD CONSTRAINT legend_daily_stats_cohort_check
        CHECK (cohort IN ('legend_i','top_1000','top_200','top_100'));

-- +goose StatementBegin
CREATE FUNCTION public.equipment_pair_usage_triples_within_attack_count(value jsonb, attack_limit bigint)
RETURNS boolean LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE AS $$
DECLARE
    entry jsonb;
    previous_hero integer := -1;
    previous_first integer := -1;
    previous_second integer := -1;
    hero_value integer;
    first_value integer;
    second_value integer;
    uses_value bigint;
    triples_value bigint;
BEGIN
    IF attack_limit < 0 OR jsonb_typeof(value) <> 'array' THEN RETURN false; END IF;
    FOR entry IN SELECT element FROM jsonb_array_elements(value) WITH ORDINALITY AS item(element, position) ORDER BY position LOOP
        IF jsonb_typeof(entry) <> 'object' OR (SELECT count(*) FROM jsonb_object_keys(entry)) <> 4
           OR NOT (entry ? 'heroId' AND entry ? 'equipmentIds' AND entry ? 'uses' AND entry ? 'triples')
           OR jsonb_typeof(entry->'heroId') <> 'number' OR jsonb_typeof(entry->'equipmentIds') <> 'array'
           OR jsonb_array_length(entry->'equipmentIds') <> 2
           OR jsonb_typeof(entry->'equipmentIds'->0) <> 'number' OR jsonb_typeof(entry->'equipmentIds'->1) <> 'number'
           OR jsonb_typeof(entry->'uses') <> 'number' OR jsonb_typeof(entry->'triples') <> 'number'
           OR entry->>'heroId' !~ '^[0-9]+$' OR entry->'equipmentIds'->>0 !~ '^[0-9]+$'
           OR entry->'equipmentIds'->>1 !~ '^[0-9]+$' OR entry->>'uses' !~ '^[0-9]+$'
           OR entry->>'triples' !~ '^[0-9]+$'
           OR (entry->>'heroId')::numeric > 2147483647
           OR (entry->'equipmentIds'->>0)::numeric > 2147483647
           OR (entry->'equipmentIds'->>1)::numeric > 2147483647
           OR (entry->>'uses')::numeric > 9223372036854775807
           OR (entry->>'triples')::numeric > 9223372036854775807 THEN RETURN false; END IF;
        hero_value := (entry->>'heroId')::integer;
        first_value := (entry->'equipmentIds'->>0)::integer;
        second_value := (entry->'equipmentIds'->>1)::integer;
        uses_value := (entry->>'uses')::bigint;
        triples_value := (entry->>'triples')::bigint;
        IF first_value >= second_value OR triples_value > uses_value OR uses_value > attack_limit
           OR hero_value < previous_hero
           OR (hero_value = previous_hero AND first_value < previous_first)
           OR (hero_value = previous_hero AND first_value = previous_first AND second_value <= previous_second)
        THEN RETURN false; END IF;
        previous_hero := hero_value;
        previous_first := first_value;
        previous_second := second_value;
    END LOOP;
    RETURN true;
EXCEPTION WHEN numeric_value_out_of_range THEN RETURN false;
END
$$;
-- +goose StatementEnd

ALTER TABLE public.legend_daily_stats
    ADD COLUMN troop_stats jsonb NOT NULL DEFAULT '[]'::jsonb,
    ADD COLUMN spell_stats jsonb NOT NULL DEFAULT '[]'::jsonb,
    ADD COLUMN siege_stats jsonb NOT NULL DEFAULT '[]'::jsonb,
    ADD COLUMN equipment_pair_stats jsonb NOT NULL DEFAULT '[]'::jsonb,
    ADD CONSTRAINT legend_daily_stats_troops_check
        CHECK (public.item_usage_triples_within_attack_count(troop_stats,attack_count)),
    ADD CONSTRAINT legend_daily_stats_spells_check
        CHECK (public.item_usage_triples_within_attack_count(spell_stats,attack_count)),
    ADD CONSTRAINT legend_daily_stats_siege_check
        CHECK (public.item_usage_triples_within_attack_count(siege_stats,attack_count)),
    ADD CONSTRAINT legend_daily_stats_equipment_pairs_check
        CHECK (public.equipment_pair_usage_triples_within_attack_count(equipment_pair_stats,attack_count));

COMMENT ON COLUMN public.legend_daily_stats.troop_stats IS
    'Per-attack presence counts for main-army troops; quantities do not multiply uses.';
COMMENT ON COLUMN public.legend_daily_stats.spell_stats IS
    'Per-attack presence counts for regular and Clan Castle spells combined by ID.';
COMMENT ON COLUMN public.legend_daily_stats.siege_stats IS
    'Per-attack presence counts for the canonical selected siege machine.';
COMMENT ON COLUMN public.legend_daily_stats.equipment_pair_stats IS
    'Per-attack counts for each hero and its sorted two-equipment loadout.';

-- Source: 031_legend_daily_pet_combos.sql
-- Pet combos were added after migration 030 had already been exercised locally,
-- so they remain a forward-only schema addition.
-- +goose StatementBegin
CREATE FUNCTION public.pet_combo_usage_triples_within_attack_count(value jsonb, attack_limit bigint)
RETURNS boolean LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE AS $$
DECLARE
    entry jsonb;
    pet_id jsonb;
    previous_pet integer;
    uses_value bigint;
    triples_value bigint;
BEGIN
    IF attack_limit < 0 OR jsonb_typeof(value) <> 'array' THEN RETURN false; END IF;
    FOR entry IN SELECT element FROM jsonb_array_elements(value) WITH ORDINALITY AS item(element, position) ORDER BY position LOOP
        IF jsonb_typeof(entry) <> 'object' OR (SELECT count(*) FROM jsonb_object_keys(entry)) <> 3
           OR NOT (entry ? 'petIds' AND entry ? 'uses' AND entry ? 'triples')
           OR jsonb_typeof(entry->'petIds') <> 'array' OR jsonb_array_length(entry->'petIds') = 0
           OR jsonb_typeof(entry->'uses') <> 'number' OR jsonb_typeof(entry->'triples') <> 'number'
           OR entry->>'uses' !~ '^[0-9]+$' OR entry->>'triples' !~ '^[0-9]+$'
           OR (entry->>'uses')::numeric > 9223372036854775807
           OR (entry->>'triples')::numeric > 9223372036854775807 THEN RETURN false; END IF;
        previous_pet := -1;
        FOR pet_id IN SELECT element FROM jsonb_array_elements(entry->'petIds') WITH ORDINALITY AS item(element, position) ORDER BY position LOOP
            IF jsonb_typeof(pet_id) <> 'number' OR pet_id #>> '{}' !~ '^[0-9]+$'
               OR (pet_id #>> '{}')::numeric > 2147483647
               OR (pet_id #>> '{}')::integer <= previous_pet THEN RETURN false; END IF;
            previous_pet := (pet_id #>> '{}')::integer;
        END LOOP;
        uses_value := (entry->>'uses')::bigint;
        triples_value := (entry->>'triples')::bigint;
        IF triples_value > uses_value OR uses_value > attack_limit THEN RETURN false; END IF;
    END LOOP;
    RETURN true;
EXCEPTION WHEN numeric_value_out_of_range THEN RETURN false;
END
$$;
-- +goose StatementEnd

ALTER TABLE public.legend_daily_stats
    ADD COLUMN pet_combo_stats jsonb NOT NULL DEFAULT '[]'::jsonb,
    ADD CONSTRAINT legend_daily_stats_pet_combos_check
        CHECK (public.pet_combo_usage_triples_within_attack_count(pet_combo_stats,attack_count));

COMMENT ON COLUMN public.legend_daily_stats.pet_combo_stats IS
    'Per-attack counts for each non-empty sorted unique whole set of assigned pets.';

-- Source: 032_remove_server_link_token_policy.sql
-- Every new account link now verifies an in-game API token, independent of server.
ALTER TABLE public.servers DROP COLUMN require_api_token_when_linking;

-- Source: 033_cwl_participation.sql
-- Manually rebuilt CWL participation buckets; raw groups and wars remain canonical.
CREATE TABLE public.cwl_participation (
    season text NOT NULL,
    cwl_league_id integer NOT NULL,
    war_size smallint NOT NULL,
    group_count bigint NOT NULL,
    clan_count bigint NOT NULL,
    registered_player_count bigint NOT NULL,
    townhall_counts jsonb NOT NULL,
    same_th_hitrates jsonb,
    finalized_wars bigint NOT NULL,
    archived_wars bigint NOT NULL,
    refreshed_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (season, cwl_league_id, war_size),
    CONSTRAINT cwl_participation_season_check CHECK (season ~ '^[0-9]{4}-(0[1-9]|1[0-2])$'),
    CONSTRAINT cwl_participation_league_check CHECK (cwl_league_id > 48000000),
    CONSTRAINT cwl_participation_size_check CHECK (war_size BETWEEN 1 AND 50),
    CONSTRAINT cwl_participation_counts_check CHECK (
        group_count >= 0 AND clan_count >= 0 AND registered_player_count >= 0
        AND finalized_wars >= 0 AND archived_wars >= 0 AND archived_wars <= finalized_wars
    ),
    CONSTRAINT cwl_participation_townhall_check CHECK (jsonb_typeof(townhall_counts) = 'array'),
    CONSTRAINT cwl_participation_hitrates_check CHECK (
        same_th_hitrates IS NULL OR jsonb_typeof(same_th_hitrates) = 'array'
    )
);

-- Source: 034_daily_army_setups.sql
-- Daily troop-overlap observations. Identity comes from core troops and setup
-- conditions, never a display name, row order or changing representative.
CREATE TABLE public.army_setup_daily_stats (
    day date NOT NULL,
    league_tier_id integer NOT NULL CHECK (league_tier_id > 0),
    rank_limit integer CHECK (rank_limit IN (200,1000)),
    group_key text NOT NULL CHECK (length(group_key) BETWEEN 1 AND 256),
    variant_key text NOT NULL DEFAULT '' CHECK (length(variant_key) <= 1024),
    core_troops integer[] NOT NULL CHECK (cardinality(core_troops) > 0),
    conditions jsonb NOT NULL DEFAULT '[]' CHECK (jsonb_typeof(conditions) = 'array'),
    representative_share_code text NOT NULL CHECK (length(representative_share_code) > 0),
    attack_count bigint NOT NULL CHECK (attack_count > 0),
    zero_star_count bigint NOT NULL CHECK (zero_star_count >= 0),
    one_star_count bigint NOT NULL CHECK (one_star_count >= 0),
    two_star_count bigint NOT NULL CHECK (two_star_count >= 0),
    three_star_count bigint NOT NULL CHECK (three_star_count >= 0),
    destruction_percentage_sum bigint NOT NULL CHECK (destruction_percentage_sum >= 0),
    evidence jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(evidence) = 'object'),
    calculated_at timestamptz NOT NULL DEFAULT now(),
    CHECK (zero_star_count + one_star_count + two_star_count + three_star_count = attack_count),
    CHECK (destruction_percentage_sum <= attack_count * 100),
    CHECK ((variant_key = '' AND conditions = '[]'::jsonb) OR (variant_key <> '' AND jsonb_array_length(conditions) > 0)),
    UNIQUE NULLS NOT DISTINCT (day,league_tier_id,rank_limit,group_key,variant_key)
);
CREATE INDEX army_setup_daily_identity ON public.army_setup_daily_stats(group_key,variant_key,day);
ALTER TABLE public.legend_daily_stats
    ADD COLUMN army_analysis_completed_at timestamptz,
    ADD COLUMN classified_army_attacks bigint,
    ADD CONSTRAINT legend_daily_classified_attacks_check CHECK (
        classified_army_attacks BETWEEN 0 AND attack_count
        AND ((army_analysis_completed_at IS NULL) = (classified_army_attacks IS NULL))
    );
COMMENT ON COLUMN public.army_setup_daily_stats.variant_key IS
    'Empty means independent troop-group overview. Setup rows may overlap and must not be summed to produce overview counts.';
COMMENT ON COLUMN public.legend_daily_stats.army_analysis_completed_at IS
    'Set atomically with setup observations. A missing setup row is not a measured zero; unsupported patterns are not persisted.';

-- Source: 035_remove_army_analysis_timestamp.sql
-- A non-null classified count is the atomic readiness marker for a finalized
-- daily army analysis, including days with zero classified attacks.
ALTER TABLE public.legend_daily_stats
    DROP CONSTRAINT legend_daily_classified_attacks_check,
    DROP COLUMN army_analysis_completed_at,
    ADD CONSTRAINT legend_daily_classified_attacks_check
        CHECK (classified_army_attacks BETWEEN 0 AND attack_count);
COMMENT ON COLUMN public.legend_daily_stats.classified_army_attacks IS
    'Non-null after daily army analysis commits atomically with its setup observations; zero is a completed empty classification.';

-- Source: 036_army_setup_siege_usage.sql
-- Per-observation counts, measured from normalized CC siege on each attack.
-- Entries need not sum to attack_count because some codes have no siege.
ALTER TABLE public.army_setup_daily_stats
    ADD COLUMN siege_usage jsonb NOT NULL DEFAULT '[]'::jsonb
        CHECK (jsonb_typeof(siege_usage) = 'array');
COMMENT ON COLUMN public.army_setup_daily_stats.siege_usage IS
    'Observed normalized Clan Castle siege counts [{id,attacks}] for this day, cohort and group or variant; not inferred from the representative code.';

-- Source: 037_roster_publication_requests.sql
-- Reserve each client nonce before sending to Discord. A missing message_id is
-- deliberately uncertain after a worker interruption and must not be resent.
CREATE TABLE public.roster_publication_requests (
    roster_id uuid NOT NULL REFERENCES public.rosters(id) ON DELETE CASCADE,
    nonce text NOT NULL CHECK (nonce ~ '^[A-Za-z0-9_-]{1,25}$'),
    payload jsonb NOT NULL CHECK (jsonb_typeof(payload) = 'object'),
    message_id text CHECK (message_id ~ '^[0-9]{1,20}$'),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (roster_id, nonce)
);

-- Source: 038_daily_analytics_count_constraints.sql
-- Preserve applied 031 and 036 byte-for-byte; tighten their checks forward.
-- +goose StatementBegin
CREATE OR REPLACE FUNCTION public.pet_combo_usage_triples_within_attack_count(value jsonb, attack_limit bigint)
RETURNS boolean LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE AS $$
DECLARE
    entry jsonb;
    pet_id jsonb;
    previous_pet integer;
    current_combo integer[];
    previous_combo integer[];
    uses_value bigint;
    triples_value bigint;
    total_uses bigint := 0;
BEGIN
    IF attack_limit < 0 OR jsonb_typeof(value) <> 'array' THEN RETURN false; END IF;
    FOR entry IN SELECT element FROM jsonb_array_elements(value) WITH ORDINALITY AS item(element, position) ORDER BY position LOOP
        IF jsonb_typeof(entry) <> 'object' OR (SELECT count(*) FROM jsonb_object_keys(entry)) <> 3
           OR NOT (entry ? 'petIds' AND entry ? 'uses' AND entry ? 'triples')
           OR jsonb_typeof(entry->'petIds') <> 'array' OR jsonb_array_length(entry->'petIds') = 0
           OR jsonb_typeof(entry->'uses') <> 'number' OR jsonb_typeof(entry->'triples') <> 'number'
           OR entry->>'uses' !~ '^[0-9]+$' OR entry->>'triples' !~ '^[0-9]+$'
           OR (entry->>'uses')::numeric > 9223372036854775807
           OR (entry->>'triples')::numeric > 9223372036854775807 THEN RETURN false; END IF;
        previous_pet := -1;
        current_combo := '{}'::integer[];
        FOR pet_id IN SELECT element FROM jsonb_array_elements(entry->'petIds') WITH ORDINALITY AS item(element, position) ORDER BY position LOOP
            IF jsonb_typeof(pet_id) <> 'number' OR pet_id #>> '{}' !~ '^[0-9]+$'
               OR (pet_id #>> '{}')::numeric > 2147483647
               OR (pet_id #>> '{}')::integer <= previous_pet THEN RETURN false; END IF;
            previous_pet := (pet_id #>> '{}')::integer;
            current_combo := array_append(current_combo, previous_pet);
        END LOOP;
        uses_value := (entry->>'uses')::bigint;
        triples_value := (entry->>'triples')::bigint;
        IF (previous_combo IS NOT NULL AND current_combo <= previous_combo)
           OR triples_value > uses_value OR uses_value > attack_limit - total_uses THEN RETURN false; END IF;
        previous_combo := current_combo;
        total_uses := total_uses + uses_value;
    END LOOP;
    RETURN true;
EXCEPTION WHEN numeric_value_out_of_range THEN RETURN false;
END
$$;
-- +goose StatementEnd

ALTER TABLE public.legend_daily_stats
    DROP CONSTRAINT legend_daily_stats_pet_combos_check,
    ADD CONSTRAINT legend_daily_stats_pet_combos_check
        CHECK (public.pet_combo_usage_triples_within_attack_count(pet_combo_stats,attack_count));

-- +goose StatementBegin
CREATE FUNCTION public.army_setup_siege_usage_within_attack_count(value jsonb, attack_limit bigint)
RETURNS boolean LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE AS $$
DECLARE
    entry jsonb;
    siege_id integer;
    previous_id integer := -1;
    attacks_value bigint;
    total_attacks bigint := 0;
BEGIN
    IF attack_limit < 0 OR jsonb_typeof(value) <> 'array' THEN RETURN false; END IF;
    FOR entry IN SELECT element FROM jsonb_array_elements(value) WITH ORDINALITY AS item(element, position) ORDER BY position LOOP
        IF jsonb_typeof(entry) <> 'object' OR (SELECT count(*) FROM jsonb_object_keys(entry)) <> 2
           OR NOT (entry ? 'id' AND entry ? 'attacks')
           OR jsonb_typeof(entry->'id') <> 'number' OR jsonb_typeof(entry->'attacks') <> 'number'
           OR entry->>'id' !~ '^[0-9]+$' OR entry->>'attacks' !~ '^[0-9]+$'
           OR (entry->>'id')::numeric > 2147483647
           OR (entry->>'attacks')::numeric > 9223372036854775807 THEN RETURN false; END IF;
        siege_id := (entry->>'id')::integer;
        attacks_value := (entry->>'attacks')::bigint;
        IF siege_id <= previous_id OR siege_id = 0 OR attacks_value > attack_limit - total_attacks THEN RETURN false; END IF;
        previous_id := siege_id;
        total_attacks := total_attacks + attacks_value;
    END LOOP;
    RETURN true;
EXCEPTION WHEN numeric_value_out_of_range THEN RETURN false;
END
$$;
-- +goose StatementEnd

ALTER TABLE public.army_setup_daily_stats
    ADD CONSTRAINT army_setup_daily_siege_usage_count_check
        CHECK (public.army_setup_siege_usage_within_attack_count(siege_usage,attack_count));

-- Source: 039_legend_daily_exclusive_usage.sql
-- Siege selection and each hero's equipment pair are exclusive per attack.
-- Preserve the previously applied 030 migration and tighten its checks forward.
-- +goose StatementBegin
CREATE FUNCTION public.legend_siege_usage_within_attack_count(value jsonb, attack_limit bigint)
RETURNS boolean LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE AS $$
DECLARE
    entry jsonb;
    total_uses bigint := 0;
BEGIN
    IF attack_limit < 0 OR NOT public.item_usage_triples_valid(value) THEN RETURN false; END IF;
    FOR entry IN SELECT element FROM jsonb_array_elements(value) item(element) LOOP
        IF (entry->>'uses')::bigint > attack_limit - total_uses THEN RETURN false; END IF;
        total_uses := total_uses + (entry->>'uses')::bigint;
    END LOOP;
    RETURN true;
END
$$;
-- +goose StatementEnd

-- +goose StatementBegin
CREATE OR REPLACE FUNCTION public.equipment_pair_usage_triples_within_attack_count(value jsonb, attack_limit bigint)
RETURNS boolean LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE AS $$
DECLARE
    entry jsonb;
    previous_hero integer := -1;
    previous_first integer := -1;
    previous_second integer := -1;
    hero_value integer;
    first_value integer;
    second_value integer;
    uses_value bigint;
    triples_value bigint;
    hero_uses bigint := 0;
BEGIN
    IF attack_limit < 0 OR jsonb_typeof(value) <> 'array' THEN RETURN false; END IF;
    FOR entry IN SELECT element FROM jsonb_array_elements(value) WITH ORDINALITY AS item(element, position) ORDER BY position LOOP
        IF jsonb_typeof(entry) <> 'object' OR (SELECT count(*) FROM jsonb_object_keys(entry)) <> 4
           OR NOT (entry ? 'heroId' AND entry ? 'equipmentIds' AND entry ? 'uses' AND entry ? 'triples')
           OR jsonb_typeof(entry->'heroId') <> 'number' OR jsonb_typeof(entry->'equipmentIds') <> 'array'
           OR jsonb_array_length(entry->'equipmentIds') <> 2
           OR jsonb_typeof(entry->'equipmentIds'->0) <> 'number' OR jsonb_typeof(entry->'equipmentIds'->1) <> 'number'
           OR jsonb_typeof(entry->'uses') <> 'number' OR jsonb_typeof(entry->'triples') <> 'number'
           OR entry->>'heroId' !~ '^[0-9]+$' OR entry->'equipmentIds'->>0 !~ '^[0-9]+$'
           OR entry->'equipmentIds'->>1 !~ '^[0-9]+$' OR entry->>'uses' !~ '^[0-9]+$'
           OR entry->>'triples' !~ '^[0-9]+$'
           OR (entry->>'heroId')::numeric > 2147483647
           OR (entry->'equipmentIds'->>0)::numeric > 2147483647
           OR (entry->'equipmentIds'->>1)::numeric > 2147483647
           OR (entry->>'uses')::numeric > 9223372036854775807
           OR (entry->>'triples')::numeric > 9223372036854775807 THEN RETURN false; END IF;
        hero_value := (entry->>'heroId')::integer;
        first_value := (entry->'equipmentIds'->>0)::integer;
        second_value := (entry->'equipmentIds'->>1)::integer;
        uses_value := (entry->>'uses')::bigint;
        triples_value := (entry->>'triples')::bigint;
        IF hero_value <> previous_hero THEN hero_uses := 0; END IF;
        IF first_value >= second_value OR triples_value > uses_value
           OR uses_value > attack_limit - hero_uses
           OR hero_value < previous_hero
           OR (hero_value = previous_hero AND first_value < previous_first)
           OR (hero_value = previous_hero AND first_value = previous_first AND second_value <= previous_second)
        THEN RETURN false; END IF;
        hero_uses := hero_uses + uses_value;
        previous_hero := hero_value;
        previous_first := first_value;
        previous_second := second_value;
    END LOOP;
    RETURN true;
EXCEPTION WHEN numeric_value_out_of_range THEN RETURN false;
END
$$;
-- +goose StatementEnd

ALTER TABLE public.legend_daily_stats
    DROP CONSTRAINT legend_daily_stats_siege_check,
    ADD CONSTRAINT legend_daily_stats_siege_check
        CHECK (public.legend_siege_usage_within_attack_count(siege_stats,attack_count)),
    DROP CONSTRAINT legend_daily_stats_equipment_pairs_check,
    ADD CONSTRAINT legend_daily_stats_equipment_pairs_check
        CHECK (public.equipment_pair_usage_triples_within_attack_count(equipment_pair_stats,attack_count));

-- Source: 040_legend_exclusive_triple_totals.sql
-- Whole pet sets and selected siege are exclusive per attack. Equipment-pair
-- choices are exclusive for each hero, so their triples cannot exceed the
-- row's three-star count in the corresponding exclusive group.
-- +goose StatementBegin
CREATE FUNCTION public.legend_exclusive_triples_within_star_count(value jsonb, triple_limit bigint, per_hero boolean)
RETURNS boolean LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE AS $$
DECLARE
    entry jsonb;
    hero_id integer;
    previous_hero integer := -1;
    triples_value bigint;
    total_triples bigint := 0;
BEGIN
    IF triple_limit < 0 OR jsonb_typeof(value) <> 'array' THEN RETURN false; END IF;
    FOR entry IN SELECT element FROM jsonb_array_elements(value) WITH ORDINALITY AS item(element, position) ORDER BY position LOOP
        IF jsonb_typeof(entry) <> 'object' OR NOT entry ? 'triples'
           OR jsonb_typeof(entry->'triples') <> 'number' OR entry->>'triples' !~ '^[0-9]+$'
           OR (entry->>'triples')::numeric > 9223372036854775807 THEN RETURN false; END IF;
        IF per_hero THEN
            IF NOT entry ? 'heroId' OR jsonb_typeof(entry->'heroId') <> 'number'
               OR entry->>'heroId' !~ '^[0-9]+$'
               OR (entry->>'heroId')::numeric > 2147483647 THEN RETURN false; END IF;
            hero_id := (entry->>'heroId')::integer;
            IF hero_id <> previous_hero THEN total_triples := 0; END IF;
            previous_hero := hero_id;
        END IF;
        triples_value := (entry->>'triples')::bigint;
        IF triples_value > triple_limit - total_triples THEN RETURN false; END IF;
        total_triples := total_triples + triples_value;
    END LOOP;
    RETURN true;
EXCEPTION WHEN numeric_value_out_of_range THEN RETURN false;
END
$$;
-- +goose StatementEnd

ALTER TABLE public.legend_daily_stats
    DROP CONSTRAINT legend_daily_stats_pet_combos_check,
    ADD CONSTRAINT legend_daily_stats_pet_combos_check CHECK (
        public.pet_combo_usage_triples_within_attack_count(pet_combo_stats,attack_count)
        AND public.legend_exclusive_triples_within_star_count(pet_combo_stats,three_star_count,false)),
    DROP CONSTRAINT legend_daily_stats_siege_check,
    ADD CONSTRAINT legend_daily_stats_siege_check CHECK (
        public.legend_siege_usage_within_attack_count(siege_stats,attack_count)
        AND public.legend_exclusive_triples_within_star_count(siege_stats,three_star_count,false)),
    DROP CONSTRAINT legend_daily_stats_equipment_pairs_check,
    ADD CONSTRAINT legend_daily_stats_equipment_pairs_check CHECK (
        public.equipment_pair_usage_triples_within_attack_count(equipment_pair_stats,attack_count)
        AND public.legend_exclusive_triples_within_star_count(equipment_pair_stats,three_star_count,true));

-- Source: 041_legend_item_triples_saved_army_index.sql
-- Troops and spells can coexist in one attack, so each item's triple count
-- is bounded separately by the day's three-star count. Do not sum items.
-- +goose StatementBegin
CREATE FUNCTION public.legend_item_triples_within_star_count(value jsonb, triple_limit bigint)
RETURNS boolean LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE AS $$
DECLARE
    entry jsonb;
BEGIN
    IF triple_limit < 0 OR NOT public.item_usage_triples_valid(value) THEN RETURN false; END IF;
    FOR entry IN SELECT element FROM jsonb_array_elements(value) item(element) LOOP
        IF (entry->>'triples')::bigint > triple_limit THEN RETURN false; END IF;
    END LOOP;
    RETURN true;
EXCEPTION WHEN numeric_value_out_of_range THEN RETURN false;
END
$$;
-- +goose StatementEnd

ALTER TABLE public.legend_daily_stats
    DROP CONSTRAINT legend_daily_stats_troops_check,
    ADD CONSTRAINT legend_daily_stats_troops_check CHECK (
        public.item_usage_triples_within_attack_count(troop_stats,attack_count)
        AND public.legend_item_triples_within_star_count(troop_stats,three_star_count)),
    DROP CONSTRAINT legend_daily_stats_spells_check,
    ADD CONSTRAINT legend_daily_stats_spells_check CHECK (
        public.item_usage_triples_within_attack_count(spell_stats,attack_count)
        AND public.legend_item_triples_within_star_count(spell_stats,three_star_count));

-- The PK and recent-list index start with user_id; this reverse index makes
-- army_compositions(share_code) cascade checks indexable.
CREATE INDEX idx_user_saved_armies_share_code
    ON public.user_saved_armies (share_code,user_id);

-- Source: 042_cwl_participation_townhall_validation.sql
-- Restore the canonical descending, typed TH distribution validation from
-- the retired CWL aggregate for the retained participation summary.
-- +goose StatementBegin
CREATE FUNCTION public.cwl_participation_town_halls_valid(value jsonb)
RETURNS boolean LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE AS $$
DECLARE
    entry jsonb;
    previous_level integer := 21;
    level_value integer;
BEGIN
    IF jsonb_typeof(value) <> 'array' THEN RETURN false; END IF;
    FOR entry IN SELECT element FROM jsonb_array_elements(value) WITH ORDINALITY AS item(element, position) ORDER BY position LOOP
        IF jsonb_typeof(entry) <> 'object'
           OR (SELECT count(*) FROM jsonb_object_keys(entry)) <> 2
           OR NOT (entry ? 'level' AND entry ? 'count')
           OR jsonb_typeof(entry->'level') <> 'number'
           OR jsonb_typeof(entry->'count') <> 'number'
           OR entry->>'level' !~ '^[0-9]+$'
           OR entry->>'count' !~ '^[0-9]+$' THEN RETURN false; END IF;
        level_value := (entry->>'level')::integer;
        IF level_value NOT BETWEEN 1 AND 20
           OR (entry->>'count')::numeric > 9223372036854775807
           OR level_value >= previous_level THEN RETURN false; END IF;
        previous_level := level_value;
    END LOOP;
    RETURN true;
EXCEPTION WHEN numeric_value_out_of_range THEN RETURN false;
END
$$;
-- +goose StatementEnd

ALTER TABLE public.cwl_participation
    DROP CONSTRAINT cwl_participation_townhall_check,
    ADD CONSTRAINT cwl_participation_townhall_check
        CHECK (public.cwl_participation_town_halls_valid(townhall_counts));

-- Source: 043_legend_selected_siege_id.sql
-- Tracking omits the zero sentinel when no siege was selected. A retained
-- selected-siege bucket must therefore have a positive canonical ID.
-- +goose StatementBegin
CREATE FUNCTION public.legend_selected_siege_ids_valid(value jsonb)
RETURNS boolean LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE AS $$
DECLARE
    entry jsonb;
BEGIN
    IF NOT public.item_usage_triples_valid(value) THEN RETURN false; END IF;
    FOR entry IN SELECT element FROM jsonb_array_elements(value) item(element) LOOP
        IF (entry->>'id')::integer = 0 THEN RETURN false; END IF;
    END LOOP;
    RETURN true;
END
$$;
-- +goose StatementEnd

ALTER TABLE public.legend_daily_stats
    DROP CONSTRAINT legend_daily_stats_siege_check,
    ADD CONSTRAINT legend_daily_stats_siege_check CHECK (
        public.legend_selected_siege_ids_valid(siege_stats)
        AND public.legend_siege_usage_within_attack_count(siege_stats,attack_count)
        AND public.legend_exclusive_triples_within_star_count(siege_stats,three_star_count,false));

-- Source: 044_cwl_participation_hitrate_validation.sql
-- Manually rebuilt same-TH observations use a canonical descending set of
-- integer town-hall buckets, never an arbitrary JSON array.
-- +goose StatementBegin
CREATE FUNCTION public.cwl_participation_hitrates_valid(value jsonb)
RETURNS boolean LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE AS $$
DECLARE
    entry jsonb;
    previous_level integer := 21;
    level_value integer;
    attempts bigint;
    triples bigint;
BEGIN
    IF jsonb_typeof(value) <> 'array' THEN RETURN false; END IF;
    FOR entry IN SELECT element FROM jsonb_array_elements(value) WITH ORDINALITY AS item(element, position) ORDER BY position LOOP
        IF jsonb_typeof(entry) <> 'object'
           OR (SELECT count(*) FROM jsonb_object_keys(entry)) <> 3
           OR NOT (entry ? 'level' AND entry ? 'attacks' AND entry ? 'three_stars')
           OR jsonb_typeof(entry->'level') <> 'number'
           OR jsonb_typeof(entry->'attacks') <> 'number'
           OR jsonb_typeof(entry->'three_stars') <> 'number'
           OR entry->>'level' !~ '^[0-9]+$'
           OR entry->>'attacks' !~ '^[0-9]+$'
           OR entry->>'three_stars' !~ '^[0-9]+$'
           OR (entry->>'attacks')::numeric > 9223372036854775807
           OR (entry->>'three_stars')::numeric > 9223372036854775807 THEN RETURN false; END IF;
        level_value := (entry->>'level')::integer;
        attempts := (entry->>'attacks')::bigint;
        triples := (entry->>'three_stars')::bigint;
        IF level_value NOT BETWEEN 1 AND 20 OR level_value >= previous_level
           OR triples > attempts THEN RETURN false; END IF;
        previous_level := level_value;
    END LOOP;
    RETURN true;
EXCEPTION WHEN numeric_value_out_of_range THEN RETURN false;
END
$$;
-- +goose StatementEnd

ALTER TABLE public.cwl_participation
    DROP CONSTRAINT cwl_participation_hitrates_check,
    ADD CONSTRAINT cwl_participation_hitrates_check CHECK (
        same_th_hitrates IS NULL OR public.cwl_participation_hitrates_valid(same_th_hitrates));

-- Source: 045_legend_daily_attack_types.sql
-- NULL means a historical closeout has not yet been rebuilt with army types.
ALTER TABLE public.legend_daily_stats
    ADD COLUMN air_attack_count bigint,
    ADD COLUMN ground_attack_count bigint,
    ADD COLUMN mixed_attack_count bigint,
    ADD COLUMN unknown_attack_count bigint,
    ADD CONSTRAINT legend_daily_stats_attack_types_check CHECK (
        num_nonnulls(air_attack_count, ground_attack_count, mixed_attack_count, unknown_attack_count) = 0
        OR (
            num_nonnulls(air_attack_count, ground_attack_count, mixed_attack_count, unknown_attack_count) = 4
            AND air_attack_count >= 0 AND ground_attack_count >= 0
            AND mixed_attack_count >= 0 AND unknown_attack_count >= 0
            AND air_attack_count + ground_attack_count + mixed_attack_count + unknown_attack_count = attack_count
        )
    );

-- Source: 047_giveaway_runtime.sql
ALTER TABLE giveaways ADD COLUMN webhook_id text;
CREATE TABLE giveaway_entry_receipts (
 interaction_id text PRIMARY KEY, giveaway_id text NOT NULL REFERENCES giveaways(id) ON DELETE CASCADE,
 server_id text NOT NULL, actor_user_id text NOT NULL, channel_id text NOT NULL, message_id text NOT NULL,
 request_hash text NOT NULL, outcome text NOT NULL CHECK (outcome IN ('entered','already_entered')),
 committed_entry_count bigint NOT NULL CHECK (committed_entry_count >= 0), created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX giveaway_entry_receipts_giveaway_idx ON giveaway_entry_receipts(giveaway_id);
CREATE TABLE giveaway_outcome_runs (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), giveaway_id text NOT NULL UNIQUE REFERENCES giveaways(id) ON DELETE CASCADE,
 server_id text NOT NULL, channel_id text NOT NULL, start_time timestamptz NOT NULL, end_time timestamptz NOT NULL,
 source_updated_at timestamptz NOT NULL, winner_count integer NOT NULL CHECK (winner_count > 0), boosters jsonb NOT NULL,
 entry_count bigint NOT NULL CHECK (entry_count >= 0), cursor bigint NOT NULL DEFAULT 0 CHECK (cursor >= 0),
 state text NOT NULL DEFAULT 'resolving' CHECK (state IN ('resolving','completed','failed')),
 lease_token uuid, lease_expires_at timestamptz, attempt_count integer NOT NULL DEFAULT 0, completed_at timestamptz, last_error text,
 created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE giveaway_outcome_entries (
 run_id uuid NOT NULL REFERENCES giveaway_outcome_runs(id) ON DELETE CASCADE, user_id text NOT NULL,
 ordinal bigint NOT NULL CHECK (ordinal > 0), weight double precision CHECK (weight >= 0), score double precision,
 PRIMARY KEY (run_id,user_id), UNIQUE (run_id,ordinal)
);
CREATE TABLE giveaway_publication_effects (
 effect_id text PRIMARY KEY CHECK (effect_id ~ '^[0-9a-f]{64}$'), giveaway_id text NOT NULL REFERENCES giveaways(id) ON DELETE CASCADE,
 server_id text NOT NULL, channel_id text NOT NULL, kind text NOT NULL CHECK (kind IN ('start','update','end','reroll')),
 start_time timestamptz NOT NULL, source_updated_at timestamptz NOT NULL, source_message_id text,
 payload_version integer NOT NULL CHECK (payload_version = 1), payload jsonb NOT NULL,
 state text NOT NULL DEFAULT 'pending' CHECK (state IN ('pending','sending','succeeded','failed','ambiguous')),
 claim_token uuid, claimed_at timestamptz, lease_expires_at timestamptz, attempt_count integer NOT NULL DEFAULT 0,
 next_attempt_at timestamptz NOT NULL DEFAULT now(), result_message_id text, last_error text,
 created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX giveaway_publications_pending_idx ON giveaway_publication_effects(state,next_attempt_at);
CREATE INDEX giveaway_publications_giveaway_idx ON giveaway_publication_effects(giveaway_id,kind);

-- Source: 048_giveaway_receipt_retention.sql
-- Retain external delivery evidence and signed interaction receipts after config
-- deletion, so a late Discord result or replay cannot authorize a second send.
ALTER TABLE giveaway_entry_receipts DROP CONSTRAINT giveaway_entry_receipts_giveaway_id_fkey;
ALTER TABLE giveaway_publication_effects DROP CONSTRAINT giveaway_publication_effects_giveaway_id_fkey;

-- Source: 049_ticket_runtime.sql
-- Activate the previously deferred, API-owned ticket runtime without rewriting
-- applied migrations. Preserve panel identities and durable Discord evidence.

-- Preparation and execution share an opaque operation identity. No ticket row
-- is fabricated before Discord supplies the required real channel_id.
CREATE TABLE public.ticket_runtime_operations (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    interaction_id text NOT NULL UNIQUE,
    action text NOT NULL CHECK (action IN ('open', 'set_status', 'assign', 'approve')),
    ticket_id uuid NOT NULL DEFAULT uuidv7(),
    ticket_number integer CHECK (ticket_number > 0),
    server_id text NOT NULL CHECK (server_id ~ '^[1-9][0-9]{0,19}$'),
    actor_user_id text NOT NULL CHECK (actor_user_id ~ '^[1-9][0-9]{0,19}$'),
    panel_id uuid NOT NULL,
    button_id uuid,
    origin_channel_id text NOT NULL CHECK (origin_channel_id ~ '^[1-9][0-9]{0,19}$'),
    origin_message_id text NOT NULL CHECK (origin_message_id ~ '^[1-9][0-9]{0,19}$'),
    context jsonb NOT NULL,
    request jsonb NOT NULL,
    request_hash text NOT NULL CHECK (request_hash ~ '^[0-9a-f]{64}$'),
    progress jsonb NOT NULL DEFAULT '{}'::jsonb,
    progress_receipts jsonb NOT NULL DEFAULT '{}'::jsonb,
    version integer NOT NULL DEFAULT 0 CHECK (version >= 0),
    expires_at timestamptz NOT NULL DEFAULT (now() + interval '15 minutes'),
    submission_interaction_id text UNIQUE,
    submitted_request jsonb,
    submitted_request_hash text,
    state text NOT NULL DEFAULT 'preparing'
        CHECK (state IN ('preparing', 'submitted', 'provisioning', 'reconciling', 'completed', 'failed')),
    result jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CHECK (interaction_id ~ '^[1-9][0-9]{0,19}$'),
    CHECK (submission_interaction_id IS NULL OR submission_interaction_id ~ '^[1-9][0-9]{0,19}$'),
    CHECK (submitted_request_hash IS NULL OR submitted_request_hash ~ '^[0-9a-f]{64}$'),
    CHECK (jsonb_typeof(context) = 'object' AND octet_length(context::text) <= 65536),
    CHECK (jsonb_typeof(request) = 'object' AND octet_length(request::text) <= 65536),
    CHECK (jsonb_typeof(progress) = 'object' AND octet_length(progress::text) <= 32768),
    CHECK (jsonb_typeof(progress_receipts) = 'object' AND octet_length(progress_receipts::text) <= 32768),
    CHECK (jsonb_typeof(result) = 'object' AND octet_length(result::text) <= 65536),
    CHECK (submitted_request IS NULL OR (jsonb_typeof(submitted_request) = 'object' AND octet_length(submitted_request::text) <= 65536)),
    CHECK ((state = 'preparing' AND action IN ('open', 'approve') AND (action <> 'open' OR button_id IS NOT NULL)
            AND submission_interaction_id IS NULL AND submitted_request IS NULL AND submitted_request_hash IS NULL AND ticket_number IS NULL)
        OR (state <> 'preparing' AND submission_interaction_id IS NOT NULL AND submitted_request IS NOT NULL AND submitted_request_hash IS NOT NULL
            AND ((action = 'open' AND button_id IS NOT NULL AND ticket_number IS NOT NULL) OR (action <> 'open' AND ticket_number IS NULL))))
);

CREATE UNIQUE INDEX idx_ticket_runtime_open_identity ON public.ticket_runtime_operations (ticket_id) WHERE action = 'open';
CREATE UNIQUE INDEX idx_ticket_runtime_open_number ON public.ticket_runtime_operations (ticket_number) WHERE action = 'open';
CREATE INDEX idx_ticket_runtime_ticket ON public.ticket_runtime_operations (server_id, ticket_id, created_at);
CREATE INDEX idx_ticket_runtime_recovery ON public.ticket_runtime_operations (updated_at, id)
    WHERE state IN ('submitted', 'provisioning', 'reconciling');
CREATE INDEX idx_ticket_runtime_guild_recovery ON public.ticket_runtime_operations (server_id, updated_at, id)
    WHERE state IN ('submitted', 'provisioning', 'reconciling');

CREATE TABLE public.ticket_runtime_effects (
    operation_id uuid NOT NULL REFERENCES public.ticket_runtime_operations(id) ON DELETE RESTRICT,
    effect_key text NOT NULL CHECK (length(btrim(effect_key)) > 0 AND length(effect_key) <= 128),
    ordinal integer NOT NULL CHECK (ordinal >= 0),
    effect_type text NOT NULL CHECK (effect_type IN ('create_channel', 'create_thread', 'send_message', 'pin_message',
        'add_role', 'remove_role', 'edit_channel', 'delete_channel', 'add_thread_member')),
    request jsonb NOT NULL,
    state text NOT NULL DEFAULT 'pending' CHECK (state IN ('pending', 'executing', 'uncertain', 'succeeded', 'failed')),
    lease_token uuid,
    lease_expires_at timestamptz,
    attempt_count integer NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
    result jsonb NOT NULL DEFAULT '{}'::jsonb,
    last_error text CHECK (octet_length(last_error) <= 2048),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (operation_id, effect_key),
    UNIQUE (operation_id, ordinal),
    CHECK (jsonb_typeof(request) = 'object' AND octet_length(request::text) <= 65536),
    CHECK (jsonb_typeof(result) = 'object' AND octet_length(result::text) <= 16384),
    CHECK ((lease_token IS NULL) = (lease_expires_at IS NULL)),
    CHECK (state <> 'executing' OR (lease_token IS NOT NULL AND lease_expires_at IS NOT NULL AND attempt_count > 0))
);

CREATE INDEX idx_ticket_runtime_effects_recovery ON public.ticket_runtime_effects (state, lease_expires_at, operation_id)
    WHERE state IN ('pending', 'executing', 'uncertain');

-- IDs/config are logical references validated by the API. Deliberately do not
-- cascade from auth_users, servers, panels, buttons, or tickets: unfinished
-- Discord effects and their resource evidence must survive configuration loss.
-- +goose StatementBegin
CREATE FUNCTION public.guard_ticket_runtime_operation() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF ROW(NEW.id, NEW.interaction_id, NEW.action, NEW.ticket_id, NEW.server_id, NEW.actor_user_id,
           NEW.panel_id, NEW.button_id, NEW.origin_channel_id, NEW.origin_message_id,
           NEW.context, NEW.request, NEW.request_hash, NEW.created_at)
       IS DISTINCT FROM
       ROW(OLD.id, OLD.interaction_id, OLD.action, OLD.ticket_id, OLD.server_id, OLD.actor_user_id,
           OLD.panel_id, OLD.button_id, OLD.origin_channel_id, OLD.origin_message_id,
           OLD.context, OLD.request, OLD.request_hash, OLD.created_at) THEN
        RAISE EXCEPTION 'ticket operation identity and initial request are immutable' USING ERRCODE = '23514';
    END IF;
    IF OLD.state <> 'preparing' AND
       (NEW.state = 'preparing' OR ROW(NEW.submission_interaction_id, NEW.submitted_request, NEW.submitted_request_hash,
           NEW.ticket_number, NEW.progress, NEW.progress_receipts, NEW.version, NEW.expires_at)
        IS DISTINCT FROM ROW(OLD.submission_interaction_id, OLD.submitted_request, OLD.submitted_request_hash,
           OLD.ticket_number, OLD.progress, OLD.progress_receipts, OLD.version, OLD.expires_at)) THEN
        RAISE EXCEPTION 'submitted ticket input and preparation receipts are immutable' USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END
$$;
-- +goose StatementEnd
CREATE TRIGGER guard_ticket_runtime_operation BEFORE UPDATE ON public.ticket_runtime_operations
    FOR EACH ROW EXECUTE FUNCTION public.guard_ticket_runtime_operation();

-- +goose StatementBegin
CREATE FUNCTION public.guard_ticket_runtime_effect() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF ROW(NEW.operation_id, NEW.effect_key, NEW.ordinal, NEW.effect_type, NEW.request, NEW.created_at)
       IS DISTINCT FROM ROW(OLD.operation_id, OLD.effect_key, OLD.ordinal, OLD.effect_type, OLD.request, OLD.created_at) THEN
        RAISE EXCEPTION 'ticket effect identity and request are immutable' USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END
$$;
-- +goose StatementEnd
CREATE TRIGGER guard_ticket_runtime_effect BEFORE UPDATE ON public.ticket_runtime_effects
    FOR EACH ROW EXECUTE FUNCTION public.guard_ticket_runtime_effect();

-- Legacy imports supplied explicit numbers without advancing the sequence.
-- Lock both the ticket writers and sequence allocators for the migration-only
-- high-water adjustment. INCREMENT BY 1 preserves its existing definition.
LOCK TABLE public.tickets IN SHARE ROW EXCLUSIVE MODE;
ALTER SEQUENCE public.tickets_number_seq INCREMENT BY 1;
-- +goose StatementBegin
DO $$
DECLARE
    imported_max bigint;
    sequence_high bigint;
BEGIN
    SELECT COALESCE(max(number), 0) INTO imported_max FROM public.tickets;
    SELECT last_value INTO sequence_high FROM public.tickets_number_seq;
    IF imported_max >= sequence_high THEN
        PERFORM setval('public.tickets_number_seq', imported_max, true);
    END IF;
END
$$;
-- +goose StatementEnd


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
           OR jsonb_typeof(component->'custom_id') <> 'string'
           OR component->>'custom_id' = ''
           OR (component ? 'id' AND (
                jsonb_typeof(component->'id') <> 'string'
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
       'ck:ticket:open:' || panel_id::text || ':' || button_id::text,
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
    IF EXISTS (
        SELECT 1
        FROM public.ticket_panels panel
        JOIN ticket_component_identity identity ON identity.panel_id = panel.id
        WHERE panel.data ? (identity.custom_id || '_settings')
          AND identity.custom_id || '_settings' <> identity.legacy_custom_id || '_settings'
    ) THEN
        RAISE EXCEPTION 'ticket button settings target key already exists';
    END IF;
END
$$;
-- +goose StatementEnd

WITH rewritten AS (
    SELECT panel.id AS panel_id,
           jsonb_agg(jsonb_set(jsonb_set(component.value, '{id}', to_jsonb(identity.button_id::text), true),
                              '{custom_id}', to_jsonb(identity.custom_id), true)
                     ORDER BY component.ordinality) AS components,
           array_agg(identity.legacy_custom_id || '_settings') AS old_settings_keys,
           COALESCE(jsonb_object_agg(identity.custom_id || '_settings',
                                    panel.data->(identity.legacy_custom_id || '_settings'))
                    FILTER (WHERE panel.data ? (identity.legacy_custom_id || '_settings')), '{}'::jsonb) AS moved_settings
    FROM public.ticket_panels panel
    JOIN ticket_component_identity identity ON identity.panel_id = panel.id
    JOIN LATERAL jsonb_array_elements(panel.components) WITH ORDINALITY component(value, ordinality)
      ON component.ordinality = identity.ordinal
    GROUP BY panel.id
)
UPDATE public.ticket_panels panel
SET components = rewritten.components,
    data = (panel.data - rewritten.old_settings_keys) || rewritten.moved_settings
FROM rewritten
WHERE panel.id = rewritten.panel_id;

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
           OR jsonb_typeof(component->'id') <> 'string'
           OR jsonb_typeof(component->'custom_id') <> 'string' THEN
            RETURN false;
        END IF;
        component_id := component->>'id';
        custom_id := component->>'custom_id';
        IF custom_id = ''
           OR component_id !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
           OR custom_id <> 'ck:ticket:open:' || panel_id::text || ':' || component_id
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
    IF ROW(NEW.id, NEW.server_id, NEW.name, NEW.created_at)
       IS DISTINCT FROM ROW(OLD.id, OLD.server_id, OLD.name, OLD.created_at) THEN
        RAISE EXCEPTION 'ticket panel identity is immutable' USING ERRCODE = '23514';
    END IF;
    IF OLD.archived_at IS NOT NULL THEN
        RAISE EXCEPTION 'archived ticket panel configuration is immutable' USING ERRCODE = '23514';
    END IF;
    IF NEW.archived_at IS NOT NULL
       AND ROW(NEW.components, NEW.data) IS DISTINCT FROM ROW(OLD.components, OLD.data) THEN
        RAISE EXCEPTION 'ticket panel archival cannot rewrite configuration' USING ERRCODE = '23514';
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
ALTER TABLE public.ticket_runtime_operations ADD CONSTRAINT ticket_runtime_operations_panel_id_fkey
    FOREIGN KEY (panel_id, server_id) REFERENCES public.ticket_panels(id, server_id) ON DELETE RESTRICT;

COMMENT ON TABLE public.ticket_panels IS 'Canonical ticket panel configuration; archived rows retain stable history identities.';
COMMENT ON TABLE public.ticket_panel IS 'Deprecated imported ticket panel copy; not a live configuration source after migration 017.';
COMMENT ON TABLE public.ticket_panel_buttons IS 'Deprecated imported ticket button copy; not a live configuration source after migration 017.';


-- A panel publication has no ticket lifecycle operation, so it needs its own
-- pre-Discord request/effect journal. Keep every attempt and result as evidence.
CREATE TABLE public.ticket_panel_publication_effects (
    effect_id text PRIMARY KEY CHECK (effect_id ~ '^[0-9a-f]{64}$'),
    panel_id uuid NOT NULL,
    server_id text NOT NULL CHECK (server_id ~ '^[1-9][0-9]{0,19}$'),
    revision bigint NOT NULL CHECK (revision > 0),
    source_updated_at timestamptz NOT NULL,
    channel_id text NOT NULL CHECK (channel_id ~ '^[1-9][0-9]{0,19}$'),
    payload_version integer NOT NULL DEFAULT 1 CHECK (payload_version = 1),
    payload jsonb NOT NULL CHECK (jsonb_typeof(payload) = 'object' AND octet_length(payload::text) <= 262144),
    state text NOT NULL DEFAULT 'pending' CHECK (state IN ('pending', 'executing', 'uncertain', 'succeeded', 'failed')),
    next_attempt_at timestamptz NOT NULL DEFAULT now(),
    retry_reason text CHECK (retry_reason IN ('pre_request_failure', 'rate_limited')),
    claim_token uuid,
    claimed_at timestamptz,
    lease_expires_at timestamptz,
    attempt_count integer NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
    result_message_id text CHECK (result_message_id ~ '^[1-9][0-9]{0,19}$'),
    last_error text CHECK (octet_length(last_error) <= 2048),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (panel_id, revision),
    UNIQUE (effect_id, panel_id, server_id, revision, source_updated_at, channel_id, result_message_id),
    FOREIGN KEY (panel_id, server_id) REFERENCES public.ticket_panels(id, server_id) ON DELETE RESTRICT,
    CHECK ((claim_token IS NULL AND claimed_at IS NULL AND lease_expires_at IS NULL)
        OR (claim_token IS NOT NULL AND claimed_at IS NOT NULL AND lease_expires_at IS NOT NULL)),
    CHECK (state <> 'executing' OR (claim_token IS NOT NULL AND attempt_count > 0)),
    CHECK (state <> 'succeeded' OR result_message_id IS NOT NULL),
    CHECK (state <> 'pending' OR result_message_id IS NULL),
    CHECK ((state = 'pending' AND attempt_count = 0 AND retry_reason IS NULL)
        OR (state = 'pending' AND attempt_count > 0 AND retry_reason IS NOT NULL)
        OR (state <> 'pending' AND retry_reason IS NULL))
);
CREATE UNIQUE INDEX ticket_panel_publication_effects_unresolved_panel_key
    ON public.ticket_panel_publication_effects (panel_id)
    WHERE state IN ('pending', 'executing', 'uncertain');
CREATE INDEX idx_ticket_panel_publication_effects_recovery
    ON public.ticket_panel_publication_effects
       (server_id, state, next_attempt_at, lease_expires_at, panel_id, revision)
    WHERE state IN ('pending', 'executing', 'uncertain');

-- +goose StatementBegin
CREATE FUNCTION public.guard_ticket_panel_publication_effect() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    expected_revision bigint;
    current_source_updated_at timestamptz;
    panel_archived_at timestamptz;
    existing public.ticket_panel_publication_effects%ROWTYPE;
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'ticket panel publication effect evidence cannot be deleted' USING ERRCODE = '23514';
    END IF;
    IF TG_OP = 'INSERT' THEN
        SELECT * INTO existing FROM public.ticket_panel_publication_effects WHERE effect_id = NEW.effect_id;
        IF FOUND THEN
            IF ROW(NEW.panel_id, NEW.server_id, NEW.revision, NEW.source_updated_at, NEW.channel_id,
                   NEW.payload_version, NEW.payload)
               IS DISTINCT FROM ROW(existing.panel_id, existing.server_id, existing.revision,
                   existing.source_updated_at, existing.channel_id, existing.payload_version, existing.payload) THEN
                RAISE EXCEPTION 'ticket panel publication effect replay conflicts with stored identity' USING ERRCODE = '23514';
            END IF;
            RETURN NEW;
        END IF;
        SELECT updated_at, archived_at INTO current_source_updated_at, panel_archived_at
        FROM public.ticket_panels
        WHERE id = NEW.panel_id AND server_id = NEW.server_id
        FOR SHARE;
        IF NOT FOUND OR panel_archived_at IS NOT NULL THEN
            RAISE EXCEPTION 'ticket panel publication requires an active canonical panel' USING ERRCODE = '23514';
        END IF;
        IF NEW.source_updated_at IS DISTINCT FROM current_source_updated_at THEN
            RAISE EXCEPTION 'ticket panel configuration changed before publication preparation' USING ERRCODE = '23514';
        END IF;
        SELECT COALESCE(max(revision), 0) + 1 INTO expected_revision
        FROM public.ticket_panel_publication_effects WHERE panel_id = NEW.panel_id;
        IF NEW.revision <> expected_revision THEN
            RAISE EXCEPTION 'ticket panel publication revision must be monotonic' USING ERRCODE = '23514';
        END IF;
        RETURN NEW;
    END IF;
    IF ROW(NEW.effect_id, NEW.panel_id, NEW.server_id, NEW.revision, NEW.source_updated_at,
           NEW.channel_id, NEW.payload_version, NEW.payload, NEW.created_at)
       IS DISTINCT FROM ROW(OLD.effect_id, OLD.panel_id, OLD.server_id, OLD.revision, OLD.source_updated_at,
           OLD.channel_id, OLD.payload_version, OLD.payload, OLD.created_at) THEN
        RAISE EXCEPTION 'ticket panel publication effect identity and payload are immutable' USING ERRCODE = '23514';
    END IF;
    IF OLD.result_message_id IS NOT NULL AND NEW.result_message_id IS DISTINCT FROM OLD.result_message_id THEN
        RAISE EXCEPTION 'ticket panel publication message evidence is immutable' USING ERRCODE = '23514';
    END IF;
    IF OLD.state IN ('succeeded', 'failed') AND NEW.state IS DISTINCT FROM OLD.state THEN
        RAISE EXCEPTION 'terminal ticket panel publication effect cannot be reopened' USING ERRCODE = '23514';
    END IF;
    IF OLD.state IN ('succeeded', 'failed')
       AND ROW(NEW.next_attempt_at, NEW.retry_reason, NEW.claim_token, NEW.claimed_at,
               NEW.lease_expires_at, NEW.attempt_count, NEW.result_message_id, NEW.last_error)
           IS DISTINCT FROM ROW(OLD.next_attempt_at, OLD.retry_reason, OLD.claim_token, OLD.claimed_at,
               OLD.lease_expires_at, OLD.attempt_count, OLD.result_message_id, OLD.last_error) THEN
        RAISE EXCEPTION 'terminal ticket panel publication evidence is immutable' USING ERRCODE = '23514';
    END IF;
    IF OLD.state = 'uncertain'
       AND ROW(NEW.next_attempt_at, NEW.retry_reason, NEW.claim_token, NEW.claimed_at,
               NEW.lease_expires_at, NEW.attempt_count)
           IS DISTINCT FROM ROW(OLD.next_attempt_at, OLD.retry_reason, OLD.claim_token, OLD.claimed_at,
               OLD.lease_expires_at, OLD.attempt_count) THEN
        RAISE EXCEPTION 'uncertain ticket panel publication claim evidence is immutable' USING ERRCODE = '23514';
    END IF;
    IF OLD.state = 'uncertain' AND NEW.state IN ('pending', 'executing') THEN
        RAISE EXCEPTION 'uncertain ticket panel create cannot be retried' USING ERRCODE = '23514';
    END IF;
    IF OLD.state = 'executing' AND NEW.state = 'pending'
       AND NEW.retry_reason NOT IN ('pre_request_failure', 'rate_limited') THEN
        RAISE EXCEPTION 'ticket panel publication retry is not known safe' USING ERRCODE = '23514';
    END IF;
    IF OLD.state = 'pending' AND NEW.state = 'executing' THEN
        SELECT updated_at, archived_at INTO current_source_updated_at, panel_archived_at
        FROM public.ticket_panels
        WHERE id = NEW.panel_id AND server_id = NEW.server_id
        FOR SHARE;
        IF NOT FOUND OR panel_archived_at IS NOT NULL
           OR NEW.source_updated_at IS DISTINCT FROM current_source_updated_at THEN
            RAISE EXCEPTION 'ticket panel configuration changed before Discord execution' USING ERRCODE = '23514';
        END IF;
    END IF;
    RETURN NEW;
END
$$;
-- +goose StatementEnd
CREATE TRIGGER guard_ticket_panel_publication_effect
    BEFORE INSERT OR UPDATE OR DELETE ON public.ticket_panel_publication_effects
    FOR EACH ROW EXECUTE FUNCTION public.guard_ticket_panel_publication_effect();

-- Only a successfully observed Discord message becomes a publication occurrence.
CREATE TABLE public.ticket_panel_publications (
    effect_id text NOT NULL UNIQUE,
    panel_id uuid NOT NULL,
    server_id text NOT NULL CHECK (server_id ~ '^[1-9][0-9]{0,19}$'),
    revision bigint NOT NULL CHECK (revision > 0),
    source_updated_at timestamptz NOT NULL,
    channel_id text NOT NULL CHECK (channel_id ~ '^[1-9][0-9]{0,19}$'),
    message_id text NOT NULL CHECK (message_id ~ '^[1-9][0-9]{0,19}$'),
    state text NOT NULL DEFAULT 'active' CHECK (state IN ('active', 'archived')),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    archived_at timestamptz,
    PRIMARY KEY (panel_id, revision),
    UNIQUE (server_id, channel_id, message_id),
    FOREIGN KEY (effect_id, panel_id, server_id, revision, source_updated_at, channel_id, message_id)
        REFERENCES public.ticket_panel_publication_effects
            (effect_id, panel_id, server_id, revision, source_updated_at, channel_id, result_message_id)
        ON DELETE RESTRICT,
    CHECK ((state = 'active') = (archived_at IS NULL))
);
CREATE UNIQUE INDEX ticket_panel_publications_active_panel_key
    ON public.ticket_panel_publications (panel_id) WHERE state = 'active';
CREATE INDEX idx_ticket_panel_publications_server_state
    ON public.ticket_panel_publications (server_id, state, updated_at, panel_id, revision);

-- +goose StatementBegin
CREATE FUNCTION public.guard_ticket_panel_publication() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    effect_state text;
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'ticket panel publication evidence cannot be deleted' USING ERRCODE = '23514';
    END IF;
    IF TG_OP = 'INSERT' THEN
        SELECT state INTO effect_state FROM public.ticket_panel_publication_effects
        WHERE effect_id = NEW.effect_id FOR KEY SHARE;
        IF effect_state NOT IN ('executing', 'succeeded') THEN
            RAISE EXCEPTION 'ticket panel publication requires a claimed successful effect' USING ERRCODE = '23514';
        END IF;
        IF NEW.state <> 'active' OR NEW.archived_at IS NOT NULL THEN
            RAISE EXCEPTION 'a new ticket panel publication must be active' USING ERRCODE = '23514';
        END IF;
        RETURN NEW;
    END IF;
    IF ROW(NEW.effect_id, NEW.panel_id, NEW.server_id, NEW.revision, NEW.source_updated_at,
           NEW.channel_id, NEW.message_id, NEW.created_at)
       IS DISTINCT FROM ROW(OLD.effect_id, OLD.panel_id, OLD.server_id, OLD.revision, OLD.source_updated_at,
           OLD.channel_id, OLD.message_id, OLD.created_at) THEN
        RAISE EXCEPTION 'ticket panel publication identity and message evidence are immutable' USING ERRCODE = '23514';
    END IF;
    IF OLD.state = 'archived' AND NEW IS DISTINCT FROM OLD THEN
        RAISE EXCEPTION 'archived ticket panel publication evidence is immutable' USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END
$$;
-- +goose StatementEnd
CREATE TRIGGER guard_ticket_panel_publication
    BEFORE INSERT OR UPDATE OR DELETE ON public.ticket_panel_publications
    FOR EACH ROW EXECUTE FUNCTION public.guard_ticket_panel_publication();

-- +goose StatementBegin
CREATE FUNCTION public.require_succeeded_ticket_panel_publication() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM public.ticket_panel_publication_effects effect
        WHERE effect.effect_id = NEW.effect_id AND effect.state = 'succeeded'
          AND effect.result_message_id = NEW.message_id
    ) THEN
        RAISE EXCEPTION 'ticket panel publication occurrence requires a succeeded effect' USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END
$$;
-- +goose StatementEnd
CREATE CONSTRAINT TRIGGER require_succeeded_ticket_panel_publication
    AFTER INSERT OR UPDATE ON public.ticket_panel_publications
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION public.require_succeeded_ticket_panel_publication();

ALTER TABLE public.ticket_runtime_effects
    ADD COLUMN next_attempt_at timestamptz NOT NULL DEFAULT now(),
    ADD COLUMN claimed_at timestamptz;
UPDATE public.ticket_runtime_effects
SET claimed_at = COALESCE(updated_at, created_at)
WHERE lease_token IS NOT NULL AND claimed_at IS NULL;
ALTER TABLE public.ticket_runtime_effects
    ADD CONSTRAINT ticket_runtime_effects_claim_triplet_check CHECK (
        (lease_token IS NULL AND claimed_at IS NULL AND lease_expires_at IS NULL)
        OR (lease_token IS NOT NULL AND claimed_at IS NOT NULL AND lease_expires_at IS NOT NULL)),
    ADD CONSTRAINT ticket_runtime_effects_active_claim_check CHECK (
        state NOT IN ('executing', 'uncertain')
        OR (lease_token IS NOT NULL AND claimed_at IS NOT NULL AND lease_expires_at IS NOT NULL AND attempt_count > 0));
CREATE INDEX idx_ticket_runtime_effects_due
    ON public.ticket_runtime_effects (state, next_attempt_at, lease_expires_at, operation_id, ordinal)
    WHERE state IN ('pending', 'executing', 'uncertain');
CREATE INDEX idx_ticket_runtime_ticket_recovery
    ON public.ticket_runtime_operations (server_id, ticket_id, state, updated_at, id)
    WHERE state IN ('submitted', 'provisioning', 'reconciling');

-- +goose StatementBegin
CREATE OR REPLACE FUNCTION public.guard_ticket_runtime_effect() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF ROW(NEW.operation_id, NEW.effect_key, NEW.ordinal, NEW.effect_type, NEW.request, NEW.created_at)
       IS DISTINCT FROM ROW(OLD.operation_id, OLD.effect_key, OLD.ordinal, OLD.effect_type, OLD.request, OLD.created_at) THEN
        RAISE EXCEPTION 'ticket effect identity and request are immutable' USING ERRCODE = '23514';
    END IF;
    IF OLD.result <> '{}'::jsonb AND NEW.result IS DISTINCT FROM OLD.result THEN
        RAISE EXCEPTION 'ticket effect resource evidence is immutable' USING ERRCODE = '23514';
    END IF;
    IF OLD.result <> '{}'::jsonb
       AND ROW(NEW.lease_token, NEW.claimed_at, NEW.lease_expires_at, NEW.attempt_count)
           IS DISTINCT FROM ROW(OLD.lease_token, OLD.claimed_at, OLD.lease_expires_at, OLD.attempt_count) THEN
        RAISE EXCEPTION 'ticket effect claim evidence is immutable after a result is known' USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END
$$;
-- +goose StatementEnd

COMMENT ON TABLE public.ticket_panel_publication_effects IS 'Fenced pre-Discord request ledger for ticket panel publication.';
COMMENT ON TABLE public.ticket_panel_publications IS 'Immutable successful Discord publication occurrences for canonical ticket panels.';
COMMENT ON COLUMN public.ticket_panel_publication_effects.source_updated_at IS 'Exact canonical panel updated_at revision used to prepare this Discord request.';
COMMENT ON COLUMN public.ticket_runtime_effects.next_attempt_at IS 'Earliest time an API-owned executor may claim or reconcile this effect.';
COMMENT ON COLUMN public.ticket_runtime_effects.claimed_at IS 'Timestamp paired with the current claim token and lease expiry.';


-- Permit the API-owned linked-clan selector before an assignment is submitted.
-- Resolve the unnamed 014 constraint by its exact column set, never by a
-- guessed PostgreSQL-generated suffix. Abort on unexpected schema drift.
-- +goose StatementBegin
DO $$
DECLARE
    matches text[];
    target record;
BEGIN
    FOR target IN SELECT * FROM (VALUES
        ('public.ticket_runtime_operations'::regclass, 'action'),
        ('public.ticket_runtime_effects'::regclass, 'effect_type')
    ) AS targets(relation_id, column_name) LOOP
        SELECT array_agg(c.conname::text) INTO matches
        FROM pg_constraint c
        WHERE c.conrelid = target.relation_id AND c.contype = 'c'
          AND c.conkey = ARRAY[(SELECT attnum FROM pg_attribute
              WHERE attrelid=target.relation_id AND attname=target.column_name)]::smallint[];
        IF COALESCE(cardinality(matches), 0) <> 1 THEN
            RAISE EXCEPTION 'expected exactly one ticket enum constraint for %', target.column_name;
        END IF;
        EXECUTE format('ALTER TABLE %s DROP CONSTRAINT %I', target.relation_id, matches[1]);
    END LOOP;
    SELECT array_agg(c.conname::text) INTO matches
    FROM pg_constraint c
    WHERE c.conrelid = 'public.ticket_runtime_operations'::regclass
      AND c.contype = 'c'
      AND ARRAY(
          SELECT a.attname::text FROM unnest(c.conkey) AS k(attnum)
          JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.attnum
          ORDER BY a.attname
      ) = ARRAY['action', 'button_id', 'state', 'submission_interaction_id',
                'submitted_request', 'submitted_request_hash', 'ticket_number'];
    IF COALESCE(cardinality(matches), 0) <> 1 THEN
        RAISE EXCEPTION 'expected exactly one ticket preparation/submission constraint';
    END IF;
    EXECUTE format('ALTER TABLE public.ticket_runtime_operations DROP CONSTRAINT %I', matches[1]);
END
$$;
-- +goose StatementEnd

ALTER TABLE public.ticket_runtime_operations
    ADD CONSTRAINT ticket_runtime_operations_action_check
    CHECK (action IN ('open', 'set_status', 'assign', 'approve', 'add_member', 'opt'));
ALTER TABLE public.ticket_runtime_effects
    ADD CONSTRAINT ticket_runtime_effects_effect_type_check
    CHECK (effect_type IN ('create_channel', 'create_thread', 'send_message', 'pin_message',
        'add_role', 'remove_role', 'edit_channel', 'delete_channel', 'add_thread_member', 'set_channel_permission'));

ALTER TABLE public.ticket_runtime_operations
    ADD CONSTRAINT ticket_runtime_operations_submission_shape_check CHECK (
        (state = 'preparing' AND action IN ('open', 'approve', 'assign')
            AND (action <> 'open' OR button_id IS NOT NULL)
            AND submission_interaction_id IS NULL AND submitted_request IS NULL
            AND submitted_request_hash IS NULL AND ticket_number IS NULL)
        OR (state <> 'preparing' AND submission_interaction_id IS NOT NULL
            AND submitted_request IS NOT NULL AND submitted_request_hash IS NOT NULL
            AND ((action = 'open' AND button_id IS NOT NULL AND ticket_number IS NOT NULL)
                OR (action <> 'open' AND ticket_number IS NULL)))
    );


-- Gateway notifications reuse the operation journal without allocating tickets.
-- Migration 019 supplies the named enum constraints and already restricts
-- preparing to open/approve/assign and ticket numbers to open.
ALTER TABLE public.ticket_runtime_operations
    DROP CONSTRAINT ticket_runtime_operations_action_check,
    ADD CONSTRAINT ticket_runtime_operations_action_check
    CHECK (action IN ('open', 'set_status', 'assign', 'approve', 'add_member', 'opt', 'notify'));

ALTER TABLE public.ticket_runtime_effects
    DROP CONSTRAINT ticket_runtime_effects_effect_type_check,
    ADD CONSTRAINT ticket_runtime_effects_effect_type_check
    CHECK (effect_type IN ('create_channel', 'create_thread', 'send_message', 'pin_message',
        'add_role', 'remove_role', 'edit_channel', 'delete_channel', 'add_thread_member',
        'set_channel_permission', 'delete_message', 'export_transcript'));

-- No message/attachment content is collected into SQL. The API persists scoped
-- R2 object keys/results, enforces the prior-send dependency and schedules
-- deletion at least one second after send completion through next_attempt_at.


CREATE TABLE public.ticket_account_preparations (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    interaction_id text NOT NULL UNIQUE CHECK (interaction_id ~ '^[1-9][0-9]{0,19}$'),
    request_hash text NOT NULL CHECK (request_hash ~ '^[0-9a-f]{64}$'),
    action text NOT NULL CHECK (action IN ('view', 'link')),
    actor_user_id text NOT NULL CHECK (actor_user_id ~ '^[1-9][0-9]{0,19}$'),
    server_id text NOT NULL CHECK (server_id ~ '^[1-9][0-9]{0,19}$'),
    channel_id text NOT NULL CHECK (channel_id ~ '^[1-9][0-9]{0,19}$'),
    origin_message_id text NOT NULL CHECK (origin_message_id ~ '^[1-9][0-9]{0,19}$'),
    ticket_id uuid REFERENCES public.tickets(id) ON DELETE RESTRICT,
    panel_id uuid NOT NULL,
    button_id uuid,
    source_updated_at timestamptz NOT NULL,
    context jsonb NOT NULL CHECK (jsonb_typeof(context) = 'object' AND octet_length(context::text) <= 65536),
    expires_at timestamptz NOT NULL DEFAULT (now() + interval '5 minutes'),
    created_at timestamptz NOT NULL DEFAULT now(),
    FOREIGN KEY (panel_id, server_id) REFERENCES public.ticket_panels(id, server_id) ON DELETE RESTRICT,
    CHECK ((action = 'view' AND ticket_id IS NOT NULL AND button_id IS NULL)
        OR (action = 'link' AND ticket_id IS NULL AND button_id IS NOT NULL)),
    CHECK (expires_at > created_at AND expires_at <= created_at + interval '5 minutes')
);

CREATE TABLE public.ticket_account_receipts (
    interaction_id text PRIMARY KEY CHECK (interaction_id ~ '^[1-9][0-9]{0,19}$'),
    preparation_id uuid NOT NULL REFERENCES public.ticket_account_preparations(id) ON DELETE RESTRICT,
    request_hash text NOT NULL CHECK (request_hash ~ '^[0-9a-f]{64}$'),
    result jsonb NOT NULL CHECK (jsonb_typeof(result) = 'object' AND octet_length(result::text) <= 65536),
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ticket_account_receipts_preparation_idx ON public.ticket_account_receipts(preparation_id);

-- Reopening uses a new interaction/session, never mutates an expired snapshot.
-- API checks expiry, actor, selected account membership and current ticket/panel
-- scope before effects. Context/results must never contain raw proof or tokens.
-- +goose StatementBegin
CREATE FUNCTION public.guard_ticket_account_snapshot() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW IS DISTINCT FROM OLD THEN
        RAISE EXCEPTION 'ticket account preparation and receipt snapshots are immutable' USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END
$$;
-- +goose StatementEnd
CREATE TRIGGER guard_ticket_account_preparation BEFORE UPDATE ON public.ticket_account_preparations
    FOR EACH ROW EXECUTE FUNCTION public.guard_ticket_account_snapshot();
CREATE TRIGGER guard_ticket_account_receipt BEFORE UPDATE ON public.ticket_account_receipts
    FOR EACH ROW EXECUTE FUNCTION public.guard_ticket_account_snapshot();


-- Approval templates can require many five-field modal pages. Increase only
-- their answer/receipt storage; retain all other actions' 32 KiB ceilings.
-- Resolve 014's unnamed checks by exact column identity, aborting on drift.
-- +goose StatementBegin
DO $$
DECLARE
    column_name text;
    matches text[];
BEGIN
    FOREACH column_name IN ARRAY ARRAY['progress', 'progress_receipts'] LOOP
        SELECT array_agg(c.conname::text) INTO matches
        FROM pg_constraint c
        WHERE c.conrelid = 'public.ticket_runtime_operations'::regclass AND c.contype = 'c'
          AND c.conkey = ARRAY[(SELECT attnum FROM pg_attribute
              WHERE attrelid = c.conrelid AND attname = column_name)]::smallint[];
        IF COALESCE(cardinality(matches), 0) <> 1 THEN
            RAISE EXCEPTION 'expected exactly one ticket size/object constraint for %', column_name;
        END IF;
        EXECUTE format('ALTER TABLE public.ticket_runtime_operations DROP CONSTRAINT %I', matches[1]);
    END LOOP;
END
$$;
-- +goose StatementEnd

ALTER TABLE public.ticket_runtime_operations
    ADD CONSTRAINT ticket_runtime_operations_progress_size_check CHECK (
        jsonb_typeof(progress) = 'object'
        AND octet_length(progress::text) <= CASE WHEN action = 'approve' THEN 524288 ELSE 32768 END),
    ADD CONSTRAINT ticket_runtime_operations_progress_receipts_size_check CHECK (
        jsonb_typeof(progress_receipts) = 'object'
        AND octet_length(progress_receipts::text) <= CASE WHEN action = 'approve' THEN 131072 ELSE 32768 END);

-- No rows, identity/submission guards, context/request bounds or other tables
-- change. API must preflight PostgreSQL JSON text bytes and retain every answer.

-- Source: 050_ticket_dashboard.sql
-- Templates belong to the server, not to a panel. Keep Discord work durable
-- and audit the authenticated dashboard actor without inventing interactions.
CREATE TABLE public.ticket_message_libraries (
    server_id text PRIMARY KEY CHECK (server_id ~ '^[1-9][0-9]{0,19}$'),
    templates jsonb NOT NULL DEFAULT '[]'::jsonb,
    updated_at timestamptz NOT NULL DEFAULT now(),
    CHECK (jsonb_typeof(templates) = 'array' AND jsonb_array_length(templates) <= 25 AND octet_length(templates::text) <= 524288)
);

CREATE TABLE public.ticket_dashboard_jobs (
    id uuid PRIMARY KEY,
    server_id text NOT NULL CHECK (server_id ~ '^[1-9][0-9]{0,19}$'),
    ticket_id uuid NOT NULL REFERENCES public.tickets(id) ON DELETE RESTRICT,
    actor_user_id text NOT NULL CHECK (actor_user_id ~ '^[1-9][0-9]{0,19}$'),
    action text NOT NULL CHECK (action IN ('set_status', 'capture_transcript')),
    request jsonb NOT NULL,
    state text NOT NULL DEFAULT 'pending' CHECK (state IN ('pending', 'running', 'completed', 'failed')),
    claim_token uuid,
    lease_expires_at timestamptz,
    result jsonb NOT NULL DEFAULT '{}'::jsonb,
    last_error text CHECK (length(last_error) <= 1000),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CHECK (jsonb_typeof(request) = 'object' AND octet_length(request::text) <= 65536),
    CHECK (jsonb_typeof(result) = 'object' AND octet_length(result::text) <= 16384),
    CHECK ((claim_token IS NULL) = (lease_expires_at IS NULL)),
    CHECK ((state = 'running') = (claim_token IS NOT NULL))
);
CREATE UNIQUE INDEX ticket_dashboard_one_active_job ON public.ticket_dashboard_jobs(ticket_id)
    WHERE state IN ('pending', 'running');
CREATE INDEX ticket_dashboard_jobs_server_history ON public.ticket_dashboard_jobs(server_id, ticket_id, created_at DESC);

-- Source: 051_ticket_panel_publication_edits.sql
-- Keep every published revision of an edited message; only its latest occurrence is active.
ALTER TABLE public.ticket_panel_publications
    DROP CONSTRAINT ticket_panel_publications_server_id_channel_id_message_id_key;
CREATE UNIQUE INDEX ticket_panel_publications_active_message_key
    ON public.ticket_panel_publications (server_id, channel_id, message_id) WHERE state = 'active';

-- Source: 052_ticket_application_accounts.sql
-- Freeze applicant identity/TH when the application is submitted. Never backfill
-- historical applications with current player levels: those are not evidence.
ALTER TABLE public.tickets ADD COLUMN application_accounts jsonb NOT NULL DEFAULT '[]'::jsonb
  CHECK (jsonb_typeof(application_accounts) = 'array' AND jsonb_array_length(application_accounts) <= 25
    AND octet_length(application_accounts::text) <= 16384);

-- Source: 053_ticket_dashboard_deletion.sql
ALTER TABLE public.ticket_dashboard_jobs DROP CONSTRAINT ticket_dashboard_jobs_action_check;
ALTER TABLE public.ticket_dashboard_jobs ADD CONSTRAINT ticket_dashboard_jobs_action_check
  CHECK (action IN ('set_status', 'capture_transcript', 'delete_ticket'));

-- Source: 054_ticket_channel_deletion_marker.sql
ALTER TABLE public.tickets ADD COLUMN conversation_deleted_at timestamptz;

-- Legacy closed tickets kept their conversation; legacy delete removed it.
UPDATE public.tickets SET status='sleep',closed_at=NULL WHERE status='closed';
UPDATE public.tickets SET status='closed',conversation_deleted_at=COALESCE(closed_at,clock_timestamp()) WHERE status='delete';

ALTER TABLE public.ticket_runtime_operations
  DROP CONSTRAINT ticket_runtime_operations_submission_shape_check,
  ADD CONSTRAINT ticket_runtime_operations_submission_shape_check CHECK (
    (state='preparing' AND action IN ('open','approve','assign','set_status')
      AND (action<>'open' OR button_id IS NOT NULL)
      AND submission_interaction_id IS NULL AND submitted_request IS NULL
      AND submitted_request_hash IS NULL AND ticket_number IS NULL)
    OR (state<>'preparing' AND submission_interaction_id IS NOT NULL
      AND submitted_request IS NOT NULL AND submitted_request_hash IS NOT NULL
      AND ((action='open' AND button_id IS NOT NULL AND ticket_number IS NOT NULL)
        OR (action<>'open' AND ticket_number IS NULL)))
  );

-- Source: 055_role_refresh.sql
INSERT INTO public.dashboard_role_grants(server_id,role_id,section,access_level,created_by_user_id,created_at,updated_at)
SELECT server_id,role_id,'roles',access_level,created_by_user_id,created_at,now()
FROM public.dashboard_role_grants WHERE section='family_settings'
ON CONFLICT(server_id,role_id,section) DO UPDATE SET
    access_level=CASE WHEN dashboard_role_grants.access_level='manage' OR EXCLUDED.access_level='manage' THEN 'manage' ELSE 'view' END,
    updated_at=now();
DELETE FROM public.dashboard_role_grants WHERE section='family_settings';
ALTER TABLE public.dashboard_role_grants DROP CONSTRAINT dashboard_role_grants_section_check;
ALTER TABLE public.dashboard_role_grants ADD CONSTRAINT dashboard_role_grants_section_check CHECK(section IN ('settings','logs','clans','rosters','links','moderation','roles','reminders','autoboards','giveaways','panels','tickets','embeds','wars','leaderboards'));
ALTER TABLE public.server_roles DROP COLUMN mode;
ALTER TABLE public.player_links_settings ADD COLUMN selected_by_user_id text;
ALTER TABLE public.servers ADD COLUMN role_leave_delay_minutes integer NOT NULL DEFAULT 5
    CHECK (role_leave_delay_minutes BETWEEN 5 AND 60);
CREATE TABLE public.role_refresh_jobs (
    id text PRIMARY KEY,
    server_id text NOT NULL REFERENCES public.servers(id) ON DELETE CASCADE,
    user_id text NOT NULL,
    request_id text,
    actor_id text,
    categories text[] NOT NULL DEFAULT ARRAY['family','clan','leadership','townhall','builderhall','league','builder_league','category','nicknames'],
    preview boolean NOT NULL DEFAULT false,
    grace_until timestamptz,
    due_at timestamptz NOT NULL DEFAULT now(),
    revision bigint NOT NULL DEFAULT 1,
    attempts integer NOT NULL DEFAULT 0,
    completed_at timestamptz,
    result jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX role_refresh_jobs_due ON public.role_refresh_jobs (due_at, id) WHERE completed_at IS NULL;
CREATE INDEX role_refresh_jobs_completed ON public.role_refresh_jobs (completed_at) WHERE completed_at IS NOT NULL;
CREATE INDEX role_refresh_jobs_request ON public.role_refresh_jobs (server_id, request_id) WHERE request_id IS NOT NULL;
CREATE TABLE public.role_refresh_leases (
    server_id text NOT NULL REFERENCES public.servers(id) ON DELETE CASCADE,
    user_id text NOT NULL,
    job_id text NOT NULL REFERENCES public.role_refresh_jobs(id) ON DELETE CASCADE,
    token uuid NOT NULL DEFAULT uuidv7(),
    revision bigint NOT NULL,
    expires_at timestamptz NOT NULL,
    PRIMARY KEY (server_id, user_id)
);

-- Source: 056_ticket_button_click_logs.sql
CREATE TABLE public.ticket_button_click_logs (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    interaction_id text NOT NULL UNIQUE,
    request_hash text NOT NULL,
    server_id text NOT NULL,
    panel_id uuid NOT NULL,
    channel_id text NOT NULL,
    content text NOT NULL,
    state text NOT NULL DEFAULT 'pending' CHECK (state IN ('pending','sent','failed')),
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX ticket_button_click_logs_pending ON public.ticket_button_click_logs(updated_at,id) WHERE state='pending';

-- Source: 057_remove_role_refresh_triggers.sql
DROP TABLE public.server_autoeval_triggers;

-- Source: 058_server_clan_verification.sql
CREATE TABLE public.server_clan_verifications (
    server_id text NOT NULL,
    clan_tag text NOT NULL,
    challenge_id uuid NOT NULL,
    marker text NOT NULL UNIQUE,
    marker_index integer NOT NULL CHECK (marker_index BETWEEN 0 AND 19),
    requested_by text NOT NULL,
    state text NOT NULL DEFAULT 'pending' CHECK (state IN ('pending', 'verified', 'expired')),
    started_at timestamptz NOT NULL DEFAULT now(),
    check_after timestamptz NOT NULL,
    next_check_at timestamptz NOT NULL,
    expires_at timestamptz NOT NULL,
    last_checked_at timestamptz,
    verified_at timestamptz,
    PRIMARY KEY (server_id, clan_tag),
    FOREIGN KEY (server_id, clan_tag) REFERENCES public.server_clans(server_id, tag) ON DELETE CASCADE,
    CHECK (check_after > started_at AND expires_at > check_after),
    CHECK ((state = 'verified') = (verified_at IS NOT NULL))
);
CREATE INDEX server_clan_verifications_due ON public.server_clan_verifications(next_check_at) WHERE state = 'pending';
COMMENT ON TABLE public.server_clan_verifications IS 'Description-edit proof scoped to a configured clan and Discord server; deleted on clan removal.';

-- Source: 059_short_clan_verification_markers.sql
ALTER TABLE public.server_clan_verifications DROP CONSTRAINT server_clan_verifications_marker_key;
-- Existing long-code challenges need a fresh description baseline for a short word.
UPDATE public.server_clan_verifications SET state='expired' WHERE state='pending';
CREATE UNIQUE INDEX server_clan_verifications_pending_word ON public.server_clan_verifications(clan_tag,marker) WHERE state='pending';

-- Source: 060_clan_notification_follows.sql
ALTER TABLE public.user_bookmarks
  ADD COLUMN war_notifications_enabled boolean NOT NULL DEFAULT false,
  ADD COLUMN raid_notifications_enabled boolean NOT NULL DEFAULT false,
  ADD COLUMN war_active_until timestamptz,
  ADD COLUMN raid_active_until timestamptz,
  ADD CONSTRAINT clan_notification_fields CHECK (entity_type = 'clan' OR
    (NOT war_notifications_enabled AND NOT raid_notifications_enabled AND war_active_until IS NULL AND raid_active_until IS NULL));
CREATE INDEX clan_war_notification_interest ON public.user_bookmarks(tag,war_active_until) WHERE war_notifications_enabled;
CREATE INDEX clan_raid_notification_interest ON public.user_bookmarks(tag,raid_active_until) WHERE raid_notifications_enabled;

-- Tracking interest is shared. A recipient's own lease is NOT a delivery gate.
CREATE VIEW public.clan_notification_tracking AS
SELECT tag, bool_or(war) AS war_tracked, bool_or(raid) AS raid_tracked FROM (
 SELECT tag, war_notifications_enabled AND war_active_until > now() AS war,
   raid_notifications_enabled AND raid_active_until > now() AS raid
 FROM public.user_bookmarks WHERE entity_type='clan'
 UNION ALL
 SELECT log.clan_tag,
   log.type IN ('war_log','war_panel','cwl_lineup_change_log'),
   log.type IN ('capital_donations','capital_attacks','raid_panel','capital_weekly_summary')
 FROM public.server_logs log JOIN public.servers server ON server.id=log.server_id
 WHERE NOT log.disabled AND server.last_command_at >= now()-interval '90 days' AND log.clan_tag <> ''
 UNION ALL
 SELECT reminder.clan_tag, reminder.type_name='War', reminder.type_name='Clan Capital'
 FROM public.reminders reminder JOIN public.servers server ON server.id=reminder.server_id
 WHERE NOT reminder.disabled AND server.last_command_at >= now()-interval '90 days' AND reminder.clan_tag <> ''
) interests GROUP BY tag HAVING bool_or(war) OR bool_or(raid);

-- One qualifying-activity timestamp, shared by tracking modes. NULL means that
-- no qualifying activity has been observed; writers coalesce updates to 15m.
ALTER TABLE public.basic_player ADD COLUMN last_active timestamptz;
ALTER TABLE public.autoboards ADD COLUMN row_limit integer NOT NULL DEFAULT 10
    CHECK (row_limit BETWEEN 1 AND 50);

-- Retire inactivity reminders in the same unpublished release extension.
-- Export matching configurations before applying when they must be recoverable.
-- Shared player activity and online history remain untouched; other IDs are stable.
DELETE FROM public.reminders
WHERE type = 4
   OR lower(type_name) = 'inactivity';
ALTER TABLE public.reminders
    ADD CONSTRAINT reminders_no_inactivity_check
    CHECK (type <> 4 AND lower(COALESCE(type_name, '')) <> 'inactivity');

-- Removing a personal base also removes that user's download entry. Retained
-- entries keep their first-download timestamp; re-downloading after removal
-- creates a new entry. The API authorizes whose key may be removed.
-- +goose StatementBegin
CREATE OR REPLACE FUNCTION public.preserve_base_first_downloads()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM jsonb_each(OLD.downloads) prior
        WHERE NEW.downloads ? prior.key
          AND NEW.downloads -> prior.key IS DISTINCT FROM prior.value
    ) THEN
        RAISE EXCEPTION 'retained base download timestamps are immutable'
            USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END
$$;
-- +goose StatementEnd

-- +goose Down
-- +goose StatementBegin
DO $$ BEGIN RAISE EXCEPTION '022_release_extension is irreversible: restore a verified backup or apply a data-preserving forward migration'; END $$;
-- +goose StatementEnd
