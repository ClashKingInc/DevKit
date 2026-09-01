# Timescale Schema SQL Guide

This repo uses goose SQL migrations for TimescaleDB, which is PostgreSQL with the
Timescale extension enabled.

`001_initial_stats.sql` owns tracking and game-stat data, including hypertables,
retention/compression policies, and analytical views. `002_initial_settings.sql`
owns application and server configuration, authentication, mobile, roster,
billing, moderation, and other user-facing state. Later numbered files upgrade
existing installations without rewriting either initial migration.

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

## Tracking Observability

`tracking_process_stats` and `tracking_domain_stats` are the generic tracking
observability hypertables. `script` identifies the tracking process, while `name`
stores a dynamic domain identifier such as `war-discovery.active`, `cwl.groups`,
or `globalclans.priority`; neither identifier is constrained to a fixed script or
domain list.

The domain rows store request, error, latency, write, queue-depth,
processing-duration, readiness, and latest-error observations. Process rows store
runtime and memory observations. `target_count`, `target_cycle`, and
`target_processed` are nullable because event-driven and scheduled domains do not
have target progress to report.

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
league, and town hall without touching player activity. Battle-log membership is derived from
Legend League and explicit tracked-player targets rather than a mutable profile-table TTL.

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

`achievement_player_awards` records each earned achievement by achievement ID,
linked player tag, and occurrence key. Lifetime awards use the default
`lifetime` occurrence, repeatable awards provide their own stable occurrence,
and every award cascades away when its player link is removed.

## Developer Link Access

`developer_applications` stores one SHA-256 API token hash and safe display prefix per
application. Revoking the application invalidates its token and grants as one unit; there is
no separate token lifecycle or generic permission/scope table. Migration 005 removes the
legacy admin creator reference and retires the `admin_users` and `admin_sessions` tables.
The cleanup is irreversible because deleted admin and session data cannot be reconstructed.

Each current `developer_link_grants` row represents `links.read` access for one application
and authenticated user. `selected` grants snapshot verified player tags in
`developer_link_grant_accounts`, while `all_current_and_future` grants are evaluated dynamically
against the user's verified `player_links`. Readers must recheck link ownership and verification
instead of treating a grant-account row as durable authorization.

## Roster Architecture

`roster_groups` organizes roster cards and is independent of the removed signup
category model. A roster has at most four configurable `signup_questions`; the
selected account is implicit in its `roster_members` row, whose
`signup_answers` object is keyed by stable question IDs.

Roster member rows retain the canonical player, clan, town hall, trophy, and
Discord identity snapshot alongside the home-hero level sum, official league
identity, latest max percentage, last-online time, and refresh timestamp.
`roster_views` stores the authoritative versioned sandbox source program and
compact share ID. Runtime roster selection and generated display/query output
are deliberately not persisted. Rosters carry stable display-column IDs and a
small JSON sort configuration, public share state, shared refresh timestamps,
and the optional Discord role ID required by the server-scoped API.

Dynamic roster metrics are calculated directly from their authoritative tables;
there is no persisted metric cache. `roster_ai_usage` records provider
token/cost accounting, including explicit cache reads and writes, without
prompts or responses. AI membership proposals stay in the browser session
and carry expected roster revisions. The API locks and revalidates those
revisions before applying an approved add/remove/move set atomically; there is
no durable draft or approval-token record.

Each roster may reference one Discord post directly through `webhook_id` and
`message_id`. No webhook token, view association, delivery mode, render queue,
or binding revision is stored in the database.

`cwl_bonus_recipients` stores only the selected clan, season, player tag, and
awarded medal count. League metadata, standings, and eligible players come from
the stored CWL group and static data when Dashboard renders the workflow.

`cwl_league_history` is temporary-consumption staging for the historical CWL
league repair. Each clan row contains only a JSONB map from season to numeric
league ID; the API deletes the row after it fills that clan's missing
`cwl_groups.cwl_league_id` values.

## Mobile Push State

Mobile push state is current-state SQL data, not a hypertable. `mobile_push_devices`
stores one FCM token and its notification preferences per
`(user_id, device_id, provider, environment)`, with a unique token hash for idempotent
registration. Store the encrypted token in `token_ciphertext`, use `token_hash` only for
lookup/dedupe, and use `enabled` as the sole device-wide master notification switch. The
same row stores the category booleans and up to three reminder timings expressed as integer
minutes from 1 through 2,820.

`mobile_notification_accounts` stores the user-wide enabled verified player accounts; each
row is authoritatively sourced from a verified player link. Player bookmarks do not create
notification accounts. Clan notifications derive from verified players' current clans rather
than a separate clan toggle.
Delivery requires an enabled device with an authorized or provisional OS authorization
status and the relevant category enabled on that device.

`admin_posts.presentation_type` distinguishes block-based articles from hosted interactive
stories. `show_on_home` controls carousel inclusion, while `pinned_on_home` keeps a post
ahead of newer home posts without hiding those newer posts.
