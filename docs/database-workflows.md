# Database workflows

DevKit is the authoritative source for ClashKing SQL-backed schema work.

## Choose the correct lane

Use a Goose SQL migration for persistent schema changes:

- tables, columns, constraints, and indexes
- hypertables, continuous aggregates, and retention policies
- destructive schema cleanup
- data transformations that must run exactly once with schema rollout

Use a Go backfill under `database/migrations/` for high-volume imports from
MongoDB, Discord, or another external service.

Do not replace Goose with ad hoc `psql` changes on a shared database. A direct
SQL command is acceptable only for an explicitly throwaway database or a
read-only diagnostic query.

## Goose migration flow

1. Inspect every existing numbered migration and the live Goose status.
2. Add the next numbered migration instead of silently rewriting an applied
   migration.
3. Include `-- +goose Up` and a deliberate `-- +goose Down` section.
4. Validate ordering and syntax:

   ```bash
   goose -dir database/timescale validate
   ```

5. Inspect remote status before applying:

   ```bash
   goose -dir database/timescale postgres "$TIMESCALE_URL" status
   ```

6. Apply while watching output:

   ```bash
   goose -dir database/timescale postgres "$TIMESCALE_URL" up
   ```

7. Query the changed objects and verify retention policies, indexes, and row
   counts rather than relying only on Goose exit status.

`user_recent_searches` is a concrete example of database-enforced lifecycle:
it is a hypertable with a 90-day retention policy. Keep durable retention in
Timescale when the database can enforce it.

## Go backfill flow

Backfills share the module in `database/migrations/go.mod` and configuration in
`migrateutil`.

- Load secrets from `database/.env` or exported environment variables.
- Keep `.env`, `migration_state.json`, and legacy `.migration_state/` files
  untracked.
- Use `migration_state.json` for resumable high-water marks. The shared loader
  still reads legacy per-script checkpoints for migration continuity.
- Keep scripts observable: print scanned rows, throughput, checkpoint, written
  rows, skips, and bounded retries.
- Prefer projected reads, bounded batches, `pgx.CopyFrom`, temporary tables,
  and set-based upserts for large imports.
- Make reruns idempotent. Never delete source data as an implicit part of a
  backfill.
- Keep a one-off script in one file when extra package layering does not buy
  reuse. `player_links.go` is intentionally stateless and reruns the import.
- The clan-war backfill writes SQL only; it must not upload R2 objects.

Compile the shared package and each build-ignored entrypoint:

```bash
cd database/migrations
GOCACHE=/tmp/go-cache go test ./...
for file in *.go; do GOCACHE=/tmp/go-cache go test "$file"; done
```

## Remote database safety

- Verify the target host, database, and Goose status before mutation.
- Keep Timescale and Valkey off public interfaces. Bind to loopback or the
  approved Cloudflare Mesh address.
- Never print DSNs, passwords, tokens, or migration-state contents containing
  sensitive identifiers.
- Preserve a live checkpoint and monitor progress when a long backfill runs on
  a remote host.
- Lead incident updates with the current live row coverage and process state.

## Final checks

```bash
gofmt -w database/migrations
git diff --check
```

Also search for stale table, column, module, and old repository names after any
path or contract migration.
