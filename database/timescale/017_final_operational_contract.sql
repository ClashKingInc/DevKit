-- +goose Up
-- Final shared storage contract for battle analytics, Legend leaderboards,
-- mobile notification preferences, and Discord-backed base layouts.
SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '15min';

-- Reject values that cannot be represented without silently changing them.
-- Legacy NULL durations intentionally become zero.
-- +goose StatementBegin
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM public.battles_farming
        WHERE duration_seconds < 0 OR duration_seconds > 32767
    ) OR EXISTS (
        SELECT 1 FROM public.battles_ranked
        WHERE duration_seconds < 0 OR duration_seconds > 32767
    ) THEN
        RAISE EXCEPTION 'migration 017 found a battle duration outside the smallint range';
    END IF;
END
$$;
-- +goose StatementEnd

SELECT remove_compression_policy('battles_farming', if_exists => TRUE);
SELECT remove_compression_policy('battles_ranked', if_exists => TRUE);
SELECT decompress_chunk(chunk, if_compressed => TRUE)
FROM show_chunks('public.battles_farming') chunk;
SELECT decompress_chunk(chunk, if_compressed => TRUE)
FROM show_chunks('public.battles_ranked') chunk;

UPDATE public.battles_farming SET duration_seconds = 0 WHERE duration_seconds IS NULL;
ALTER TABLE public.battles_farming
    DROP CONSTRAINT battles_farming_duration_check,
    ALTER COLUMN duration_seconds TYPE smallint USING duration_seconds::smallint,
    ALTER COLUMN duration_seconds SET DEFAULT 0,
    ALTER COLUMN duration_seconds SET NOT NULL,
    ADD CONSTRAINT battles_farming_duration_check CHECK (duration_seconds BETWEEN 0 AND 32767);

UPDATE public.battles_ranked SET duration_seconds = 0 WHERE duration_seconds IS NULL;
DROP INDEX public.idx_battles_ranked_attacks_time;
DROP INDEX public.idx_battles_ranked_player_mode_time;
DROP INDEX public.idx_battles_ranked_player_direction_time;
ALTER TABLE public.battles_ranked
    DROP CONSTRAINT battles_ranked_direction_check,
    DROP CONSTRAINT battles_ranked_mode_check,
    DROP CONSTRAINT battles_ranked_duration_check,
    DROP CONSTRAINT battles_ranked_loot_check,
    DROP CONSTRAINT battles_ranked_army_hash_length,
    DROP COLUMN army_hash,
    ALTER COLUMN direction TYPE smallint USING CASE direction WHEN 'attack' THEN 1 WHEN 'defense' THEN 2 END,
    ALTER COLUMN battle_mode TYPE smallint USING CASE battle_mode WHEN 'ranked' THEN 1 WHEN 'legend' THEN 2 END,
    ALTER COLUMN duration_seconds TYPE smallint USING duration_seconds::smallint,
    ALTER COLUMN duration_seconds SET DEFAULT 0,
    ALTER COLUMN duration_seconds SET NOT NULL,
    ADD CONSTRAINT battles_ranked_direction_check CHECK (direction IN (1,2)),
    ADD CONSTRAINT battles_ranked_mode_check CHECK (battle_mode IN (1,2)),
    ADD CONSTRAINT battles_ranked_duration_check CHECK (duration_seconds BETWEEN 0 AND 32767),
    ADD CONSTRAINT battles_ranked_loot_check CHECK (
        (direction = 1 AND looted_resources IS NOT NULL
            AND public.battle_looted_resources_valid(looted_resources))
        OR (direction = 2 AND looted_resources IS NULL)
    );
CREATE INDEX idx_battles_ranked_player_mode_time
    ON public.battles_ranked (player_tag, battle_mode, battle_time DESC);
CREATE INDEX idx_battles_ranked_player_direction_time
    ON public.battles_ranked (player_tag, direction, battle_time DESC);
CREATE INDEX idx_battles_ranked_attacks_time
    ON public.battles_ranked (battle_mode, battle_time DESC, player_town_hall, opponent_town_hall, share_code)
    WHERE direction = 1;
