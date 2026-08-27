# ClashKing Database Toolkit

This directory owns the ClashKing SQL schema, database migration tools, and the
local data stack. The Compose files start services used by tracking and API
development. Apply schema changes through Goose or an explicit SQL command.

The compose project name is intentionally `clashking_tracking` so Docker reuses
the same container/volume names as the tracking development stack, including
the existing Timescale data volume.

From the developer-kit root, enter this directory first:

```bash
cd database
```

Set the environment variables in Coolify, copy `.env.example` to `.env`, or
export the variables in your shell before starting services. Migration tools
resolve `migration_state.json` from this directory. Migration connection
settings are read from the repository-root `.env`.

## Start

```bash
docker compose -f docker-compose.timescale.yml up -d
docker compose -f docker-compose.valkey.yml up -d
```

To start both service files from one command:

```bash
docker compose \
  -f docker-compose.timescale.yml \
  -f docker-compose.valkey.yml \
  up -d
```

The staging player/clan search stack adds Elasticsearch and PGSync while
reusing the same Timescale and Valkey services:

```bash
docker compose \
  -f docker-compose.timescale.yml \
  -f docker-compose.valkey.yml \
  -f docker-compose.elasticsearch.yml \
  -f docker-compose.pgsync.yml \
  up -d
```

PGSync bootstrap is a separate one-time administrative command and is never
part of normal container startup. Complete the PostgreSQL preflight, index
provisioning, role setup, and validation process in
[`pgsync/RUNBOOK.md`](pgsync/RUNBOOK.md) before starting the daemon in staging.

Services:

| Service | URL / address |
| --- | --- |
| Timescale/Postgres | `postgres://${TIMESCALE_USERNAME}:${TIMESCALE_PASSWORD}@${HOST_BIND_IP}:${TIMESCALE_PORT}/${TIMESCALE_DATABASE}?sslmode=${TIMESCALE_SSLMODE}` |
| Valkey | `${HOST_BIND_IP}:${VALKEY_PORT}` |
| Elasticsearch | Private Compose network only at `http://elasticsearch:9200` |
| PGSync | Private worker with no listening/public port |

Set `HOST_BIND_IP` to `127.0.0.1` when only same-host access is needed. Use an
explicit trusted interface when another host must connect; do not bind database
services to a public interface.

## Apply Timescale Schema

Use goose when you want migration semantics:

```bash
go run github.com/pressly/goose/v3/cmd/goose@latest \
  -dir timescale \
  postgres "postgres://${TIMESCALE_USERNAME}:${TIMESCALE_PASSWORD}@${HOST_BIND_IP}:${TIMESCALE_PORT}/${TIMESCALE_DATABASE}?sslmode=${TIMESCALE_SSLMODE}" \
  up
```

Do not mount the `timescale/` folder directly into Postgres
`/docker-entrypoint-initdb.d`; these files are goose migrations and may contain
rollback sections.

## Data migration tools

The Go programs in `migrations/` backfill data from legacy stores. Run them from
this directory or from `migrations/`; both locations resolve this directory as
the database root. Only `clan_wars.go` is checkpointed and resumable. Every
other importer is a one-shot rebuild: it clears its owned destination data,
drops its secondary indexes before streaming, and recreates those indexes only
after the full import succeeds. Primary keys, unique constraints, and foreign
keys remain in place when the importer needs them for identity or integrity.

```bash
cd migrations
go run clan_wars.go
```

The war importer writes immutable 10,000-war Zstd packs to R2, stores only the
searchable war metadata and byte-range locator in Timescale, and builds
integer war-ID arrays for every lineup member. It never changes
the source Mongo collection. Configure `R2_ACCOUNT_ID`, `R2_ACCESS_KEY_ID`, and
`R2_SECRET_ACCESS_KEY`; the bucket defaults to `clashking-wars` and can be
overridden with `WAR_ARCHIVE_BUCKET`. `WAR_ARCHIVE_S3_ENDPOINT` can replace the
account-derived endpoint, while `WAR_ARCHIVE_DICTIONARY` can replace the
checked-in `database/war-json.zdict` path.

The full migration pipelines packs instead of waiting for each pack to finish
before reading the next one. `WAR_ARCHIVE_PACK_WORKERS` controls total packs in
flight (default: 24),
`WAR_ARCHIVE_UPLOAD_WORKERS` limits concurrent R2 PUTs (default: 8), and
`WAR_ARCHIVE_SQL_WORKERS` limits concurrent SQL preparation/finalization
(default: 4). Chronological backfills decode BSON in ordered batches using
`WAR_ARCHIVE_DECODE_WORKERS` workers (default: 4), so pack boundaries and
checkpoints remain in source order: `data.endTime` for chronological backfills
and Mongo `_id` for explicitly split ranges. The 10,000-war
per-second target therefore keeps 10,000-war packs and uses enough parallel
pack work to hide construction, upload, and SQL latency without allowing
unbounded memory, R2 requests, or database transactions.

