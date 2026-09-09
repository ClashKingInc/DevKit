#!/usr/bin/env bash
# Run one integration command against isolated canonical Timescale and Valkey fixtures.
set -euo pipefail

if [[ ${1:-} != --profile || ( ${2:-} != retained-api && ${2:-} != baseline-006 ) ]]; then
  echo 'An explicit --profile retained-api or baseline-006 is required.' >&2
  exit 2
fi
integration_profile="$2"
shift 2
if [[ ${1:-} != -- || $# -lt 2 ]]; then
  echo 'Usage: bash scripts/with-test-integration.sh --profile retained-api -- COMMAND [ARG ...]' >&2
  exit 2
fi
shift

integration_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
integration_valkey_image='valkey/valkey:8'
integration_valkey_container=''
integration_child=''
integration_state_dir=''
integration_run_id=''

command -v docker >/dev/null || { echo 'Required tool missing: docker' >&2; exit 1; }

# Refuse to create even a temporary cache on a remote or ambiguous Docker context.
integration_endpoint="${DOCKER_HOST:-$(docker context inspect --format '{{.Endpoints.docker.Host}}')}"
if [[ $integration_endpoint != unix://* || -n ${DOCKER_CONTEXT:-} && -n ${DOCKER_HOST:-} ]]; then
  echo 'The integration fixture requires a local Unix-socket Docker context without conflicting overrides.' >&2
  exit 1
fi
export DOCKER_HOST="$integration_endpoint"
unset DOCKER_CONTEXT

cleanup() {
  integration_status=$?
  trap - EXIT INT TERM
  if [[ -n $integration_child ]]; then
    kill "$integration_child" 2>/dev/null || true
    wait "$integration_child" 2>/dev/null || true
  fi
  if [[ -n $integration_valkey_container ]]; then
    integration_actual_run_id="$(docker inspect --format '{{ index .Config.Labels "io.clashking.fixture.run" }}' "$integration_valkey_container" 2>/dev/null || true)"
    if [[ $integration_actual_run_id != "$integration_run_id" ]]; then
      echo "Integration cleanup refused: Valkey container $integration_valkey_container is not owned by run $integration_run_id" >&2
      integration_status=1
    elif ! docker rm --force --volumes "$integration_valkey_container" >/dev/null; then
      echo "Integration cleanup failed for Valkey container $integration_valkey_container" >&2
      integration_status=1
    fi
  fi
  if [[ -n $integration_state_dir ]]; then
    rm -r -- "$integration_state_dir" || integration_status=1
  fi
  exit "$integration_status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

integration_state_dir="$(mktemp -d "${TMPDIR:-/tmp}/clashking-integration-run.XXXXXX")"
integration_run_id="${integration_state_dir##*.}"
if [[ ! $integration_run_id =~ ^[A-Za-z0-9]+$ ]]; then
  echo 'Integration run ID is not safe for a Docker label.' >&2
  exit 1
fi
export CLASHKING_FIXTURE_RUN_ID="$integration_run_id"
printf '%s\n' "$integration_run_id" > "$integration_state_dir/run-id"

integration_valkey_container="$(docker run --detach \
  --label "io.clashking.fixture=valkey-$integration_run_id" \
  --label "io.clashking.fixture.run=$integration_run_id" \
  --label io.clashking.fixture.owner=with-test-integration \
  --mount type=tmpfs,destination=/data \
  --publish 127.0.0.1::6379 \
  "$integration_valkey_image" \
  valkey-server --save '' --appendonly no)"
if [[ ! $integration_valkey_container =~ ^[a-f0-9]{64}$ ]]; then
  integration_valkey_container=''
  echo 'Docker did not return a valid Valkey container ID; refusing an ambiguous cleanup target.' >&2
  exit 1
fi
printf '%s\n' "$integration_valkey_container" > "$integration_state_dir/valkey-container-id"

integration_valkey_ready=false
for ((integration_attempt=0; integration_attempt<60; integration_attempt++)); do
  if docker exec "$integration_valkey_container" valkey-cli ping 2>/dev/null | grep -qx PONG; then
    integration_valkey_ready=true
    break
  fi
  sleep 0.25
done
if [[ $integration_valkey_ready != true ]]; then
  echo 'Disposable Valkey did not become ready within 15 seconds.' >&2
  docker logs "$integration_valkey_container" >&2
  exit 1
fi

integration_valkey_address="$(docker port "$integration_valkey_container" 6379/tcp)"
if [[ ! $integration_valkey_address =~ ^127\.0\.0\.1:([0-9]+)$ ]]; then
  echo 'Disposable Valkey must expose exactly one loopback port.' >&2
  exit 1
fi
integration_valkey_port="${BASH_REMATCH[1]}"

export CLASHKING_DISPOSABLE_VALKEY=1
export TEST_VALKEY_ADDR="127.0.0.1:${integration_valkey_port}"
export TEST_VALKEY_URL="redis://${TEST_VALKEY_ADDR}"
# Tracking reads host and port separately. Override inherited values so a test
# cannot accidentally connect to a retained or production cache.
export VALKEY_HOST=127.0.0.1
export VALKEY_PORT="$integration_valkey_port"
unset VALKEY_PASSWORD

echo 'Disposable Valkey is ready; starting the canonical Timescale fixture.' >&2
bash "$integration_root/scripts/with-test-timescale.sh" --profile "$integration_profile" -- "$@" &
integration_child=$!
set +e
wait "$integration_child"
integration_result=$?
integration_child=''
exit "$integration_result"
