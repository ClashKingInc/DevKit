-- +goose Up
-- Search changes are durable independently of whole-database WAL retention.
-- The generation is never reset: it fences stale Elasticsearch bulk retries.
CREATE SEQUENCE search_sync_generation START 1000000000000000000;
CREATE TABLE search_sync_pending (
    entity text NOT NULL CHECK (entity IN ('player', 'clan')),
    tag text NOT NULL,
    generation bigint NOT NULL DEFAULT nextval('search_sync_generation'),
    document jsonb,
    queued_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (entity, tag)
);
CREATE INDEX search_sync_pending_order ON search_sync_pending (entity, queued_at, tag);
CREATE TABLE search_sync_state (
    entity text PRIMARY KEY CHECK (entity IN ('player', 'clan')),
    index_name text NOT NULL UNIQUE,
    cursor_tag text NOT NULL DEFAULT '',
    snapshot_done boolean NOT NULL DEFAULT false,
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
-- +goose StatementBegin
CREATE FUNCTION search_sync_enqueue() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
DECLARE
    entity_name text := TG_ARGV[0];
    payload jsonb;
BEGIN
    -- Updates to timestamps, trophies, and other unindexed values do no queue
    -- work. Compare typed fields before building JSON, including NULL changes.
    IF TG_OP = 'UPDATE' THEN
        IF entity_name = 'player' THEN
            IF ROW(OLD.tag,OLD.name,OLD.league_id,OLD.clan_tag,OLD.townhall_level)
                IS NOT DISTINCT FROM ROW(NEW.tag,NEW.name,NEW.league_id,NEW.clan_tag,NEW.townhall_level) THEN
                RETURN NEW;
            END IF;
        ELSE
            IF ROW(OLD.tag,OLD.name,OLD.clan_level,OLD.badge_token,OLD.location_id,OLD.cwl_league_id,OLD.member_count)
                IS NOT DISTINCT FROM ROW(NEW.tag,NEW.name,NEW.clan_level,NEW.badge_token,NEW.location_id,NEW.cwl_league_id,NEW.member_count) THEN
                RETURN NEW;
            END IF;
        END IF;
    END IF;
    IF TG_OP = 'DELETE' OR (TG_OP = 'UPDATE' AND OLD.tag IS DISTINCT FROM NEW.tag) THEN
        INSERT INTO search_sync_pending(entity,tag,document) VALUES(entity_name,OLD.tag,NULL)
        ON CONFLICT(entity,tag) DO UPDATE SET document=NULL,generation=nextval('search_sync_generation');
    END IF;
    IF TG_OP <> 'DELETE' THEN
        IF entity_name = 'player' THEN
            payload := jsonb_build_object('tag',NEW.tag,'name',NEW.name,'league_id',NEW.league_id,'clan_tag',NEW.clan_tag,'townhall_level',NEW.townhall_level);
        ELSE
            payload := jsonb_build_object('tag',NEW.tag,'name',NEW.name,'clan_level',NEW.clan_level,'badge_token',NEW.badge_token,'location_id',NEW.location_id,'cwl_league_id',NEW.cwl_league_id,'member_count',NEW.member_count);
        END IF;
        -- Coalesce repeated changes, but preserve the oldest queue position.
        -- A worker acknowledges only the generation it actually indexed.
        INSERT INTO search_sync_pending(entity,tag,document) VALUES(entity_name,NEW.tag,payload)
        ON CONFLICT(entity,tag) DO UPDATE SET document=EXCLUDED.document,generation=nextval('search_sync_generation');
    END IF;
    RETURN NULL;
END;
$$;
-- +goose StatementEnd
CREATE TRIGGER search_sync_player AFTER INSERT OR UPDATE OR DELETE ON basic_player
FOR EACH ROW EXECUTE FUNCTION search_sync_enqueue('player');
CREATE TRIGGER search_sync_clan AFTER INSERT OR UPDATE OR DELETE ON basic_clan
FOR EACH ROW EXECUTE FUNCTION search_sync_enqueue('clan');
-- TRUNCATE is not a supported ingestion operation. Fail closed rather than leave
-- a live search index full of deleted records without individual tombstones.
-- +goose StatementBegin
CREATE FUNCTION search_sync_no_truncate() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'Search source TRUNCATE requires an explicit index rebuild; use DELETE for captured removals';
END;
$$;
-- +goose StatementEnd
CREATE TRIGGER search_sync_player_truncate BEFORE TRUNCATE ON basic_player
FOR EACH STATEMENT EXECUTE FUNCTION search_sync_no_truncate();
CREATE TRIGGER search_sync_clan_truncate BEFORE TRUNCATE ON basic_clan
FOR EACH STATEMENT EXECUTE FUNCTION search_sync_no_truncate();


CREATE TABLE search_sync_capture (
    singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
    started_lsn pg_lsn NOT NULL,
    started_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE TABLE search_sync_bridge (
    entity text PRIMARY KEY CHECK (entity IN ('player', 'clan')),
    slot_name text NOT NULL UNIQUE,
    through_lsn pg_lsn NOT NULL,
    completed boolean NOT NULL DEFAULT false,
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
-- DDL locks exclude old source writers until this transaction commits. Every
-- source change after this boundary is captured by the installed row triggers.
INSERT INTO search_sync_capture(singleton,started_lsn) VALUES(true,pg_current_wal_insert_lsn());

-- +goose Down
-- Stop the Go consumer before rollback. Old indexes/PGSync slots are untouched.
DROP TRIGGER search_sync_player_truncate ON basic_player;
DROP TRIGGER search_sync_clan_truncate ON basic_clan;
DROP TRIGGER search_sync_player ON basic_player;
DROP TRIGGER search_sync_clan ON basic_clan;
DROP FUNCTION search_sync_no_truncate();
DROP FUNCTION search_sync_enqueue();
DROP TABLE search_sync_bridge;
DROP TABLE search_sync_capture;
DROP TABLE search_sync_state;
DROP TABLE search_sync_pending;
DROP SEQUENCE search_sync_generation;