ALTER TABLE public.battles_ranked SET (
    timescaledb.compress,
    timescaledb.compress_orderby = 'battle_time DESC',
    timescaledb.compress_segmentby = 'player_tag,battle_mode,direction'
);
SELECT add_compression_policy('battles_farming', compress_after => INTERVAL '30 days', if_not_exists => TRUE);
SELECT add_compression_policy('battles_ranked', compress_after => INTERVAL '30 days', if_not_exists => TRUE);

-- Preserve only authoritative composition/family identity data. Daily totals
-- are derived and must be rebuilt because the old tables have no cohort key.
-- +goose StatementBegin
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM public.army_families family
        LEFT JOIN public.army_compositions composition
          ON composition.normalized_share_code=family.representative_share_code
        WHERE composition.normalized_share_code IS NULL
    ) OR EXISTS (
        SELECT 1 FROM public.army_family_members member
        LEFT JOIN public.army_compositions composition
          ON composition.normalized_share_code=member.share_code
        WHERE composition.normalized_share_code IS NULL
    ) THEN
        RAISE EXCEPTION 'migration 017 requires parsed compositions for every family representative and member';
    END IF;
END
$$;
-- +goose StatementEnd

CREATE TEMP TABLE migration_017_compositions ON COMMIT DROP AS
SELECT normalized_share_code AS share_code, main_troops, clan_castle_troops,
       spells, heroes, equipment, pet_assignments, siege_machine_id, created_at
FROM public.army_compositions;
CREATE TEMP TABLE migration_017_families ON COMMIT DROP AS
SELECT family_id, representative_share_code,
       COALESCE(name, NULLIF(regexp_replace(btrim(family_name), '[[:space:]]+', ' ', 'g'), '')) AS name,
       created_at, updated_at
FROM public.army_families;
CREATE TEMP TABLE migration_017_members ON COMMIT DROP AS
SELECT share_code, family_id, assigned_at
FROM public.army_family_members;

DROP TABLE public.legend_daily_stats_v2;
DROP TABLE public.army_family_daily_stats_v2;
DROP TABLE public.army_family_daily_stats;
DROP TABLE public.legend_daily_stats;
DROP TABLE public.army_family_members;
DROP TABLE public.army_families;
DROP TABLE public.army_compositions;
DROP FUNCTION public.prepare_compatible_army_family_member();
DROP FUNCTION public.prepare_compatible_army_family();
DROP FUNCTION public.protect_army_family_anchor();
DROP FUNCTION public.reject_army_identity_mutation();

CREATE TABLE public.army_compositions (
    share_code text PRIMARY KEY,
    main_troops jsonb NOT NULL DEFAULT '[]',
    clan_castle_troops jsonb NOT NULL DEFAULT '[]',
    spells jsonb NOT NULL DEFAULT '[]',
    heroes integer[] NOT NULL DEFAULT '{}',
    equipment jsonb NOT NULL DEFAULT '[]',
    pet_assignments jsonb NOT NULL DEFAULT '[]',
    siege_machine_id integer,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT army_compositions_share_code_check CHECK (btrim(share_code) <> ''),
    CONSTRAINT army_compositions_main_troops_check CHECK (public.army_component_rows_valid(main_troops,'troop')),
    CONSTRAINT army_compositions_clan_castle_troops_check CHECK (public.army_component_rows_valid(clan_castle_troops,'clan_castle_troop')),
    CONSTRAINT army_compositions_spells_check CHECK (public.army_component_rows_valid(spells,'spell')),
    CONSTRAINT army_compositions_heroes_check CHECK (public.army_hero_ids_valid(heroes)),
    CONSTRAINT army_compositions_equipment_check CHECK (public.army_component_rows_valid(equipment,'equipment')),
    CONSTRAINT army_compositions_pets_check CHECK (public.army_component_rows_valid(pet_assignments,'pet')),
    CONSTRAINT army_compositions_siege_check CHECK (siege_machine_id IS NULL OR siege_machine_id >= 0)
);
INSERT INTO public.army_compositions
SELECT * FROM migration_017_compositions;

CREATE TABLE public.army_families (
    family_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    representative_share_code text NOT NULL UNIQUE REFERENCES public.army_compositions(share_code),
    name text,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT army_families_name_check CHECK (
        name IS NULL OR (name <> '' AND char_length(name) <= 120
            AND name = regexp_replace(btrim(name), '[[:space:]]+', ' ', 'g'))
    )
);
CREATE UNIQUE INDEX army_families_name_unique ON public.army_families (lower(name)) WHERE name IS NOT NULL;
INSERT INTO public.army_families(family_id,representative_share_code,name,created_at,updated_at)
    OVERRIDING SYSTEM VALUE
