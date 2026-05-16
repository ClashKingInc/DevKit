-- +goose Up
CREATE TABLE player_online_events (
    seen_at DateTime64(3, 'UTC') DEFAULT now64(3),
    tag String,
    clan_tag String,
    townhall_level UInt8
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(seen_at)
ORDER BY (clan_tag, seen_at DESC);

CREATE TABLE player_online_events_by_player (
    seen_at DateTime64(3, 'UTC'),
    tag String,
    clan_tag String,
    townhall_level UInt8
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(seen_at)
ORDER BY (tag, seen_at DESC);

CREATE MATERIALIZED VIEW player_online_events_by_player_mv
TO player_online_events_by_player
AS
SELECT
    seen_at,
    tag,
    clan_tag,
    townhall_level
FROM player_online_events;



CREATE TABLE join_leave_history (
    event_time DateTime('UTC') DEFAULT now(),
    event_type Enum8('join' = 1, 'leave' = 2),
    clan_tag String,
    player_tag String,
    player_name String,
    townhall_level UInt8
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(event_time)
ORDER BY (clan_tag, event_time DESC);

CREATE TABLE join_leave_history_by_player (
    event_time DateTime('UTC'),
    event_type Enum8('join' = 1, 'leave' = 2),
    clan_tag String,
    player_tag String,
    player_name String,
    townhall_level UInt8
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(event_time)
ORDER BY (player_tag, event_time DESC);

CREATE MATERIALIZED VIEW join_leave_history_by_player_mv
TO join_leave_history_by_player
AS
SELECT
    event_time,
    event_type,
    clan_tag,
    player_tag,
    player_name,
    townhall_level
FROM join_leave_history;

-- +goose Down
