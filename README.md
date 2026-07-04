# ClashKing Local Data Stack

This repo owns the database schema. The local compose files start the services
used by tracking/API development, while schema application should still happen
through goose or an explicit SQL command.

The compose project name is intentionally `clashking_tracking` so Docker reuses
the same container/volume names as the tracking development stack, including
the existing Timescale data volume.

Set the env vars in Coolify, copy `.env.example` to `.env`, or export the
variables in your shell before starting services.

## Start

```bash
docker compose -f docker-compose.timescale.yml up -d
docker compose -f docker-compose.valkey.yml up -d
docker compose -f docker-compose.jaeger.yml up -d
```

To start all three service files from one command:

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
| Timescale/Postgres | `postgres://${POSTGRES_USER}:${POSTGRES_PASSWORD}@100.96.0.1:${TIMESCALE_PORT}/${POSTGRES_DB}?sslmode=disable` |
| Valkey | `100.96.0.1:${VALKEY_PORT}` |
| Jaeger UI | `http://100.96.0.1:${JAEGER_UI_PORT}` |
| OTLP HTTP | `http://100.96.0.1:${OTEL_HTTP_PORT}` |
| OTLP gRPC | `100.96.0.1:${OTEL_GRPC_PORT}` |

Host ports are bound to the server's Cloudflare Mesh IP, `100.96.0.1`, so
services are reachable to devices on the Mesh but not published on the public
interface.

## Cloudflare Mesh

Cloudflare Mesh is not a `cloudflared` tunnel service. Mesh nodes run the
Cloudflare One Client (`warp-cli`) on the Linux host in headless connector mode.
Install it on the server from the Cloudflare Zero Trust dashboard:

1. Go to **Networking** > **Mesh**.
2. Select **Add a node**.
3. Create the node and copy the Linux install commands from Cloudflare.
4. Run the generated install commands on the server.
5. Register and connect the node:

```bash
sudo warp-cli connector new <TOKEN>
sudo warp-cli connect
warp-cli status
```

After the node is online, connect to these services through the server's Mesh IP
and the Mesh-bound host ports.

## Apply Timescale Schema

Use goose when you want migration semantics:

```bash
go run github.com/pressly/goose/v3/cmd/goose@latest \
  -dir timescale \
  postgres "postgres://${POSTGRES_USER}:${POSTGRES_PASSWORD}@100.96.0.1:${TIMESCALE_PORT}/${POSTGRES_DB}?sslmode=disable" \
  up
```

For a throwaway fresh database where only the initial schema is needed:

```bash
psql "postgres://${POSTGRES_USER}:${POSTGRES_PASSWORD}@100.96.0.1:${TIMESCALE_PORT}/${POSTGRES_DB}?sslmode=disable" \
  -f timescale/001_initial.sql
```

Do not mount the `timescale/` folder directly into Postgres
`/docker-entrypoint-initdb.d`; these files are goose migrations and may contain
rollback sections.

## Tracking Environment

When running `clashking_tracking` from the host, use:

```bash
TIMESCALE_URL="postgres://${POSTGRES_USER}:${POSTGRES_PASSWORD}@100.96.0.1:${TIMESCALE_PORT}/${POSTGRES_DB}?sslmode=disable"
VALKEY_ADDR="100.96.0.1:${VALKEY_PORT}"
VALKEY_PASSWORD="${VALKEY_PASSWORD}"
```

For local wars runs, keep `r2.mock_upload` enabled in
`clashking_tracking/config.json`. That exercises the finished-war SQL flow
without uploading to a local object store.

For tracing from the host, set the tracking config OTLP endpoint to Jaeger:

```text
http://100.96.0.1:${OTEL_HTTP_PORT}
```

For tracing from another compose container on this network, use:

```text
http://jaeger:4318
```

## Events GUI

Open Redis Insight or another Redis-compatible client and add:

```text
Host: 100.96.0.1
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
