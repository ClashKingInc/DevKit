# ClashKing staging search sync

This staging stack copies selected `basic_player` and `basic_clan` columns from
PostgreSQL into Elasticsearch. PostgreSQL remains authoritative. Do not connect
the application search API until the validation section has passed.

## Components and sizing

- Existing Timescale/PostgreSQL with logical WAL enabled.
- Existing authenticated, AOF-backed Valkey, using logical database `1` for
  PGSync queues and checkpoints.
- One private Elasticsearch 8.19.17 node with 6 CPUs, a 12 GB container limit,
  a 6 GB JVM heap, and a persistent volume.
- PGSync 7.2.0 in normal `--daemon` mode. PGSync has no hard CPU or memory limit
  initially; its concurrency is bounded to two workers, an eight-connection
  maximum SQLAlchemy pool, and 2,000-document Elasticsearch batches.

The player index starts with four primary shards because the source is expected
to contain about 50 million rows. The clan index has one primary shard. Both
have zero replicas because staging has one Elasticsearch node.

## Required secrets

Configure these in the staging Coolify environment. Never commit their values.

- `ELASTIC_PASSWORD`: Elasticsearch bootstrap administrator password. Use it
  only to provision mappings, aliases, and the restricted API key.
- `PGSYNC_ELASTICSEARCH_API_KEY_ID` and
  `PGSYNC_ELASTICSEARCH_API_KEY`: restricted runtime API-key parts returned by
  Elasticsearch.
- `PGSYNC_BOOTSTRAP_DB_USER` and `PGSYNC_BOOTSTRAP_DB_PASSWORD`: one-time
  database owner/bootstrap credential.
- `PGSYNC_DB_USER` and `PGSYNC_DB_PASSWORD`: runtime logical-replication role.
- Existing `TIMESCALE_DATABASE` and `VALKEY_PASSWORD` values. Compose exposes
  the former to PGSync internally as `POSTGRES_DB` for schema substitution.

The PGSync container connects only through the private Compose network. None of
PGSync, Elasticsearch, or Valkey should have a public port.

## PostgreSQL preflight

Run `monitoring.sql` and record the results before restarting or bootstrapping.
Also record the PostgreSQL version, deployment method, free space on the volume
containing `pg_wal`, and all other replication consumers.

The proposed settings are:

```text
wal_level=logical
max_replication_slots=5
max_wal_senders=5
max_slot_wal_keep_size=5GB
```

PGSync normally creates two permanent slots, one per physical index. During
startup validation it briefly creates and removes `_tmp_`. Five slots leave
room for those three plus two unused slots only when PostgreSQL has no other
replication consumers. If the preflight finds existing slots, raise the limit
enough to preserve every existing consumer, both PGSync slots, the temporary
slot, and at least one additional slot. The values are capacity limits; they do
not create five slots or five sender processes.

The 5 GB WAL limit favors PostgreSQL availability over surviving a long PGSync
outage. Alert at 2.5 GB retained WAL and escalate at 4 GB. Crossing the limit
can invalidate a lagging slot at a checkpoint; an invalidated slot requires a
controlled full reindex. `wal_level`, `max_replication_slots`, and
`max_wal_senders` require a PostgreSQL restart when their current values differ.
Report the preflight findings before performing that restart.

## Host preparation

Elasticsearch uses many memory-mapped Lucene segments. Verify the host value:

```bash
sysctl vm.max_map_count
```

Set it to at least `1048576` when lower and persist the setting through host
reboots. This is a count of permitted virtual-memory mappings, not preallocated
RAM. The Compose service separately sets the required open-file and memory-lock
ulimits.

Confirm Elasticsearch's persistent Docker volume is backed up or can be
discarded and rebuilt from PostgreSQL. Valkey uses AOF and its existing volume;
document its normal host-volume backup procedure before deployment.

## Database roles

Use a dedicated bootstrap login only for the administrative command. PGSync
bootstrap creates and drops triggers while preparing the schema, so this role
must be a member of the role that owns `public.basic_player` and
`public.basic_clan` (or otherwise have equivalent owner-level administrative
authority), have `CREATE` on `public`, and have `REPLICATION`.

The runtime login needs `LOGIN REPLICATION`, `CONNECT` on the database, `USAGE`
on `public`, and `SELECT` on `basic_player`, `basic_clan`, and the bootstrap-created
`public._view`. PGSync 7.2.0 also creates and drops a temporary `_tmp_` logical
slot during startup validation, which is why the runtime role still requires
`REPLICATION`. It does not need permanent schema-DDL or table-write privileges.
Validate these grants with the final PostgreSQL version before deployment.

After bootstrap, record the created objects and remove the bootstrap secret
from the continuously running PGSync service. The Compose service uses only the
runtime credential.

## Build and start dependencies

