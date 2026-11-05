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

Migration 008 adds one-year farming history, two-perspective Ranked/Legend history, and exact army compositions. Raw Ranked/Legend rows are compressed after 30 days. Migration 008 also reshapes the existing `ranked_league_group_members` table to match the source counters directly.

Migration 009 adds permanent normal-PostgreSQL rollups for league hit rates, Ranked tier populations, Legend daily item usage, and immutable army-family assignments. It does not add a Ranked group parent table, item presence registry, prefix tables, or compression policies for rollups. See [the complete storage contract](../../docs/ranked-battle-history.md).

Migration 016 removes the rejected CWL season-statistics table, reconciliation procedure, and JSON validator while leaving the canonical CWL group, clan, and member tables unchanged. Migration 009's public war and league rollups are unrelated and remain available. See [the cross-repository removal contract](../../docs/cwl-season-statistics-removal.md).

Migration 017 is the irreversible final contract: numeric battle codes, non-null smallint durations, share-code composition/family identity, cohort-keyed unsuffixed aggregates, compact current/daily leaderboard storage, user-level notification preferences, and relational bigint bases. See [the consumer contract](../../docs/final-operational-contract.md) and [the battle contract](../../docs/ranked-battle-history.md).

## Index Notes

Farming and Ranked/Legend uniqueness is `(player_tag,battle_time)` after migration 013. Tracking stores only the requested player's perspective; migration 017 uses `battle_mode` 1/2 and `direction` 1/2. Player/time and player/mode/time indexes serve history, while a partial mode/time index containing only `direction = 1` serves aggregate scans.

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

`cwl_league_history` retains historical league-repair input as a JSONB map from
season to numeric league ID. Public API reads do not mutate or consume this
staging data.

## Mobile Push State

Mobile push state is current-state SQL data, not a hypertable. `mobile_push_devices`
stores one FCM token per `(user_id, device_id, provider, environment)`, with a unique token
hash for idempotent registration. Store the encrypted token in `token_ciphertext`, use
`token_hash` only for lookup/dedupe, and use `enabled` as the sole device-wide master
notification switch. Device rows do not store notification categories or reminder timings.

`mobile_notification_preferences` stores category booleans and reminder timings once per
user. Every enabled device for that user shares those preferences. War timings allow up to
three integer-minute values from 1 through 2,820; raid timings allow up to three values from
1 through 4,320.

`mobile_notification_accounts` stores the user-wide enabled verified player accounts; each
row is authoritatively sourced from a verified player link. Player bookmarks do not create
notification accounts. Clan notifications derive from verified players' current clans rather
than a separate clan toggle.
Delivery requires an enabled device and the relevant category enabled in that user's
preferences. Runtime delivery and deduplication use Valkey Streams; there is no SQL
notification-delivery or outbox table.

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
`015_army_code_family_compatibility.sql` adds code/family-ID identity plus
parallel shifted-day aggregates without deleting the old history.
`016_remove_cwl_season_statistics.sql` then removes the rejected CWL-only
aggregate without changing the retained war and league analytics.
`017_final_operational_contract.sql` removes compatibility storage and establishes
the final cross-repository contracts. `018_personal_base_library.sql` introduces
authenticated saved-base references, and `019_unlimited_personal_bases.sql` supersedes
its slot model with an unlimited library and base-owned download history. Migration
`022_release_extension.sql` consolidates the unpublished extensions formerly
numbered 022 through 060. It includes saved-army references, roster settings,
daily analytics, CWL participation, reminders, giveaways, tickets, role refresh,
clan verification, and notification follows. The original Up sections retain
their order and behavior. Published migrations 001 through 021 are unchanged.
The extension also adds nullable `basic_player.last_active` and the bounded
`autoboards.row_limit` (default 10, allowed 1 through 50).
It also removes inactivity reminder configurations (numeric type 4 or the
case-insensitive name `inactivity`) and prevents their reintroduction. Export
those rows before production application if their configuration must be recoverable.
Player activity and online history remain available. The unpublished standalone
023 migration has been folded into 022; there is no production migration 023.

The consolidated migration refuses Down because reversing it would lose data.
Use a verified backup or a reviewed forward migration for rollback.

An existing local database that already applied all original migrations through
060 must use `scripts/bridge-release-extension-local.mjs` before running Goose
with this inventory. The bridge verifies the original complete ledger, published
file hashes, consolidated file hash, and an explicitly approved schema hash. It
backs up the ledger, adds only the two new columns, and records the consolidated
head in one transaction. It also removes the obsolete manual-reminder request
table, but refuses removal when the table contains rows. The ledger backup also
includes retired inactivity reminder rows before the bridge deletes them. The bridge never
replays the earlier data migrations. Partial
histories and non-loopback databases are refused. The bridge is not a production
migration procedure.

Inspect first with `CLASHKING_API_REPO` and `CLASHKING_LOCAL_DATABASE_URL` set:

```bash
node scripts/bridge-release-extension-local.mjs
node scripts/bridge-release-extension-local.mjs --apply-local --expect-schema-sha256=HASH_FROM_INSPECTION
```

