# Cross-repository contracts

Shared contracts must be updated from their source of truth outward.

## Contract ownership

| Contract | Authority | Typical consumers |
| --- | --- | --- |
| SQL tables, indexes, hypertables, retention | `DevKit/database/timescale` | `clashking_api`, `clashking_tracking`, migration tools |
| Backend routes and application response models | `clashking_api` | `ClashKingApp`, `ClashKingDashboard`, bot clients |
| Clash API-compatible models and enums | Official API plus client library implementation | `clashy.go`, `cocpy`, `MockAPI`, API services |
| Mock fixtures and interactive OpenAPI examples | `MockAPI` | local clients, demos, integration tests |
| Shared visual tokens | `DevKit/design` | dashboard, admin, mobile adoption |

## Migration sequence

1. Record the exact old and new contract.
2. Inspect the authoritative implementation and every direct consumer.
3. Decide compatibility explicitly. When compatibility is not required, remove
   old routes, aliases, parsers, docs, and tests.
4. Apply required DevKit schema changes through Goose.
5. Update backend handlers and typed models.
6. Regenerate Swagger, OpenAPI, static data, or API docs through the existing
   workflow.
7. Update clients, apps, dashboard routes, mocks, fixtures, and examples.
8. Run targeted tests and search for stale identifiers.

## Current examples

### Player links

`player_links.user_id` is the link subject. The removed `discord_id` column is
not a compatibility surface. API, bot, app, and dashboard code must use the
explicit subject contract instead of inventing an identity-normalization layer.

### Recent searches

Recent-search API behavior depends on the Timescale hypertable and 90-day
retention policy in DevKit. Application-only pruning is not a substitute for
database retention.

### App announcements

`database/timescale/017_mobile_admin_operations.sql` defines the shared
`admin_posts` persistence surface. Migration 009 is retained only as immutable
history; migration 017 moves its rows and retires the legacy table.

## Validation checklist

- [ ] Authoritative schema or service updated
- [ ] Database migration added and validated
- [ ] Generated docs refreshed
- [ ] Typed clients and consumers checked
- [ ] Mock fixtures and examples checked
- [ ] Obsolete compatibility removed when requested
- [ ] Stale-contract search returns only intentional history
- [ ] Targeted tests and `git diff --check` pass
