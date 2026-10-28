#!/usr/bin/env bash
# Full legacy Mongo -> migration programs -> canonical PostgreSQL check.
set -euo pipefail
[[ ${CLASHKING_DISPOSABLE_TIMESCALE:-} == 1 ]] || exit 2
[[ ${TEST_DATABASE_URL:-} == postgres://clashking_test:clashking_test@127.0.0.1:*/clashking_test?sslmode=disable ]] || exit 2
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
run_dir=$(mktemp -d "${TMPDIR:-/tmp}/ck-donation-import.XXXXXX")
run_id=${run_dir##*.}
container=''
cleanup() {
  status=$?
  if [[ -n $container ]]; then
    actual=$(docker inspect --format '{{ index .Config.Labels "io.clashking.donation-import" }}' "$container")
    [[ $actual == "$run_id" ]] && docker rm --force --volumes "$container" >/dev/null
  fi
  rm -r -- "$run_dir"
  exit "$status"
}
trap cleanup EXIT
endpoint=${DOCKER_HOST:-$(docker context inspect --format '{{.Endpoints.docker.Host}}')}
[[ $endpoint == unix://* ]] || { echo 'Requires local Docker socket' >&2; exit 2; }
export DOCKER_HOST="$endpoint"
unset DOCKER_CONTEXT
# MongoDB 8 refuses newer runner kernels (SERVER-121912). This legacy-import
# fixture needs no 8-specific features; pin the compatible 7.x multi-arch image.
# This only selects the disposable test source, never a deployment database.
container=$(docker run --detach --label "io.clashking.donation-import=$run_id" --publish 127.0.0.1::27017 mongo:7@sha256:8bb4442761a63a8dda452744082cdac9644b429807eb977b42324a63cef59ca4)
ready=false
for ((i=0;i<60;i++)); do
  if [[ $(docker inspect --format '{{.State.Running}}' "$container") != true ]]; then
    echo 'Disposable Mongo exited before becoming ready:' >&2
    docker inspect --format '{{json .State}}' "$container" >&2
    docker logs "$container" >&2
    exit 1
  fi
  if docker exec "$container" mongosh --quiet --eval 'db.runCommand({ping:1})' >/dev/null 2>&1; then ready=true; break; fi
  sleep 0.5
done
if [[ $ready != true ]]; then
  echo 'Disposable Mongo did not become ready within 30 seconds:' >&2
  docker logs "$container" >&2
  exit 1
fi
address=$(docker port "$container" 27017/tcp)
[[ $address =~ ^127\.0\.0\.1:([0-9]+)$ ]] || exit 2
mongo="mongodb://127.0.0.1:${BASH_REMATCH[1]}"
docker exec "$container" mongosh --quiet --eval '
const source=db.getSiblingDB("usafam");
source.server.insertOne({server:"99990002",name:"Import test",logs:{donations:{webhook:"999902",thread:"999912",enabled:true}}});
source.clans.insertOne({server:"99990002",tag:"#PYLQ",events:{war:true},logs:{donation_log:{webhook:"999903",thread:"999913",disabled:true}}});
' >/dev/null
psql "$TEST_DATABASE_URL" -v ON_ERROR_STOP=1 -c "INSERT INTO basic_clan(tag,name,public_war_log,war_wins,member_count,badge_token,troops_donated,troops_received) VALUES('#PYLQ','Imported Clan',true,0,0,'',0,0)"
(cd "$root/database" && go build -o "$run_dir/server-settings" ./migrations/server_settings.go && go build -o "$run_dir/server-clans" ./migrations/server_clans.go)
# The real programs locate an env file from their working directory. Give them
# an isolated root rather than reading any developer or production credentials.
mkdir -p "$run_dir/database/timescale"
touch "$run_dir/database/timescale/001_initial_stats.sql" "$run_dir/.env"
(cd "$run_dir/database" && env -i PATH="$PATH" HOME="$HOME" TIMESCALE_URL="$TEST_DATABASE_URL" STATIC_MONGODB="$mongo" STATS_MONGODB="$mongo" "$run_dir/server-settings")
(cd "$run_dir/database" && env -i PATH="$PATH" HOME="$HOME" TIMESCALE_URL="$TEST_DATABASE_URL" STATIC_MONGODB="$mongo" STATS_MONGODB="$mongo" "$run_dir/server-clans")
# Clan imports may be retried during a cutover. Existing matching boards must
# not multiply or replace the new board's message identity on a retry.
(cd "$run_dir/database" && env -i PATH="$PATH" HOME="$HOME" TIMESCALE_URL="$TEST_DATABASE_URL" STATIC_MONGODB="$mongo" STATS_MONGODB="$mongo" "$run_dir/server-clans")
psql "$TEST_DATABASE_URL" -v ON_ERROR_STOP=1 <<'SQL'
DO $$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM server_clans WHERE server_id='99990002' AND tag='#PYLQ' AND war_events_enabled) THEN RAISE EXCEPTION 'War event opt-in not preserved'; END IF;
 IF EXISTS(SELECT 1 FROM server_logs WHERE type='donation_log') THEN RAISE EXCEPTION 'Importer recreated donation log'; END IF;
 IF (SELECT count(*) FROM autoboards WHERE server_id='99990002')<>2 THEN RAISE EXCEPTION 'Missing or duplicated imported board'; END IF;
 IF NOT EXISTS(SELECT 1 FROM autoboards WHERE server_id='99990002' AND webhook_id='999902' AND thread_id='999912' AND target_scope='family' AND enabled AND message_id IS NULL) THEN RAISE EXCEPTION 'Family destination not preserved'; END IF;
 IF NOT EXISTS(SELECT 1 FROM autoboards a JOIN autoboard_targets t ON t.autoboard_id=a.id WHERE a.server_id='99990002' AND a.webhook_id='999903' AND a.thread_id='999913' AND NOT a.enabled AND t.target='#PYLQ') THEN RAISE EXCEPTION 'Disabled clan destination not preserved'; END IF;
END $$;
SQL
printf 'Legacy donation importer E2E passed: actual Mongo documents -> server/clan migration programs -> donation autoboards; retry did not duplicate boards.\n'
