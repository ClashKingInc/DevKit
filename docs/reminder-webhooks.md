# Retained reminder webhook repair

Run `go run migrations/reminder_webhooks.go` from `database/` with the intended
Timescale connection and production bot identity checked first. The default is
a read-only preview. Set `REMINDER_WEBHOOKS_APPLY=1` only after reviewing it.
For a repair limited to active reminders missing webhook IDs, set both
`REMINDER_WEBHOOKS_ONLY_MISSING=1` and `REMINDER_WEBHOOKS_ACTIVE_ONLY=1` in the
preview and apply runs. The active filter excludes disabled reminders and
servers that the bot has left. Omit these flags to retain the full migration.
Preview runs use a read-only transaction without configuration write locks.
They cache channel and webhook GET results within the run; apply re-reads each
destination under the server lock before changing configuration.
To restrict the repair to reviewed reminder IDs, set `REMINDER_WEBHOOKS_IDS` to
a comma- or whitespace-separated list of canonical UUIDs. Invalid and duplicate
IDs fail before Discord or database access. The allowlist intersects the
active/missing filters; it never widens them. The summary reports the requested
allowlist size separately from the currently matching rows. Apply still checks
current server, channel, thread and webhook ownership under the server lock.
Allowlisted previews print the proposed reminder, server, parent channel, thread
and webhook IDs without tokens. The serial repair uses at most one database
connection in both preview and apply modes.
The tool takes the same server lock as API configuration, reuses bot-owned
parent-channel webhooks, and creates a shared webhook only when none exists.
It stores the webhook ID, never a webhook secret or a bot-message fallback.

Removed or inaccessible destinations (Discord 403/404) remain unchanged and do
not prevent repair of other reminders. GET transport/5xx failures receive at
most three bounded retries. A 429 can be retried because Discord rejected the
request. Ambiguous POST failures stop immediately; retry the tool after review,
so it lists existing hooks before deciding whether creation is needed again.

A failed run prints its completed count and the failed reminder ID. Set
`REMINDER_WEBHOOKS_START_AT` to that ID to resume inclusively in stable database
order. An unknown ID is an error. Retain both partial and resumed preview logs
and review their combined coverage before applying. The apply run is safe to
repeat because each reminder resolves the current shared webhook under lock.
