# Selectively restored local API fixture

Source snapshot: `4608b2af8c4321f8c76d44e697ffbd0f0fe7f713`, from the original
Schema repository. This is an independent, selectively populated repository,
not a linked worktree or a production-ready migration branch. The original
checkout and archived snapshot refs remain unchanged. `FETCH_HEAD` identifies
the source; no commit or branch was created.

The user approved restoring the test setup and migrations required by retained
API features. The harness now requires `--profile retained-api`; it does not
support the old blanket `--through 27` command.

| Source migrations | Retained purpose |
| --- | --- |
| 001–003 | Original statistics, settings and tracking observability |
| 004–006 | Existing developer API management and intentionally retired consent/auth storage transitions |
| 007, 009, 010 | Preserved app updates, Capital Gold and rollback fields |
| 008 | Existing Discord cache |
| 012 | Ownership of Discord resources created by existing Dashboard handlers |
| 013, 020 | Coordination for retained account/link mutations |
| 022 | Retained billing mutation coordination |
| 023 | Retained roster AI usage settlement |
| 027 | Explicitly approved server linking-token setting, OFF by default |

The harness copies only these exact source files into a private temporary
directory and runs Goose against them. Numeric gaps are intentional in this
disposable test profile; this is **not** a proposed production migration order.
The migration SQL is unchanged. No denied/deferred migration payload was
reconstructed. Migration 017 remains excluded because it requires a deferred
runtime table. The API uses the original ticket settings instead.

The fixture creates only a fresh local Docker container, pinned Timescale image,
tmpfs storage, deterministic test credentials and a random loopback port. It
rejects remote Docker hosts and ignores inherited Goose connection settings.
Cleanup removes only its returned container ID and its generated migration-copy
directory, including on test failure. No Compose service, host volume or
production connection is used. The original Admin allowlist/bootstrap is absent.

Run the harness tests with `node --test scripts/with-test-timescale.test.mjs`.
From the independent API copy, run
`bash scripts/test-postgres.sh --keep-going ../clashking_schemas` with the
repository's Node/npm toolchain, Docker and Goose on PATH. Every retained test
file receives a separate database. The API manifest classifies all archived SQL
suites and fails on unreviewed additions or missing files.

September 4 validation: all nine harness tests passed, followed by the full
retained run of 35 isolated API PostgreSQL suites, covering 130 cases. Deferred
suites were excluded explicitly, not silently skipped as successes. The local
run removed its disposable containers after each suite; no production or
original-checkout migration was applied.