SELECT family_id,representative_share_code,name,created_at,updated_at
FROM migration_017_families;
SELECT setval(
    pg_get_serial_sequence('public.army_families','family_id'),
    COALESCE((SELECT max(family_id) FROM public.army_families),1),
    EXISTS (SELECT 1 FROM public.army_families)
);

CREATE TABLE public.army_family_members (
    share_code text PRIMARY KEY REFERENCES public.army_compositions(share_code) ON DELETE CASCADE,
    family_id bigint NOT NULL REFERENCES public.army_families(family_id) ON DELETE CASCADE,
    assigned_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX army_family_members_family_code_idx
    ON public.army_family_members (family_id, share_code);
INSERT INTO public.army_family_members
SELECT * FROM migration_017_members;

CREATE TABLE public.army_family_daily_stats (
    day date NOT NULL,
    cohort text NOT NULL,
    family_id bigint NOT NULL REFERENCES public.army_families(family_id) ON DELETE CASCADE,
    attack_count bigint NOT NULL,
    distinct_player_count bigint NOT NULL,
    zero_star_count bigint NOT NULL,
    one_star_count bigint NOT NULL,
    two_star_count bigint NOT NULL,
    three_star_count bigint NOT NULL,
    destruction_percentage_sum bigint NOT NULL,
    duration_seconds_sum bigint NOT NULL,
    PRIMARY KEY (day, cohort, family_id),
    CONSTRAINT army_family_daily_stats_cohort_check CHECK (cohort IN ('legend_i','top_1000','top_200')),
    CONSTRAINT army_family_daily_stats_counts_check CHECK (
        attack_count >= 0 AND distinct_player_count BETWEEN 0 AND attack_count
        AND zero_star_count >= 0 AND one_star_count >= 0
        AND two_star_count >= 0 AND three_star_count >= 0
        AND attack_count = zero_star_count + one_star_count + two_star_count + three_star_count
    ),
    CONSTRAINT army_family_daily_stats_sums_check CHECK (
        destruction_percentage_sum BETWEEN 0 AND attack_count * 100
        AND duration_seconds_sum BETWEEN 0 AND attack_count * 32767
    )
);
CREATE INDEX army_family_daily_stats_family_day_idx
    ON public.army_family_daily_stats (family_id, day DESC, cohort);

CREATE TABLE public.legend_daily_stats (
    day date NOT NULL,
    cohort text NOT NULL,
    attack_count bigint NOT NULL,
    distinct_player_count bigint NOT NULL,
    zero_star_count bigint NOT NULL,
    one_star_count bigint NOT NULL,
    two_star_count bigint NOT NULL,
    three_star_count bigint NOT NULL,
    destruction_percentage_sum bigint NOT NULL,
    duration_seconds_sum bigint NOT NULL,
    hero_stats jsonb NOT NULL DEFAULT '[]',
    pet_stats jsonb NOT NULL DEFAULT '[]',
    equipment_stats jsonb NOT NULL DEFAULT '[]',
    pet_hero_assignments jsonb NOT NULL DEFAULT '[]',
    PRIMARY KEY (day, cohort),
    CONSTRAINT legend_daily_stats_cohort_check CHECK (cohort IN ('legend_i','top_1000','top_200')),
    CONSTRAINT legend_daily_stats_counts_check CHECK (
        attack_count >= 0 AND distinct_player_count BETWEEN 0 AND attack_count
        AND zero_star_count >= 0 AND one_star_count >= 0
        AND two_star_count >= 0 AND three_star_count >= 0
        AND attack_count = zero_star_count + one_star_count + two_star_count + three_star_count
    ),
    CONSTRAINT legend_daily_stats_sums_check CHECK (
        destruction_percentage_sum BETWEEN 0 AND attack_count * 100
        AND duration_seconds_sum BETWEEN 0 AND attack_count * 32767
    ),
    CONSTRAINT legend_daily_stats_heroes_check CHECK (public.item_usage_triples_within_attack_count(hero_stats,attack_count)),
    CONSTRAINT legend_daily_stats_pets_check CHECK (public.item_usage_triples_within_attack_count(pet_stats,attack_count)),
    CONSTRAINT legend_daily_stats_equipment_check CHECK (public.item_usage_triples_within_attack_count(equipment_stats,attack_count)),
    CONSTRAINT legend_daily_stats_pet_hero_check CHECK (public.pet_hero_usage_triples_within_attack_count(pet_hero_assignments,attack_count))
);

COMMENT ON COLUMN public.battles_ranked.battle_mode IS '1=ranked, 2=legend.';
COMMENT ON COLUMN public.battles_ranked.direction IS '1=attack, 2=defense. Aggregate writers count direction 1 only.';
COMMENT ON TABLE public.army_family_daily_stats IS 'Attack-only totals for half-open 05:10 UTC days, grouped by cohort and family.';
COMMENT ON TABLE public.legend_daily_stats IS 'Attack-only totals and item usage for half-open 05:10 UTC days, grouped by cohort.';

-- Tracking replaces this compact materialization only after a complete player
-- refresh. Preserve the relation in place because api_global_counts depends on
-- its object identity.
TRUNCATE TABLE public.legend_rankings_current;
DROP INDEX public.idx_legend_rankings_current_rank;
ALTER TABLE public.legend_rankings_current
    RENAME COLUMN player_tag TO tag;
ALTER TABLE public.legend_rankings_current
    RENAME COLUMN player_name TO name;
ALTER TABLE public.legend_rankings_current
    RENAME COLUMN rank TO global_rank;
ALTER TABLE public.legend_rankings_current
    DROP COLUMN data,
    DROP COLUMN updated_at,
    ALTER COLUMN name DROP DEFAULT,
    ALTER COLUMN clan_name DROP DEFAULT,
    ALTER COLUMN clan_name DROP NOT NULL,
    ADD CONSTRAINT legend_rankings_current_tag_check CHECK (tag ~ '^#[0289PYLQGRJCUV]{1,15}$'),
    ADD CONSTRAINT legend_rankings_current_name_check CHECK (btrim(name) <> ''),
    ADD CONSTRAINT legend_rankings_current_rank_check CHECK (global_rank > 0),
    ADD CONSTRAINT legend_rankings_current_trophies_check CHECK (trophies >= 0),
    ADD CONSTRAINT legend_rankings_current_clan_check CHECK (
        (clan_tag IS NULL AND clan_name IS NULL)
        OR (clan_tag IS NOT NULL AND clan_name IS NOT NULL
            AND btrim(clan_tag) <> '' AND btrim(clan_name) <> '')
    ),
    ADD UNIQUE (global_rank);
CREATE INDEX idx_legend_rankings_current_trophies
    ON public.legend_rankings_current (trophies DESC, tag);
INSERT INTO public.legend_rankings_current(tag,name,trophies,global_rank,clan_tag,clan_name)
SELECT player.tag,player.name,player.trophies,
       row_number() OVER (ORDER BY player.trophies DESC,player.tag)::integer,
       clan.tag,clan.name
FROM public.basic_player player
LEFT JOIN public.basic_clan clan ON clan.tag=player.clan_tag
WHERE player.league_id=105000036;

CREATE TEMP TABLE migration_017_player_history ON COMMIT DROP AS
SELECT date AS day,player_tag AS tag,rank AS global_rank,trophies
FROM public.leaderboard_history_player_home
WHERE location_id='global';
DROP TABLE public.leaderboard_history_player_home;
CREATE TABLE public.leaderboard_history_player_home (
    day date NOT NULL,
    tag text NOT NULL,
    global_rank integer NOT NULL,
    trophies integer NOT NULL,
    PRIMARY KEY (day, tag),
    UNIQUE (day, global_rank),
    CONSTRAINT leaderboard_history_player_home_tag_check CHECK (tag ~ '^#[0289PYLQGRJCUV]{1,15}$'),
    CONSTRAINT leaderboard_history_player_home_rank_check CHECK (global_rank > 0),
    CONSTRAINT leaderboard_history_player_home_trophies_check CHECK (trophies >= 0)
);
CREATE INDEX idx_leaderboard_history_player_home_player
    ON public.leaderboard_history_player_home (tag,day DESC);
INSERT INTO public.leaderboard_history_player_home
SELECT * FROM migration_017_player_history;

-- Notification account selection is valid only while the same user owns a
-- currently verified link. Ownership changes delete the selection first.
DROP TABLE public.mobile_notification_deliveries;
CREATE TABLE public.mobile_notification_preferences (
    user_id text PRIMARY KEY REFERENCES public.auth_users(user_id) ON DELETE CASCADE,
    war_attacks_enabled boolean NOT NULL DEFAULT false,
    war_state_enabled boolean NOT NULL DEFAULT false,
    war_reminders_enabled boolean NOT NULL DEFAULT false,
    raid_reminders_enabled boolean NOT NULL DEFAULT false,
    events_enabled boolean NOT NULL DEFAULT false,
    announcements_enabled boolean NOT NULL DEFAULT false,
    monthly_support_enabled boolean NOT NULL DEFAULT false,
    legend_defenses_enabled boolean NOT NULL DEFAULT false,
    reminder_timings integer[] NOT NULL DEFAULT '{}',
    raid_reminder_timings integer[] NOT NULL DEFAULT '{}',
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT mobile_notification_preferences_war_timings_check CHECK (
        cardinality(reminder_timings) <= 3
        AND array_position(reminder_timings,NULL) IS NULL
        AND 0 < ALL(reminder_timings) AND 2820 >= ALL(reminder_timings)
    ),
    CONSTRAINT mobile_notification_preferences_raid_timings_check CHECK (
        cardinality(raid_reminder_timings) <= 3
        AND array_position(raid_reminder_timings,NULL) IS NULL
        AND 0 < ALL(raid_reminder_timings) AND 4320 >= ALL(raid_reminder_timings)
    )
);
INSERT INTO public.mobile_notification_preferences(
    user_id,war_attacks_enabled,war_state_enabled,war_reminders_enabled,
    raid_reminders_enabled,events_enabled,announcements_enabled,monthly_support_enabled,
    reminder_timings,raid_reminder_timings,updated_at
)
SELECT users.user_id,
       bool_or(device.war_attacks_enabled), bool_or(device.war_state_enabled),
       bool_or(device.war_reminders_enabled), bool_or(device.raid_reminders_enabled),
       bool_or(device.events_enabled), bool_or(device.announcements_enabled),
       bool_or(device.monthly_support_enabled),
       (SELECT recent.reminder_timings FROM public.mobile_push_devices recent
        WHERE recent.user_id=users.user_id ORDER BY recent.last_seen_at DESC, recent.device_id LIMIT 1),
       (SELECT recent.raid_reminder_timings FROM public.mobile_push_devices recent
        WHERE recent.user_id=users.user_id ORDER BY recent.last_seen_at DESC, recent.device_id LIMIT 1),
       now()
FROM (
    SELECT DISTINCT device.user_id
    FROM public.mobile_push_devices device
    JOIN public.auth_users auth ON auth.user_id=device.user_id
) users
JOIN public.mobile_push_devices device ON device.user_id=users.user_id
GROUP BY users.user_id;

DROP INDEX public.idx_mobile_push_devices_announcements;
ALTER TABLE public.mobile_push_devices
    DROP CONSTRAINT mobile_push_devices_reminder_timings_check,
    DROP CONSTRAINT mobile_push_devices_raid_reminder_timings_check,
    DROP COLUMN war_attacks_enabled,
    DROP COLUMN war_state_enabled,
    DROP COLUMN war_reminders_enabled,
    DROP COLUMN raid_reminders_enabled,
    DROP COLUMN events_enabled,
    DROP COLUMN announcements_enabled,
    DROP COLUMN monthly_support_enabled,
    DROP COLUMN reminder_timings,
    DROP COLUMN raid_reminder_timings;

DROP INDEX public.idx_mobile_notification_accounts_delivery;
DROP INDEX public.idx_mobile_notification_accounts_player;
CREATE TEMP TABLE migration_017_notification_accounts ON COMMIT DROP AS
SELECT account.user_id, account.player_tag, account.active AS enabled,
       account.created_at, account.updated_at
FROM public.mobile_notification_accounts account
JOIN public.player_links link
  ON link.tag=account.player_tag AND link.user_id=account.user_id AND link.is_verified
JOIN public.auth_users auth ON auth.user_id=account.user_id;
DROP TABLE public.mobile_notification_accounts;
ALTER TABLE public.player_links ADD CONSTRAINT player_links_tag_user_key UNIQUE (tag,user_id);
CREATE TABLE public.mobile_notification_accounts (
    user_id text NOT NULL REFERENCES public.auth_users(user_id) ON DELETE CASCADE,
    player_tag text NOT NULL,
    enabled boolean NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id,player_tag),
    FOREIGN KEY (player_tag,user_id) REFERENCES public.player_links(tag,user_id) ON DELETE CASCADE
);
INSERT INTO public.mobile_notification_accounts SELECT * FROM migration_017_notification_accounts;
CREATE INDEX idx_mobile_notification_accounts_delivery
    ON public.mobile_notification_accounts (player_tag,user_id) WHERE enabled;

