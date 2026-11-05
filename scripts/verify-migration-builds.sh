#!/usr/bin/env bash
# Build, but never execute, every migration command. Most standalone importers
# use //go:build ignore, so go build ./... alone leaves them unchecked.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/clashking-migration-builds.XXXXXX")
trap 'rm -rf -- "$build_dir"' EXIT
cd "$root/database"
go build ./...
count=0
for source in migrations/*.go; do
  name=$(basename "$source" .go)
  go build -o "$build_dir/$name" "$source"
  printf 'Built importer: %s\n' "$name"
  count=$((count+1))
done
printf 'Verified %s standalone migration entry points; none executed.\n' "$count"
