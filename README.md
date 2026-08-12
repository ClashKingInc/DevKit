# ClashKing DevKit

ClashKing DevKit is the shared home for ClashKing's database schema,
infrastructure configuration, and design system. It keeps the pieces used by
multiple ClashKing projects together so they don't drift between repositories.

Application code and product-specific UI still live in their own repositories,
and secrets stay in the deployment environment.

## What DevKit governs

### Database and infrastructure

The `database/` workspace contains the PostgreSQL and TimescaleDB schema, Goose
migrations, and one-off Go backfills from legacy data stores. It also contains
the Compose files used to run Timescale, Valkey, Elasticsearch, and PGSync.

Schema changes belong in numbered migrations under `database/timescale/`.
Backfills belong in `database/migrations/` and should use the existing shared
connection, checkpoint, and schema-discovery utilities.

The staging PGSync setup copies selected player and clan fields from PostgreSQL
into Elasticsearch while PostgreSQL remains the source of truth. Its folder
also contains the mappings, monitoring queries, and instructions for setup,
validation, recovery, and reindexing.

### Shared design language

The `design/` workspace provides shared tokens and reusable components for web,
admin, and Flutter projects. Complete pages, navigation, state management, and
product-specific components stay in the app that uses them.

Design changes should preserve semantic parity across platforms where the
concept is shared, include usage documentation, and follow the decisions and
governance recorded under `design/docs/`.

## Working locally

Create a local database environment file from the non-secret template:

```bash
cd database
cp .env.example .env
```

Start the core Timescale and Valkey services:

```bash
docker compose \
  -f docker-compose.timescale.yml \
  -f docker-compose.valkey.yml \
  up -d
```

The Elasticsearch and PGSync definitions are intentionally separate. Follow
the PGSync runbook before starting them because logical replication settings,
database roles, mappings, and the one-time bootstrap must be prepared first.

Validate the shared design packages with:

```bash
npm --prefix design install
npm --prefix design run check
```

The complete repository validation entrypoint is:

```bash
./scripts/validate-repository.sh
```

It checks the Go migration tools, Goose migrations, CSS and Flutter packages,
and application design drift. You'll need the Go, Goose, Node, and Flutter
toolchains installed to run everything.
