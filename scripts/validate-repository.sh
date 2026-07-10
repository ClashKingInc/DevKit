#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

(
  cd "$repo_root/database/migrations"
  go test ./...
  for file in *.go; do
    go test "$file"
  done
)

npm --prefix "$repo_root/design" run check

if command -v goose >/dev/null 2>&1; then
  goose -dir "$repo_root/database/timescale" validate
else
  echo "goose is not installed; skipping SQL migration validation"
fi

if command -v docker >/dev/null 2>&1; then
  (
    cd "$repo_root/database"
    export POSTGRES_DB=clashking_validation
    export POSTGRES_USER=clashking_validation
    export POSTGRES_PASSWORD=validation_only
    export HOST_BIND_IP=127.0.0.1
    export TIMESCALE_PORT=5432
    export VALKEY_PASSWORD=validation_only
    export VALKEY_PORT=6379
    docker compose \
      -f docker-compose.timescale.yml \
      -f docker-compose.valkey.yml \
      config -q
  )
else
  echo "docker is not installed; skipping Compose validation"
fi

if command -v flutter >/dev/null 2>&1; then
  (
    cd "$repo_root/design/packages/flutter"
    flutter pub get
    flutter analyze
  )
else
  echo "flutter is not installed; skipping Flutter analysis"
fi

if rg -n 'ClashKingDesignSystem|design-system/pages/\[page-name\]' \
  "$repo_root/README.md" "$repo_root/design" "$repo_root/ai" "$repo_root/database"; then
  echo "Found a stale design-system path" >&2
  exit 1
fi

if rg -n 'clashking_schemas_migrations|could not locate clashking_schemas' \
  "$repo_root/database"; then
  echo "Found a stale schema-repository identifier" >&2
  exit 1
fi

git -C "$repo_root" diff --check

echo "Developer-kit validation passed"