The upstream registry does not publish a usable amd64 `7.2.0` image, and its
current `latest` manifest is arm64-only. Compose therefore follows PGSync's own
Dockerfile pattern and installs directly from GitHub. The source is pinned to
commit `d438650e6b6a046505e847a604d5be0e9338f2d6`, the commit behind release
`7.2.0`, and the build fails if the installed package reports another version.
The Python base image is also digest-pinned.

Run Compose commands from `database/` and include the service files together:

```bash
docker compose \
  -f docker-compose.timescale.yml \
  -f docker-compose.valkey.yml \
  -f docker-compose.elasticsearch.yml \
  -f docker-compose.pgsync.yml \
  build pgsync

docker compose \
  -f docker-compose.timescale.yml \
  -f docker-compose.valkey.yml \
  -f docker-compose.elasticsearch.yml \
  up -d elasticsearch
```

Do not start PGSync yet.

## Create Elasticsearch indexes and runtime key

Using a secret-enabled administrative client on the private network:

1. `PUT /clashking_players_v1` with
   `indexes/clashking_players_v1.json` as the body.
2. `PUT /clashking_clans_v1` with
   `indexes/clashking_clans_v1.json` as the body.
3. `POST /_security/api_key` with `elasticsearch-api-key.json` as the body.
4. Store the returned `id` and `api_key` in the two Coolify runtime secrets.

The mappings are `dynamic: strict`. PGSync adds `_meta` to each document source,
so `_meta` is explicitly present with `enabled: false`. Root table fields remain
flat, for example `name` and `clan_tag`; they are not nested below the table name.

This exact shape was checked against Elasticsearch 8.19.17 using a document
produced by PGSync 7.2.0's root-node transform:

```json
{
  "_id": "#TEST",
  "_source": {
    "_meta": {"basic_player": {"tag": ["#TEST"]}},
    "tag": "#TEST",
    "name": "Test Player",
    "league_id": 29000022,
    "clan_tag": "#CLAN",
    "townhall_level": 17
  }
}
```

Elasticsearch accepted the strict player and clan mappings and both generated
document shapes. `_meta` is PGSync relationship bookkeeping, not an application
search field; `enabled: false` retains it in `_source` without parsing or
indexing its contents.

Do not give the daemon the Elasticsearch administrator password. The API key is
restricted to the two v1 physical indexes. A separate administrative credential
will create or switch the stable aliases only after staging validation.

## One-time PGSync bootstrap

Export the bootstrap credentials into the invoking shell without printing them,
then pass them through as environment variables to the one-off container:

```bash
export PG_USER="${PGSYNC_BOOTSTRAP_DB_USER}"
export PG_PASSWORD="${PGSYNC_BOOTSTRAP_DB_PASSWORD}"

docker compose \
  -f docker-compose.timescale.yml \
  -f docker-compose.valkey.yml \
  -f docker-compose.elasticsearch.yml \
  -f docker-compose.pgsync.yml \
  run --rm \
  -e PG_USER \
  -e PG_PASSWORD \
  --entrypoint bootstrap \
  pgsync --config /config/schema.json

unset PG_USER PG_PASSWORD
```

Bootstrap is explicit and must not run on normal restarts. It creates:

- `public.table_notify()`;
- the `public._view` materialized view and its `_idx` unique index;
- `public_basic_player_notify`, `public_basic_player_truncate`,
  `public_basic_clan_notify`, and `public_basic_clan_truncate` triggers;
- one `test_decoding` logical slot for each configured physical index.

Slot names are derived from `<database>_<index>`, with unsupported characters
removed. Record the exact names from `pg_replication_slots` after bootstrap.

## Start the daemon and initial load

```bash
docker compose \
  -f docker-compose.timescale.yml \
  -f docker-compose.valkey.yml \
  -f docker-compose.elasticsearch.yml \
  -f docker-compose.pgsync.yml \
  up -d pgsync
```

The permanent command is exactly:

```text
pgsync --config /config/schema.json --daemon
```

Do not add PGSync's direct `--wal` option. PostgreSQL still uses logical WAL;
normal daemon mode additionally uses trigger-side configured-column filtering.
All roughly 50 million player rows are indexed initially. Battle-log tracking
membership is intentionally absent from `basic_player`; it is derived by the
tracking service and therefore cannot create irrelevant Elasticsearch updates.

Watch PostgreSQL load, retained WAL, PGSync logs, Elasticsearch heap/CPU/disk,
bulk failures, indexing rate, and shard sizes throughout the initial load. The
30-second refresh interval reduces refresh overhead while keeping the staging
index queryable.

With Redis database `1`, each schema entry gets independent queue and checkpoint
metadata keys derived from its database/index slot name. They have the form
`queue:<database>_clashking_players_v1[:meta]` and
`queue:<database>_clashking_clans_v1[:meta]`; do not share or manually copy
checkpoint metadata between them.

