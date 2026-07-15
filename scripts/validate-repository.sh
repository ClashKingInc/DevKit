#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

echo "Validating Go migration tools..."
(
  cd database/migrations
  go test ./...
)

echo "Validating Goose SQL migrations..."
goose -dir database/timescale validate

echo "Validating shared design packages..."
npm --prefix design run check

echo "Validating Flutter design package..."
(
  cd design/packages/flutter
  flutter pub get
  flutter analyze
  flutter test
)

echo "Running design drift check against ClashKingApp (warning mode, informational only)..."
if [ -d "clashking-app-drift-check" ]; then
  npm --prefix design run drift:app -- --target "$repo_root/clashking-app-drift-check" || true
else
  npm --prefix design run drift:app || true
fi
