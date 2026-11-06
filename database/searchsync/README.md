# Dedicated Go search stream

This service streams existing PostgreSQL WAL for `basic_player` and `basic_clan`
into the existing Elasticsearch indexes. Migration 063 creates a publication
with only their five/seven canonical indexed fields. It adds **no queue table,
row trigger, replica-identity widening, or per-change SQL write**.

PostgreSQL may still send updates whose published values did not change. Go
coalesces pending tags and compares successful documents in a bounded LRU cache.
A first visit or cache miss always indexes safely. The cache is an optimization,
not a durable checkpoint or correctness dependency. Unrelated table payloads
are excluded from the normal pgoutput stream.

## Handoff without a full snapshot

1. Apply `063_search_stream_publication.sql`.
2. Prepare the Coolify service and persistent `/state` volume. Keep current
   indexes and aliases. Stop old PGSync through Coolify before starting Go.
3. Go creates one `pgoutput` slot and atomically saves its fixed initial boundary
   and target identity in `/state/handoff.json` (file and directory fsync).
4. Go bridges both old `test_decoding` slots only through that boundary. It
   keeps one continuous replication connection per legacy slot, so a pinned
   restart position does not cause repeated decoding for each batch. Both slots
   progress independently. Go ignores unrelated table payloads, coalesces tags,
   reads current minimal SQL documents, and sends bounded bulk upserts/deletes.
   Only completed transactions whose bulks succeeded are acknowledged.
5. After bridging, Go persists handoff completion and streams the new slot.
   Old pending changes and changes during handoff are covered. No 56-million-row
   snapshot, new index, or alias switch is used.
6. Validate live delivery, lag, errors, memory and WAL. Retire old PGSync triggers
   and slots only after the new consumer is healthy. The service never drops a
   slot automatically.

The one-time bridge still reads legacy retained WAL, including unrelated table payloads
from the old test_decoding plugin. Filtering those payloads happens in Go;
there is no claim that this legacy catch-up has publication filtering. Normal operation only receives the publication.
A logical slot still retains whole-database WAL while its consumer is behind;
this design reduces work and acknowledges small successful batches. It does not
make retention risk disappear.

## Correctness and resource limits

The service uses pgoutput protocol 1 without streaming uncommitted transactions.
A BEGIN therefore belongs to a committed source transaction. Large transactions
can flush bounded Elasticsearch batches without holding all rows in memory, but
Go acknowledges only through a received COMMIT after every required bulk succeeds.

Partial ES failures leave the transaction unacknowledged. Restart safely replays
it. Each document uses an external version derived from the source LSN plus a
reserved high range, preserving legacy-index adoption and idempotent retries.
Deletes, key changes, nulls, and source rollbacks are handled explicitly. Missing
TOAST values use a rare minimal SQL read; they are never fabricated.

One database advisory lock and the active replication slot prevent parallel
consumers. Requests have a 20-second timeout. Stop the previous worker before
replacement; never resume an old suspended worker after a successor. Native ES
delete versions have finite retention, so this is recoverable at-least-once
synchronization, not a distributed exactly-once claim.

Source TRUNCATE fails closed with no acknowledgment; it requires explicit search
reconciliation. A missing recorded slot or mismatched handoff identity also
fails closed. Neither causes an automatic reset or full snapshot.

## Runtime configuration

- `DATABASE_URL`, or standard `PGHOST`, `PGPORT`, `PGDATABASE`, `PGUSER`,
  `PGPASSWORD`, `PGSSLMODE` bindings.
- `SEARCH_EXPECT_DATABASE`, `SEARCH_EXPECT_SYSTEM_ID`.
- `SEARCH_SLOT=clashking_search_go`.
- `SEARCH_PLAYER_INDEX=clashking_players_v2`.
- `SEARCH_CLAN_INDEX=clashking_clans_v2`.
- `SEARCH_PLAYER_OLD_SLOT=clashking_clashking_players_v2`.
- `SEARCH_CLAN_OLD_SLOT=clashking_clashking_clans_v2`.
- `SEARCH_STATE_DIR=/state` on a persistent Coolify volume.
- `ELASTICSEARCH_URL` on the private network.
- Existing `ELASTICSEARCH_API_KEY_ID` and raw `ELASTICSEARCH_API_KEY`; alternatively
  an encoded API key without an ID, or user/password bindings.
- `SEARCH_BATCH_SIZE`: default 1000, range 1–5000.
- `SEARCH_CACHE_ENTRIES`: default 100000, range 1–1000000.
- `SEARCH_RUN_UNTIL_IDLE=1`: disposable/operator checks only; never production.

Credentials are never logged. Normal checkpoints live in the replication slot;
the state file is written only for handoff initialization/completion.

## Checks and rollback

`search-stream-smoke.py` runs actual PGSync, Timescale and Elasticsearch. It tests
existing-index adoption, pre/post-boundary changes, deletes/recreate, key changes,
SQL rollback, failed handoff without slot consumption, large-transaction partial
bulk failure, restart, and unchanged-field filtering in a live consumer.
`search-stream-benchmark.py` compares the current PGSync and Go containers using
the same data, services, CPU/memory limits and batch size. Results are local,
workload-specific measurements, not guaranteed production gains.

Before old slot retirement, failed handoff can safely resume from those retained
slots because consumption follows durable ES writes. Keep the new slot/state
when fixing a deployment; do not reset them. After retiring old slots, reverting
to PGSync requires an explicit handoff/reconciliation plan. Dropping the
publication does not drop slots or Elasticsearch data, but first stop Go and
establish the replacement consumer.

## Full background resync

`SEARCH_MODE=full` targets freshly created, empty replacement indexes. Use a new
`SEARCH_STATE_DIR` beneath the retained state volume so the previous handoff
record stays intact. The service runs a keyset snapshot and the normal WAL
consumer concurrently. Each snapshot batch uses its own current SQL statement,
version 1, and a 30-second lifetime. WAL versions are higher, so a snapshot cannot
overwrite a newer streamed value. Configure replacement indexes with
`index.gc_deletes=24h` during the build to retain delete versions well beyond a
snapshot batch. Never resume a suspended old process after its replacement.

Snapshot cursors persist to the local state file only after successful bulk
writes. There is no database queue or snapshot-progress table. The default
snapshot ceiling is 25,000 documents/second (`SEARCH_SNAPSHOT_RATE`, 100–100,000).
The live WAL consumer does not wait for the full snapshot. Keep Tracking running;
reduce snapshot throughput if resource pressure requires it.

Keep existing aliases on the old indexes until both source snapshots finish,
the new stream catches up, and counts/sample documents validate. Then switch
both aliases atomically. The service does not switch aliases or delete indexes.
`search-full-smoke.py` exercises the actual local service with updates and deletes
behind/ahead of the snapshot cursor, key moves, concurrent WAL acknowledgments,
and process crash/resume using the same state volume.
