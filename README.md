# ClashKing Local Data Stack

This repo owns the database schema. The local compose files start the services
used by tracking/API development, while schema application should still happen
through goose or an explicit SQL command.

The compose project name is intentionally `clashking_tracking` so Docker reuses
the same container/volume names as the tracking development stack, including
the existing Timescale data volume.

Each compose file requires its env vars to be set. Copy `.env.example` to
`.env` or export the variables in your shell before starting services.

## Start

```bash
docker compose -f docker-compose.timescale.yml up -d
docker compose -f docker-compose.valkey.yml up -d
docker compose -f docker-compose.jaeger.yml up -d
```

To start all three from one command:

```bash
docker compose \
  -f docker-compose.timescale.yml \
  -f docker-compose.valkey.yml \
  -f docker-compose.jaeger.yml \
  up -d
```

Services:

| Service | URL / address |
| --- | --- |
| Timescale/Postgres | `postgres://${POSTGRES_USER}:${POSTGRES_PASSWORD}@localhost:${TIMESCALE_PORT}/${POSTGRES_DB}?sslmode=disable` |
| Valkey | `localhost:${VALKEY_PORT}` |
| Jaeger UI | `http://localhost:${JAEGER_UI_PORT}` |
| OTLP HTTP | `http://localhost:${OTEL_HTTP_PORT}` |
| OTLP gRPC | `localhost:${OTEL_GRPC_PORT}` |

## Apply Timescale Schema

Use goose when you want migration semantics:

```bash
go run github.com/pressly/goose/v3/cmd/goose@latest \
  -dir timescale \
  postgres "postgres://${POSTGRES_USER}:${POSTGRES_PASSWORD}@localhost:${TIMESCALE_PORT}/${POSTGRES_DB}?sslmode=disable" \
  up
```

For a throwaway fresh database where only the initial schema is needed:

```bash
psql "postgres://${POSTGRES_USER}:${POSTGRES_PASSWORD}@localhost:${TIMESCALE_PORT}/${POSTGRES_DB}?sslmode=disable" \
  -f timescale/001_initial.sql
```

Do not mount the `timescale/` folder directly into Postgres
`/docker-entrypoint-initdb.d`; these files are goose migrations and may contain
rollback sections.

## Tracking Environment

When running `clashking_tracking` from the host, use:

```bash
TIMESCALE_URL="postgres://${POSTGRES_USER}:${POSTGRES_PASSWORD}@localhost:${TIMESCALE_PORT}/${POSTGRES_DB}?sslmode=disable"
VALKEY_ADDR="localhost:${VALKEY_PORT}"
VALKEY_PASSWORD="${VALKEY_PASSWORD}"
```

For local wars runs, keep `r2.mock_upload` enabled in
`clashking_tracking/config.json`. That exercises the finished-war SQL flow
without uploading to a local object store.

For tracing from the host, set the tracking config OTLP endpoint to Jaeger:

```text
http://localhost:${OTEL_HTTP_PORT}
```

For tracing from another compose container on this network, use:

```text
http://jaeger:4318
```

## Events GUI

Open Redis Insight or another Redis-compatible client and add:

```text
Host: localhost
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
docker compose -f docker-compose.jaeger.yml down
```

To delete local data too:

```bash
docker compose -f docker-compose.timescale.yml down -v
docker compose -f docker-compose.valkey.yml down -v
```
