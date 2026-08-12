# DevKit repository map

DevKit holds shared database, infrastructure, design, and operational material
that should not be reimplemented independently in each ClashKing application.

## Ownership

| Path | Owns | Does not own |
| --- | --- | --- |
| `database/timescale/` | Authoritative PostgreSQL and TimescaleDB schema managed by Goose. | API handlers and application business logic. |
| `database/migrations/` | One-off Go backfills from legacy stores into the authoritative schema. | Long-running application workers. |
| `database/docker-compose.timescale.yml` | Local/staging Timescale service definition and PostgreSQL server settings. | SQL schema changes or production credentials. |
| `database/docker-compose.valkey.yml` | Persistent authenticated Valkey service definition. | Application cache-key contracts. |
| `database/docker-compose.elasticsearch.yml` | Private staging Elasticsearch service, storage, health check, and resource limits. | Application search queries or public network exposure. |
| `database/docker-compose.pgsync.yml` | PGSync daemon build/runtime wiring against Timescale, Elasticsearch, and Valkey. | One-time bootstrap execution or application search integration. |
| `database/pgsync/` | Staging PGSync schema, explicit Elasticsearch mappings, restricted-key template, monitoring queries, and operations runbook. | Source-table schema ownership, secrets, production rollout, or the ClashKing search API. |
| `design/packages/css/` | Web and admin design tokens and primitives. | Product-specific page composition. |
| `design/packages/flutter/` | Shared Flutter tokens and dependency-light reusable components. | `ClashKingApp` pages, navigation, and product-specific state. |
| `design/docs/` | Shared design-system usage, component, governance, and decision records. | Point-in-time audit reports. |
| `docs/mobile-design.md` | Mobile implementation guidance tied to `ClashKingApp`. | Reusable agent behavior. |
| `docs/production-environment.md` | Canonical Coolify/server environment-variable contract and platform boundaries. | Secret values or resource-local process settings. |
| `docs/` | DevKit structure, conventions, and cross-repository ownership. | General-purpose agent preferences already captured by a skill. |
| `scripts/validate-repository.sh` | Repository-wide schema, migration, design-package, and drift validation entrypoint. | Deployment orchestration. |

## Placement rules

- Put persistent database changes in a numbered Goose migration under
  `database/timescale/`.
- Put legacy data backfills in a focused Go file under `database/migrations/`.
- Put PGSync topology, mappings, monitoring queries, and operational guidance
  under `database/pgsync/`; keep source-table changes in the Goose schema.
- Keep service definitions separate under `database/docker-compose.*.yml` and
  combine them explicitly at invocation time.
- Put reusable visual values in a design package; keep application widgets in
  their application repository.
- Put shared design-system guidance in `design/docs/` and repository ownership,
  environment contracts, and cross-repository workflows in `docs/`.
- Keep generated files only when the repository already owns their generation
  workflow.

## Related repositories

- `clashking_api` consumes the schema and publishes backend contracts.
- `ClashKingApp` and `ClashKingDashboard` consume API and design contracts.
- `clashy.go` and `cocpy` expose Clash API behavior to downstream developers.
- `MockAPI` owns fixture-backed API examples and OpenAPI documentation.
- `clashking_tracking` writes Timescale data and publishes tracking events.
- `ClashKingProxy` owns Clash API-compatible proxy behavior and request stats.

When a change crosses these boundaries, follow
[`cross-repo-contracts.md`](cross-repo-contracts.md).