-- +goose StatementBegin
CREATE FUNCTION public.require_verified_notification_account()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM public.player_links
        WHERE tag=NEW.player_tag AND user_id=NEW.user_id AND is_verified
    ) THEN
        RAISE EXCEPTION 'notification account requires a currently verified owned link'
            USING ERRCODE='23514';
    END IF;
    NEW.updated_at := clock_timestamp();
    RETURN NEW;
END
$$;
-- +goose StatementEnd
CREATE TRIGGER mobile_notification_accounts_verified
    BEFORE INSERT OR UPDATE ON public.mobile_notification_accounts
    FOR EACH ROW EXECUTE FUNCTION public.require_verified_notification_account();

-- +goose StatementBegin
CREATE FUNCTION public.reset_notification_account_on_link_change()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.user_id IS DISTINCT FROM OLD.user_id OR NEW.is_verified IS DISTINCT FROM OLD.is_verified THEN
        DELETE FROM public.mobile_notification_accounts
        WHERE player_tag=OLD.tag AND user_id=OLD.user_id;
    END IF;
    RETURN NEW;
END
$$;
-- +goose StatementEnd
CREATE TRIGGER player_links_reset_notification_account
    BEFORE UPDATE OF user_id,is_verified ON public.player_links
    FOR EACH ROW EXECUTE FUNCTION public.reset_notification_account_on_link_change();

