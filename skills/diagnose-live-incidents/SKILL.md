---
name: diagnose-live-incidents
description: Diagnose production, remote-server, deployment, sync, database, or runtime incidents from current live evidence before changing systems. Use when a process is stuck, data is missing, a server crashes, production differs from local behavior, or high-stakes operational accuracy matters.
---

# Diagnose Live Incidents

Prove the failure mode from the system the user says is affected.

## Start read-only

1. State the current live symptom and requested coverage or recovery target.
2. Identify the exact host, deployment, database, process, run, time window, and environment.
3. Capture a current snapshot before theorizing:
   - process and listener identity
   - deployment or job status
   - recent logs and timestamps
   - database coverage, counts, and heartbeats
   - relevant configuration and resource pressure
4. Compare healthy and failing cases.
5. Reproduce locally only when it helps explain the live evidence.

## Prove the cause

- Correlate the symptom with logs, state transitions, queries, or code paths.
- Separate root cause, contributing conditions, and stale aftermath.
- Do not label a hypothesis as confirmed until evidence distinguishes it from realistic alternatives.
- When credentials are available locally, use them without printing or copying them into reports.

## Repair only when authorized

Diagnosis alone does not authorize a fix. When the user asks for repair, make the narrowest change that restores the target, then verify both the immediate symptom and the full requested coverage.

## Verify recovery

Lead status updates with the current live snapshot. Include exact counts, dates, run IDs, endpoints, or process state. Confirm that stuck or stale markers are cleared and that the condition will not silently recur.
