# Retained API database fixture

The canonical Goose sequence is `database/timescale/001` through `011`.
Production was confirmed by the user to be at 006 before consolidation; files
001–006 are unchanged. `007_worker_api.sql` combines the unapplied Worker/API
migrations formerly numbered 007, 008, 009, 010, 012, 013, 020, 022, 023, 027 and
028 into one transaction, excluding the user-rejected player-link mutex, global
AI-budget mutex, subject mutex, resource ownership ledger and Discord delivery receipt tables. Its Down operation is intentionally irreversible.

`008_ranked_battle_history.sql` adds the one-year farming and two-perspective Ranked/Legend histories, immutable normalized army compositions, and the final `ranked_league_group_members` source-counter shape. `009_league_army_analytics.sql` adds permanent league/Legend rollups and immutable army-family assignments. Both have structural Down paths, but 008 cannot recreate stale duplicate season memberships removed before it enforces one group per player and season. `010_cwl_season_statistics.sql` remains the independent, reversible CWL population summary, and 011 adds active verified-player state. See `docs/ranked-battle-history.md` for every column and lifecycle.

`bash scripts/with-test-timescale.sh --profile retained-api -- COMMAND [ARG ...]`
applies the complete canonical sequence to a fresh local tmpfs Timescale
container. The API's existing retained-api invocation is unchanged.
`--profile baseline-006` applies only the immutable baseline for upgrade tests:

Cross-process tests that also require Valkey use the repository-owned wrapper:

```sh
bash scripts/with-test-integration.sh --profile retained-api -- COMMAND [ARG ...]
```

It starts an unauthenticated disposable Valkey on a random loopback port, exports
`TEST_VALKEY_ADDR`, `TEST_VALKEY_URL`, `VALKEY_HOST`, and `VALKEY_PORT`, then
delegates Timescale creation and migration to `with-test-timescale.sh`. Both
containers use tmpfs storage and are removed after the child exits. The wrapper
never reads or reuses retained Valkey coordinates.

```sh
node --test scripts/with-test-timescale.test.mjs scripts/with-test-integration.test.mjs
cd database
bash ../scripts/with-test-timescale.sh --profile baseline-006 -- go test ./schema -run TestWorkerAPIUpgrade -count=1 -v
```

Both profiles reject remote Docker hosts, use deterministic test credentials and
a random loopback port, ignore inherited Goose connection settings, and remove
only their own container and temporary migration directory. There is no volume
reset, production connection, or migration ceiling supplied by the caller.

Old disposable fixtures at any prior 007–028 version must be recreated through
the harness. Do not rename Goose history rows or apply this consolidation over
such a database. Any persistent installation beyond 006 needs separate review.

007 includes stable ticket panel/button IDs, editable panel names and archival,
without rewriting existing Discord custom IDs or adding deferred runtime tables.
See `docs/worker-api-schema.md` for required consumer changes. The original 017
proposal remains verbatim in docs/deferred as a historical reference.

The fixture is local validation, not evidence that production has been upgraded.
