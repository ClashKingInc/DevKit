-- +goose Up
-- Compact rerunnable CWL population statistics. Source tables remain canonical.

-- +goose StatementBegin
CREATE FUNCTION public.cwl_town_halls_valid(value jsonb)
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

CREATE TABLE public.cwl_season_statistics (
    season text NOT NULL,
    cwl_league_id integer NOT NULL,
    war_size smallint NOT NULL,
    group_count bigint NOT NULL,
    clan_count bigint NOT NULL,
    registered_player_count bigint NOT NULL,
    town_halls jsonb NOT NULL DEFAULT '[]'::jsonb,
    refreshed_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (season, cwl_league_id, war_size),
    CONSTRAINT cwl_season_statistics_season_check CHECK (season ~ '^[0-9]{4}-(0[1-9]|1[0-2])$'),
    CONSTRAINT cwl_season_statistics_league_check CHECK (cwl_league_id > 0),
    CONSTRAINT cwl_season_statistics_war_size_check CHECK (war_size BETWEEN 1 AND 50),
    CONSTRAINT cwl_season_statistics_counts_check CHECK (
        group_count >= 0 AND clan_count >= 0 AND registered_player_count >= 0
    ),
    CONSTRAINT cwl_season_statistics_town_halls_check CHECK (public.cwl_town_halls_valid(town_halls))
);

-- +goose StatementBegin
CREATE PROCEDURE public.reconcile_cwl_season_statistics(requested_seasons text[] DEFAULT NULL)
LANGUAGE plpgsql AS $$
DECLARE
    selected_season text;
BEGIN
    IF requested_seasons IS NOT NULL AND EXISTS (
        SELECT 1 FROM unnest(requested_seasons) AS requested(season)
        WHERE season IS NULL OR season !~ '^[0-9]{4}-(0[1-9]|1[0-2])$'
    ) THEN
        RAISE EXCEPTION 'requested CWL seasons must use YYYY-MM' USING ERRCODE = 'check_violation';
    END IF;
    PERFORM pg_advisory_xact_lock(4850467623902124044);
    FOR selected_season IN
        SELECT season FROM (
            SELECT DISTINCT groups.season FROM public.cwl_groups AS groups
            WHERE groups.season ~ '^[0-9]{4}-(0[1-9]|1[0-2])$'
              AND (requested_seasons IS NULL OR groups.season = ANY(requested_seasons))
            UNION
            SELECT DISTINCT stats.season FROM public.cwl_season_statistics AS stats
            WHERE requested_seasons IS NULL OR stats.season = ANY(requested_seasons)
            UNION
            SELECT unnest(COALESCE(requested_seasons, '{}'::text[]))
        ) AS seasons ORDER BY season
    LOOP
        DELETE FROM public.cwl_season_statistics WHERE season = selected_season;
        INSERT INTO public.cwl_season_statistics(
            season,cwl_league_id,war_size,group_count,clan_count,
            registered_player_count,town_halls,refreshed_at
        )
        WITH eligible_groups AS (
            SELECT groups.cwl_id,groups.season,groups.cwl_league_id,groups.war_size
            FROM public.cwl_groups AS groups
            WHERE groups.season = selected_season
              AND groups.season ~ '^[0-9]{4}-(0[1-9]|1[0-2])$'
              AND groups.cwl_league_id > 0 AND groups.war_size BETWEEN 1 AND 50
        ), group_totals AS (
            SELECT season,cwl_league_id,war_size,count(*)::bigint AS group_count
            FROM eligible_groups GROUP BY season,cwl_league_id,war_size
        ), distinct_clans AS (
            SELECT DISTINCT groups.season,groups.cwl_league_id,groups.war_size,clans.cwl_id,clans.clan_tag
            FROM eligible_groups AS groups
            JOIN public.cwl_group_clans AS clans ON clans.cwl_id = groups.cwl_id
        ), clan_totals AS (
            SELECT season,cwl_league_id,war_size,count(*)::bigint AS clan_count
            FROM distinct_clans GROUP BY season,cwl_league_id,war_size
        ), distinct_members AS (
            SELECT DISTINCT groups.season,groups.cwl_league_id,groups.war_size,
                members.cwl_id,members.tag,members.town_hall
            FROM eligible_groups AS groups
            JOIN public.cwl_group_members AS members ON members.cwl_id = groups.cwl_id
        ), member_totals AS (
            SELECT season,cwl_league_id,war_size,count(*)::bigint AS registered_player_count
            FROM distinct_members GROUP BY season,cwl_league_id,war_size
        ), town_hall_totals AS (
            SELECT season,cwl_league_id,war_size,town_hall,count(*)::bigint AS player_count
            FROM distinct_members WHERE town_hall BETWEEN 1 AND 20
            GROUP BY season,cwl_league_id,war_size,town_hall
        ), town_hall_json AS (
            SELECT season,cwl_league_id,war_size,
                jsonb_agg(jsonb_build_object('level',town_hall,'count',player_count) ORDER BY town_hall DESC) AS town_halls
            FROM town_hall_totals GROUP BY season,cwl_league_id,war_size
        )
        SELECT groups.season,groups.cwl_league_id,groups.war_size,groups.group_count,
            COALESCE(clans.clan_count,0),COALESCE(members.registered_player_count,0),
            COALESCE(town_halls.town_halls,'[]'::jsonb),clock_timestamp()
        FROM group_totals AS groups
        LEFT JOIN clan_totals AS clans USING (season,cwl_league_id,war_size)
        LEFT JOIN member_totals AS members USING (season,cwl_league_id,war_size)
        LEFT JOIN town_hall_json AS town_halls USING (season,cwl_league_id,war_size);
    END LOOP;
END
$$;
-- +goose StatementEnd

-- +goose Down
DROP PROCEDURE public.reconcile_cwl_season_statistics(text[]);
DROP TABLE public.cwl_season_statistics;
DROP FUNCTION public.cwl_town_halls_valid(jsonb);
