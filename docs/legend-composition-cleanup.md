# Legend-only composition rollout

1. Apply Goose migration 012. It changes constraints/triggers only; it deletes no data. Family foreign keys, update immutability, and the no-truncate trigger remain.
2. Deploy Tracking's Legend-only composition writer. The old writer remains compatible with 012 during rollout.
3. Wait for operator confirmation of that deployment. Run dry-run from the local machine against production via an SSH tunnel.
4. Before apply, pause all battle ingestion and family closeouts for the duration of cleanup. This is required because the protected Legend-hash set is computed once. A live writer could otherwise introduce a reference after that snapshot. Resume workers afterward.

From `database/`, with the existing migration connection environment pointing to the intended database:

```sh
go run migrations/cleanup_army_compositions.go
```

Only after deployment confirmation, pausing writers, and reviewing the candidate count:

```sh
ARMY_COMPOSITION_CLEANUP_APPLY=true ARMY_COMPOSITION_WRITERS_PAUSED=true \
go run migrations/cleanup_army_compositions.go
```

The script uses temporary protected/candidate hash tables, a singleton advisory lock, a 5-second lock timeout, a 120-second statement timeout, and independently committed batches of 1,000 deletes. Batch size can be set to 1–5,000 with `ARMY_COMPOSITION_CLEANUP_BATCH_SIZE`. It does not delete battle rows, change schemas, rewrite tables, or run VACUUM FULL. An interrupted run is safe to restart while writers remain paused. Existing family references are rechecked and protected by foreign keys. The final check verifies all protected hashes remain.

Regular vacuum can reuse freed space internally. Returning space to the filesystem is deliberately outside this operation. Rolling migration 012 back requires restoring compositions for all retained raw battle hashes first; Goose Down fails transactionally if those references are missing.
