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
settings are read from the repository-root `.env` (with `database/.env` kept
as a compatibility fallback). The shared checkpoint loader can still read
legacy `.migration_state/<script>.json` files.

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

Services:

| Service | URL / address |
| --- | --- |
| Timescale/Postgres | `postgres://${POSTGRES_USER}:${POSTGRES_PASSWORD}@${HOST_BIND_IP}:${TIMESCALE_PORT}/${POSTGRES_DB}?sslmode=disable` |
| Valkey | `${HOST_BIND_IP}:${VALKEY_PORT}` |

Set `HOST_BIND_IP` to `127.0.0.1` when only same-host access is needed. Use an
explicit trusted interface when another host must connect; do not bind database
services to a public interface.

## Apply Timescale Schema

Use goose when you want migration semantics:

```bash
go run github.com/pressly/goose/v3/cmd/goose@latest \
  -dir timescale \
  postgres "postgres://${POSTGRES_USER}:${POSTGRES_PASSWORD}@${HOST_BIND_IP}:${TIMESCALE_PORT}/${POSTGRES_DB}?sslmode=disable" \
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

Each tool documents its required environment keys in code and fails closed when
required values are absent. Never commit the local `.env` file or migration
checkpoint data.

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

Historical official leaderboard data has two dedicated one-shot imports:

```bash
cd migrations
go run leaderboard_history.go
go run legend_history.go
```

`leaderboard_history.go` reads the five canonical full-snapshot collections
from the `ranking_history` Mongo database. It does not import the incompatible
seasonal `player_leaderboard`/`clan_leaderboard` collections or the explicitly
retired `legends`/`league_history` collections. Capital snapshots retain only
Tuesday source documents and store them under the preceding Monday date.
`legend_history.go` reads the separate `looper.legend_history` collection.
Leaderboard history has no JSONB: each of the five source collections writes
to its own typed table, retaining numeric league/location IDs and one badge
token where static API metadata can be reconstructed. Legend history likewise
stores player/ranking, nullable clan snapshot/token, and league-tier ID fields
as typed columns. API readers rebuild standard 70/200/512 badge URLs and other
static metadata before public responses. Both scripts truncate only their
owned destinations when they start, delay secondary-index creation until the
complete source stream succeeds, and do not use checkpoints.

The baseline copies existing Timescale settings into typed tables before it
removes old JSON columns and retired tables. Migration 003 then consolidates
server configuration into `servers`. It also unifies server logs, adds the
disabled state, links server clans to `basic_clan`, renames `role_rules` to
`server_roles`, and enforces the current role options. Migration 004 replaces
roster signup categories/substitutes with bounded question/answer JSON,
complete typed player snapshots, normalized saved-view references, secure live
post bindings/events, metric and AI accounting, short-lived membership drafts,
recent access, and an immutable roster-independent CWL bonus award ledger. Do
not run
`rosters.go` against version 4 until its legacy category/substitute projection
is migrated. The other settings imports retain their existing ownership;
`server_settings.go` is the source-oriented importer name but writes canonical
`servers`. The migrations and importers do not truncate or update
`player_links`.

See [`../docs/database-workflows.md`](../docs/database-workflows.md) for the
Goose, backfill, remote-run, and validation workflow.

## Tracking Environment

When running `clashking_tracking` from the host, use:

```bash
TIMESCALE_URL="postgres://${POSTGRES_USER}:${POSTGRES_PASSWORD}@${HOST_BIND_IP}:${TIMESCALE_PORT}/${POSTGRES_DB}?sslmode=disable"
VALKEY_ADDR="${HOST_BIND_IP}:${VALKEY_PORT}"
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
