# Retained reminder webhook repair

Run `go run migrations/reminder_webhooks.go` from `database/` with the intended
Timescale connection and production bot identity checked first. The default is
a read-only preview. Set `REMINDER_WEBHOOKS_APPLY=1` only after reviewing it.
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
