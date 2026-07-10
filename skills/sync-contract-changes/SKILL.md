---
name: sync-contract-changes
description: Migrate public API, schema, model, generated-data, or asset contracts across an authoritative source and downstream consumers. Use when routes, fields, enums, request or response shapes, database schemas, Swagger or OpenAPI, client libraries, fixtures, or generated artifacts change across repositories.
---

# Sync Contract Changes

Treat a contract migration as one coordinated change, not a collection of local guesses.

## Map the contract

1. Identify the authoritative source.
2. Record the exact old and new shapes: paths, methods, fields, nullability, enums, authentication, ownership, and error behavior.
3. Search every direct consumer, fixture, test, example, and generated artifact.
4. Determine whether backward compatibility is required. If the user says it is not, remove obsolete routes, aliases, parsers, docs, and tests instead of supporting both.

## Implement from authority outward

1. Update the authoritative schema or service.
2. Apply database migrations through the repository's established migration system.
3. Update server models and handlers.
4. Regenerate OpenAPI, Swagger, static data, or API docs through existing workflows.
5. Update typed clients and application consumers.
6. Update fixtures, mocks, examples, and tests.

Reuse existing helpers and identity sources of truth. Do not add local normalization, aliases, or hidden decode-time mutation when the contract can remain explicit.

## Validate the migration

- Run focused tests at each layer.
- Run the established generator and confirm a clean second run when practical.
- Search for stale routes, field names, enum values, imports, and old repository paths.
- Run formatting and diff checks.
- Verify a representative payload end to end.

## Handoff

List the authoritative change, every consumer checked, generated artifacts refreshed, compatibility intentionally removed or retained, tests run, and any consumer that can remain unchanged with the reason.
