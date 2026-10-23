#!/usr/bin/env bash
# Exercise real Goose migrations against the disposable local database only.
set -euo pipefail
[[ ${CLASHKING_DISPOSABLE_TIMESCALE:-} == 1 ]] || { echo 'Disposable Timescale harness required' >&2; exit 2; }
[[ ${TEST_DATABASE_URL:-} == postgres://clashking_test:clashking_test@127.0.0.1:*/clashking_test?sslmode=disable ]] || { echo 'Unexpected smoke database URL' >&2; exit 2; }
schema_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
goose -env /dev/null -dir "$schema_root/database/timescale" postgres "$TEST_DATABASE_URL" up
psql "$TEST_DATABASE_URL" -v ON_ERROR_STOP=1 <<'SQL'
DO $$
BEGIN
 IF (SELECT max(version_id) FROM goose_db_version WHERE is_applied) <> 22 THEN
   RAISE EXCEPTION 'Expected consolidated migration22';
 END IF;
 IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='basic_player' AND column_name='last_active' AND data_type='timestamp with time zone' AND is_nullable='YES') THEN
   RAISE EXCEPTION 'Missing nullable activity column';
 END IF;
 IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='autoboards' AND column_name='row_limit') THEN
   RAISE EXCEPTION 'Missing autoboard row limit';
 END IF;
 IF to_regclass('public.manual_reminder_requests') IS NOT NULL THEN
   RAISE EXCEPTION 'Manual reminders must not retain a request queue table';
 END IF;
 IF to_regclass('public.user_saved_armies') IS NULL OR to_regclass('public.ticket_runtime_operations') IS NULL
   OR to_regclass('public.cwl_participation') IS NULL THEN
   RAISE EXCEPTION 'Incomplete consolidated release schema';
 END IF;
END $$;
SQL
# A second run must be a no-op against the same real database.
goose -env /dev/null -dir "$schema_root/database/timescale" postgres "$TEST_DATABASE_URL" up
