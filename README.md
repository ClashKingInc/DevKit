# ClashKing Developer Kit

Shared development resources for ClashKing applications and services.

## Repository layout

| Path | Contents |
| --- | --- |
| [`database/`](database/) | TimescaleDB schema, Goose migrations, MongoDB-to-Timescale migration tools, and the local Timescale/Valkey Compose stack. |
| [`design/`](design/) | Cross-platform design tokens and reusable CSS and Flutter packages. |
| [`ai/`](ai/) | Implementation guidance intended for coding agents and AI-assisted development. |
| [`docs/`](docs/) | Developer-kit maintenance and repository-migration records. |
| [`scripts/`](scripts/) | Cross-cutting developer-kit validation. |

Database-specific migration executables stay in `database/migrations/` rather
than a root `scripts/` directory because they share a Go module, configuration,
and checkpoint lifecycle with the database schema.

## Quick start

### Database stack

```bash
cd database
cp .env.example .env
docker compose -f docker-compose.timescale.yml -f docker-compose.valkey.yml up -d
```

See [`database/README.md`](database/README.md) for schema application and
service configuration.

### Web design tokens

```bash
npm --prefix design install
npm --prefix design run check
```

See [`design/README.md`](design/README.md) for CSS and Flutter package usage.

### Validate the repository

```bash
scripts/validate-repository.sh
```

The script compiles the database migration tools, checks SQL migrations when
Goose is installed, validates Compose, verifies design-package exports and
tokens, and analyzes Flutter when the SDK is installed. The same script runs in
GitHub Actions with every required tool available.

## Repository history

This repository was renamed from `ClashKingInc/DatabaseSchemas` to
`ClashKingInc/ClashKingDevKit`. The public
`ClashKingInc/ClahKingDesignSystem` history was imported without squashing.
The original design-system repository remains available during migration
review. See [`docs/design-system-migration.md`](docs/design-system-migration.md)
for the exact file mapping and deletion checklist.

## Secrets

Do not commit local `.env` files, migration checkpoints, tokens, database URLs,
or generated build output. The tracked examples contain keys only, never
credentials.
