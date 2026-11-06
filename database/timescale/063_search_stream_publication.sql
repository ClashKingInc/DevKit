-- +goose Up
-- Publication metadata only: no row trigger, outbox, replica-identity widening,
-- or additional per-change SQL writes. Unchanged published values may still be
-- sent for UPDATE; the Go consumer compares payloads after decoding.
CREATE PUBLICATION clashking_search
FOR TABLE
    public.basic_player (tag, name, league_id, clan_tag, townhall_level),
    public.basic_clan (tag, name, clan_level, badge_token, location_id, cwl_league_id, member_count)
WITH (publish = 'insert, update, delete, truncate');
-- +goose Down
-- Stop the Go consumer first. Slots and existing Elasticsearch data are retained.
DROP PUBLICATION clashking_search;