-- Only valid layout links are imported. Arrays are normalized into private
-- per-user relation tables; API responses expose counts, not voter identities.
-- +goose StatementBegin
CREATE FUNCTION public.base_layout_link_valid(value text)
RETURNS boolean LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE AS $$
DECLARE
    action_count integer;
    action_valid boolean;
    id_count integer;
BEGIN
    IF value !~ '^https://link[.]clashofclans[.]com/[^?#]*[?][^#]+$' THEN
        RETURN false;
    END IF;
    SELECT count(*), COALESCE(bool_and(captures[1]='OpenLayout'),false)
      INTO action_count,action_valid
    FROM regexp_matches(value,'[?&]action=([^&#]*)','g') AS matches(captures);
    SELECT count(*) INTO id_count
    FROM regexp_matches(value,'[?&]id=([^&#]+)','g');
    RETURN action_count=1 AND action_valid AND id_count=1;
END
$$;
-- +goose StatementEnd

CREATE TEMP TABLE migration_017_bases ON COMMIT DROP AS
SELECT row_number() OVER (ORDER BY created_at,id)::bigint AS id,
       message_id,base_link,created_at,server_id,channel_id,description,
       images,downloaders,upvoter_ids,downvoter_ids
FROM public.bases
WHERE public.base_layout_link_valid(base_link)
  AND message_id ~ '^[0-9]+$'
  AND (server_id IS NULL OR server_id ~ '^[0-9]+$')
  AND (channel_id IS NULL OR channel_id ~ '^[0-9]+$');
