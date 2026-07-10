# ClashKing DevKit

Shared database, design, documentation, and AI-development resources for
ClashKing applications and services.

## Repository layout

| Path | Contents |
| --- | --- |
| [`database/`](database/) | TimescaleDB schema, Goose migrations, MongoDB-to-Timescale backfills, and the local Timescale/Valkey Compose stack. |
| [`design/`](design/) | Cross-platform design tokens and reusable CSS and Flutter packages. |
| [`docs/`](docs/) | DevKit-specific architecture, workflows, ownership, and mobile design guidance. |
| [`skills/`](skills/) | Versioned copies of custom Codex skills plus reusable workflow skills derived from recurring team work. |

Database migration executables stay in `database/migrations/` because they
share a Go module, environment loading, checkpoint storage, and schema-root
discovery.

## Quick start

### Database stack

```bash
cd database
cp .env.example .env
docker compose -f docker-compose.timescale.yml -f docker-compose.valkey.yml up -d
```

See [`database/README.md`](database/README.md) and
[`docs/database-workflows.md`](docs/database-workflows.md).

### Design tokens

```bash
npm --prefix design install
npm --prefix design run check
```

See [`design/README.md`](design/README.md) and
[`docs/mobile-design.md`](docs/mobile-design.md).

### Skills

Browse [`docs/skills-catalog.md`](docs/skills-catalog.md). Each directory under
`skills/` is self-contained and can be copied into a Codex skills directory.

## Repository history

The repository was renamed from `ClashKingInc/DatabaseSchemas` to
`ClashKingInc/DevKit`. The two-commit history of the public
`ClashKingInc/ClahKingDesignSystem` repository is preserved in this Git history.
The source design-system repository remains unchanged until its migration is
reviewed separately.

## Secrets

Do not commit `.env` files, migration checkpoints, tokens, database URLs, or
generated build output. Tracked examples must contain keys and placeholders
only.