## Repository smoke-test result

A disposable local Postgres 18, Valkey 8, Elasticsearch 8.19.17, and the built
PGSync 7.2.0 image were used to exercise this exact configuration. Bootstrap
created the materialized view, index, function, four triggers, and two
`test_decoding` slots listed above. Initial sync produced one flat document for
each table in 0.58 seconds.

Configured-field updates advanced Elasticsearch `_seq_no`; player `trophies`
and clan `last_active`/`description`
updates left `_seq_no` unchanged. Player autocomplete with combined clan, town
hall, and league filters returned the row, using the clan tag as the `name`
query returned no row, and PostgreSQL deletes removed both Elasticsearch
documents. This is a configuration smoke test, not staging load, recovery, or
resource validation for the 50-million-row dataset.

## Required validation

Save timestamps, SQL/Elasticsearch queries, PGSync logs, and before/after
Elasticsearch `_seq_no` values for each case.

Player validation:

- Insert, rename, change town hall, change league, change clan, and delete a
  staging player; verify every corresponding document change.
- Change only `trophies`; verify `_seq_no` does not change.
- Use a `bool.must` `match` query on `name`, with optional `bool.filter` `terms`
  clauses on `clan_tag`, `townhall_level`, and `league_id`.
- Verify one and multiple clan tags, independent and combined numeric filters,
  and that a clan tag supplied as the name query produces no name match.
- Verify exact lookup through `_id` and through `tag`. `_id` preserves the
  PostgreSQL spelling; the `tag` keyword field lowercases query and indexed terms.

Clan validation:

- Insert, rename, change each filterable field, change `badge_token`, and delete
  a staging clan; verify every corresponding document change.
- Change only `last_active`, then another omitted field; verify `_seq_no` does
  not change.
- Use a `match` query only on `name`, with exact/range filters for clan level,
  location, CWL league, and member count, independently and together.
- Confirm `badge_token` is returned in `_source` but cannot be searched or used
  for sorting/aggregation.

Recovery validation:

- Stop PGSync, commit source changes, restart it, and verify catch-up.
- Stop Elasticsearch, commit changes, restore it, and verify catch-up.
- Restart PGSync, Valkey, Elasticsearch, and PostgreSQL independently.
- Delete staging rows before a restart and verify they are not resurrected.
- Temporarily apply an Elasticsearch write block, generate a relevant source
  update, and verify PGSync reports the bulk failure. Remove the block, restart
  PGSync if required, and prove the update is delivered before accepting the
  checkpoint behavior.
- Compare `COUNT(*)` for both PostgreSQL tables with Elasticsearch `_count` and
  compare a random sample field-by-field. Elasticsearch `_meta` is expected and
  is not a PostgreSQL business field.
- Measure initial indexing throughput, steady-state change lag, PostgreSQL CPU,
  query latency, connection count, WAL generation, Elasticsearch heap/CPU/disk,
  and Valkey queue size under representative tracking traffic.

Do not mark staging validated until all cases have recorded evidence.

## Monitoring

Monitor and alert on:

- PGSync container state, restarts, and bulk/indexing errors;
- both slot states, `wal_status`, and retained WAL bytes from `monitoring.sql`;
- 2.5 GB/4 GB retained-WAL thresholds and PostgreSQL free disk;
- Valkey availability, AOF persistence errors, and PGSync queue length;
- Elasticsearch cluster health, JVM heap, disk watermarks, rejected bulk work,
  and shard size;
- PostgreSQL/Elasticsearch count drift and sampled-document drift;
- measured end-to-end change lag using periodic staging canary updates.

PGSync consumes logical changes through SQL functions, so a slot's `active`
flag can be transiently false; alerting must combine slot presence, WAL growth,
daemon health, queue depth, and canary lag rather than relying on `active` alone.

## Reindex and rollback

For a new mapping, create `clashking_players_v2` or `clashking_clans_v2` with a
new PGSync schema entry. Populate and validate it while v1 remains available.
After validation, atomically switch `clashking_players` or `clashking_clans` to
v2, keep v1 temporarily, and switch the alias back if rollback is required.
Extend or replace the runtime API key so it grants the same narrow privileges
to the specific v2 index before starting that reindex; the v1 key deliberately
does not grant wildcard access to future physical indexes.

PGSync's function, metadata view, and table triggers are shared between schema
entries. Bootstrap the complete desired configuration when adding/removing an
entry; do not run a one-index teardown against a live configuration. After the
rollback window, deliberately remove the old schema entry, slot, checkpoint
keys, and physical index, then bootstrap the complete remaining configuration.

An invalidated/deleted slot or an untrusted checkpoint requires a controlled
full reindex into a new physical version. Never advance a slot or checkpoint by
guessing.