DROP TABLE public.bases;
CREATE TABLE public.bases (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    base_link text NOT NULL,
    message_id text NOT NULL,
    server_id text,
    channel_id text,
    description text NOT NULL DEFAULT '',
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT bases_link_check CHECK (public.base_layout_link_valid(base_link)),
    CONSTRAINT bases_message_id_check CHECK (message_id ~ '^[0-9]+$'),
    CONSTRAINT bases_server_id_check CHECK (server_id IS NULL OR server_id ~ '^[0-9]+$'),
    CONSTRAINT bases_channel_id_check CHECK (channel_id IS NULL OR channel_id ~ '^[0-9]+$'),
    CONSTRAINT bases_message_location_check CHECK ((server_id IS NULL) = (channel_id IS NULL)),
    CONSTRAINT bases_description_length_check CHECK (char_length(description) <= 1000),
    UNIQUE (message_id)
);
INSERT INTO public.bases(id,base_link,message_id,server_id,channel_id,description,created_at)
    OVERRIDING SYSTEM VALUE
SELECT id,base_link,message_id,server_id,channel_id,description,created_at
FROM migration_017_bases;
SELECT setval(
    pg_get_serial_sequence('public.bases','id'),
    COALESCE((SELECT max(id) FROM public.bases),1),
    EXISTS (SELECT 1 FROM public.bases)
);

