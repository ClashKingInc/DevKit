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

## Battle and league analytics

Migration 008 adds one-year farming history, two-perspective Ranked/Legend history, and immutable exact army compositions. Raw Ranked/Legend rows are compressed after 30 days; aggregate queries count only `direction = 'attack'` so the defense perspective does not double results. Migration 008 also reshapes the existing `ranked_league_group_members` table to match the source counters directly.

Migration 009 adds permanent normal-PostgreSQL rollups for league hit rates, Ranked tier populations, Legend daily item usage, and immutable army-family assignments. It does not add a Ranked group parent table, item presence registry, prefix tables, or compression policies for rollups. See [the complete storage contract](../../docs/ranked-battle-history.md).

`cwl_season_statistics` remains a separate normal PostgreSQL summary refreshed from the existing CWL group, clan, and member tables. See [the reconciliation contract](../../docs/cwl-season-statistics.md). The legacy `battlelogs`, its continuous aggregate, and `legend_history` remain during the consumer cutover.

## Index Notes

Farming and Ranked/Legend uniqueness is `(player_tag,battle_time)` after migration 013. Tracking stores only the requested player's perspective; `battle_mode` remains available for filtering. Player/time and player/mode/time indexes serve history, while a partial mode/time index containing only `direction = 'attack'` serves aggregate scans.

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
developer, along with cumulative API-request and shared-link lookup counters. Both counters
are nonnegative `bigint` values that start at zero. Revocation remains part of the application
row, and there is no separate token, grant, permission, or scope lifecycle.

Migration 005 removes the legacy admin creator reference and retires the `admin_users` and
`admin_sessions` tables. Migration 006 backfills missing developer names from the former
application name, makes the developer name required, removes optional application metadata,
and retires the developer-link grant tables. Both cleanups are irreversible because their
deleted data cannot be reconstructed.

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

## Worker/API upgrade and production operation

`007_worker_api.sql` consolidates the Worker/API upgrade,
`008_ranked_battle_history.sql` adds retained raw battles,
`009_league_army_analytics.sql` adds the original league/army rollups,
`010_cwl_season_statistics.sql` adds rerunnable CWL population summaries,
`013_battle_player_time_identity.sql` fixes raw identity at player/time,
`014_ranked_defense_loot_nullable.sql` opens the bounded defense-loot cleanup,
and `015_army_code_family_compatibility.sql` adds code/family-ID identity plus
parallel shifted-day aggregates without deleting the old history.
Do not use the former 007–028 fixture numbering. See
[the schema decisions](../../docs/worker-api-schema.md),
[the disposable upgrade test](../../RETAINED_API_FIXTURE.md).

Migration 013 replaces the Ranked/Legend primary key without deleting data. Existing collisions cause a transactional failure. Migration 014 changes no rows; with the old writer paused, run the bounded defense-only cleanup companion before migration 015. Keep the writer paused until a binary that stores defense loot as SQL NULL is deployed. Migration 015 refuses incomplete cleanup, retains the player/time primary key, makes legacy hashes nullable, and introduces `army_family_daily_stats_v2` and `legend_daily_stats_v2` for the 05:10 UTC shifted-day meaning. See `docs/ranked-battle-history.md` for the complete schemas and rollback limits.
