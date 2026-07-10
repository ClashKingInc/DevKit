# DevKit repository map

DevKit holds shared material that should not be reimplemented independently in
each ClashKing application.

## Ownership

| Path | Owns | Does not own |
| --- | --- | --- |
| `database/timescale/` | Authoritative PostgreSQL and TimescaleDB schema managed by Goose. | API handlers and application business logic. |
| `database/migrations/` | One-off Go backfills from legacy stores into the authoritative schema. | Long-running application workers. |
| `database/docker-compose.*.yml` | Local Timescale and Valkey service definitions. | Production deployment secrets. |
| `design/packages/css/` | Web and admin design tokens and primitives. | Product-specific page composition. |
| `design/packages/flutter/` | Shared Flutter token constants. | `ClashKingApp` widgets and navigation. |
| `docs/mobile-design.md` | Mobile implementation guidance tied to `ClashKingApp`. | Reusable agent behavior. |
| `skills/` | Broad, reusable Codex workflows and versioned custom-skill snapshots. | Repository-specific schema facts that would become stale outside DevKit. |
| `docs/` | DevKit structure, conventions, and cross-repository ownership. | General-purpose agent preferences already captured by a skill. |

## Placement rules

- Put persistent database changes in a numbered Goose migration under
  `database/timescale/`.
- Put legacy data backfills in a focused Go file under `database/migrations/`.
- Put reusable visual values in a design package; keep application widgets in
  their application repository.
- Put broad workflows in `skills/`; put ClashKing and DevKit facts in `docs/`.
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
