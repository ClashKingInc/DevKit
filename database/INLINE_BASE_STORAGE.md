# Base storage correction (021)

All shared base data now lives on `bases`. Personal ownership remains in `user_saved_bases`.

| Before | After |
| --- | --- |
| base_images: base_id, position, image_url | bases.images: ordered text array |
| base_votes: base_id, user_id, vote, updated_at | bases.votes: JSON object keyed by user ID, containing vote and updatedAt |
| bases.downloads | Unchanged user ID → first-download timestamp map |

Example row fields:

```json
{
  "images": ["https://api.clashk.ing/v2/media/base_example.png"],
  "votes": {"123456789012345678": {"vote": 1, "updatedAt": "2026-09-17T00:00:00Z"}},
  "downloads": {"123456789012345678": "2026-09-16T12:00:00Z"}
}
```

Migration 021 copies every image position, vote identity/direction/timestamp, and leaves downloads unchanged, then removes the two old tables. Sparse image positions retain null placeholders internally so a partially staged Discord message can resume without replacing another image. API responses omit those placeholders. Existing media objects are not copied, deleted or renamed.

Vote changes use an atomic update of one JSON key; image staging updates only an empty position. Repeated votes remain one vote, switching direction replaces it, and removing a vote removes only that user's key. Voter IDs stay private; Dashboard responses still expose counts and downloader identities only.

## Deployment boundary

This is a coordinated base-storage cutover, not a rolling-compatible migration. Stop/drain old base readers and writers, apply 021 with Goose, deploy the paired API revision, then resume traffic. The migration takes exclusive locks while copying so old writes cannot be silently lost, but old API processes cannot continue using the dropped tables afterward. Do not apply it independently while the old API serves bases. No deployment is performed by this PR.

Down is intentionally blocked rather than silently destroying inline data. An operational rollback needs a separate data-preserving conversion and coordinated API rollback. Earlier applied migrations are unchanged.
