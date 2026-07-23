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
also resolve `.env` and `migration_state.json` from this directory. The shared
checkpoint loader can still read legacy `.migration_state/<script>.json` files.

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
| Timescale/Postgres | `postgres://${TIMESCALE_USER}:${TIMESCALE_PASSWORD}@${HOST_BIND_IP}:${TIMESCALE_PORT}/${TIMESCALE_DB}?sslmode=disable` |
| Valkey | `${HOST_BIND_IP}:${VALKEY_PORT}` |

Set `HOST_BIND_IP` to `127.0.0.1` when only same-host access is needed. Use an
explicit trusted interface when another host must connect; do not bind database
services to a public interface.

## Apply Timescale Schema

Use goose when you want migration semantics:

```bash
go run github.com/pressly/goose/v3/cmd/goose@latest \
  -dir timescale \
  postgres "postgres://${TIMESCALE_USER}:${TIMESCALE_PASSWORD}@${HOST_BIND_IP}:${TIMESCALE_PORT}/${TIMESCALE_DB}?sslmode=disable" \
  up
```

For a throwaway fresh database where only the initial schema is needed:

```bash
psql "postgres://${TIMESCALE_USER}:${TIMESCALE_PASSWORD}@${HOST_BIND_IP}:${TIMESCALE_PORT}/${TIMESCALE_DB}?sslmode=disable" \
  -f timescale/001_initial.sql
```

Do not mount the `timescale/` folder directly into Postgres
`/docker-entrypoint-initdb.d`; these files are goose migrations and may contain
rollback sections.

## Data migration tools

The Go programs in `migrations/` backfill data from legacy stores. Run them from
this directory or from `migrations/`; both locations resolve this directory as
the database root. Most long-running backfills use shared checkpoints;
`player_links.go` intentionally reruns without a checkpoint.

```bash
cd migrations
go run player_stats.go
```

Each tool documents its required environment keys in code and fails closed when
required values are absent. Never commit the local `.env` file or migration
checkpoint data.

For the server settings cutover, apply Goose migrations `019` through `024`.
Then run the four imports in this order:

```bash
cd migrations
go run server_clans.go
go run server_settings.go
go run rosters.go
go run bot_server_settings.go
```

Migration `019` copies existing Timescale settings into normalized tables before
it removes the old JSON columns and retired tables. Migration `020` replaces the
aggregate server and clan log tables with one `server_logs` row for each server,
optional clan, and log type. It stores the webhook ID and optional thread ID. It
does not store the Discord channel because the webhook identifies the channel.
Migration `021` adds a disabled state so a log can stop without losing its
webhook or thread setup. Migration `022` removes server-clan links that have no
`basic_clan` row and adds a cascading foreign key so they cannot return.
Migration `023` renames `role_rules` to `server_roles`, changes the combined
role mode from `sync` to `both`, and removes ignored, exclusive-family, and
duplicate server-level member roles.
Migration `024` prevents those removed family-role options from being created
again.
The four imports then copy the current Mongo documents into those tables. The
migrations and importers do not truncate or update `player_links`.

See [`../docs/database-workflows.md`](../docs/database-workflows.md) for the
Goose, backfill, remote-run, and validation workflow.

## Tracking Environment

When running `clashking_tracking` from the host, use:

```bash
TIMESCALE_URL="postgres://${TIMESCALE_USER}:${TIMESCALE_PASSWORD}@${HOST_BIND_IP}:${TIMESCALE_PORT}/${TIMESCALE_DB}?sslmode=disable"
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
