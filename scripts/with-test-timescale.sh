#!/usr/bin/env bash
# Run one integration suite against an isolated, Goose-migrated Timescale database.
set -euo pipefail

if [[ ${1:-} != --profile || ( ${2:-} != retained-api && ${2:-} != baseline-006 ) ]]; then
  echo 'An explicit --profile retained-api or baseline-006 is required.' >&2
  exit 2
fi
fixture_profile="$2"
shift 2
if [[ ${1:-} != -- || $# -lt 2 ]]; then
  echo 'Usage: bash scripts/with-test-timescale.sh --profile retained-api -- COMMAND [ARG ...]' >&2
  exit 2
fi
shift

fixture_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$fixture_root/scripts/retained-api-profile.sh"
if [[ $fixture_profile == baseline-006 ]]; then
  fixture_sources=("${fixture_sources[@]:0:6}")
fi
fixture_container=''
fixture_child=''
fixture_migrations=''
fixture_data_dir=''
fixture_timescale_storage="${CLASHKING_FIXTURE_TIMESCALE_STORAGE:-tmpfs}"
if [[ $fixture_timescale_storage == tmpfs ]]; then
  fixture_timescale_mount='type=tmpfs,destination=/var/lib/postgresql'
elif [[ $fixture_timescale_storage == disk ]]; then
  if [[ -n ${CLASHKING_FIXTURE_TIMESCALE_TMPFS_SIZE:-} ]]; then
    echo 'CLASHKING_FIXTURE_TIMESCALE_TMPFS_SIZE cannot be used with disk storage.' >&2
    exit 2
  fi
  fixture_data_dir="$(mktemp -d "${TMPDIR:-/tmp}/clashking-timescale-data.XXXXXX")"
  fixture_timescale_mount="type=bind,source=$fixture_data_dir,destination=/var/lib/postgresql"
else
  echo 'CLASHKING_FIXTURE_TIMESCALE_STORAGE must be tmpfs or disk.' >&2
  exit 2
fi
if [[ $fixture_timescale_storage == tmpfs && -n ${CLASHKING_FIXTURE_TIMESCALE_TMPFS_SIZE:-} ]]; then
  if [[ ! $CLASHKING_FIXTURE_TIMESCALE_TMPFS_SIZE =~ ^[1-9][0-9]*$ ]]; then
    echo 'CLASHKING_FIXTURE_TIMESCALE_TMPFS_SIZE must be a positive byte count.' >&2
    exit 2
  fi
  fixture_timescale_mount+=",tmpfs-size=$CLASHKING_FIXTURE_TIMESCALE_TMPFS_SIZE"
fi
# Copy only these authoritative files, unchanged, into a private Goose directory.
# Do not discover or apply other migrations just because a snapshot has them.
for fixture_source in "${fixture_sources[@]}"; do
  if [[ ! -f $fixture_root/database/timescale/$fixture_source ]]; then
    echo "Missing retained API migration: $fixture_source" >&2
    exit 1
  fi
done

for fixture_tool in docker goose; do
  command -v "$fixture_tool" >/dev/null || { echo "Required tool missing: $fixture_tool" >&2; exit 1; }
done

# Do not create test containers on a remote/production Docker context.
fixture_endpoint="${DOCKER_HOST:-$(docker context inspect --format '{{.Endpoints.docker.Host}}')}"
if [[ $fixture_endpoint != unix://* || -n ${DOCKER_CONTEXT:-} && -n ${DOCKER_HOST:-} ]]; then
  echo 'The fixture requires a local Unix-socket Docker context without conflicting overrides.' >&2
  exit 1
fi
export DOCKER_HOST="$fixture_endpoint"
unset DOCKER_CONTEXT

cleanup() {
  fixture_status=$?
  trap - EXIT INT TERM
  if [[ -n $fixture_child ]]; then
    kill "$fixture_child" 2>/dev/null || true
    wait "$fixture_child" 2>/dev/null || true
  fi
  if [[ -n $fixture_container ]]; then
    fixture_actual_run_id="$(docker inspect --format '{{ index .Config.Labels "io.clashking.fixture.run" }}' "$fixture_container" 2>/dev/null || true)"
    if [[ $fixture_actual_run_id != "$fixture_run_id" ]]; then
      echo "Fixture cleanup refused: container $fixture_container is not owned by run $fixture_run_id" >&2
      fixture_status=1
    elif ! docker rm --force --volumes "$fixture_container" >/dev/null; then
      echo "Fixture cleanup failed for container $fixture_container" >&2
      fixture_status=1
    fi
  fi
  if [[ -n $fixture_migrations ]]; then
    # mktemp generated this exact directory; it contains copies, never originals.
    rm -r -- "$fixture_migrations" || fixture_status=1
  fi
  if [[ -n $fixture_data_dir ]]; then
    # mktemp generated this exact disk-backed PostgreSQL directory.
    rm -r -- "$fixture_data_dir" || fixture_status=1
  fi
  exit "$fixture_status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

fixture_migrations="$(mktemp -d "${TMPDIR:-/tmp}/clashking-retained-migrations.XXXXXX")"
fixture_run_id="${CLASHKING_FIXTURE_RUN_ID:-${fixture_migrations##*.}}"
if [[ ! $fixture_run_id =~ ^[A-Za-z0-9]+$ ]]; then
  echo 'Fixture run ID is not safe for a Docker label.' >&2
  exit 1
fi
for fixture_source in "${fixture_sources[@]}"; do
  cp -- "$fixture_root/database/timescale/$fixture_source" "$fixture_migrations/$fixture_source"
done

fixture_container="$(docker run --detach \
  --label "io.clashking.fixture=timescale-$fixture_run_id" \
  --label "io.clashking.fixture.run=$fixture_run_id" \
  --label io.clashking.fixture.owner=with-test-timescale \
  --mount "$fixture_timescale_mount" \
  --publish 127.0.0.1::5432 \
  --env POSTGRES_DB=clashking_test \
  --env POSTGRES_USER=clashking_test \
  --env POSTGRES_PASSWORD=clashking_test \
  "$fixture_image")"
if [[ ! $fixture_container =~ ^[a-f0-9]{64}$ ]]; then
  fixture_container=''
  echo 'Docker did not return a valid container ID; refusing an ambiguous cleanup target.' >&2
  exit 1
fi

fixture_ready=false
for ((fixture_attempt=0; fixture_attempt<60; fixture_attempt++)); do
  # The image starts a temporary Unix-socket-only server during initialization.
  # Require TCP readiness so Goose cannot race that server's shutdown.
  if docker exec "$fixture_container" pg_isready -h 127.0.0.1 -U clashking_test -d clashking_test >/dev/null 2>&1; then
    fixture_ready=true
    break
  fi
  sleep 0.5
done
if [[ $fixture_ready != true ]]; then
  echo 'Disposable Timescale did not become ready within 30 seconds.' >&2
  docker logs "$fixture_container" >&2
  exit 1
fi

fixture_address="$(docker port "$fixture_container" 5432/tcp)"
if [[ ! $fixture_address =~ ^127\.0\.0\.1:([0-9]+)$ ]]; then
  echo 'Disposable Timescale must expose exactly one loopback port.' >&2
  exit 1
fi
fixture_port="${BASH_REMATCH[1]}"

# These are public deterministic TEST credentials, never production credentials.
export TEST_DATABASE_URL="postgres://clashking_test:clashking_test@127.0.0.1:${fixture_port}/clashking_test?sslmode=disable"
export TEST_TIMESCALE_DSN="$TEST_DATABASE_URL"
export CLASHKING_DISPOSABLE_TIMESCALE=1
export CLASHKING_TIMESCALE_PROFILE="$fixture_profile"
export TEST_ADMIN_ACCESS_SUBJECT='00000000-0000-4000-8000-000000000001'
export TEST_ADMIN_EMAIL='owner@example.test'

# Explicit CLI connection + disabled dotenv loading prevent inherited production
# configuration from affecting migration execution. Never accept a caller DSN.
unset GOOSE_DBSTRING GOOSE_DRIVER GOOSE_MIGRATION_DIR GOOSE_TABLE ADMIN_OWNER_BOOTSTRAP_B64
goose -env /dev/null -dir "$fixture_migrations" validate
goose -env /dev/null -dir "$fixture_migrations" postgres "$TEST_DATABASE_URL" up
goose -env /dev/null -dir "$fixture_migrations" postgres "$TEST_DATABASE_URL" status

echo 'Disposable Timescale has the requested migration profile; running integration command.' >&2
# Preserve the caller cwd, arguments, exit status, and ordinary output.
"$@" &
fixture_child=$!
set +e
wait "$fixture_child"
fixture_result=$?
fixture_child=''
exit "$fixture_result"
