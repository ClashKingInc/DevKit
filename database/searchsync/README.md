# Dedicated Go search sync

The service indexes only the five canonical `basic_player` fields and seven
`basic_clan` fields listed in `../pgsync/schema.json`. It reuses those mappings.
Migration 063 captures indexed-field changes atomically with source writes.
Observation-only updates compare typed fields and create no queue row.

`search_sync_pending` coalesces work by `(entity, tag)`. A NULL document is a
removal tombstone. Each new state gets a monotonically increasing generation,
starting at 10^18 to exceed legacy PGSync's internal document versions. Never
reset this sequence or run old PGSync against the indexes after handoff.
The worker acknowledges only the generation Elasticsearch accepted; concurrent
changes remain queued. Rows keep their original queue position. The consumer
alternates bounded player/clan batches under one database advisory lock.

## Existing-index handoff (production)

Keep `clashking_players_v2`, `clashking_clans_v2`, and their stable aliases.
There is **no full source snapshot** in handoff mode.

1. Apply migration 063. It records a fixed WAL boundary after installing capture
   triggers. Source-table DDL locks exclude old writers until commit; subsequent
   changes are durable in the new queue.
2. Stop PGSync through Coolify. Do not resume an old suspended worker later.
3. Start this service with `SEARCH_MODE=handoff` and the exact old slot names.
   It streams bounded committed batches from each old `test_decoding` slot up to
   the capture boundary. Only actual typed tag fields from the matching source
   table are used; all other tables are ignored. It reads current SQL documents
   for those tags, including missing-row tombstones. Newer captured queue rows
   always win. It persists the queue before consuming each old slot batch.
4. After both boundaries are transferred, adopt the existing validated mappings
   and drain the queue. The worker retains all failed batches and resumes after
   restart. An Elasticsearch failure cannot erase the already transferred gap.
5. Verify queue age/size, actual search results, source write latency and index
   errors. Then retire obsolete slots explicitly; no slot is dropped by this
   service. The steady-state service never reads WAL or creates slots.

This one-time bridge must still decode legacy retained WAL. Its purpose is to
replace repeated Elasticsearch writes with one pending state per identity and
release completed WAL batches progressively. It cannot recover a slot that was
already invalidated. Never force-advance a slot to bypass missing changes.

## Failure and ordering

The consumer has one PostgreSQL connection that owns its advisory lock and all
acknowledgments. The bridge temporarily uses a second connection for queue
writes while streaming slot records. A broken connection terminates the process;
there is no hidden reconnect while an old bulk request might still be active.
A failed bulk or item failure leaves the queue unchanged. Partial successes can
replay. External generations reject stale writes; not-found deletes succeed.

Native Elasticsearch delete-version retention is finite. Keep its existing
60-second minimum, use the 20-second request timeout, stop the old worker before
replacement, and never resume it after a successor. This is recoverable
at-least-once synchronization, not distributed exactly-once execution.

Source TRUNCATE fails closed because it cannot emit individual tombstones.
Normal DELETE, NULL field changes and primary-key changes are captured.

## Configuration

Required names (never log their values):

- `DATABASE_URL`, or standard `PGHOST`, `PGPORT`, `PGDATABASE`, `PGUSER`,
  `PGPASSWORD`, `PGSSLMODE` environment bindings
- `SEARCH_EXPECT_DATABASE`
- `SEARCH_EXPECT_SYSTEM_ID` (PostgreSQL system identifier)
- `ELASTICSEARCH_URL` (private origin)
- `SEARCH_PLAYER_INDEX`, `SEARCH_CLAN_INDEX`
- `SEARCH_SCHEMA_FILE` (image default `/etc/searchsync/schema.json`)

Handoff requires `SEARCH_MODE=handoff`, `SEARCH_PLAYER_SLOT` and
`SEARCH_CLAN_SLOT`. Use `ELASTICSEARCH_API_KEY` (encoded ID:key), or the existing raw key plus
`ELASTICSEARCH_API_KEY_ID`, or
`ELASTICSEARCH_USER` and `ELASTICSEARCH_PASSWORD`.
`SEARCH_BATCH_SIZE` defaults to 1000 and accepts 1–5000.
`SEARCH_RUN_ONCE=1` drains available work and exits (local/operator use).

For a genuinely new empty deployment, omit handoff mode. The service scans each
source by primary-key cursor, saves progress after every accepted bulk, and then
drains concurrent changes. Precreate indexes with canonical mappings; optional
`SEARCH_ALLOW_INDEX_CREATE=1` exists for disposable fixtures. Production does not
need new indexes, alias changes, or new index-creation privileges.

## Local checks

Use canonical disposable fixtures for all checks:

- `search-sync-smoke.py`: snapshot crash/resume, concurrent changes/deletes,
  irrelevant fields, actual ES failure, ES-success/SQL-ACK failure, restart.
- `search-sync-handoff-smoke.py`: actual old PGSync indexes and logical slots,
  before/after capture changes, SQL transfer failure, ES failure after durable
  transfer, deletes/recreate, existing-index adoption without a snapshot.
- `search-sync-benchmark.py`: optional matched PGSync/Go comparison, same local
  PG/ES, 2 CPU and 1 GiB per sync container, batch 1000. Report environment and
  workload; do not present the local ratio as a production guarantee.

## Rollback

Before bridge consumption, stop the new service and resume the old PGSync path.
After old slot batches are consumed, their pending changes exist in the new
queue. Preserve that queue and complete its delivery before considering another
consumer. Merely restarting old PGSync would skip transferred-but-undelivered
work. Migration Down discards pending synchronization work and must not be used
as an automatic production rollback. Raw source tables and indexes are retained.
