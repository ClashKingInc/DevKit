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
| Production environment names | `DevKit/docs/production-environment.md` | Coolify resources, API, admin, proxy, tracking, Cloudflare deployment |

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

Home upgrade data is keyed only by the globally unique `player_links.tag`.
`player_upgrades.data` and `player_upgrade_preferences.preferences` are separate
whole-document JSON objects, and deleting the player link deletes both records.
`player_links.last_login` remains null until an app launch updates a verified link.

### Recent searches

Recent-search API behavior depends on the Timescale hypertable and 90-day
retention policy in DevKit. Application-only pruning is not a substitute for
database retention.

### App announcements

`database/timescale/002_initial_settings.sql` defines both the shared
`admin_posts` persistence surface and the supported `app_announcements`
surface. New app archive content uses `admin_posts`; the legacy announcement
API keeps its own table until its callers are migrated.

### CWL season statistics removal

Migration `016_remove_cwl_season_statistics.sql` removes only
`cwl_season_statistics`, `reconcile_cwl_season_statistics(text[])`, and
`cwl_town_halls_valid(jsonb)`. The current Tracking checkout has no caller, but
the deployed Tracking revision must still be checked for a scheduled or manual
procedure invocation before migration 016 is applied. The current API checkout
has no query against the removed table; it must add migration 016 to the expected
local schema inventory in `scripts/local-api-database.mjs`.

The API's `/v2/stats/cwl` performance route does not use this table and remains
supported. Migration 009's public war hit-rate, Ranked population, Legend usage,
and army family aggregates also remain supported and must not be removed as part
of this cutover.

## Validation checklist

- [ ] Authoritative schema or service updated
- [ ] Database migration added and validated
- [ ] Generated docs refreshed
- [ ] Typed clients and consumers checked
- [ ] Mock fixtures and examples checked
- [ ] Obsolete compatibility removed when requested
- [ ] Stale-contract search returns only intentional history
- [ ] Targeted tests and `git diff --check` pass