Large backfills can be split into non-overlapping Mongo ObjectID ranges with
`CLAN_WARS_ID_FROM` (inclusive) or `CLAN_WARS_ID_AFTER` (exclusive), plus the
exclusive `CLAN_WARS_ID_BEFORE` upper bound. Each range derives its own
checkpoint key; set `CLAN_WARS_CHECKPOINT_KEY` to name it explicitly and set a
different `MIGRATION_STATE_FILE` for every concurrent process so worker writes
cannot replace one another. Relative checkpoint paths resolve from the
repository root. A worker resumes after its last fully uploaded and committed
pack, and an already committed pack can recover its assigned war IDs from SQL
without downloading the archive object.

For the full backfill, set `WAR_ARCHIVE_DEFER_PLAYER_HISTORY=true`. Each archive
worker then appends `(player_tag, war_id)` mappings to 256 hash shards under
`WAR_ARCHIVE_HISTORY_SHARD_DIR`. A window becomes ready after 5,000,000 wars;
the final partial window is also made ready when its archive worker exits.
`WAR_ARCHIVE_HISTORY_RUN_ID` must be unique for each concurrently running source
range, while the checkpoint key is used by default. The shard and window sizes
can be changed with `WAR_ARCHIVE_HISTORY_SHARDS` and
`WAR_ARCHIVE_HISTORY_WINDOW_WARS`. The shard directory is required and should
be on persistent local storage. By default an archiver pauses before starting
another mapping window while two ready or processing windows remain queued;
`WAR_ARCHIVE_HISTORY_MAX_READY_WINDOWS` changes that bounded backlog.

Run the history consumer alongside the archive workers so temporary mappings
stay bounded instead of accumulating until the whole migration completes:

```bash
PLAYER_WAR_HISTORY_CONTINUOUS=true go run player_war_history.go
```

The consumer claims each ready window, reads only one hash shard at a time,
deduplicates and sorts that shard's war IDs, and upserts one array per player.
It writes a completion marker after each committed shard, so a restart resumes
the remaining shards. The merge itself is idempotent, covering a stop between
the SQL commit and its marker. A completed window is deleted only after every
shard commits successfully. `PLAYER_WAR_HISTORY_WORKERS` controls parallel
shard loads (default: 2), and `PLAYER_WAR_HISTORY_POLL_SECONDS` controls how
often the continuous consumer looks for newly ready windows (default: 5).

For a parallel full import, run the prepare-only command once to drop the three
`wars` secondary indexes:

```bash
CLAN_WARS_PREPARE_ONLY=true go run clan_wars.go
```

Run every range worker with `CLAN_WARS_SKIP_INDEX_MANAGEMENT=true`, then run
`CLAN_WARS_FINALIZE_ONLY=true go run clan_wars.go` once after all workers
succeed. Index finalization creates each missing index separately, so rerunning
it resumes after a failed statement. A single unfiltered worker manages this
drop-and-recreate lifecycle automatically.

Legacy numeric strings are converted while canonicalizing a war. Documents
whose nested BSON shape still cannot be decoded are reported and skipped, and
their ObjectID remains eligible for checkpoint advancement so one malformed
record cannot block the rest of a bounded worker.

After each durable PUT, the importer performs one best-effort one-byte GET through
`WAR_ARCHIVE_ORIGIN` (default: `https://wars.clashk.ing`). On a cache miss,
Cloudflare fetches and stores the complete object while returning only the
requested byte to the importer. A cache-prime failure is logged but does not invalidate an
otherwise successful R2 upload.

Every pack stores additive statistics under `stats.byDay`. Each UTC day records
war counts by type and size plus total and missed attacks. Regular wars also
record town-hall hit rates with separate zero-, one-, two-, and three-star
outcomes, and combined lineup/outcome totals by war size. Destruction and
duration sums are stored for zero through two stars; three-star destruction is
derived as `attacks * 100`, while its duration sum remains stored. The combined
outcomes count both war sides, so a decisive war contributes one win and one
loss and a tied war contributes two ties.

Set `CLAN_WARS_CLAN_TAG` to import only wars where that tag is either the clan
or opponent. The value is normalized to uppercase and may be provided with or
without the leading `#`. Clan-scoped runs use their own checkpoint and do not
advance or reuse the full-import checkpoint. They also keep the destination
indexes in place because the filtered insert is small:

