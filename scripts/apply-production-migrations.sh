#!/usr/bin/env bash
# Invoked only by the protected production job. No down/reset/arbitrary target.
set -euo pipefail
set +x
[[ ${GITHUB_ACTIONS:-} == true && ${GITHUB_REPOSITORY:-} == ClashKingInc/DevKit && ${GITHUB_REF:-} == refs/heads/main && ${GITHUB_EVENT_NAME:-} == workflow_dispatch ]] || { echo 'Protected manual main workflow required.' >&2; exit 1; }
[[ ${EXPECTED_SHA:-} == "$(git rev-parse HEAD)" && ${CONFIRMATION:-} == apply-006-to-007 ]] || { echo 'Commit or confirmation mismatch.' >&2; exit 1; }
: "${PRODUCTION_DATABASE_URL:?Production environment database secret is required}"
[[ $(goose -version 2>&1) == 'goose version: v3.26.0' ]] || { echo 'Goose v3.26.0 required.' >&2; exit 1; }
# Never accept inherited Goose settings or put the credential in process arguments.
unset GOOSE_MIGRATION_DIR GOOSE_TABLE GOOSE_DBSTRING GOOSE_DRIVER
export GOOSE_DRIVER=postgres GOOSE_DBSTRING="$PRODUCTION_DATABASE_URL"
unset PRODUCTION_DATABASE_URL
migration_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/database/timescale"
version() {
 local output
 output="$(goose -env /dev/null -dir "$migration_root" version 2>&1)" || { echo 'Cannot read Goose version.' >&2; return 1; }
 [[ $output =~ goose:[[:space:]]version[[:space:]]([0-9]+) ]] || { echo 'Unrecognized Goose version response.' >&2; return 1; }
 printf '%s' "${BASH_REMATCH[1]}"
}
[[ $(version) == 6 ]] || { echo 'Expected database version 006; refusing migration or retry.' >&2; exit 1; }
goose -env /dev/null -dir "$migration_root" validate
# Bound lock waits; migration stays transactional. Budget for leaderboard rebuild.
export PGOPTIONS='-c lock_timeout=10s -c statement_timeout=1200000'
goose -env /dev/null -dir "$migration_root" -timeout 20m up-to 7
[[ $(version) == 7 ]] || { echo 'Post-migration version verification failed.' >&2; exit 1; }
printf 'Applied Goose 006 -> 007 at commit %s\n' "$EXPECTED_SHA"
