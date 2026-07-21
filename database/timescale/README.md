# Timescale Schema SQL Guide

This repo uses goose SQL migrations for TimescaleDB, which is PostgreSQL with the
Timescale extension enabled.

## Migration Format

```sql
-- +goose Up
CREATE EXTENSION IF NOT EXISTS timescaledb;

CREATE TABLE example_events (
    happened_at timestamptz NOT NULL DEFAULT now(),
    tag text NOT NULL
);

SELECT create_hypertable(
    'example_events',
    'happened_at',
    if_not_exists => TRUE
);

-- +goose Down
```

## When To Use Hypertables

Use hypertables for large time-series/event tables:

- player online events
- join/leave history
- battlelogs
- append-heavy analytics history

Use normal PostgreSQL tables for smaller current-state tables and compact rollups.

## Battlelog Analytics

`battlelogs` is the raw source of truth. It stores the display data plus army search data:

```sql
army_items text[] NOT NULL
army_counts jsonb NOT NULL
```

Use `army_items` for fast contains searches:

```sql
army_items @> ARRAY['h_1', 'e_10', 'u_5']
```

Use `army_counts` only when quantity matters:

```sql
COALESCE((army_counts->>'u_5')::int, 0) >= 5
```

Army and townhall stats are Timescale continuous aggregates. Item usage and item hitrate
are app-written rollups to avoid inserting one raw item row per battle item.

## Index Notes

Hypertable unique indexes must include the time column. For `battlelogs`, the primary key is:

```sql
PRIMARY KEY (battle_id, timestamp)
```

Use GIN indexes for array/jsonb search:

```sql
CREATE INDEX idx_battlelogs_army_items
    ON battlelogs
    USING gin (army_items);
```

Keep dynamic army-builder searches bounded by time, townhall, and battle type.

## Global Clan Changes

`basic_clan` is the current-state row for global clan tracking. It intentionally stores only
the member tag set needed for membership comparison; member donation deltas are not a
durable global structure.

Optional Clash IDs on `basic_clan`, such as location, CWL league, and capital league, are
nullable. Missing API values should be stored as `NULL`, not as a sentinel `0`.

`basic_player` is the shared player profile table. Profile ingesters can upsert tag, name,
league, and town hall without touching player activity. `battlelogs_tracking_ttl` is nullable and is
reserved for scripts that observe actual activity signals such as war attacks.

`join_leave_history` stores append-only membership events. It stores player tags, optional
player names, and town hall values. It does not store role snapshots or extra JSONB data.
New chunks are created at a 3-month interval to keep full-history player/clan lookups from
fanning out across many small chunks.

`clan_change_history` stores profile/league changes as append-only JSONB values keyed by
`change_type`. The initial supported changes are description, clan level, CWL league ID,
and capital league ID.

`basic_clan.last_active` is the shared activity signal for global clan tracking. Pollers can
split active and inactive budgets from this timestamp without storing script-specific cadence
state in SQL. Other scripts can update it from war, capital, or membership activity.

## Home Player Data

`player_links.last_login` is nullable and records the most recent app launch reported for a
verified linked player. Existing links remain `NULL` until the app launch flow updates them.

`player_upgrades` stores one whole upgrade-data JSON object per globally unique player tag.
`player_upgrade_preferences` stores that player's separate preferences object. Both tables use
`player_links.tag` as their only identity, timestamp writes with the database clock, and cascade
on unlink; neither table carries a user or account identifier.

## Mobile Push State

Mobile push state is current-state SQL data, not a hypertable. `mobile_push_devices`
stores one active APNs/FCM token per user, device, provider, and environment with a unique
token hash for idempotent registration. Store the encrypted token in `token_ciphertext` and
use `token_hash` only for lookup/dedupe.

`mobile_notification_preferences` stores the device-wide master switch, enabled notification
types, and account filters. `mobile_notification_subscriptions` stores per-type/player details.
Announcement delivery must join these preferences and require the `announcements` type
instead of broadcasting to every registered token.

`admin_posts.presentation_type` distinguishes block-based articles from hosted interactive
stories. `show_on_home` controls carousel inclusion, while `pinned_on_home` keeps a post
ahead of newer home posts without hiding those newer posts.

`mobile_war_subscriptions` stores the selected clan notification preferences per device.
Tracking workers should query enabled subscriptions by `clan_tag` when war or CWL events
arrive.

`mobile_live_activities` stores active iOS ActivityKit push tokens and their war identity.
Workers should only push rows with `status = 'active'` and should update `last_payload_hash`
after successful delivery to avoid repeated Dynamic Island score updates.
