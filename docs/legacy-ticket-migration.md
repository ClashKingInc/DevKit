# Legacy ticket migration

The settings importer writes the existing `ticket_panels` JSON columns directly.
Each imported action receives a stable canonical ID, while `data.legacy_button_ids`
retains the exact old custom ID. Existing panel rows and ticket rows are preserved
on repeat import. No new mapping or migration table is required.

On the first old button click, the API verifies the Discord signature, application,
freshness, bot author, and exact button inside the signed message. The API then
resolves the saved legacy ID, stores that publication and its inline message in
the existing panel JSON, and continues through the canonical opening flow.
Older imports may resolve through the already existing deprecated button rows.
Missing or ambiguous identity is rejected; labels and panel names are not proof.
Repeat clicks reuse the stored publication without rewriting the panel.

The legacy Python uploader stored transcript HTML at
`https://cdn.clashk.ing/transcript-CHANNEL_ID.html`. Thread transcripts use the
thread ID in the same path. Embedded attachments use
`https://cdn.clashk.ing/transcripts/ATTACHMENT_ID/FILENAME`.

`node scripts/copy-legacy-ticket-media-local.mjs` inventories a bounded page of
local ticket URLs. Set `CLASHKING_LOCAL_DATABASE_URL` and `CLASHKING_API_REPO`, or
pass `--manifest FILE` with an array of `{ "sourceUrl": "https://..." }` entries.
The default mode performs read-only HEAD requests. `--limit` is bounded to 1000;
`--after CHANNEL_ID` selects a later database page.

Pass `--output DIRECTORY` to stage accessible objects locally. Object keys are
deterministic, each source URL and content hash are preserved in a sidecar, and
matching files are skipped on repeat runs. HTML downloads discover transcript
attachment URLs within the same bounded run. `--report FILE` records failures
explicitly. There is no R2 upload, CDN write/delete, or SQL update path.

## Transcript recovery boundary

Inventory retained ticket channel/thread IDs and any orphaned storage objects
before copying historical transcripts. Preserve content hashes and a
source-to-destination manifest. Keep missing objects explicit; a failed HEAD
request alone does not prove deletion.

Existing API HTML serving requires capability checks, a manifest, and ownership
metadata. Copying raw files into the bucket is not sufficient. Legacy HTML needs
a reviewed archive-serving or conversion path, attachment rewrites, and the
current content restrictions. Retain the source until migration acceptance.
Local samples and temporary download directories are not durable backups or
proof that the historical archive has migrated.
