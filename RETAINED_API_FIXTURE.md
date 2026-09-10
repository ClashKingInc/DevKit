# Retained API database fixture

The canonical Goose sequence is `database/timescale/001` through `016`.
Production was confirmed by the user to be at 006 before consolidation; files
001–006 are unchanged. `007_worker_api.sql` combines the unapplied Worker/API
migrations formerly numbered 007, 008, 009, 010, 012, 013, 020, 022, 023, 027 and
028 into one transaction, excluding the user-rejected player-link mutex, global
AI-budget mutex, subject mutex, resource ownership ledger and Discord delivery receipt tables. Its Down operation is intentionally irreversible.

`008_ranked_battle_history.sql` adds the one-year farming and two-perspective Ranked/Legend histories, immutable normalized army compositions, and the final `ranked_league_group_members` source-counter shape. `009_league_army_analytics.sql` adds permanent league/Legend rollups and immutable army-family assignments. Both have structural Down paths, but 008 cannot recreate stale duplicate season memberships removed before it enforces one group per player and season. Migration 010 remains immutable history, 011 adds active verified-player state, and 016 removes the rejected CWL-only population summary. See `docs/ranked-battle-history.md` for every retained analytics column and lifecycle, and `docs/cwl-season-statistics-removal.md` for the consumer cutover.

`bash scripts/with-test-timescale.sh --profile retained-api -- COMMAND [ARG ...]`
applies the complete canonical sequence to a fresh local tmpfs Timescale
container. The API's existing retained-api invocation is unchanged.
`--profile baseline-006` applies only the immutable baseline for Worker/API upgrade tests. `--profile baseline-013` applies through the deployed battle identity so migration 014 cleanup 015 conversion and rollback behavior can be tested with populated data:

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
bash ../scripts/with-test-timescale.sh --profile baseline-013 -- go test ./schema -run TestArmyCodeFamilyCompatibilityMigration -count=1 -v
```

Both profiles reject remote Docker hosts, use deterministic test credentials and
a random loopback port, ignore inherited Goose connection settings, and remove
only their own container and temporary migration directory. There is no volume
reset, production connection, or migration ceiling supplied by the caller.

Old disposable fixtures at any prior 007–028 version must be recreated through
the harness. Do not rename Goose history rows or apply this consolidation over
such a database. Any persistent installation beyond 006 needs separate review.


Migrations 014 and 015 are intentionally not one automatic production step.
Apply 014, pause the old battle writer, run the default-dry-run
`database/migrations/clear_ranked_defense_loot.go` companion until it verifies
zero remaining defense rows, then apply 015 and deploy compatible binaries before
resuming ingestion. The companion requires Goose version 14 exactly, refuses
compressed chunks, uses bounded committed batches, and never changes attack
loot. No fixture run is evidence that this sequence has run in production.

007 leaves all 006 ticket tables and data unchanged. Stable panel/button IDs,
editable names, archival, and stricter component validation remain deferred
until the Bot rewrite resolves legacy Discord component IDs and duplicate
custom IDs. The proposal remains in docs/deferred as reference material.

The fixture is local validation, not evidence that production has been upgraded.