```bash
CLAN_WARS_CLAN_TAG="#VY2J0LL" go run clan_wars.go
```

To import only the CWL wars required to reconstruct one clan's historical
league chain, use the clan's stored group round tags. This mode is bounded to
August 2025 through July 2026, queries Mongo by its indexed official war
tag, preserves unrelated SQL wars, and cannot be combined with truncation:

```bash
CLAN_WARS_CWL_CLAN_TAG="#VY2J0LL" CLAN_WARS_TRUNCATE=false go run clan_wars.go
```

`CLAN_WARS_TRUNCATE=true` is intentionally rejected. Archive objects and their
SQL locators must remain paired, so destructive rebuilds require an explicit
operator-managed cleanup rather than a migration flag.

Join/leave history can likewise be rebuilt for one clan. This importer is
always a one-shot rebuild, so it truncates `join_leave_history` before loading
the matching source documents. Set `JOIN_LEAVE_HISTORY_PLAYER_TAG` instead to
replace only that player's existing rows and load every event for the player
across clans, preserving unrelated local history. If both variables are set,
both filters must match and only that player-clan pair is replaced:

```bash
JOIN_LEAVE_HISTORY_CLAN_TAG="#VY2J0LL" go run join_leave_history.go
JOIN_LEAVE_HISTORY_PLAYER_TAG="#2J8V28GV0" go run join_leave_history.go
```

Each tool documents its required environment keys in code and fails closed when
required values are absent. Never commit the local `.env` file or migration
checkpoint data.

Player change history is imported from `new_looper.player_history` into the
normalized `player_change_history` hypertable. The importer is resumable: every
committed SQL batch advances a SQL-side Mongo ObjectID checkpoint in the same
transaction, and the temporary checkpoint row is removed after both destination
indexes are rebuilt. It resolves compact item IDs from the ClashKing static-data
JSON files; set `PLAYER_CHANGE_HISTORY_STATIC_DATA_DIR` when the assets repository
is not in the usual sibling location.

```bash
cd migrations
go run player_change_history.go
```

For a destructive validation import, `PLAYER_CHANGE_HISTORY_SAMPLE_DOCS` divides
the requested document count across 40 evenly spaced ObjectID time windows by
default. This still truncates only `player_change_history`, so use it only on a
local or otherwise disposable destination:

```bash
PLAYER_CHANGE_HISTORY_SAMPLE_DOCS=1000000 go run player_change_history.go
```

The stored change type IDs are: troop level `1`, super-troop boost `2`, hero
level `3`, spell level `4`, pet level `5`, equipment level `6`, Town Hall level
`7`, best trophies `8`, best Builder Base trophies `9`, experience level `10`,
war preference `11`, and player name `12`. Super boosts are normalized to
`0 -> 1`; non-super equal values, decreases, missing previous values, broad
equal-value snapshot clusters, and explicitly excluded legacy profile types are
reported and skipped. The destination uses three-month hypertable chunks without
a compression or Hypercore policy.

The Goose baseline includes the consolidated canonical `servers`
configuration schema.
After it is applied, run the settings imports in this order:

```bash
cd migrations
go run server_settings.go
go run server_clans.go
go run rosters.go
go run bot_server_settings.go
```

Server bans and player strikes have one combined one-shot importer because the
two moderation surfaces share the same legacy `usafam` database and are
normally cut over together:

```bash
cd migrations
go run bans_and_strikes.go
```

The importer reads `usafam.banlist` and `usafam.strikes`, replaces only
`server_bans` and `strikes`, and recreates their secondary indexes after the
load. Apply the Timescale schema and import servers first. It treats the named
SQL columns as authoritative and does not copy the source documents into the
removed catch-all `data` columns. One optional image-evidence value is written
to each table's typed `image` column. Strike rollover timestamps are written to
the typed `rollover_date` column; legacy ban rollover timestamps are not
imported because `server_bans` has no corresponding typed column.

`server_settings.go` also aggregates `new_looper.command_stats` from the stats
Mongo database and writes each server's most recent command to
`servers.last_command_at`. Servers without command history remain `NULL`, which
the tracking and API consumers treat as inactive. This activity backfill is part
of the server import and has no separate migration command.

Historical official leaderboard data has two dedicated one-shot imports:

```bash
cd migrations
go run player_rankings_current.go
go run leaderboard_history.go
go run legend_history.go
```

