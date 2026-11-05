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

Three real historical closed-ticket URLs were inventoried in this task and all
returned 404. Those objects were not copied and must not be reported as migrated.
The report is `/tmp/clashking-real-ticket-media-report.json`.

## November 3, 2026 follow-up: bounded recovery sample

A read-only sample of the 20 most recent retained `delete` ticket records from
`usafam.open_tickets` yielded 20 transcript URLs. All 20 HTML documents and
18 referenced attachments were downloaded to private local staging (65,059,085
bytes). All source receipts and SHA-256 hashes matched; the HTML contained
chat-exporter message markup. This is sample evidence, not a full inventory.
The earlier three 404s are not representative of all historical transcripts.

The locally configured Bunny storage credential returned HTTP 401 for the
root listing, so no full storage inventory was possible. The public CDN GET
path worked for the sample. No upload, SQL update, Discord change, or CDN
change was performed. Private evidence is in `/tmp/ck-legacy-followup/`; it is
temporary staging, not a durable backup or a release artifact.

A full migration must enumerate retained ticket channel/thread IDs and inventory
storage for orphaned transcripts if valid read credentials become available.
Copy HTML and attachments with hashes and a source-to-destination manifest.
Keep missing objects explicit; do not infer deletion from a failed HEAD alone.
Existing API HTML serving requires a capability, manifest and ownership metadata;
copying raw files into the bucket is not enough. Legacy HTML also needs a reviewed
archive-serving or conversion path with attachment rewrites and appropriate
content restrictions. Retain the source until migration acceptance.