CREATE TABLE public.base_images (
    base_id bigint NOT NULL REFERENCES public.bases(id) ON DELETE CASCADE,
    position smallint NOT NULL,
    image_url text NOT NULL,
    PRIMARY KEY (base_id,position),
    UNIQUE (base_id,image_url),
    CONSTRAINT base_images_position_check CHECK (position BETWEEN 1 AND 4),
    CONSTRAINT base_images_owned_url_check CHECK (
        image_url ~ '^https://api[.]clashk[.]ing/v2/media/[A-Za-z0-9][A-Za-z0-9._-]*$'
    )
);
INSERT INTO public.base_images(base_id,position,image_url)
SELECT base.id, image.ordinality::smallint, image.url
FROM migration_017_bases base
CROSS JOIN LATERAL unnest(base.images) WITH ORDINALITY image(url,ordinality)
WHERE image.ordinality <= 4
  AND image.url ~ '^https://api[.]clashk[.]ing/v2/media/[A-Za-z0-9][A-Za-z0-9._-]*$'
ON CONFLICT DO NOTHING;

CREATE TABLE public.base_downloaders (
    base_id bigint NOT NULL REFERENCES public.bases(id) ON DELETE CASCADE,
    user_id text NOT NULL,
    downloaded_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (base_id,user_id),
    CONSTRAINT base_downloaders_user_check CHECK (user_id ~ '^[0-9]+$')
);
INSERT INTO public.base_downloaders(base_id,user_id)
SELECT base.id,user_id
FROM migration_017_bases base CROSS JOIN LATERAL unnest(base.downloaders) user_id
WHERE user_id ~ '^[0-9]+$'
ON CONFLICT DO NOTHING;

CREATE TABLE public.base_votes (
    base_id bigint NOT NULL REFERENCES public.bases(id) ON DELETE CASCADE,
    user_id text NOT NULL,
    vote smallint NOT NULL,
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (base_id,user_id),
    CONSTRAINT base_votes_user_check CHECK (user_id ~ '^[0-9]+$'),
    CONSTRAINT base_votes_value_check CHECK (vote IN (-1,1))
);
INSERT INTO public.base_votes(base_id,user_id,vote)
SELECT base.id,user_id,1
FROM migration_017_bases base CROSS JOIN LATERAL unnest(base.upvoter_ids) user_id
WHERE user_id ~ '^[0-9]+$'
UNION ALL
SELECT base.id,user_id,-1
FROM migration_017_bases base CROSS JOIN LATERAL unnest(base.downvoter_ids) user_id
WHERE user_id ~ '^[0-9]+$';

CREATE VIEW public.base_public_counts AS
SELECT base.id AS base_id,
       (SELECT count(*) FROM public.base_downloaders downloader WHERE downloader.base_id=base.id) AS download_count,
       (SELECT count(*) FROM public.base_votes vote WHERE vote.base_id=base.id AND vote.vote=1) AS upvote_count,
       (SELECT count(*) FROM public.base_votes vote WHERE vote.base_id=base.id AND vote.vote=-1) AS downvote_count
FROM public.bases base;

COMMENT ON TABLE public.base_votes IS 'Private per-user vote state. Public readers use base_public_counts.';
COMMENT ON TABLE public.mobile_notification_accounts IS 'User-level enablement scoped to currently verified owned player links.';
COMMENT ON TABLE public.mobile_notification_preferences IS 'User-level categories and reminder timings shared by every enabled device.';

-- +goose Down
-- The migration deliberately removes legacy identities and derived totals. A
-- downgrade cannot reconstruct those values, so fail transactionally.
-- +goose StatementBegin
DO $$
BEGIN
    RAISE EXCEPTION 'migration 017 is irreversible: final identities and user-level settings cannot be losslessly downgraded';
END
$$;
-- +goose StatementEnd