`player_rankings_current.go` reads `new_looper.leaderboard_db`, resolves its
retained country name/code through the Clash locations catalog, and writes the
normalized Home Village and Builder Base rows. The legacy collection clears
rank fields when a player leaves a local leaderboard but deliberately keeps the
last known country. The importer preserves that fact as a numeric-location row
with nullable rank and points; global rows exist only for active global ranks.
Legacy documents do not contain trophy values, so migrated placements retain
their rank with a null `points` value. Set `PLAYER_RANKINGS_LOCATIONS_URL` only
when the default ClashKing proxy locations endpoint must be replaced.

Historical CWL league changes have a separate one-shot staging import:

```bash
cd migrations
go run cwl_league_history.go
```

`cwl_league_history.go` reads `ranking_history.league_history`, shifts each
recorded month forward to the CWL season in which that league was played, maps
league names to numeric CWL league IDs, and stores one compact JSONB season map
per clan. API reads consume and delete each clan row after its missing stored
CWL group league IDs have been repaired.

`leaderboard_history.go` reads the five canonical full-snapshot collections
from the `ranking_history` Mongo database. It does not import the incompatible
seasonal `player_leaderboard`/`clan_leaderboard` collections, the retired
`legends` collection, or `league_history`, which is handled by the separate
CWL staging importer above. Capital snapshots retain only Tuesday source
documents and store them under the preceding Monday date.
`legend_history.go` reads the separate `looper.legend_history` collection.
Leaderboard history has no JSONB: each of the five source collections writes
to its own typed table, retaining numeric league/location IDs and one badge
token where static API metadata can be reconstructed. Legend history likewise
stores player/ranking, nullable clan snapshot/token, and league-tier ID fields
as typed columns. API readers rebuild standard 70/200/512 badge URLs and other
static metadata before public responses. Both scripts truncate only their
owned destinations when they start, delay secondary-index creation until the
complete source stream succeeds, and do not use checkpoints.

The two-file baseline directly creates the final schema without replaying the
retired JSON layouts or their transitional copy/drop steps. Migration 001 owns
tracking, player, clan, war, leaderboard, and Timescale-specific structures;
migration 002 owns application, authentication, mobile, roster, server, billing,
and moderation settings. The final schema includes canonical `servers` and
server logs, bounded roster question/answer JSON, reusable roster-view programs,
typed player snapshots, AI accounting, and the roster-independent CWL bonus
recipient ledger.
The roster importer generates canonical roster UUIDs and uses legacy source
identifiers only transiently to resolve relationships during the one-shot
import; it never persists Mongo roster IDs, signup categories, signup groups,
or substitute flags. The other settings imports retain their existing ownership;
`server_settings.go` is the source-oriented importer name but writes canonical
`servers`. The migrations and importers do not truncate or update
`player_links`.

See [`../docs/database-workflows.md`](../docs/database-workflows.md) for the
Goose, backfill, remote-run, and validation workflow.

## Tracking Environment

When running `clashking_tracking` from the host, use:

```bash
TIMESCALE_HOST="${HOST_BIND_IP}"
TIMESCALE_PORT="${TIMESCALE_PORT}"
TIMESCALE_DATABASE="${TIMESCALE_DATABASE}"
TIMESCALE_USERNAME="${TIMESCALE_USERNAME}"
TIMESCALE_PASSWORD="${TIMESCALE_PASSWORD}"
TIMESCALE_SSLMODE="${TIMESCALE_SSLMODE}"
VALKEY_HOST="${HOST_BIND_IP}"
VALKEY_PORT="${VALKEY_PORT}"
VALKEY_PASSWORD="${VALKEY_PASSWORD}"
```

For local wars runs, keep `r2.mock_upload` enabled in
`clashking_tracking/config.json`. That exercises the finished-war SQL flow
without uploading to a local object store.

For tracing, point the tracking service at Better Stack's OTLP/HTTP endpoint:

```text
OTEL_EXPORTER_OTLP_TRACES_ENDPOINT=https://${BETTERSTACK_INGESTING_HOST}/v1/traces
OTEL_EXPORTER_OTLP_HEADERS=Authorization=Bearer ${BETTERSTACK_SOURCE_TOKEN}
OTEL_EXPORTER_OTLP_COMPRESSION=gzip
```

## Events GUI

Open Redis Insight or another Redis-compatible client and add:

```text
Host: ${HOST_BIND_IP}
Port: ${VALKEY_PORT}
Password: ${VALKEY_PASSWORD}
```

If connecting from another compose container on this project network, use:

```text
Host: valkey
Port: 6379
Password: ${VALKEY_PASSWORD}
```

Tracking events stream:

```text
tracking:events
```

## Stop

```bash
docker compose -f docker-compose.timescale.yml down
docker compose -f docker-compose.valkey.yml down
```

To delete local data too:

```bash
docker compose -f docker-compose.timescale.yml down -v
docker compose -f docker-compose.valkey.yml down -v
```
