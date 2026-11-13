# ClashKing DevKit

ClashKing DevKit is the shared home for ClashKing's database schema,
infrastructure configuration, and design system. It keeps the pieces used by
multiple ClashKing projects together so they don't drift between repositories.

For the local `clashking` CLI, shared workspace/env file, and encrypted contributor
datasets, see [Contributor setup](CONTRIBUTING.md). Install it locally
with `npm install --global ./cli`; nothing is published to npm.

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
See [retained reminder webhook repair](docs/reminder-webhooks.md) for preview,
safe retry, and resume behavior.

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

## Contributor guidance

[AGENTS.md](AGENTS.md) contains shared ClashKing development, verification, and
release rules. The [Dashboard and App design skill](.agents/skills/design-clashking-dashboard/SKILL.md)
includes its Expo and adaptive-layout references. These copies contain no personal
workspace paths. Tools that support skills can load the folder directly or copy it
to their configured skills directory.

## Working locally

The coordinated Effect-rewrite environment uses the versioned configuration in
`local/local-stack.example.json` and the foreground runner:

```bash
node scripts/local-stack.mjs start
```

It adopts existing PostgreSQL, proxy, API/R2, and frontend listeners, starts
only missing services that it owns, and stops owned children in reverse order.
The established Expo Metro listener is port `7357`, managed through the App
repository's `tooling/dev-app`; the runner adopts that listener and must not
start a duplicate on `8081`. See [docs/local-development.md](docs/local-development.md)
for required toolchains, ignored local credentials, optional frontends, and
physical-device LAN configuration.

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

### Headline count estimates

Migration 067 replaces only the four whole-table totals in `api_global_counts`
(players, clans, stored wars and join/leave records) with Timescale's
`approximate_row_count`. Results are catalog estimates, not exact counts or a
guaranteed error bound; ordinary statistics maintenance controls their accuracy.
The API columns and cached refresh cadence stay unchanged.

Town Hall, league and CWL distributions, current-war metrics, and battle analytics
retain their existing calculations. No historical initialization is required.
The unused daily history-count preparation aggregates are removed, together with
the initializer, so they do not track invalidations on history writes. Rollback
restores the old exact-scan view and recreates the preparation aggregates empty.
The migration is changed in place because production was verified at 066 before
its first application; do not use this approach for an already-applied migration.