For a local database already at the former consolidated 022 plus unpublished 023,
use `scripts/adopt-consolidated-022-local.mjs`. Set `CLASHKING_API_REPO`,
`CLASHKING_LOCAL_DATABASE_URL`, and `CLASHKING_REFERENCE_DATABASE_URL`; the reference
must be a separate local database freshly migrated through 001–022 with Goose.
The script compares all public schema dump objects except Goose's ledger, checks
Timescale dimensions, compression flags and policy settings, verifies
published and consolidated hashes, and accepts only two previously observed local
drifts: the obsolete `family_settings` check value and a missing completed-job index.
The API accepts `roles` instead, and existing `family_settings` rows cause refusal.
Inspect first, then apply with the exact reported hash:

```bash
node scripts/adopt-consolidated-022-local.mjs
node scripts/adopt-consolidated-022-local.mjs --apply-local --expect-schema-sha256=HASH_FROM_INSPECTION
```

Application rows are not rewritten. The script saves a private ledger/schema backup,
reconciles those exact schema drifts, checks row counts and definitions, and removes
only the already-applied 023 ledger row in one transaction. It refuses unexpected
schema or ledger histories and all non-loopback databases. Run Goose status and
compare the public schema again after adoption. This local-only adoption does not
authorize a production ledger rewrite or deployment.

Original unpublished file hashes are retained in
`database/migration_history/unpublished-022-060/manifest.json`; the original SQL
snapshot for this consolidation was preserved outside the repository at
`/tmp/clashking-original-migrations-20261014`.

Manual sends now use the shared API and existing worker's best-effort wake path,
without a request queue table. The earlier column-reconciliation script is
retired. A previously bridged local database must be inspected separately before
removing its obsolete table; never drop nonempty requests without review.

Reminder imports preserve existing SQL rows by default. Use
`BOT_SERVER_SETTINGS_ONLY=reminders BOT_REMINDERS_DRY_RUN=1` to report new IDs and
differing field names without writing SQL. After reviewing the differences,
`BOT_REMINDERS_MERGE_EXISTING=reviewed` explicitly enables replacement from the
source. Scope a local rehearsal with `MIGRATION_LIMIT_DOCS` and a local
`TIMESCALE_URL`; source connections remain read-only.
Do not use the former 007–028 fixture numbering. See
[the schema decisions](../../docs/worker-api-schema.md),
[the disposable upgrade test](../../RETAINED_API_FIXTURE.md).

Migration 013 replaces the Ranked/Legend primary key without deleting data. Migration 014 and the bounded cleanup prepare nullable defense loot; migration 015 is the temporary compatibility bridge. Migration 017 removes that bridge, maps legacy NULL duration to zero, and requires coordinated final writers before ingestion resumes.

### Migration 051: manual server limits and AI reservations

Defaults: 10 clans, 5 AutoBoards, $0.05 per UTC month. Existing AutoBoard values
of 0 (the old SQL default) or 10 (the former UI default) become 5; other overrides are retained.
Existing boards are never deleted. Historical AI costs retain their original month.
Rollback refuses once any step reservation exists. A rollback does not reconstruct
former AutoBoard values; use the release backup if that configuration must be restored.

### Migration 052: bot customization grants

Bot profile customization defaults to disabled for every server. Grant it explicitly
from Admin's Server limits page. Name, avatar, banner, bio and reset actions require
both this grant and the caller's existing settings-management permission. Revoking a
grant prevents future changes but does not reset the current Discord profile.
Apply 052 before deploying the API that reads this column. Downgrading removes the
grant data, so retain a backup and coordinate the API rollback.

### Migration 053: tracking observation ordering

Adds `basic_player.observed_at` with an epoch default for legacy/unobserved rows
and a singleton `tracking_availability` row for the controller's current outage
state. Official recovery updates war clocks and clears this row's official
interval in one transaction. This is current operational state, not a history
or notification delivery ledger.

Apply 053 before the new Tracking writers. Restart all participating profile
writers together; an old binary does not honor the observation guard. Start the
new controller outside a legacy in-progress maintenance interval. Down removes
only this metadata; stop the new writers before Down. Existing war-clock
corrections and player facts are not reversed by Down.

### Donation-log retirement

Migration 028 removes legacy donation event-log settings without creating
AutoBoards. Mongo server/clan importers skip both `donations` and `donation_log`.
Separately configured donation AutoBoards and Discord webhooks are retained.
A database that already ran the earlier unpublished conversion needs an explicit
review of its generated boards: their current rows do not reliably distinguish
them from user-created boards. Do not delete all donation AutoBoards as cleanup.
Migration 028 is forward-only; retain the pre-cutover settings export for rollback.

### Migration 054: reminder webhook identities

Adds nullable `reminders.webhook_id` (text; no default). Apply before the new API
and Tracking delivery worker. After the legacy settings import, run from
`database/` with the reviewed database and bot credentials:

```bash
go run migrations/reminder_webhooks.go
REMINDER_WEBHOOKS_APPLY=1 go run migrations/reminder_webhooks.go
```

The first command is read-only. The apply command resolves each parent channel,
reuses an existing incoming webhook owned by the bot, creates one only when none
exists, and saves its ID. Threads share their parent's hook. The server-row lock
serializes this with API resource creation. It never deletes hooks or enables
disabled reminders. Failed requests stop the run; rerun after fixing the cause.
A successful run must cover all required reminders before enabling new delivery.
Run again after any subsequent legacy import that changes destinations.

For loopback service verification only, `REMINDER_DISCORD_API_URL` overrides the
Discord origin; non-loopback overrides are rejected. The old token column is
retained for compatibility but cleared by migrated/saved rows and ignored by new
delivery. Stop the new consumers before Down. Shared Discord webhooks survive
rollback and must not be blindly deleted.
