# Schema Baseline Coordination Report

This report tracks the coordinated implementation of the V2 cleanup in
`001_initial_stats.sql`, `002_initial_settings.sql`, and
`003_v2_schema_cleanup.sql` across DevKit and its consumers. Every task that
changes an affected surface must update its section before reporting
completion.

## DevKit

Status: the two-file baseline plus migration 003 are applied to the real local
Timescale database. No production or remote database was touched.

Validation:

- A fresh database migrates successfully to Goose version 2.
- On 2026-07-27, Goose applied `003_v2_schema_cleanup.sql` to the real local
  `tracking` database in 1.8 seconds and reported schema version 3.
- Before application, `public.player_links` had 175,634 rows and its complete,
  tag-ordered CSV content had SHA-256
  `4179fc4090b90bd544d2ddfbd4ccccd32f2bba2c396b5a66e1640409070a4306`.
  The post-migration row count and complete content fingerprint are identical,
  and the table still has its 11 prior columns. Migration 003 only read
  verified links while populating notification accounts; it did not alter,
  delete, or rebuild `player_links`.
- A restorable custom-format table archive was created before application at
  `/private/tmp/clashking_player_links_pre_003_20260727.dump` (2.8 MB, archive
  SHA-256
  `efd167a569c9a5483e0bf0e0136f1b2b66d41e232e1005dfb21a9fb59f6b0662`);
  no restore was necessary.
- `git diff --check` passes.

### Accepted schema decisions

#### 1. `auth_discord_tokens`

- Keep the `(user_id, device_id)` primary key.
- Keep `user_id`, `device_id`, `access_token_ciphertext`,
  `refresh_token_ciphertext`, `expires_at`, `created_at`, and `updated_at`.
- Drop `scopes`.
- Drop `data`; do not replace `device_name` with another column.

#### 2. `auth_email_verifications`

- Keep `email_hash` as the primary key.
- Keep `verification_code_hash`, `expires_at`, and `created_at`.
- Add required typed `username`, `password_hash`, and `device_id` columns.
- Backfill those columns from the existing nested `data.user_data` values.
- Drop `user_id` and `data`.
- Keep only the verification-code hash; never store a plaintext code.

#### 3. `auth_password_reset_tokens`

- Keep `email_hash`, the server-secret-bound `reset_code_hash`, `user_id`,
  `expires_at`, and `created_at`.
- Keep only the newest existing row per email during migration.
- Make `email_hash` the primary key so a new request supersedes the previous
  reset credential.
- Drop `id`, `used`, and `data`.
- Replace the old lookup index with an expiry index; the primary key handles
  email lookup.
- Require the API consume path to delete a successful reset atomically with
  password update and refresh-session revocation.

#### 4. `auth_refresh_tokens`

- Keep `token_hash` as the primary key and retain `user_id`, `device_id`, and
  `expires_at`.
- Drop `revoked_at`, `data`, and `created_at`; never store a raw refresh token,
  duplicated device metadata, or session-history metadata.
- Keep `idx_auth_refresh_tokens_expires_at` for expiry cleanup and
  `idx_auth_refresh_tokens_user_device` for user/device session operations;
  both already match the final shape and contain no revoked-state predicate.
- Require rotation to atomically delete the presented token row and insert its
  replacement.
- Require password reset to delete every refresh-token row for the user.
- Change issuance and persistence to a 30-day rolling renewal window everywhere
  refresh tokens are created.

#### 5. `auth_users`

- Keep `user_id`, `email_hash`, `discord_user_id`, `password_hash`,
  `created_at`, and `updated_at`.
- Drop `display_name`, `verified`, `profile`, and `data`.
- Retain `username` for email accounts, but remove its empty-string default and
  `NOT NULL` constraint so Discord accounts do not require stored profile data.
- Clear existing `username` values for rows with `discord_user_id`; the
  single-provider constraint already prevents an email identity on those rows.
- Do not add replacement columns for Discord username, display name, avatar, or
  locale. The API must fetch those values live using the relevant device's
  stored Discord OAuth credentials.
- Keep both timestamps because the current schema/API audit did not establish
  either as safely unused.

#### 6. `bases`

- Keep `id`, `message_id`, `base_link`, `downloaders`, and `created_at`.
- Drop `downloads`. `downloaders` is the authoritative unique set of Discord
  user IDs, and download count is derived as `cardinality(downloaders)`.
  Repeated downloads by the same user are a no-op.
- Add `images text[] NOT NULL DEFAULT '{}'` and
  `description text NOT NULL DEFAULT ''`, with a database check limiting
  descriptions to 1,000 characters and another check limiting images to four.
- Add `server_id` and `channel_id` as a paired message location and reject rows
  where only one is populated.
- Existing SQL rows contain only `message_id`; no table, migration state, or
  durable relation can derive their Discord server/channel ownership. The
  migration therefore adds both location columns as nullable for legacy rows
  rather than inventing IDs or deleting data. Reaching the final `NOT NULL`
  shape requires a reliable external backfill or an explicit decision to
  remove legacy rows, followed by constraint enforcement.
- Drop `whitelisted_role_id`; do not add `feedback`, `new`, or other legacy bot
  compatibility fields.
- Drop the `upvotes` and `downvotes` counters. Add
  `upvoter_ids text[] NOT NULL DEFAULT '{}'` and
  `downvoter_ids text[] NOT NULL DEFAULT '{}'` directly to `bases`.
- Derive vote totals from each voter array's cardinality; do not maintain
  duplicate integer counters or a separate vote table.
- Prevent a Discord ID from appearing in both voter arrays with a database
  overlap check. The trusted bot owns deduplication within each array and vote
  switching between arrays.
- Existing counter totals cannot be migrated into voter arrays because legacy
  rows contain no voter identities. The Up migration discards those
  unverifiable totals rather than inventing Discord IDs. The Down migration
  reconstructs counters from the voter arrays before dropping them.

#### 7. `bot_settings`

- Drop the legacy table entirely; no API, bot, Dashboard, or App runtime caller
  exists.
- Remove its dedicated Mongo-to-Timescale importer, including the now-dead
  checkpoint and collection references.
- Keep unrelated settings tables, migration paths, and runtime configuration
  unchanged.
- Restore the exact prior `type`, `data`, and `updated_at` columns, defaults,
  and `bot_settings_pkey` primary key in the Down migration.
- No downstream application task is required because the caller audit found no
  affected consumer.

#### 8. Capital Raid cache tables

- Drop `capital_raid_cache` and `capital_raid_members`; their SQL cache and
  reverse-member lookup are superseded by the Tracking service's existing
  Valkey.
- The DevKit migration audit found no dedicated Mongo importer or other
  generated schema consumer to remove.
- Preserve unrelated Capital Raid history, reminder, log, and server-settings
  tables and migration paths.
- The Down migration restores both tables' exact prior columns, defaults,
  primary keys, and `idx_capital_raid_cache_end_time` and
  `idx_capital_raid_members_player_time` indexes. It recreates empty cache
  tables because a rollback cannot recover rows discarded by the Up migration.
- Persistent Tracking task `019f94ba-972b-7171-ad08-0f4f86796eef` owns the
  Valkey replacement and remains available for future cleanup decisions.

#### 9. `clan_categories`

- Preserve the `clan_categories` table shape and all existing keys and
  constraints.
- Replace `server_clans_category_id_fkey` with the same foreign key plus
  `ON DELETE SET NULL`, so deleting a category automatically uncategorizes
  every assigned clan rather than blocking deletion.
- The Down migration restores the prior foreign key without a delete action.
- Persistent API task `019f92a8-f4b8-74a2-ab70-cf25481fd6d1` owns the
  server-manager category API and coordinates the existing persistent
  Dashboard task `019f929f-bd3f-7ca0-ab74-f6ad08ddec1e`; no App work applies.

#### 10. `clan_rankings_current` and clan ranking points

- Rebuild `clan_rankings_current` as one typed row per
  `(clan_tag, ranking_type, location_id)`. The only ranking types are `home`,
  `builder_base`, and `capital`; location is `global` or an official numeric
  location ID encoded as text.
- Keep required integer `rank` and `points` values plus `updated_at`. Remove
  `country_code`, `country_name`, `global_rank`, `local_rank`, and `data`.
- Add `idx_clan_rankings_current_scope_rank` on
  `(ranking_type, location_id, rank)` for complete leaderboard-group
  replacement and ordered reads.
- Add `basic_clan.builder_base_points` and `basic_clan.capital_points` as
  required integers with the same zero default as `clan_points`. Update the
  DevKit `basic_clans` importer to read the official
  `clanBuilderBasePoints`/`clanCapitalPoints` values, while accepting the
  legacy Mongo aliases when present.
- Preserve an existing legacy row's explicit Home Village global placement.
  Preserve its explicit local placement only when the clan's authoritative
  `basic_clan.location_id` supplies the official numeric location. Use a
  numeric legacy `data.points` value when present, otherwise the typed
  `basic_clan.clan_points`; do not infer a numeric location from country
  names/codes or manufacture Builder Base/Capital rankings.
- The Down migration restores the exact prior columns, primary key, and
  country/rank index. It collapses Home Village global and most-recent local
  placements back into the legacy one-row shape with null country fields,
  because the new schema deliberately stores no country name/code. Builder
  Base and Capital placements cannot be represented by the prior table and
  are discarded on rollback.
- Persistent Tracking task `019f94ba-972b-7171-ad08-0f4f86796eef` owns the
  clans-only scheduled official top-200 refresh and typed basic-clan point
  ingestion. Persistent API task `019f92a8-f4b8-74a2-ab70-cf25481fd6d1`
  owns the response-specific `/v2/clan/{clan_tag}/rankings` contract and every
  other affected current-ranking query. Rankings remain excluded from the
  basic clan endpoint; no player-ranking, Valkey, Dashboard, or App change is
  authorized unless an existing consumer is proven.

#### 11. `clan_season_stats`

- Drop `clan_season_stats` completely. Its seasonal `donations`, `clan_games`,
  `activity`, and `data` JSONB documents have no active writer or runtime
  consumer.
- The DevKit migration audit found no dedicated importer or checkpoint path
  for this table.
- The Down migration faithfully restores `clan_tag`, `season`, all four JSONB
  columns and defaults, `updated_at`, and the `(clan_tag, season)` primary key.
  It recreates an empty table because the dropped JSONB documents have no
  authoritative replacement source.
- The API audit found one dead `clanDonationsSingle` handler that still reads
  the table, but its route is already deliberately absent and covered by the
  removed-route registration test. Dashboard contains an unused legacy client
  wrapper and README example for that absent endpoint; Tracking, Bot, and App
  contain no SQL-table caller. Persistent API task
  `019f92a8-f4b8-74a2-ab70-cf25481fd6d1` owns removal of the dead handler and
  confirms whether any now-unused response type can also be removed. No new
  downstream task is required.

#### 12. `countdowns` naming

- Rename `countdowns` to `server_countdowns` in Up and rename it back in Down.
  This is a table-name-only cleanup: PostgreSQL carries the existing columns,
  data, primary key, checks, foreign key, and server/type index through both
  renames without rebuilding them.
- Update the DevKit `server_settings` and `server_clans` importers to write the
  renamed table.
- API countdown CRUD and server/clan settings reads are the only active
  application SQL callers and must switch to `server_countdowns`. Their
  external `/countdowns` paths, request/response models, and behavior remain
  unchanged.
- Dashboard uses those unchanged API paths and has no database table-name
  dependency. Tracking, Bot, and App contain no direct SQL caller, so no
  downstream client task is required.
- Persistent API task `019f92a8-f4b8-74a2-ab70-cf25481fd6d1` owns the literal
  query-name replacement and regression validation; it may reuse an existing
  downstream owner only if its own audit discovers a real contract change.

#### 13. `current_war_timers`

- Keep `current_war_timers` as the Postgres reverse lookup from a player to
  that player's one current Global War Tracking war. Keep only `player_tag`,
  `war_id`, `clan_tag`, `opponent_tag`, and `end_time`, with `player_tag` as
  the primary key.
- Drop `data` and `updated_at`; the lookup has no auxiliary JSON payload or
  row-history semantics. The DevKit audit found no dedicated importer.
- Keep `idx_current_war_timers_end_time` for the five-minute expiry cleanup and
  add nonunique `idx_current_war_timers_war_id` so maintenance can shift every
  participant in the same war efficiently.
- The Down migration drops only the new war-ID index and restores the exact
  prior JSONB/timestamp columns and defaults. It preserves the existing rows,
  primary key, and end-time index in both directions.
- Persistent Tracking task `019f94ba-972b-7171-ad08-0f4f86796eef` owns the
  Global War Tracking writer. It uses `old-python/global_war_track.py` as the
  behavioral reference, batch-upserts every participant's current war in one
  database operation, and deletes expired rows every five minutes. Postgres
  remains authoritative; no Valkey copy applies.
- Maintenance shifting is authorized only when the official Clash API returns
  HTTP 500. A successful recovery measures one positive elapsed duration and,
  in one transaction, shifts active `war_schedule` rows plus matching active
  `current_war_timers` rows selected by those war IDs. Transport failures and
  every non-500 HTTP error shift nothing.
- The only application SQL reader is the API's legacy current-war-timer
  lookup. Persistent API task `019f92a8-f4b8-74a2-ab70-cf25481fd6d1` owns
  removal of the dropped JSON read and must add `end_time > now()` to the
  lookup. Every runtime lookup must enforce that predicate so cleanup timing
  never determines correctness. Tracking, Bot, Dashboard, and App have no
  other direct table reader.

#### 14. `custom_embeds` naming

- Rename `custom_embeds` to `server_custom_embeds` in Up and rename it back in
  Down. This is a table-name-only cleanup; PostgreSQL carries the existing
  rows, timestamps, and `(server_id, name)` primary key through both renames.
- Update the DevKit custom-embed importer to write `server_custom_embeds`.
  The legacy Mongo collection remains named
  `custom_embeds`; that source name is outside the SQL table rename.
- API ticket/custom-embed list, upsert, and delete queries are the only active
  application SQL callers and must use `server_custom_embeds`. Their routes,
  request/response models, and behavior remain unchanged.
- Bot references named `custom_embeds` target the legacy Mongo collection, not
  this Postgres table. Tracking, Dashboard, and App contain no direct SQL
  caller, so no downstream client task is required.
- Persistent API task `019f92a8-f4b8-74a2-ab70-cf25481fd6d1` owns the literal
  query-name replacement and regression validation without changing the
  external contract.

#### 15. legacy `embeds` and ticket-panel templates

- Drop the obsolete UUID-keyed `embeds` table only after every legacy row has
  been copied to `server_custom_embeds` and every `ticket_panel` and
  `ticket_panel_buttons` reference has been converted.
- A migration-only target map includes each legacy embed's source server plus
  every panel server that references it. This preserves an old cross-server
  UUID reference by creating a server-scoped copy rather than linking a panel
  to another server's template.
- Legacy templates use collision-safe deterministic names of the form
  `legacy:<uuid>:<source-server-hex>:<original-name-hex>` with a deterministic
  `:copy:<n>` suffix only if an existing template has that exact name. The
  encoded source/name values retain the original UUID identity and name for a
  safe Down reconstruction without adding permanent legacy columns or JSON
  metadata to active template data.
- `ticket_panel` now stores nullable `(embed_server_id, embed_name)` and
  references `server_custom_embeds` with `ON DELETE SET NULL`; a scope check
  requires a non-null template pair to belong to the panel's server.
  `ticket_panel_buttons` gains its inherited `server_id` plus nullable
  `(open_message_embed_server_id, open_message_embed_name)`, a composite FK
  back to its own panel/server, and the same scoped template FK/check. This
  preserves template deletion behavior while enforcing server ownership.
- The migration raises an error instead of dropping the old table if a legacy
  panel/button reference cannot resolve. No unresolved legacy row is silently
  discarded.
- Down recreates the exact `embeds` table and UUID FKs, reconstructing UUID,
  source server, original name, and data from tagged legacy templates. It
  leaves migrated active templates in place so a rollback cannot delete a
  template changed after Up.
- The DevKit importer has no UUID-embed or singular-ticket-panel path to
  update.
- API, Bot, Dashboard, and App audits found no active SQL caller of the old
  singular `ticket_panel`/`ticket_panel_buttons` or `embeds` schema. Current
  API and Dashboard ticket flows use the separate plural `ticket_panels` JSON
  contract and active template names; Bot custom embeds remain Mongo-backed.
  No application task is required unless a later caller audit finds a live
  singular-table dependency.

### Authorized Bases feature

Status: complete in the persistent API and Dashboard tasks, which remain
available for later initiative decisions.

- Add a server-manager-authorized Bases surface under Dashboard Clan
  Management.
- Scope every list/detail/downloader request to a server the caller administers
  through the existing authorization model.
- Exclude legacy rows with missing server/channel ownership from authorized
  responses; do not infer ownership.
- Return camelCase feature fields, direct Discord message-link components,
  description, up to four images, layout link, timestamps, counts, and raw
  downloader IDs without eagerly resolving every Discord profile.
- Do not read, write, or return a stored `downloads` field. Expose the derived
  camelCase `downloadCount` from the unique `downloaders` array, and display
  that value in Dashboard.
- Implement one authorized server-scoped create POST plus authorized list/read
  endpoints because the API has no existing Bases handlers.
- Creation accepts an authorized server-scoped channel selection, `base_link`,
  `description`, and up to four images. It does not accept `message_id`.
- The backend sends the base message through the established Discord/bot
  integration, captures the returned message ID, and persists `server_id`,
  `channel_id`, and that internal `message_id`. A failed Discord send must not
  create a database row; a later database failure must attempt message cleanup
  and report the cleanup outcome.
- Bases cannot be edited after creation and have no generic update endpoint.
  Add an authorized server-manager delete action.
- Manager delete first attempts to remove the associated Discord message using
  `server_id`, `channel_id`, and `message_id` through the appropriate trusted
  integration. An already-missing Discord message must not prevent database
  cleanup. The API task must document the final response/database semantics for
  other Discord deletion failures.
- Download history and voter arrays may change only through the trusted
  bot integration using its existing special authentication. Do not add public
  user-facing vote/download mutation endpoints or generic end-user vote auth.
- The bot owns duplicate avoidance, direction changes, and removals while the
  database guarantees that one Discord ID cannot be in both voter arrays.
  Repeated downloads by the same Discord ID remain a no-op.
- An upvote atomically removes the Discord ID from `downvoter_ids` and ensures
  it appears exactly once in `upvoter_ids`; a downvote performs the inverse.
  Repeating the same vote is idempotent, and concurrent events must use one
  database operation or transaction so contradictory arrays cannot persist.
- API responses derive camelCase upvote/downvote counts from voter-array
  cardinality, and Dashboard displays those values without receiving voter-ID
  arrays.
- Resolve a downloader's safe current display name/avatar only through a
  narrow, authorized on-demand endpoint.
- Treat `downloaders` only as engagement/history for server managers.
  Downloading is distinct from saving: there is no App saved-bases feature,
  per-user saved-base index, or saved-record behavior in this initiative.
- Use the existing Bunny CDN upload pattern and leave a clear nearby TODO for
  a future Cloudflare migration without starting that migration.
- Reuse persistent API task `019f92a8-f4b8-74a2-ab70-cf25481fd6d1` and
  persistent Dashboard task `019f929f-bd3f-7ca0-ab74-f6ad08ddec1e`; create no
  duplicate per-feature tasks.

## ClashKing API

Status: decisions 1–6, decisions 9–14, the final authorized Bases feature, and
the accepted migration-003 notification, normalized-current-ranking, Raid
Weekend retirement, and canonical-server work are complete in the persistent
API task. All work remains local and uncommitted.

Tasks:

- `019f929a-bd35-7f40-8fa4-f032de41e149`: decisions 1–2
- `019f92a4-5e6b-70a2-a9da-9f6d16a01d88`: decision 3, complete
- `019f92a8-f4b8-74a2-ab70-cf25481fd6d1`: persistent API owner; decisions 4–6,
  decisions 9–14, and the authorized Bases backend complete; remains
  available for future initiative decisions

Affected routes and behavior:

- `POST /v2/discord` and `POST /v2/auth/discord` still exchange PKCE
  credentials, store encrypted Discord access/refresh tokens under the
  composite `(user_id, device_id)` identity, and return only ClashKing session
  tokens plus `AuthUserInfo`. `device_name` was removed from
  `AuthDiscordOAuthRequest` because it existed only in the dropped token
  `data`.
- `GET /v2/guilds` and Discord-backed server authorization continue using
  `getDiscordAccessTokenForDevice` / `sqlDiscordToken`: lookup remains
  per-device, ciphertext is decrypted before use, expired tokens are refreshed,
  replacement credentials are encrypted, and `expires_at` plus `updated_at`
  are updated without the removed JSONB mirror.
- `GET /v2/auth/export` and `GET /v2/privacy/export` now export Discord session
  `device_id`, `expires_at`, `created_at`, and `updated_at` only. They do not
  select `scopes`, `data.device_name`, or either OAuth ciphertext.
- `POST /v2/register` and `POST /v2/auth/register` hash the verification code
  and write typed `username`, `password_hash`, and `device_id` pending values.
- `POST /v2/resend-verification` and
  `POST /v2/auth/resend-verification` read and rewrite those typed pending
  values while replacing only the server-secret-bound code hash and
  timestamps.
- `POST /v2/verify-email-code` and
  `POST /v2/auth/verify-email-code` atomically consume the matching unexpired
  row with `DELETE ... RETURNING`, use the returned typed pending values to
  create the account/session, and reinsert the pending row with the submitted
  code re-hashed if account upsert fails. No plaintext verification code is
  persisted.
- `POST /v2/forgot-password` and `POST /v2/auth/forgot-password` continue
  returning the same enumeration-safe response. For an existing account they
  upsert one reset row by `email_hash`, replacing the prior
  server-secret-bound HMAC code hash, user, expiry, and creation time so a
  newer request supersedes the older credential. If email delivery fails, the
  API deletes only the still-matching code hash so it cannot delete a newer
  concurrent request.
- `POST /v2/reset-password` and `POST /v2/auth/reset-password` atomically
  delete the matching unexpired reset row with `DELETE ... RETURNING`, update
  the user's password, and delete every `auth_refresh_tokens` row for that
  user in one transaction. Invalid or expired codes remain unauthorized;
  database failures propagate and roll back the transaction, preserving the
  credential for a legitimate retry instead of reporting a false credential
  failure. A successful reset retains no spent reset credential.
- Every email, password-reset, and Discord sign-in path now issues a refresh
  JWT with a 30-day expiry and persists that exact signed expiry. The
  `auth_refresh_tokens` row contains only the SHA-256 `token_hash`, `user_id`,
  `device_id`, and `expires_at`; the raw refresh token and duplicated session
  metadata are never passed to SQL.
- `POST /v2/refresh` and `POST /v2/auth/refresh` still return a new access token
  and replacement refresh token. Rotation now starts one SQL transaction,
  deletes the matching unexpired old-token hash, inserts the replacement hash
  and its 30-day signed expiry, then commits. A missing/already-consumed token
  or replacement insert/commit failure leaves no partial rotation because the
  transaction rolls back.
- Every `auth_users` lookup and write now uses only `user_id`, nullable
  `email_hash`, nullable `discord_user_id`, nullable email-account `username`,
  nullable `password_hash`, `created_at`, and `updated_at`. The internal typed
  `authUser` scanner/persistence helpers enforce the single-provider identity
  constraint and never read or write `display_name`, `verified`, `profile`, or
  `data`.
- Email registration/login/password behavior still uses typed
  `username`/`password_hash`. Discord authentication persists only
  `user_id`/`discord_user_id`; `GET /v2/me` and `GET /v2/auth/me` require the
  current device ID, select that device's encrypted Discord OAuth credential,
  fetch the live Discord profile, and reject an identity mismatch. There is no
  stored profile fallback or cross-device credential fallback.
- Privacy export returns only safe typed identity/timestamp fields and the
  derived authentication method. Server tickets and giveaways no longer read
  removed `auth_users` profile data as a display-name/avatar fallback.
- `GET /v2/server/{server_id}/bases` and
  `GET /v2/server/{server_id}/bases/{base_id}` are manager-only, server-scoped
  reads. Both exclude legacy rows with missing channel ownership, return raw
  downloader IDs without eager Discord resolution, derive `downloadCount`,
  `upvotes`, and `downvotes` from `cardinality(downloaders)`,
  `cardinality(upvoter_ids)`, and `cardinality(downvoter_ids)`, and return the
  direct Discord message URL. No removed integer counter or voter-ID array is
  exposed.
- `POST /v2/server/{server_id}/bases` is the only base-record creation route.
  Live manager authorization supplies `server_id`; the request supplies
  the normal server-scoped channel selection value, HTTPS `baseLink`, at most
  four ClashKing CDN image URLs, and at most 1,000 description characters.
  The backend sends a new Discord message and persists its returned ID; clients
  never submit `messageId`. The Discord adapter verifies that the selected
  channel belongs to the authorized server and supports bot message creation
  before sending the base embed. SQL initializes
  `downloaders`, `upvoter_ids`, and `downvoter_ids` to empty arrays and accepts
  no client engagement state. Existing bases have no manager/user PUT/PATCH
  surface, while authorized manager DELETE handles Discord-message cleanup.
- Creation performs no database insert when Discord message creation fails.
  Invalid/out-of-server/non-writable channels return HTTP 409 and nonretryable
  `discordMessageCleanup: "notNeeded"`; Discord auth/permission or other
  non-transient rejections return HTTP 502/nonretryable; integration absence,
  network failure, rate limiting, and Discord 5xx return HTTP 503/retryable.
  If Discord reports message creation but returns no usable message ID, the API
  cannot target safe compensation: it returns HTTP 502 with
  `discordMessageCreated: true`, no `discordMessageId`,
  `discordMessageCleanup: "failed"`, and `retryable: false` to prevent a
  duplicate/orphan-producing automatic retry.
  If Discord creation succeeds but insertion fails, the API attempts to delete
  the new message. HTTP 500 reports `databaseInserted: false`,
  `discordMessageCreated: true`, the generated `discordMessageId`, and cleanup
  `deleted`, `alreadyMissing`, or `failed`. Completed/already-missing cleanup
  is retryable; failed cleanup is nonretryable so an automatic retry cannot
  silently duplicate the orphaned Discord message.
- `DELETE /v2/server/{server_id}/bases/{base_id}` is manager-write authorized
  and selects the message location by both base ID and authorized server ID,
  so absent and cross-server bases return HTTP 404 before any Discord call.
  Discord deletion happens before the database delete. Success is HTTP 200
  with `databaseDeleted: true` and `discordMessageCleanup` `deleted` or
  `alreadyMissing`. Invalid stored IDs return HTTP 409/nonretryable; Discord
  auth/permission or non-transient rejection returns HTTP 502/nonretryable;
  integration absence, network failure, rate limiting, and Discord 5xx return
  HTTP 503/retryable. Those failures retain the row. If Discord cleanup
  succeeds but the database delete fails, HTTP 500 reports the completed
  cleanup state, `databaseDeleted: false`, and `retryable: true`; retrying
  safely treats the now-missing Discord message as satisfied and finishes the
  scoped row deletion.
- `POST /v2/server/{server_id}/bases/images` uses the existing Bunny CDN
  upload helper for PNG/JPEG/GIF/WebP images under live manager authorization.
  A nearby TODO records the intended Cloudflare migration without starting it.
- `GET /v2/server/{server_id}/bases/{base_id}/downloaders/{user_id}` first
  proves the downloader belongs to that base and the base belongs to the
  authorized server, then resolves only that current Discord member's safe
  display name/avatar. A missing Discord member returns the known user ID with
  nullable profile fields rather than a stored fallback.
- Trusted-bot-only `PUT /v2/bases/{base_id}/votes/{voter_id}` and
  `DELETE /v2/bases/{base_id}/votes/{voter_id}` atomically switch or remove one
  Discord voter in the two voter arrays. One SQL row update removes every old
  occurrence and appends exactly one ID to the chosen direction, so repeats
  are idempotent and simultaneous events take PostgreSQL's row lock while the
  database overlap check remains the safety backstop.
- Trusted-bot-only
  `POST /v2/bases/{base_id}/downloaders/{user_id}` atomically appends a
  downloader only when absent and returns the derived unique count. These bot
  integration routes create no public voting/downloading API and no saved-base
  semantics.
- Manager-only `GET /v2/server/{server_id}/clan-categories` lists the
  authorized server's categories as camelCase `ClanCategory` objects with
  `id`, `serverId`, `name`, and a live `clanCount`. `POST` on the same path
  creates one category; `PATCH
  /v2/server/{server_id}/clan-categories/{category_id}` renames one category.
  Both mutations normalize names through the same helper used by clan
  assignment: surrounding and repeated internal whitespace collapses to
  single spaces, case remains significant, blank/control-containing names are
  rejected, and the maximum is 64 Unicode runes. Exact duplicate names use the
  existing `(server_id, name)` unique constraint and return HTTP 409.
- `GET
  /v2/server/{server_id}/clan-categories/{category_id}/delete-preview`
  returns the server-scoped category plus `affectedClanCount`; an absent or
  cross-server UUID returns HTTP 404. `DELETE
  /v2/server/{server_id}/clan-categories/{category_id}` locks the same
  server-owned category, counts assigned `server_clans`, deletes the category,
  and commits before returning camelCase `categoryId`, `name`, `deleted`, and
  the actual `uncategorizedClanCount`. The API does not issue a separate clan
  update: decision 9's `ON DELETE SET NULL` foreign key atomically clears every
  affected `category_id`. Begin/query/delete/commit failures return no success
  response and roll back.
- Existing `PATCH /v2/server/{server_id}/clan/{clan_tag}/settings` keeps its
  category-name/null request contract but no longer has divergent implicit
  category creation. It validates and normalizes with the direct-category
  helper, selects or creates by the exact `(server_id, name)` conflict key,
  assigns inside the existing transaction, reloads the live count after the
  assignment statement, and returns the same nested camelCase `ClanCategory`
  representation (or `null` when clearing/no category was requested).
- `GET /v2/clan/{clan_tag}/rankings` now returns identity plus exactly three
  response-specific camelCase categories: `homeVillage`, `builderBase`, and
  `clanCapital`. Each category exposes current typed `points` from
  `basic_clan` and a non-null `placements` array. Every
  `clan_rankings_current` row is represented by camelCase `locationId`,
  `rank`, row `points`, and `updatedAt`; `locationId` remains the exact
  `global` or official numeric-text value. The response has no generic
  `globalRank`, `localRank`, country, donation, war, or near-match metric
  fields.
- `GET /v2/clan/{clan_tag}/basic` is unchanged. Its SQL projection and
  `ClanBasicResponse` still exclude rankings, `builder_base_points`, and
  `capital_points`; generated-contract coverage explicitly prevents the two
  new point fields from leaking into that endpoint.
- The existing server leaderboard helper now reads Home Village global and
  current-clan-location ranks from typed `clan_rankings_current` rows and
  sources the already-exposed clan level/points/member/capital values from
  `basic_clan`. It preserves the existing public server-leaderboard shape and
  adds no Builder Base or Clan Capital ranking surface.
- Decision 11 removes the unreachable `clanDonationsSingle` handler and its
  now-unused `DonationEntry` model. No route is added or removed:
  `/v2/clan/{clan_tag}/donations/{season}` was already deliberately absent and
  remains covered by the removed-route registration test. No active API query
  references `clan_season_stats`.
- Decision 12 changes only the SQL table identifier in countdown CRUD and
  server/clan settings hydration from `countdowns` to `server_countdowns`.
  All public `/countdowns` paths, request/response models, JSON, authorization,
  Discord channel lifecycle, and error behavior remain unchanged.
- Decision 13 updates the legacy current-war-timer lookup to select only
  `war_id`, `clan_tag`, `opponent_tag`, and `end_time` by retained
  `player_tag`, with `end_time > now()` enforced in SQL. The response is built
  only from those typed values and preserves its meaningful existing `tag`,
  `war_id`, `clan`, `opponent`, `unix_time`, and RFC3339 `time` fields; expired
  rows now return the existing no-current-war result even between Tracking
  cleanup passes.
- Decision 14 changes only the three API SQL table references used by
  ticket/custom-embed list, upsert, and delete from `custom_embeds` to
  `server_custom_embeds`. The existing routes, request/response models, JSON,
  authentication, timestamps, conflict behavior, and ticket/embed behavior
  are unchanged.

Affected queries, helpers, models, and generated contracts:

- `internal/routes/auth.go`: `storeDiscordTokens`,
  `findEmailVerification`, `insertEmailVerification`,
  `deleteEmailVerification`, `deleteExpiredEmailVerification`, and
  `consumeEmailVerification`; the JSON-shaped pending record is replaced by
  the typed internal `emailVerification` record.
- `internal/routes/guilds.go`: refreshed Discord credential update; the
  unchanged lookup still selects only encrypted credentials and expiry by
  `(user_id, device_id)`.
- `internal/routes/privacy.go`: Discord session export query.
- `internal/models/v2/auth.go`: `AuthDiscordOAuthRequest`.
- `internal/models/v2/auth_test.go`: Discord request-contract and
  public-response credential regression coverage.
- `internal/routes/auth.go`: `insertPasswordReset` now inserts/upserts only
  `email_hash`, `reset_code_hash`, `user_id`, `expires_at`, and `created_at`;
  `deletePasswordReset` deletes only the matching HMAC hash; obsolete
  `findPasswordReset` and `markPasswordResetUsed` helpers were removed;
  `resetPasswordAndRevokeSessions` consumes via `DELETE ... RETURNING`,
  updates `auth_users`, and deletes all user refresh-token rows before commit.
- `internal/routes/auth_test.go`: regression coverage confirms reset-code
  hashing remains opaque, deterministic, and bound to both the server secret
  and email identity.
- `internal/routes/auth.go`: `storeRefreshToken` /
  `persistRefreshToken` write only the four final columns using a SHA-256 hash
  and the JWT's signed expiry; `findRefreshToken` returns the typed
  `refreshTokenRecord` from a primary-key hash lookup without a revoked-state
  predicate; `rotateRefreshToken` / `rotateRefreshTokenInStore` perform
  `DELETE` plus `INSERT` in one transaction without any removed-column
  reference. `deleteUserRefreshTokensQuery` preserves decision 3's
  full-user password-reset session deletion.
- `internal/routes/auth_test.go`: focused coverage proves hashed-only
  persistence, delete-and-insert rotation in one transaction, rollback when
  replacement insertion fails, rejection of an already-consumed token, the
  absence of `revoked_at` / `data` / `created_at`, and full-user
  password-reset deletion.
- `internal/utils/auth.go`: `GenerateRefreshToken` now signs a 30-day expiry.
- `internal/utils/auth_test.go`: regression coverage bounds the signed refresh
  expiry to the 30-day rolling window.
- `internal/docs/docs.go`, `internal/docs/swagger.json`, and
  `internal/docs/swagger.yaml`: regenerated Discord OAuth request schema with
  `device_name` removed while retaining the repository's custom QUERY
  operations.
- `internal/routes/auth.go`: typed `authUser`, `scanAuthUser`,
  `persistAuthUser`, provider-specific validation, and device-scoped live
  Discord `currentUser` resolution use only decision 5's final columns.
- `internal/routes/guilds.go` and `internal/routes/authz.go`:
  `getDiscordAccessTokenForDevice` now requires the explicit current device and
  never falls back to another device's OAuth credential.
- `internal/routes/privacy.go`, `internal/routes/server/tickets.go`, and
  `internal/routes/server/giveaways.go`: removed `auth_users` profile/data
  reads and stored Discord profile fallbacks.
- `internal/models/v2/auth.go` and `internal/models/v2/auth_test.go`:
  `AuthUserInfo` no longer exposes the obsolete email/profile storage shape,
  with generated-contract regression coverage.
- `internal/models/v2/bases.go`: camelCase response/request-specific Base,
  pagination, creation, create-compensation error, manager-delete,
  delete-cleanup error, downloader-profile, trusted-bot vote, and trusted-bot
  download contracts. `CreateBaseRequest` has no `messageId`; voter arrays are
  intentionally internal.
- `internal/routes/bases.go`: manager list/read/create/image/lazy-profile
  handlers and manager delete; server-scoped SQL; Discord message creation and
  insert-failure compensation; fail-closed Discord-first deletion;
  legacy-row exclusion; cardinality-derived counts; Bunny upload TODO; atomic
  trusted-bot voter-array switching/removal; and unique downloader append.
- `internal/routes/bases_test.go`: focused validation, server scoping,
  legacy-row exclusion, generated-message-ID persistence, no insert after
  Discord creation failure, missing/invalid returned-message-ID orphan
  handling, every insertion-failure compensation outcome,
  Discord-first delete ordering, missing-message success, cross-server delete
  prevention, row retention across Discord failure classes, completed-cleanup
  database failure, creation-controlled empty engagement state, cardinality
  derivation, camelCase serialization, non-editable route surface, manager/bot
  authentication boundaries, atomic vote switching/removal, and
  unique-download regression coverage.
- `internal/utils/discord.go`: server/channel validation, Discord base-message
  embed creation returning the created message snowflake, and message deletion
  through the configured bot integration.
- `internal/routes/register.go` and `internal/routes/register_test.go`: exact
  manager and trusted-bot route registration plus absence of manager
  PUT/PATCH routes for existing bases. Manager DELETE is registered through
  the existing manager-write authorization wrapper.
- `internal/models/v2/clan_categories.go`: response-specific camelCase
  category, list, create, rename, delete-preview, and delete contracts.
- `internal/models/v2/clan_categories_test.go`: category-model camelCase and
  shared clan-assignment representation coverage.
- `internal/models/v2/server_clans.go`: `ClanSettingsResponse` now includes
  the shared nested category representation.
- `internal/routes/server/categories.go`: manager handlers, shared
  normalization/error mapping, server-scoped list/count/create/rename SQL,
  UUID validation, and locked transactional delete/count behavior.
- `internal/routes/server/categories_test.go`: focused normalization, exact
  conflict, not-found/cross-server, SQL scoping, live count, transaction
  lifecycle/rollback, delete-FK reliance, and implicit-assignment consistency
  coverage.
- `internal/routes/server/clans.go`: existing implicit category assignment now
  uses the shared validation/normalization and returns the shared category
  model after the transactional assignment is visible.
- `internal/routes/clan_categories_test.go`: exact route registration and
  server-manager authorization coverage for every category operation.
- `internal/models/v2/clan_responses.go`: replaces the obsolete generic
  ranking metric with `ClanRankingCategory` and `ClanRankingPlacement`, and
  removes the dead single-clan seasonal donation response type.
- `internal/models/v2/clan_rankings_test.go`: exact camelCase category and
  placement serialization plus forbidden legacy-field coverage.
- `internal/routes/clan.go`: typed basic-clan point query, all-row current
  placement query/assembly, and removal of the dead `clan_season_stats`
  handler/query.
- `internal/routes/clan_rankings_test.go`: three-category point/placement
  assembly, exact row preservation, empty-clan behavior, tag scoping, error
  propagation, and decision-10 SQL-column regression coverage.
- `internal/routes/server/leaderboards.go` and
  `internal/routes/server/leaderboards_rankings_test.go`: typed Home Village
  ranking aggregation, existing server-leaderboard field hydration, and a
  static guard against removed ranking columns.
- `internal/routes/server/countdowns.go` and
  `internal/routes/server/settings.go`: all eight active API SQL references
  now target `server_countdowns`.
- `internal/routes/schema_cleanup_decisions_11_12_test.go`: static guards
  prevent the dead seasonal handler/table and bare SQL `countdowns` or
  `custom_embeds` table names from returning; it also verifies exactly three
  `server_custom_embeds` references.
- `internal/routes/legacy_player.go` and
  `internal/routes/current_war_timer_test.go`: retained-column timer scan,
  typed response construction, active-row predicate, and a regression guard
  against `data`/`updated_at`.
- `internal/routes/server/tickets.go`: all three live Postgres custom-embed
  operations now target `server_custom_embeds`; no Mongo collection reference
  was changed.
- `test/api/swagger_test.go`: exact decision-10 ranking definitions, absence
  of stale ranking models/fields, and unchanged basic-clan contract coverage.
- `internal/routes/server/exports.go`, `internal/routes/register.go`, and
  `internal/routes/register_test.go`: exported/registered list, create,
  rename, preview, and delete handlers through the existing manager-only
  read/write wrappers.
- `internal/docs/docs.go`, `internal/docs/swagger.json`, and
  `internal/docs/swagger.yaml`: generated Bases, clan-category, and
  decision-10 ranking routes/models; the six existing custom QUERY operation
  keys remain preserved.

### Migration 003 normalized rankings, notifications, Raid Weekend, and servers

- `GET /v2/player/{player_tag}/rankings` and mobile initialization now return
  the response-specific camelCase shape `{tag, homeVillage, builderBase}`.
  Each category has nullable `points`, `globalRank`, `locationId`,
  `locationName`, `countryCode`, and `localRank`, and reads only normalized
  `player_rankings_current(player_tag, ranking_type, location_id, rank,
  points)` rows. A retained numeric-location row remains visible with its
  canonical Clash location metadata when both ranks are null; the API neither
  suppresses the known location nor fabricates a global placement. Clan
  current-ranking readers use the final typed columns and no longer read or
  expose `updated_at`. This final migration-003 contract supersedes earlier
  decision-10 wording in this report that included ranking `updatedAt`.
- `GET` and `PUT /v2/notifications/preferences` use the final combined
  camelCase device, eight-boolean preference, reminder-minute, and user-wide
  account contract. `PUT` atomically updates the existing
  `mobile_push_devices.enabled` master switch, upserts per-device preferences,
  and replaces the user's enabled accounts. Reminder minutes are normalized
  and deduplicated, allow at most three values, and enforce the inclusive
  `1..2820` range. Account tags are normalized and deduplicated and must be
  backed by an actual verified `player_links` row or player
  `user_bookmarks` row; verified eligibility takes precedence and no numeric
  bookmark cap is invented. Push registration, privacy export, and erasure use
  only the final device columns.
- Every SQL-backed `raid_weekends` consumer was retired: clan and player Raid
  Weekend history, capital aggregate statistics, the server capital-raids
  leaderboard, and mobile `raid_data`, together with their route, helper,
  model, documentation, and test dependencies. Current official Clash and
  expiring Valkey Capital Raid behavior remains unchanged.
- Runtime settings now read and write the consolidated canonical `servers`
  table, including the surviving `embed_color`; no API SQL references
  `server_settings`. The API removed `server_clan_settings`,
  `server_blacklisted_roles`, `server_link_parse_channels`, and their retired
  settings/clan/role fields. `server_clans` responses join current names from
  `basic_clan` and retain only abbreviation/category configuration. The
  existing webhook log flow now supports clan-scoped `ban_alert` and
  server-scoped `reddit_feed`; legacy channel-only values are dropped and are
  never interpreted as webhook IDs.
- Core implementation is in
  `internal/routes/{public_stats.go,mobile.go,clan.go,legacy_player.go,register.go,privacy.go,notifications.go}`,
  the matching route tests, and
  `internal/routes/server/{settings.go,clans.go,roles.go,logs.go,leaderboards.go,countdowns.go}`.
  `internal/routes/{capital.go,legacy_capital.go}` were deleted. Response and
  request models were updated in
  `internal/models/v2/{notifications.go,player.go,clan_responses.go,activity_responses.go,settings.go,server_responses.go,server_clans.go,roles.go,enums.go}`;
  generated OpenAPI, API contract tests, and
  `docs/privacy_compliance.md` were updated with the same surface.
- The persistent App owner completed the matching Raid Weekend and normalized
  ranking cleanup with 758/758 tests plus analysis, localization, and diff
  checks. The persistent Dashboard owner completed the canonical-server/log
  caller cleanup with 328 tests plus ESLint, TypeScript, production build,
  localization, and diff checks. Neither client retains a removed Raid Weekend
  or server-settings caller.
- **Deferred Bot compatibility break:** per explicit user direction, no Bot
  task was created, reused, or messaged and no Bot checkout was changed.
  Proven active Bot consumers still expect the removed server capital-raids
  endpoint and retired `blacklisted_roles`, `reddit_feed`, link-parse channel,
  clan-channel, ban-alert-channel, and auto-greet fields. The API deliberately
  retains no aliases for those retired contracts, so Bot follow-through
  remains blocked until the user authorizes an owner.

Validation:

- `/Users/matthewanderson/go/bin/swag init -g main.go -o internal/docs --parseDependency`
  — passed for the final migration-003 API batch.
- `go test ./... -count=1` — passed across all API packages after the existing
  sandbox-only listener denial was rerun outside the sandbox; the separately
  rerun `go test ./test/api -count=1` also passed after OpenAPI regeneration.
- `go vet ./...`, `go build ./...`, and `git diff --check` — passed. Every
  changed Go file is formatted; only untouched pre-existing
  `internal/models/v1/player.go` appears in the repository-wide formatting
  audit.
- Generated OpenAPI retains exactly six custom `x-http-method: QUERY`
  operations, and production/OpenAPI stale-reference scans found no retired
  migration-003 schema, routes, or fields.
- `env GOCACHE=/tmp/clashking-api-go-cache go test ./internal/routes ./internal/routes/server ./internal/models/v2 ./test/api -run 'Test(QueryClanRankings|ClanRankingQueries|ClanRankingsResponse|ClanLeaderboardRankQuery|DecisionEleven|DecisionTwelve|DecisionFourteen|CurrentWarTimer|RegisterOmitsRemovedRoutesAndKeepsV2Routes|BuildDocIncludesPublicAndAuthenticatedOperations|BuildDocRepresentsQueryOperationsWithoutAdvertisingPost)' -count=1`
  — passed across all four affected packages.
- `env GOCACHE=/tmp/clashking-api-go-cache go vet ./...` — passed with no
  findings.
- `/Users/matthewanderson/go/bin/swag init -g main.go -o internal/docs` —
  passed; the exact three-category ranking models were generated and the six
  custom `x-query` operations were restored in `docs.go`, `swagger.json`, and
  `swagger.yaml`.
- `jq empty internal/docs/swagger.json` and generated definition inspection —
  passed; rankings expose only `homeVillage`, `builderBase`, `clanCapital`
  plus identity, while `ClanBasicResponse` has neither new point field.
- `go test ./...` — passed across every API package with the existing
  localhost-listener permission required by the proxy test.
- `git diff --check` — passed.
- Targeted source audit found exactly two pre-decision-10
  `clan_rankings_current` readers; both now use only `clan_tag`,
  `ranking_type`, `location_id`, `rank`, `points`, and `updated_at` plus typed
  `basic_clan` columns. No active source reads removed country/global/local/data
  columns, `clan_season_stats`, the old SQL `countdowns` table, or dropped
  current-war-timer columns, and no API SQL references bare `custom_embeds`.
- `env GOCACHE=/tmp/clashking-api-go-cache go test ./...` — passed across all
  packages, including route, utility, and API tests after the final
  server-generated create and manager-delete corrections.
- `env GOCACHE=/tmp/clashking-api-go-cache go test ./internal/routes -run 'Test(ValidateCreateBaseRequest|InsertBaseControlsOwnershipAndEngagementState|CreateManagedBase.*|DeleteManagedBase.*|BasesRoutesAreManagerProtectedAndImmutable|BaseModelsUseCamelCaseJSON|BaseBotVoteAndDownloadMutationsAreAtomicAndIdempotent|BaseReadsAndDownloaderLookupAreServerScoped|BaseListExcludesUnownedLegacyRowsAndDerivesCounts)$' -count=1`
  — passed.
- `env GOCACHE=/tmp/clashking-api-go-cache go test ./internal/utils ./internal/models/v2 -run '^$' -count=1`
  — passed; both affected packages compile.
- `env GOCACHE=/tmp/clashking-api-go-cache go vet ./internal/routes ./internal/utils ./internal/models/v2`
  — passed with no findings.
- `/Users/matthewanderson/go/bin/swag init -g main.go -o internal/docs` —
  passed; the final creation/deletion contracts were regenerated.
- `jq empty internal/docs/swagger.json` — passed, and `docs.go`,
  `swagger.json`, and `swagger.yaml` each retain exactly six custom `x-query`
  operations.
- `env GOCACHE=/tmp/clashking-api-go-cache go test ./internal/routes/server ./internal/routes ./internal/models/v2 -run 'Test(ClanCategory|NormalizeClanCategoryName|ParseClanCategoryID|QueryClanCategories|InsertAndRenameClanCategory|RemoveClanCategory|AssignClanCategory|RegisterOmitsRemovedRoutesAndKeepsV2Routes)' -count=1`
  — passed.
- `env GOCACHE=/tmp/clashking-api-go-cache go vet ./internal/routes/server ./internal/routes ./internal/models/v2`
  — passed with no findings.
- `env GOCACHE=/tmp/clashking-api-go-cache go test ./...` — passed across all
  API packages after decision 9 and generated-contract changes.
- `/Users/matthewanderson/go/bin/swag init -g main.go -o internal/docs` —
  passed; the five category operations and response-specific models were
  generated.
- `env GOCACHE=/tmp/clashking-api-go-cache go test ./... -run '^$'` — passed;
  every package compiles.
- `env GOCACHE=/tmp/clashking-api-go-cache go test ./internal/routes -run 'Test(UpsertAuthUserRejectsCombinedIdentity|ParseRefreshTokenRejectsUnexpectedAlgorithm|DiscordIdentityDataIgnoresDiscordEmail)$'`
  — passed.
- `env GOCACHE=/tmp/clashking-api-go-cache go test ./internal/routes -run 'Test(PasswordResetCodeHashIsSecretBoundAndOpaque|UpsertAuthUserRejectsCombinedIdentity|ParseRefreshTokenRejectsUnexpectedAlgorithm|DiscordIdentityDataIgnoresDiscordEmail)$'`
  — passed.
- `env GOCACHE=/tmp/clashking-api-go-cache go test ./internal/models/v2` —
  passed.
- `env GOCACHE=/tmp/clashking-api-go-cache go test ./internal/routes -run 'Test(RotateRefreshToken|PersistRefreshToken|PasswordReset|ParseRefreshToken|UpsertAuthUser|DiscordIdentity)' -count=1`
  — passed.
- `env GOCACHE=/tmp/clashking-api-go-cache go test ./internal/utils -run 'TestGenerateRefreshTokenUsesThirtyDayRollingExpiry' -count=1`
  — passed.
- `env GOCACHE=/tmp/clashking-api-go-cache go test ./internal/routes -run 'Test(ValidateCreateBaseRequest|InsertBaseControlsOwnershipAndEngagementState|BaseReadsAndDownloaderLookupAreServerScoped|BaseListExcludesUnownedLegacyRowsAndDerivesCounts|BaseBotVoteAndDownloadMutationsAreAtomicAndIdempotent|BasesRoutesAreManagerProtectedAndImmutable|BaseModelsUseCamelCaseJSON|RegisterOmitsRemovedRoutesAndKeepsV2Routes)$'`
  — passed.
- `env GOCACHE=/tmp/clashking-api-go-cache go test ./internal/models/v2` —
  passed.
- `/Users/matthewanderson/go/bin/swag init -g main.go -o internal/docs` —
  completed successfully; generated Bases routes/models were added and the
  six repository-specific custom QUERY operation keys were restored.
- `go test ./...` — passed across every API package after localhost listener
  permission was granted for the existing proxy tests.
- `swag init --parseDependency --parseInternal --output internal/docs` —
  completed successfully with the existing Go runtime constant-evaluation
  warning; generated custom QUERY operation keys were preserved.
- `git diff --check` — passed.
- Targeted `rg` audit of every `auth_discord_tokens` and
  `auth_email_verifications` query confirms no decision 1–2 query reads or
  writes the dropped columns.
- Targeted `rg` audit of every `auth_password_reset_tokens` query confirms
  decision 3 reads or writes none of `id`, `used`, or `data`; only the HMAC
  code hash is persisted. The full `go test ./...` suite initially hit the
  sandbox's localhost bind restriction in `TestProxyForwardJoinsBaseAndEscapedPath`;
  rerunning with localhost test-port permission passed across all packages.
- Targeted `rg` audit of every `auth_refresh_tokens` query confirms decision 4
  reads or writes none of `revoked_at`, `data`, or `created_at`; hashed lookup
  uses the `token_hash` primary key, password reset uses the user prefix of
  `idx_auth_refresh_tokens_user_device`, and persisted expiry remains available
  to `idx_auth_refresh_tokens_expires_at`.

Downstream decision:

- Both ClashKing Dashboard and ClashKing App directly sent `device_name` to
  `/v2/auth/discord`, so focused saved-workspace tasks removed that stale
  request field and validated the callers. No other downstream auth surface was
  changed.
- Decision 3 does not change the forgot-password or reset-password
  request/response contracts. A direct audit confirmed Dashboard and App
  callers already match the unchanged API fields, so no downstream task or
  code change is relevant.
- Decision 4 keeps the Dashboard refresh request/response contract unchanged,
  and its active refresh path already stores the returned replacement refresh
  token, so no Dashboard change was required. The App consumed the same
  response but retained only the new access token; the persistent App task
  fixed that caller because delete-and-insert rotation invalidates the
  presented refresh token immediately.
- Decision 5 changes internal persistence/profile resolution without changing
  the Dashboard or App `AuthUserInfo` fields those callers consume, so neither
  downstream needed decision 5 code.
- Decision 6 and the authorized Bases feature require Dashboard implementation,
  so the existing persistent Dashboard task added the manager-only Clan
  Management page and exact API/proxy contracts. The App is explicitly
  unaffected: downloads are engagement history rather than saved bases, and
  no mobile saved/downloaded collection was created.
- Decision 9 requires the existing Dashboard Clan Management surface to expose
  category list/create/rename/delete and the server-scoped pre-delete affected
  count, so persistent Dashboard task
  `019f929f-bd3f-7ca0-ab74-f6ad08ddec1e` owns that focused UI/caller work. The
  ClashKing App does not manage server clan categories and requires no change.
- Decisions 10–14 require no downstream task. Dashboard's ranking/donation
  methods and README example are unused legacy wrappers, and its live
  countdown UI uses the unchanged API paths/contracts. The App ranking tab is
  feature-flagged preview UI with mock/local clan data and makes no rankings
  request. No Dashboard/App runtime caller consumes the legacy current-war
  timer response, and Tracking/Bot/App have no decision-11/12/14 SQL caller.
  Bot `custom_embeds` references are the legacy Mongo collection and remain
  untouched. No Dashboard or App code was changed.

## ClashKing Dashboard

Status: complete for the authorized Bases manager surface, decision 9 clan
category management, decision 16 typed giveaway caller migration, and the
migration-003 `open_tickets` retirement, destination follow-ups, and typed
Autoboards clean break, including the final server-generated create and
manager-delete contracts. Task
`019f929f-bd3f-7ca0-ab74-f6ad08ddec1e` is the persistent Dashboard owner for
this initiative; keep it unarchived and reuse it when a future schema decision
affects Dashboard.

Task: `019f929f-bd3f-7ca0-ab74-f6ad08ddec1e`

Outcome: Dashboard changes were required. The Discord OAuth exchange request no
longer declares or sends `device_name`; `device_id` and `redirect_uri` remain
unchanged. The separate `/v2/auth/link-discord` request surface was left
unchanged because it is outside the `/v2/auth/discord` contract.

Files:

- `lib/api/types/auth.ts`
- `lib/api-client.ts`
- `app/[locale]/auth/callback/page.tsx`
- `app/api/v2/auth/discord/route.test.ts`
- `tests/app/auth-callback/page.test.tsx`

Validation:

- `npm test -- app/api/v2/auth/discord/route.test.ts tests/app/auth-callback/page.test.tsx`
  — passed, 2 test files and 6 tests.
- `npx eslint lib/api/types/auth.ts lib/api-client.ts 'app/[locale]/auth/callback/page.tsx' app/api/v2/auth/discord/route.test.ts tests/app/auth-callback/page.test.tsx`
  — passed with no findings.
- `npx tsc --noEmit` — passed.
- `git diff --check` — passed.

### Migration 003 `open_tickets` Dashboard retirement

Status: complete in persistent Dashboard task
`019f929f-bd3f-7ca0-ab74-f6ad08ddec1e`; no new task was created.

Outcome: Removed the Dashboard contract and UI tied solely to the retired
legacy `open_tickets` JSON model. The mixed Tickets page now opens directly on
the operational ticket-panel editor, so panel creation/deletion, panel embed
selection and preview, buttons, approval messages, channel/log settings, and
the separate embed manager remain reachable. The existing
`/[locale]/dashboard/[guildId]/tickets/settings` redirect still lands on that
same operational page.

Removed contracts:

- `GET /v2/server/{serverId}/tickets/open`
- `PUT /v2/server/{serverId}/tickets/open/{channelId}/status`
- `PUT /v2/server/{serverId}/tickets/open/{channelId}/clan`
- `DELETE /v2/server/{serverId}/tickets/open/{channelId}`
- The corresponding `OpenTicket`, collection, status-request, and clan-request
  types plus all four `TicketsClient` methods were removed. No SQL `tickets`
  mapping or compatibility model was added.

Preserved contracts:

- Ticket panel collection/detail, button, approval-message, and panel-setting
  client/proxy calls under `/v2/server/{serverId}/tickets` remain unchanged.
- Embed collection/detail management under
  `/v2/server/{serverId}/embeds` remains unchanged and is still linked from
  the panel embed editor.

Files:

- `app/[locale]/dashboard/[guildId]/tickets/page.tsx`
- `app/[locale]/dashboard/[guildId]/tickets/page.test.tsx`
- `app/api/v2/server/[server_id]/tickets/open/route.ts` (removed)
- `app/api/v2/server/[server_id]/tickets/open/[channel_id]/status/route.ts`
  (removed)
- `app/api/v2/server/[server_id]/tickets/open/[channel_id]/clan/route.ts`
  (removed)
- `app/api/v2/server/[server_id]/tickets/open/[channel_id]/route.ts` (removed)
- `app/api/v2/server/[server_id]/tickets/route.test.ts`
- `app/api/v2/server/[server_id]/embeds/[embed_name]/route.test.ts`
- `lib/api/clients/tickets-client.ts`
- `lib/api/clients/tickets-client.test.ts`
- `lib/api/types/tickets.ts`
- `messages/en.json`
- `messages/fr.json`
- `messages/nl.json`

Validation:

- `npx vitest run 'app/[locale]/dashboard/[guildId]/tickets/page.test.tsx' 'lib/api/clients/tickets-client.test.ts' 'app/api/v2/server/[server_id]/tickets/route.test.ts' 'app/api/v2/server/[server_id]/embeds/[embed_name]/route.test.ts`
  — passed, 4 test files and 6 tests. Coverage confirms the page loads panel
  and embed management directly without an open-ticket request, the retired
  client methods are absent, and surviving panel/embed proxy calls retain
  authorization, encoding, bodies, and response passthrough.
- Scoped ESLint over the touched Dashboard source and tests — passed with no
  findings.
- `npx next typegen` and `npx tsc --noEmit` — passed.
- `npm test` — passed, 47 test files and 322 tests.
- `npm run build` — passed. The production manifest emits the Tickets page,
  ticket panel collection/detail/buttons/approve-message routes, and embed
  routes; it emits none of the four retired `/tickets/open` routes.
- Locale JSON parse for `messages/en.json`, `messages/fr.json`, and
  `messages/nl.json` — passed.
- Retired-contract source search found no implementation reference to
  `/tickets/open`, `OpenTicket`, or the removed client methods; only explicit
  negative regression assertions name the removed methods.
- `git diff --check` — passed.

### Migration 003 server settings Dashboard batch

Status: complete in persistent Dashboard task
`019f929f-bd3f-7ca0-ab74-f6ad08ddec1e`; no new task was created.

Outcome: Removed live Dashboard response/request types, form state, controls,
payloads, tests, help text, and localization for the retired server settings
`api_token`, `banlist`, `strike_log`, `reddit_feed`, and `greeting`; role
setting `blacklisted_roles`; and clan settings `clan_channel`, `greeting`,
`auto_greet_option`, and `ban_alert_channel`. Embed color, full-whitelist and
canonical server-role settings, bans, strikes, countdowns, clan categories,
and clan role assignment remain operational. The separate player-link
verification `api_token` request is unrelated to server settings and remains
unchanged.

Contracts and product behavior:

- `ServerSettings` and `ServerSettingsUpdate` keep the API's existing
  snake_case wire convention. `link_parse` is now typed as exactly the five
  optional booleans `clan`, `army`, `player`, `base`, and `show`; no
  `channels` field is accepted or sent.
- `RoleSettings` and `RoleSettingsUpdate` no longer declare or send
  `blacklisted_roles`.
- `ClanSettingsUpdate` and the Clan Management form no longer declare, read,
  render, or send `clan_channel`, `greeting`, `auto_greet_option`, or
  `ban_alert_channel`. Legacy channel IDs are deliberately not converted into
  webhook IDs.
- Clan Management keeps category, abbreviation, member/leader role,
  countdown, and category-management behavior. A clan is considered
  configured from its canonical category rather than the retired
  `clan_channel` field.
- The existing webhook-based Logs page now exposes `ban_alert` in clan scope
  and `reddit_feed` in a server scope tab. Clan-scoped writes include the
  selected `clan_tag`; server-scoped writes omit `clan_tag`. Both continue to
  use the existing channel selector, thread selector, enabled state, and
  `/v2/server/{serverId}/logs` proxy flow.
- A full Dashboard caller and proxy audit found no use of retired
  `GET /v2/server/{serverId}/leaderboards/capital-raids`; no replacement was
  invented. The existing `/api/v1/leaderboard/{players|clans}/capital`
  Dashboard feature is a separate contract and remains unchanged.

Files:

- `app/[locale]/dashboard/[guildId]/general/page.tsx`
- `app/[locale]/dashboard/[guildId]/roles/page.tsx`
- `app/[locale]/dashboard/[guildId]/clans/page.tsx`
- `app/[locale]/dashboard/[guildId]/logs/page.tsx`
- `app/[locale]/dashboard/[guildId]/logs/page.test.tsx`
- `lib/api/types/server.ts`
- `lib/api/types/roles.ts`
- `lib/api/types/migration-003-contract.test.ts`
- `lib/api/clients/server-client.test.ts`
- `lib/api/clients/roles-client.test.ts`
- `messages/en.json`
- `messages/fr.json`
- `messages/nl.json`

Validation:

- `npx vitest run 'app/[locale]/dashboard/[guildId]/logs/page.test.tsx' lib/api/types/migration-003-contract.test.ts lib/api/clients/roles-client.test.ts lib/api/clients/server-client.test.ts 'app/[locale]/dashboard/[guildId]/clans/clan-category-manager.test.tsx' lib/dashboard-cache.test.ts`
  — passed, 6 test files and 20 tests. Coverage verifies server-scoped
  `reddit_feed` omits `clan_tag`, clan-scoped `ban_alert` includes the selected
  clan, retired settings fail compile-time contract guards, the five
  link-parse booleans contain no channel list, canonical role settings still
  PATCH correctly, and clan-category behavior remains intact.
- Scoped ESLint over every touched Dashboard source and test file — passed
  with no findings.
- `npx tsc --noEmit` — passed.
- `npm test` — passed, 50 test files and 328 tests.
- `npm run build` — passed; the production manifest includes General, Roles,
  Clans, Logs, Links, Bans and Strikes, and the canonical settings/log proxy
  routes.
- Locale JSON parse for `messages/en.json`, `messages/fr.json`, and
  `messages/nl.json` — passed.
- Retired-field source searches found no live settings/API/UI/localization
  reference. Remaining `api_token` references belong only to the preserved
  player-link verification contract plus an explicit negative type test.
- Exact retired capital-raids route search found no Dashboard caller or proxy.
- Dashboard and shared-report `git diff --check` — passed.

### Migration 003 Logs and Reminder destination Dashboard follow-up

Status: complete in persistent Dashboard task
`019f929f-bd3f-7ca0-ab74-f6ad08ddec1e`; local and unpublished.

Outcome: Updated the Logs and Reminders destination UI and wire types. Both
surfaces now treat a destination as a parent `channel_id` plus nullable
snake_case `thread_id`. Text and announcement/news parents can be used directly
or with one of their exact child threads; forum parents require a selected
child post/thread. Changing the parent clears the prior child, and Dashboard
validation rejects missing forum posts and mismatched parent/thread pairs
before the API repeats its authoritative guild membership and parent-child
validation. At the time of this follow-up, forum acceptance was limited to
Logs and Reminders. The later typed Autoboards clean break separately adopted
the same parent/thread destination contract; ticketing, panels, giveaways,
rosters, embeds, and every other channel selector remain unchanged.

Logs now load forum parents and active child threads with the initial page
data, so the migrated guild `923764211845312533` row using webhook
`1128181917582364703`, forum parent `1127708751479197806`, and a stored child
thread resolves as configured instead of showing the false “channel no longer
exists” issue. Parent and child are saved atomically through the unchanged PUT
shape `{channel_id, thread_id, log_types, clan_tag?}`. The existing Server tab
and server/clan scope behavior are unchanged. Active Logs now counts every
configured, enabled row across all family clans plus server-scoped rows,
independent of the selected clan. Issues uses the same family-wide scope and
counts enabled rows with a missing/unsupported parent, required forum child,
or invalid parent-child relationship. Both cards explicitly localize that
complete-family scope.

Reminder reads consume nullable `thread_id`; create and update send parent
`channel_id` plus nullable `thread_id`. Existing reminder cards show the
parent/thread destination and open the child in Discord when present.

Exact Dashboard files:

- `app/[locale]/dashboard/[guildId]/logs/page.tsx`
- `app/[locale]/dashboard/[guildId]/logs/page.test.tsx`
- `app/[locale]/dashboard/[guildId]/reminders/page.tsx`
- `app/[locale]/dashboard/[guildId]/reminders/page.test.tsx`
- `lib/discord-destinations.ts`
- `lib/discord-destinations.test.ts`
- `messages/en.json`
- `messages/fr.json`
- `messages/nl.json`

Validated contract: Logs PUT remains `{channel_id, thread_id?, log_types,
clan_tag?}`. GET reminder rows expose `thread_id: string | null`; reminder POST
and PUT accept `channel_id` plus nullable `thread_id`. Discord parent types are
text `0`, announcement/news `5`, and forum `15`/`forum`; `/threads` supplies
active children with `parent_channel_id`. The existing Next proxies forward
request bodies and API errors unchanged, so no proxy file required
modification. API destination validation returns HTTP 400 with
`code: "validation_failed"`, `message: "Invalid Discord destination"`,
`request_id`, and field-level `details`; Discord lookup failures other than a
missing destination return HTTP 502 with `code: "upstream_unavailable"`.

Validation:

- `npx vitest run 'app/[locale]/dashboard/[guildId]/logs/page.test.tsx'
  'app/[locale]/dashboard/[guildId]/reminders/page.test.tsx'
  lib/discord-destinations.test.ts` — passed, 3 files and 14 tests. Coverage
  includes the exact migrated forum parent/webhook display, required forum
  posts, optional text/news threads, atomic parent/thread payloads, parent
  switching clearing the child, exact parent-child validation, unchanged
  server/clan log scope, and family-wide Active Logs/Issues counts.
- `npm test -- --run` — passed, 52 files and 340 tests.
- `npm run lint` — passed with no findings.
- `npx tsc --noEmit --pretty false` — passed.
- `npm run build` — passed; Next.js 16.2.10 compiled, type-checked, generated
  all 23 static pages, and retained the Logs and Reminder pages plus their
  log/reminder/thread proxy routes in the production manifest.
- Dashboard `git diff --check` — passed.

Delivery boundary: Bot work remains explicitly out of scope. Tracking/Bot must
still carry and consume `thread_id` when dispatching reminder events before
child-thread delivery can be called end-to-end compatible; this Dashboard task
does not claim that deferred runtime delivery work.

### Migration 003 typed Autoboards Dashboard clean break

Status: complete in persistent Dashboard task
`019f929f-bd3f-7ca0-ab74-f6ad08ddec1e`; local, uncommitted, and unpublished.
No App or Bot work was added, and the Dashboard did not modify migration or
seed SQL.

Outcome: Replaced the legacy hardcoded Autoboards catalog and its
post/refresh/button/day/locale contract outright. The Dashboard now renders
only board types returned by the manager-authorized registry endpoint and
supports an intentionally empty registry without inventing the future board
catalog. The UI uses the API term `targets` exclusively. Registry metadata
drives target kind, family/custom scope availability, custom target minimum
and maximum cardinality (including an exact-one location rule), delivery mode
availability, and refresh interval bounds. Family scope always sends an empty
target list; custom target values remain opaque strings for the API to
interpret and normalize by `targetKind`.

The shared API checkout also contains five explicitly sample-prefixed registry
definitions requested for demonstration: family overview, clan activity,
player leaderboard, location rankings, and war summary. They exercise
family/custom scope, clan/player/location/war target kinds and cardinalities,
and refresh/send constraints. Their `sample-*` identifiers and labels make
their non-permanent status explicit while the final catalog remains undecided.

Contracts and operational behavior:

- `GET /v2/server/{serverId}/autoboards/capabilities` consumes
  `{boardTypes:[{boardType,label,targetKind,minTargets,maxTargets,
  allowedScopes,allowedModes,refreshInterval,uiCapabilities}]}`. The parser
  accepts the API's legitimate `{boardTypes:[]}` empty-registry response; no
  Dashboard board-type catalog or compatibility alias remains.
- `GET /v2/server/{serverId}/autoboards` consumes the typed `items`, `total`,
  `refreshCount`, `sendCount`, and `limit` response. The page shows target
  scope/history, destination, schedule/interval, enabled state, next run, and
  the read-only current `messageId` for refresh boards when present.
- `POST /v2/server/{serverId}/autoboards` and full-replacement `PUT
  /v2/server/{serverId}/autoboards/{autoboardId}` send exactly `boardType`,
  `targetScope`, `targets`, `deliveryMode`, `channelId`, nullable `threadId`,
  `enabled`, nullable `intervalMinutes`, and nullable typed
  `schedule`. The retired PATCH route and partial-update behavior were removed.
- Refresh mode sends a registry-bounded `intervalMinutes` and no schedule.
  Dashboard never includes `messageId` in POST or PUT. API creation stores it
  null and full replacement clears it so the future executor exclusively owns
  establishing refresh-message state. Send mode sends a null interval plus a
  daily, selected-ISO-weekday, or day-of-month schedule with IANA timezone and
  `HH:MM` time.
- Destination selection sends the parent channel and nullable child atomically.
  Text and announcement/news parents may deliver directly or to an exact child
  thread; forum parents require an exact child post. Parent changes clear the
  selected child, and Dashboard validation rejects missing forum posts and
  mismatched parent/thread pairs before API validation.
- The page now uses the same centered `max-w-7xl` content shell and responsive
  `p-4`/`p-6`/`p-8` gutters as the surrounding management surfaces. Header,
  alerts, metrics, filters, and the empty state have consistent responsive
  spacing, and a load failure no longer renders a contradictory empty-registry
  notice underneath it. The metric cards no longer use the shared
  header-oriented `CardContent` primitive, whose `pt-0` rule crowded their
  labels against the top edge; each now has one balanced, vertically centered
  `p-5` body.
- API capability serialization preserves empty `uiCapabilities` as `[]`
  rather than Go `null`, including the five demonstrable sample definitions.
  Dashboard also continues to accept a legitimate future
  `{boardTypes:[]}` response without inventing a local catalog.
- `DELETE /v2/server/{serverId}/autoboards/{autoboardId}` remains available to
  managers. API error envelopes and response messages are preserved for
  validation, missing/conflicting records, Discord failures, and persistence
  failures.
- Movable Clash-event triggers were not added. SQL scheduler execution in Bot
  remains outside this Dashboard task and is a disclosed deferred integration
  boundary; there is no App/saved-board behavior.

Exact Dashboard files:

- `app/[locale]/dashboard/[guildId]/autoboards/page.tsx`
- `app/[locale]/dashboard/[guildId]/autoboards/page.test.tsx`
- `app/[locale]/dashboard/[guildId]/autoboards/autoboards.ts`
- `app/[locale]/dashboard/[guildId]/autoboards/autoboards.test.ts`
- `app/api/v2/server/[server_id]/autoboards/route.ts`
- `app/api/v2/server/[server_id]/autoboards/route.test.ts`
- `app/api/v2/server/[server_id]/autoboards/[autoboard_id]/route.ts`
- `app/api/v2/server/[server_id]/autoboards/[autoboard_id]/route.test.ts`
- `app/api/v2/server/[server_id]/autoboards/capabilities/route.ts`
- `app/api/v2/server/[server_id]/autoboards/capabilities/route.test.ts`
- `messages/en.json`
- `messages/fr.json`
- `messages/nl.json`

Exact API sample-registry files:

- `internal/routes/server/autoboards.go`
- `internal/routes/server/autoboards_test.go`

Validation:

- `npm test -- --run 'app/[locale]/dashboard/[guildId]/autoboards/autoboards.test.ts' 'app/[locale]/dashboard/[guildId]/autoboards/page.test.tsx' 'app/api/v2/server/[server_id]/autoboards/route.test.ts' 'app/api/v2/server/[server_id]/autoboards/[autoboard_id]/route.test.ts' 'app/api/v2/server/[server_id]/autoboards/capabilities/route.test.ts'`
  — passed, 5 files and 13 tests. Coverage includes empty/live registry
  parsing, exact-one custom target cardinality, family targets, refresh bounds,
  every typed schedule shape, complete write-payload omission of `messageId`,
  forum-required child selection, optional direct text delivery, atomic
  parent/thread writes, parent switching, full PUT, delete, and API error
  forwarding.
- Scoped ESLint over all Autoboards page/helper/proxy source and tests — passed
  with no findings.
- `npm test` — passed, 57 files and 353 tests.
- `npm run lint` — passed with no findings.
- `npx tsc --noEmit` — passed.
- `npm run build` — passed with Next.js 16.2.10; the production manifest emits
  the Autoboards page and collection, item, and capabilities proxy routes.
- Focused API Autoboard route, registration, model, destination, transaction,
  sample-registry serialization, and empty-array tests passed.
- `env GOCACHE=/tmp/clashking-api-go-cache go vet ./...` and `go build ./...`
  in ClashKing API — passed.
- `env GOCACHE=/tmp/clashking-api-go-cache go test ./test/api -run
  TestAutoboardOpenAPIUsesTypedCleanBreakContract` — passed after the
  persistent API owner regenerated Swagger for the final camelCase contract.
  The documented create/full-PUT request omits response-only `messageId`.
- Dashboard and shared-report `git diff --check` — passed.

### Authorized Bases Dashboard

Status: manager-delete addendum and channel-selector/server-generated message
correction complete in persistent Dashboard task
`019f929f-bd3f-7ca0-ab74-f6ad08ddec1e`.

Outcome: Added a manager-only Bases page under Clan Management using the
existing Dashboard access context, authenticated API client, and Next.js proxy
patterns. Existing bases cannot be edited: the Dashboard exposes list, read,
create, image upload, lazy downloader-profile reads, and an authorized delete
action, with no PUT/PATCH/edit/vote/download controls.

Contracts:

- `GET /v2/server/{serverId}/bases?limit=50&offset=0` returns the paginated
  camelCase Base collection.
- `GET /v2/server/{serverId}/bases/{baseId}` returns one Base.
- `POST /v2/server/{serverId}/bases` sends only the selected channel value,
  `baseLink`, uploaded `images`, and `description`; `messageId` is generated by
  the backend after it sends the Discord message.
- `POST /v2/server/{serverId}/bases/images` forwards multipart field `file`
  before base creation.
- `GET /v2/server/{serverId}/bases/{baseId}/downloaders/{userId}` resolves one
  downloader only after a manager clicks that raw Discord user ID.
- `DELETE /v2/server/{serverId}/bases/{baseId}` removes the base through the
  manager-authorized API. HTTP 200 returns camelCase `baseId`,
  `databaseDeleted: true`, and `discordMessageCleanup` as `deleted` or
  `alreadyMissing`.
- The create form reuses the existing server-scoped Discord channel selector;
  it has no free-text channel ID or message ID field.
- Structured create failures preserve the API's camelCase `code`, `message`,
  `requestId`, `databaseInserted`, `discordMessageCreated`,
  `discordMessageId`, `discordMessageCleanup`, and `retryable` fields. The
  Dashboard distinguishes pre-message rejection (`notNeeded`), completed
  orphan cleanup (`deleted` or `alreadyMissing`), and failed orphan cleanup
  (`failed`). A failed cleanup explicitly warns that the Discord message may
  remain and that automatic retry is unsafe because it could create a
  duplicate message.
- Delete failures preserve the API's structured `code`, `message`, `requestId`,
  `baseId`, `databaseDeleted`, `discordMessageCleanup`, and `retryable` fields.
  The Dashboard explicitly distinguishes Discord cleanup failure from the
  HTTP 500 case where Discord cleanup completed but database deletion failed;
  it never claims the Discord message was deleted without that API outcome.
- `downloadCount` is the API-derived cardinality of the unique `downloaders`
  set. `upvotes` and `downvotes` are API-derived cardinalities of
  `upvoter_ids` and `downvoter_ids`; the Dashboard receives numeric counts
  only and never receives voter ID arrays.

Product boundary: downloader IDs are read-only manager engagement history, not
saved-base collections. Vote/download mutations remain trusted-bot-only and
are not called by the Dashboard. No ClashKing App/mobile behavior was added or
required.

Files:

- `app/[locale]/dashboard/[guildId]/bases/page.tsx`
- `app/[locale]/dashboard/[guildId]/bases/page.test.tsx`
- `app/[locale]/dashboard/[guildId]/bases/bases-utils.ts`
- `app/[locale]/dashboard/[guildId]/bases/bases-utils.test.ts`
- `app/api/v2/server/[server_id]/bases/route.ts`
- `app/api/v2/server/[server_id]/bases/route.test.ts`
- `app/api/v2/server/[server_id]/bases/images/route.ts`
- `app/api/v2/server/[server_id]/bases/images/route.test.ts`
- `app/api/v2/server/[server_id]/bases/[base_id]/route.ts`
- `app/api/v2/server/[server_id]/bases/[base_id]/route.test.ts`
- `app/api/v2/server/[server_id]/bases/[base_id]/downloaders/[user_id]/route.ts`
- `app/api/v2/server/[server_id]/bases/[base_id]/downloaders/[user_id]/route.test.ts`
- `lib/api/types/bases.ts`
- `lib/api/types/common.ts`
- `lib/api/clients/bases-client.ts`
- `lib/api/clients/bases-client.test.ts`
- `lib/api/core/base-client.ts`
- `lib/api/client.ts`
- `lib/api/index.ts`
- `components/dashboard/sidebar.tsx`
- `components/dashboard/dashboard-access-provider.tsx`
- `messages/en.json`
- `messages/fr.json`
- `messages/nl.json`

Validation:

- `npm test -- 'app/api/v2/server/[server_id]/bases/route.test.ts' 'app/api/v2/server/[server_id]/bases/images/route.test.ts' 'app/api/v2/server/[server_id]/bases/[base_id]/downloaders/[user_id]/route.test.ts' 'app/[locale]/dashboard/[guildId]/bases/bases-utils.test.ts' lib/api/clients/bases-client.test.ts`
  — passed, 5 test files and 10 tests.
- `npm test -- lib/api/client.test.ts` — passed, 1 test file and 8 tests,
  covering the composed client after adding the Bases domain.
- `npm test -- 'app/[locale]/dashboard/[guildId]/bases/page.test.tsx' 'app/[locale]/dashboard/[guildId]/bases/bases-utils.test.ts' 'app/api/v2/server/[server_id]/bases/[base_id]/route.test.ts' 'app/api/v2/server/[server_id]/bases/route.test.ts' 'app/api/v2/server/[server_id]/bases/images/route.test.ts' 'app/api/v2/server/[server_id]/bases/[base_id]/downloaders/[user_id]/route.test.ts' lib/api/clients/bases-client.test.ts lib/api/core/base-client.test.ts`
  — passed, 8 test files and 68 tests. The page coverage confirms the
  server-scoped channel selector sends no manager-supplied message ID, plus
  structured HTTP 500 create feedback when Discord cleanup fails,
  `alreadyMissing` delete success, and fail-closed HTTP 500 delete behavior
  with Discord cleanup complete and the database row retained.
- `npm test -- 'app/[locale]/dashboard/[guildId]/bases/page.test.tsx' 'app/[locale]/dashboard/[guildId]/bases/bases-utils.test.ts'`
  — passed, 2 test files and 11 tests after the final strict structured-create
  response guard.
- `npx eslint 'app/[locale]/dashboard/[guildId]/bases/page.tsx' 'app/[locale]/dashboard/[guildId]/bases/page.test.tsx' 'app/[locale]/dashboard/[guildId]/bases/bases-utils.ts' 'app/[locale]/dashboard/[guildId]/bases/bases-utils.test.ts' 'app/api/v2/server/[server_id]/bases/route.ts' 'app/api/v2/server/[server_id]/bases/route.test.ts' 'app/api/v2/server/[server_id]/bases/images/route.ts' 'app/api/v2/server/[server_id]/bases/images/route.test.ts' 'app/api/v2/server/[server_id]/bases/[base_id]/route.ts' 'app/api/v2/server/[server_id]/bases/[base_id]/route.test.ts' 'app/api/v2/server/[server_id]/bases/[base_id]/downloaders/[user_id]/route.ts' 'app/api/v2/server/[server_id]/bases/[base_id]/downloaders/[user_id]/route.test.ts' lib/api/types/bases.ts lib/api/clients/bases-client.ts lib/api/clients/bases-client.test.ts lib/api/core/base-client.ts lib/api/core/base-client.test.ts lib/api/index.ts`
  — passed with no findings for the final structured create/delete addendum.
- `npx eslint 'app/[locale]/dashboard/[guildId]/bases/page.tsx' 'app/[locale]/dashboard/[guildId]/bases/bases-utils.ts' 'app/[locale]/dashboard/[guildId]/bases/bases-utils.test.ts' 'app/api/v2/server/[server_id]/bases/route.ts' 'app/api/v2/server/[server_id]/bases/route.test.ts' 'app/api/v2/server/[server_id]/bases/images/route.ts' 'app/api/v2/server/[server_id]/bases/images/route.test.ts' 'app/api/v2/server/[server_id]/bases/[base_id]/route.ts' 'app/api/v2/server/[server_id]/bases/[base_id]/downloaders/[user_id]/route.ts' 'app/api/v2/server/[server_id]/bases/[base_id]/downloaders/[user_id]/route.test.ts' lib/api/types/bases.ts lib/api/clients/bases-client.ts lib/api/clients/bases-client.test.ts lib/api/client.ts lib/api/index.ts components/dashboard/sidebar.tsx components/dashboard/dashboard-access-provider.tsx`
  — passed with no findings.
- `npx tsc --noEmit` — passed.
- `npm run build` — passed; the Bases page and all four Bases proxy route
  patterns were emitted by the production build.
- Locale JSON parse for `messages/en.json`, `messages/fr.json`, and
  `messages/nl.json` — passed.
- Forbidden-contract searches found no `.downloads` field, separate vote-table
  assumption, voter ID array exposure, Bases PUT/PATCH/edit surface, or public
  vote/download control.
- `git diff --check` — passed.

### Decision 9 clan-category management

Status: complete in persistent Dashboard task
`019f929f-bd3f-7ca0-ab74-f6ad08ddec1e`; the task remains the Dashboard owner
and should stay unarchived.

Outcome: Added dense operational category management to the existing Clan
Management page. Managers can list, create, rename, preview deletion, and
delete server-owned categories through the authenticated client and Next.js
proxy. Every successful create, rename, or delete refreshes both category and
clan state. Clan settings keep their existing category string/clear behavior,
use the API's normalized category records as the list source, and refresh
categories after assignment so an atomically created category appears
immediately.

Contracts:

- `GET /v2/server/{serverId}/clan-categories` returns camelCase `items` and
  `total`, with each `ClanCategory` containing `id`, `serverId`, `name`, and
  live `clanCount`.
- `POST /v2/server/{serverId}/clan-categories` sends only `{name}` and consumes
  `{category}`; `PATCH
  /v2/server/{serverId}/clan-categories/{categoryId}` uses the same body and
  response wrapper.
- The UI mirrors the API's normalization boundary: collapsed whitespace,
  non-empty names, no control characters, and at most 64 Unicode code points.
  The API remains authoritative for exact-name conflicts and returns the
  shared 400/404/409 error envelope without Dashboard compatibility aliases.
- A manager delete action first calls `GET
  /v2/server/{serverId}/clan-categories/{categoryId}/delete-preview`. The
  confirmation dialog opens only after that real response and explicitly
  warns that `affectedClanCount` clans will become uncategorized.
- `DELETE /v2/server/{serverId}/clan-categories/{categoryId}` consumes the
  committed `uncategorizedClanCount`. The Dashboard renders that actual locked
  count after success and does not reuse or assume the preview count.
- Clan settings PATCH remains a category name string/clear request and now has
  the typed `ClanSettingsResponse.category: ClanCategory | null` response.
  Exact existing names select their category; valid new names are created and
  assigned atomically by the API.

Files:

- `app/[locale]/dashboard/[guildId]/clans/page.tsx`
- `app/[locale]/dashboard/[guildId]/clans/clan-category-manager.tsx`
- `app/[locale]/dashboard/[guildId]/clans/clan-category-manager.test.tsx`
- `app/api/v2/server/[server_id]/clan-categories/route.ts`
- `app/api/v2/server/[server_id]/clan-categories/route.test.ts`
- `app/api/v2/server/[server_id]/clan-categories/[category_id]/route.ts`
- `app/api/v2/server/[server_id]/clan-categories/[category_id]/route.test.ts`
- `app/api/v2/server/[server_id]/clan-categories/[category_id]/delete-preview/route.ts`
- `app/api/v2/server/[server_id]/clan-categories/[category_id]/delete-preview/route.test.ts`
- `lib/api/types/clan-categories.ts`
- `lib/api/types/clan-categories.test.ts`
- `lib/api/clients/clan-categories-client.ts`
- `lib/api/clients/clan-categories-client.test.ts`
- `lib/api/types/server.ts`
- `lib/api/clients/server-client.ts`
- `lib/api/clients/server-client.test.ts`
- `lib/api/client.ts`
- `lib/api/client.test.ts`
- `lib/api/index.ts`
- `messages/en.json`
- `messages/fr.json`
- `messages/nl.json`

Validation:

- `npm test -- 'app/[locale]/dashboard/[guildId]/clans/clan-category-manager.test.tsx' 'app/api/v2/server/[server_id]/clan-categories/route.test.ts' 'app/api/v2/server/[server_id]/clan-categories/[category_id]/route.test.ts' 'app/api/v2/server/[server_id]/clan-categories/[category_id]/delete-preview/route.test.ts' lib/api/clients/clan-categories-client.test.ts lib/api/types/clan-categories.test.ts lib/api/clients/server-client.test.ts lib/api/client.test.ts`
  — passed, 8 test files and 25 tests. Coverage includes exact camelCase model
  guards, all five client calls, proxy authorization/body/error/status
  forwarding, cross-server 404 handling, Unicode/name validation, refreshes
  after create/rename/delete, preview-before-confirm behavior, and rendering
  the actual delete count when it differs from the preview.
- `npm test -- 'app/[locale]/dashboard/[guildId]/clans/clan-category-manager.test.tsx'`
  — passed, 1 test file and 4 tests after the final duplicate-submission guard.
- `npx eslint 'app/[locale]/dashboard/[guildId]/clans/page.tsx' 'app/[locale]/dashboard/[guildId]/clans/clan-category-manager.tsx' 'app/[locale]/dashboard/[guildId]/clans/clan-category-manager.test.tsx' 'app/api/v2/server/[server_id]/clan-categories/route.ts' 'app/api/v2/server/[server_id]/clan-categories/route.test.ts' 'app/api/v2/server/[server_id]/clan-categories/[category_id]/route.ts' 'app/api/v2/server/[server_id]/clan-categories/[category_id]/route.test.ts' 'app/api/v2/server/[server_id]/clan-categories/[category_id]/delete-preview/route.ts' 'app/api/v2/server/[server_id]/clan-categories/[category_id]/delete-preview/route.test.ts' lib/api/types/clan-categories.ts lib/api/types/clan-categories.test.ts lib/api/clients/clan-categories-client.ts lib/api/clients/clan-categories-client.test.ts lib/api/clients/server-client.ts lib/api/clients/server-client.test.ts lib/api/client.ts lib/api/client.test.ts lib/api/index.ts lib/api/types/server.ts`
  — passed with no findings.
- `npx tsc --noEmit` — passed.
- `npm run build` — passed; the production route manifest contains the
  collection, detail, and delete-preview clan-category proxy patterns.
- Locale JSON parse for `messages/en.json`, `messages/fr.json`, and
  `messages/nl.json` — passed.
- `git diff --check` — passed.

Product boundary: this is server-manager Dashboard configuration only. No
ClashKing App/mobile work was added.

### Decision 16 typed giveaway caller migration

Status: complete in persistent Dashboard task
`019f929f-bd3f-7ca0-ab74-f6ad08ddec1e`; no new task was created.

Outcome: Migrated the active Giveaway client and every visible Dashboard read
from the removed snake_case/JSONB-era representation to the typed external
camelCase contract. List rows, summary counts, editing, duplication, Discord
message links, eligibility badges, winners, rerolls, and entrant details
retain their existing behavior. The list loader now rejects stale snake_case
models and removed `{data: ...}` wrappers instead of silently accepting them.

Contracts:

- `Giveaway` now uses `id`, `serverId`, `prize`, `channelId`, `status`,
  `startTime`, `endTime`, `winners`, `mentions`, `textAboveEmbed`,
  `textInEmbed`, `textOnEnd`, `imageUrl`, `profilePictureRequired`,
  `cocAccountRequired`, `rolesMode`, `roles`, `boosters`, `entryCount`,
  `updated`, `messageId`, `winnersList`, `eventPending`, `eventPendingAt`,
  `createdAt`, and `updatedAt`.
- Nested winners use camelCase `userId` and `avatarUrl`. Entries responses use
  `giveawayId`, `serverId`, `totalEntries`, `uniqueUsers`, and entrant
  `userId`/`winChance`. Mutation and reroll responses use `giveawayId`,
  `serverId`, and `newWinners`.
- The existing multipart create/update form keys and reroll
  `user_ids_to_replace` request body remain unchanged; decision 16 changes
  external JSON responses, not those input contracts.
- No response type or UI path reads or reconstructs removed
  `giveaways.data`.

Files:

- `app/[locale]/dashboard/[guildId]/giveaways/GiveawaysClient.tsx`
- `app/[locale]/dashboard/[guildId]/giveaways/GiveawaysClient.test.ts`
- `app/[locale]/dashboard/[guildId]/giveaways/useGiveawayEntries.ts`
- `app/[locale]/dashboard/[guildId]/giveaways/useGiveawayEntries.test.ts`
- `app/api/v2/server/[server_id]/giveaways/route.test.ts`
- `app/api/v2/server/[server_id]/giveaways/[giveaway_id]/entries/route.test.ts`
- `lib/api/types/server.ts`
- `lib/api/types/giveaways.test.ts`
- `lib/api/clients/server-client.ts`
- `lib/api/clients/server-client.test.ts`
- `lib/api/index.ts`

Validation:

- `npm test -- 'app/[locale]/dashboard/[guildId]/giveaways/GiveawaysClient.test.ts' 'app/[locale]/dashboard/[guildId]/giveaways/useGiveawayEntries.test.ts' 'app/api/v2/server/[server_id]/giveaways/route.test.ts' 'app/api/v2/server/[server_id]/giveaways/[giveaway_id]/entries/route.test.ts' lib/api/types/giveaways.test.ts lib/api/clients/server-client.test.ts`
  — passed, 6 test files and 16 tests. Coverage includes exact camelCase model
  acceptance, stale snake_case and removed-data rejection, collection/entry
  proxy passthrough, typed mutation/entries/reroll client responses, and
  edit/duplicate visible-state preservation.
- `npx eslint 'app/[locale]/dashboard/[guildId]/giveaways/GiveawaysClient.tsx' 'app/[locale]/dashboard/[guildId]/giveaways/GiveawaysClient.test.ts' 'app/[locale]/dashboard/[guildId]/giveaways/useGiveawayEntries.ts' 'app/[locale]/dashboard/[guildId]/giveaways/useGiveawayEntries.test.ts' 'app/api/v2/server/[server_id]/giveaways/route.test.ts' 'app/api/v2/server/[server_id]/giveaways/[giveaway_id]/entries/route.test.ts' lib/api/types/server.ts lib/api/types/giveaways.test.ts lib/api/clients/server-client.ts lib/api/clients/server-client.test.ts lib/api/index.ts`
  — passed with no findings.
- `npx tsc --noEmit` — passed.
- `npm run build` — passed; the production build includes the Giveaway page
  and its collection/detail/entries/reroll proxies.
- Targeted stale-response-field audit found no snake_case giveaway response
  property reads in the active UI/client/types; the remaining snake_case names
  are intentional multipart or reroll request keys.
- `git diff --check` — passed.

Product boundary: no ClashKing App or Bot work was added, and no new downstream
task was created.

## ClashKing App

Status: complete for Discord OAuth caller compatibility, decision 4 refresh
token rotation, migration 003 iOS Live Activities removal, and migration 003
retired synthetic ranking-history caller cleanup. Migration 003 notification
normalization, push-device payload cleanup, the one-time-login-token App audit,
retired player Raid Weekend initialization cleanup, and normalized current
player rankings contract alignment are also complete. Task
`019f92aa-b5fb-77f1-8370-85a80d9cfb3a` is the persistent App owner for this
initiative and remains unarchived for future relevant follow-ups.

Tasks:

- `019f929f-be56-7fe2-8b16-a28d3872ba6e`: Discord OAuth caller compatibility
- `019f92aa-b5fb-77f1-8370-85a80d9cfb3a`: decision 4 refresh-token rotation
- `019f92aa-b5fb-77f1-8370-85a80d9cfb3a`: migration 003 iOS Live Activities
  removal
- `019f92aa-b5fb-77f1-8370-85a80d9cfb3a`: migration 003 retired Town Hall and
  Ranked League history caller cleanup
- `019f92aa-b5fb-77f1-8370-85a80d9cfb3a`: migration 003 notification,
  push-device, and retired one-time-login caller cleanup
- `019f92aa-b5fb-77f1-8370-85a80d9cfb3a`: migration 003 retired player
  Raid Weekend initialization/UI cleanup and final current player rankings
  response/mobile-initialization contract alignment

Files:

- `/Users/matthewanderson/IdeaProjects/ClashKingApp/lib/features/auth/data/auth_service.dart`
- `/Users/matthewanderson/IdeaProjects/ClashKingApp/test/features/auth/data/auth_service_test.dart`
- `/Users/matthewanderson/IdeaProjects/ClashKingApp/lib/core/services/token_service.dart`
- `/Users/matthewanderson/IdeaProjects/ClashKingApp/test/core/services/token_service_test.dart`
- `/Users/matthewanderson/IdeaProjects/ClashKingApp/lib/core/services/live_activity_debug_service.dart`
  (deleted)
- `/Users/matthewanderson/IdeaProjects/ClashKingApp/lib/features/settings/presentation/settings_page.dart`
- `/Users/matthewanderson/IdeaProjects/ClashKingApp/ios/Runner/LiveActivityDebugPlugin.swift`
  (deleted)
- `/Users/matthewanderson/IdeaProjects/ClashKingApp/ios/Runner/AppDelegate.swift`
- `/Users/matthewanderson/IdeaProjects/ClashKingApp/ios/Runner/Info.plist`
- `/Users/matthewanderson/IdeaProjects/ClashKingApp/ios/Runner.xcodeproj/project.pbxproj`
- `/Users/matthewanderson/IdeaProjects/ClashKingApp/ios/WarWidget/WarWidget.swift`
- `/Users/matthewanderson/IdeaProjects/ClashKingApp/lib/l10n/app_{af,ar,ca,cs,da,de,el,en,en_GB,en_US,es,es_ES,fi,fr,he,hi,hu,it,ja,ko,nl,no,pl,pt,ro,ru,sr,sv,tr,uk,ur,vi,zh}.arb`
- `/Users/matthewanderson/IdeaProjects/ClashKingApp/feature-flags-audit.md`
- `/Users/matthewanderson/IdeaProjects/ClashKingApp/docs/translation_audit_notes.md`
- `/Users/matthewanderson/IdeaProjects/ClashKingApp/sonar-project.properties`
- `/Users/matthewanderson/IdeaProjects/ClashKingApp/lib/features/rankings/data/rankings_service.dart`
- `/Users/matthewanderson/IdeaProjects/ClashKingApp/lib/features/rankings/models/ranking_models.dart`
- `/Users/matthewanderson/IdeaProjects/ClashKingApp/test/features/rankings/data/rankings_service_test.dart`
- `/Users/matthewanderson/IdeaProjects/ClashKingApp/test/features/rankings/data/rankings_provider_test.dart`
- `/Users/matthewanderson/IdeaProjects/ClashKingApp/test/features/rankings/presentation/rankings_page_test.dart`
- `/Users/matthewanderson/IdeaProjects/ClashKingApp/lib/core/models/notification_preferences.dart`
- `/Users/matthewanderson/IdeaProjects/ClashKingApp/lib/core/services/notification_preferences_service.dart`
- `/Users/matthewanderson/IdeaProjects/ClashKingApp/lib/core/services/push_notification_service.dart`
- `/Users/matthewanderson/IdeaProjects/ClashKingApp/lib/features/pages/data/announcement_presentation_service.dart`
- `/Users/matthewanderson/IdeaProjects/ClashKingApp/lib/features/settings/presentation/notification_settings_page.dart`
- `/Users/matthewanderson/IdeaProjects/ClashKingApp/test/core/services/notification_preferences_service_test.dart`
- `/Users/matthewanderson/IdeaProjects/ClashKingApp/test/core/services/push_notification_service_test.dart`
- `/Users/matthewanderson/IdeaProjects/ClashKingApp/test/features/pages/data/announcement_presentation_service_test.dart`
- `/Users/matthewanderson/IdeaProjects/ClashKingApp/test/features/settings/presentation/notification_settings_page_test.dart`
- `/Users/matthewanderson/IdeaProjects/ClashKingApp/lib/core/functions/functions.dart`
- `/Users/matthewanderson/IdeaProjects/ClashKingApp/lib/features/player/models/player.dart`
- `/Users/matthewanderson/IdeaProjects/ClashKingApp/lib/features/player/models/player_raids.dart`
  (deleted)
- `/Users/matthewanderson/IdeaProjects/ClashKingApp/lib/features/player/models/player_rankings.dart`
- `/Users/matthewanderson/IdeaProjects/ClashKingApp/lib/features/player/presentation/legend/player_legend_header.dart`
- `/Users/matthewanderson/IdeaProjects/ClashKingApp/lib/features/player/presentation/to_do/widget/player_to_do_body_card.dart`
- `/Users/matthewanderson/IdeaProjects/ClashKingApp/lib/features/player/presentation/to_do/widget/player_to_do_header.dart`
- `/Users/matthewanderson/IdeaProjects/ClashKingApp/lib/features/pages/widgets/home_todo_card.dart`
- `/Users/matthewanderson/IdeaProjects/ClashKingApp/test/features/player/data/player_service_test.dart`
- `/Users/matthewanderson/IdeaProjects/ClashKingApp/test/features/player/models/player_rankings_test.dart`
- The existing 33 ARB files listed above and generated
  `/Users/matthewanderson/IdeaProjects/ClashKingApp/lib/l10n/app_localizations*.dart`

Validation:

- `dart format lib/features/auth/data/auth_service.dart test/features/auth/data/auth_service_test.dart`
  passes; 2 files formatted, 0 changed.
- `flutter test test/features/auth/data/auth_service_test.dart` passes; all
  51 tests passed.
- `flutter analyze lib/features/auth/data/auth_service.dart test/features/auth/data/auth_service_test.dart`
  passes; no issues found.
- `dart format lib/core/services/token_service.dart test/core/services/token_service_test.dart`
  passes; 2 files formatted, 1 changed.
- `flutter test test/core/services/token_service_test.dart` passes; all 7 tests
  passed.
- `flutter analyze lib/core/services/token_service.dart test/core/services/token_service_test.dart`
  passes; no issues found.
- `dart format lib/features/settings/presentation/settings_page.dart` passes; 1
  file formatted, 0 changed.
- `flutter gen-l10n` passes and regenerates every ignored
  `app_localizations*.dart` artifact plus `untranslated_messages.json` without
  the seven removed Live Activity settings keys.
- JSON validation with `jq empty` passes for all 33 ARB files.
- `plutil -lint` passes for Runner and WarWidget Info plists plus Runner debug,
  Runner release, and WarWidget entitlements.
- `xcodebuild -list -json -project ios/Runner.xcodeproj` passes and retains
  `Runner`, `RunnerTests`, and `WarWidgetExtension` targets plus the ordinary
  `WarWidgetExtension` scheme.
- `flutter test` passes; all 747 tests passed.
- `flutter analyze lib test` passes with no issues. A bare `flutter analyze`
  also inspected generated SwiftPM package checkouts under `build/ios` and
  `build/macos` and reported 16 third-party Firebase Messaging
  version/analysis-options findings; no App source or test finding was
  reported.
- `flutter build ios --release --no-codesign` passes; Xcode completed in 68.0
  seconds and produced `build/ios/iphoneos/Runner.app` at 47.7 MB.
- Built-product `plutil`, `otool`, and `strings` audits confirm the Runner
  retains `remote-notification`, the embedded WarWidget extension remains a
  `com.apple.widgetkit-extension` linked to SwiftUI and WidgetKit, and neither
  binary contains or links Live Activity/ActivityKit symbols.
- The final tracked/source audit finds none of `LiveActivity`, `ActivityKit`,
  `live_activity`, `liveActivityEnabled`, `live_activity_enabled`,
  `mobile_live_activities`, `pushToStart`, or the seven removed localization
  keys.
- `dart format` passes for the five changed rankings source/test files; 5 files
  formatted, 0 changed on the final run.
- The focused rankings service/provider/page/model suite passes; all 24 tests
  passed.
- `flutter analyze lib/features/rankings test/features/rankings` passes with no
  issues.
- The final full `flutter test` passes; all 748 tests passed, and
  `flutter analyze lib test` passes with no issues.
- The final source/test audit finds neither retired Town Hall nor retired
  Ranked League history route.
- `dart format` passes for all notification model/service/UI/test files.
- The focused notification preferences, push registration, announcement
  preference, and settings-page suite passes; all 10 tests passed.
- Focused notification analysis passes with no issues.
- The final full `flutter test` passes; all 755 tests passed, and
  `flutter analyze lib test` passes with no issues.
- The final App audit finds no one-time-login-token route, model, flow,
  documentation, or test to remove.
- `dart format` passes for the nine changed player/to-do source and test files;
  9 files formatted, 0 changed on the final run.
- `flutter gen-l10n` passes after removing the five retired raid-only to-do
  keys plus the raid-dependent mock status, and `jq empty` passes for all 33
  ARB files.
- The focused player rankings/mobile-initialization suite passes; all 56 tests
  passed.
- Focused analysis of the nine changed player/to-do source and test files
  passes with no issues.
- The final full `flutter test` passes; all 758 tests passed, and
  `flutter analyze lib test` passes with no issues.
- The final source/test/docs audit finds none of `raid_data`, `PlayerRaids`,
  `player.raids`, `raid_attacks`, or the retired raid-only to-do localization
  identifiers. The player surface also has no old `country_code`,
  `country_name`, `global_rank`, `local_rank`, `builder_global_rank`, or
  `builder_local_rank` parser/property.
- `git diff --check` passes.

Outcome:

- `POST /v2/auth/discord` no longer retrieves or sends `device_name`.
- The Discord OAuth request still sends `device_id`, the authorization code,
  PKCE `code_verifier`, and `redirect_uri`.
- Other `device_name` fields used by email login, registration, password
  reset, account linking, and token flows are unchanged.
- A successful `POST /v2/auth/refresh` now requires non-empty replacement
  `access_token` and `refresh_token` values and persists both through the
  existing paired token-storage path before updating the session cache.
- An incomplete successful response is treated as refresh failure, clears the
  unusable local session, and requires reauthentication instead of retaining
  the deleted presented refresh token.
- Focused regression coverage proves the next refresh presents the replacement
  refresh token and that both replacement tokens remain stored after two
  rolling rotations.
- The App has no remaining Live Activity debug service, settings UI/action,
  MethodChannel, Swift plugin or Xcode source registration,
  `NSSupportsLiveActivities`, ActivityKit attributes/configuration/views,
  widget-bundle declaration, localization key, generated localization getter,
  Sonar exclusion, or feature/translation audit claim.
- No App API model/request field or token-registration call named
  `liveActivityEnabled`, `live_activity_enabled`, or
  `mobile_live_activities` existed, so no compatibility alias or deprecated
  caller remains.
- Ordinary Firebase/FCM device registration, `aps-environment`,
  remote-notification background mode, notification debug tooling, App Group
  entitlements, WarWidget, and UpgradeWidget remain intact and build
  successfully.
- Town Hall and Ranked League boards remain available through their existing
  current top-500 routes, but both are now explicitly current-only:
  `supportsHistory` is false, the period/date control is hidden, provider
  attempts to select history retain the current period, and direct service
  history queries throw before making an API call.
- No replacement history mapping, deprecated/501 call, or compatibility alias
  was added. The five canonical geographic/global history boards for player
  home trophies, player builder trophies, clan home points, clan builder
  points, and clan capital points are unchanged.
- Current ranking response parsing, including server-supplied `previousRank`,
  is unchanged; the App no longer fabricates a dated Town Hall or league-tier
  comparison from an unsupported history source.
- Notification preferences now use the exact camelCase GET/PUT contract:
  `deviceEnabled`, eight explicit category booleans, integer
  `reminderTimings`, request-only `accountTags`, and response
  `{playerTag,source}` accounts. The master is cached locally as false by
  default but is never stored as a preference; PUT updates the retained
  `mobile_push_devices.enabled` row atomically with preferences/accounts.
- Disabling delivery no longer unregisters or deletes the FCM token. Enabling
  first obtains permission/registers the current device, then saves
  `deviceEnabled=true`; explicit unregister/logout retains its existing delete
  behavior.
- The UI exposes exactly the eight final categories. Events and war state are
  single booleans, war attacks has no mode picker, and the only nested control
  is war reminder timing. Reminder values are integer minutes, limited to
  three, with the existing 15/30-minute and 1–47-hour choices.
- Account selection is one user-wide set shared by all devices and categories.
  The App offers current verified links and player bookmarks, sends tags only,
  and replaces displayed sources with the API's authoritative
  `verified|bookmarked` response. No count cap, per-type audience, account
  scope, Town Hall filter, clan selector, subscription payload, or
  compatibility alias remains; clan delivery derives from enabled players'
  current clans.
- The V2 local snapshot stores the same booleans, integer minutes, and
  server-derived accounts. A successful V2 sync deletes the obsolete
  array/scope/filter local keys, and announcement presentation reads the new
  explicit announcement boolean.
- Push registration now sends only the retained request fields: token,
  device identity, provider, platform, environment, app version, locale, and
  authorization status. It no longer sends APNS token, build number, OS
  version, device model, or timezone. The existing
  `CK_PUSH_API_V2_BASE_URL` override still applies to device and preference
  requests.
- Mobile initialization no longer parses `raid_data` into `PlayerRaids`, and
  the retired model, player field, raid timing helper, raid to-do metric,
  player to-do card/chip/explanation, home to-do mappings/mock entries, and
  raid-only localization keys are removed. The App no longer fabricates
  missing Raid Weekend progress as `0/5`.
- Official/live clan Capital Raid views, current snapshot analytics, medal
  prediction, player-to-clan mapping behavior, and unrelated war/player
  behavior remain unchanged.
- `PlayerRankings` now parses exactly `tag`, `homeVillage`, and `builderBase`;
  each category retains nullable `points`, `globalRank`, `locationId`,
  `locationName`, `countryCode`, and `localRank` from camelCase responses.
  The same parser covers the mobile initialization rankings copy.
- Home Legend presentation reads the Home Village category and shows
  `locationName`/`countryCode`, nullable local placement, and nullable global
  placement without converting missing values to zero. Builder Base placement
  remains independently available in the model.
- Focused tests prove both categories parse independently and a retained
  numeric location with null points/local rank keeps a null global rank rather
  than fabricating placement.
- The existing unrelated ClashKing font work remains intact.

## ClashKing Tracking

Status: decision 8 Capital Raid Valkey replacement is complete in persistent
Tracking task `019f94ba-972b-7171-ad08-0f4f86796eef`, which remains available
for later database-cleanup decisions. No SQL replacement, durable history,
public API, Dashboard, or App work was added.

Files:

- `/Users/matthewanderson/PycharmProjects/clashking_tracking/scripts/bot_clans.go`
- `/Users/matthewanderson/PycharmProjects/clashking_tracking/scripts/bot_clans_test.go`

Capital Raid cache contract:

- With the default `botclans.snapshot_prefix` of `botclans:snapshot:`, the
  compressed previous response key is
  `botclans:snapshot:raid:<clanTag>`.
- The internal replacement-cleanup participant set is
  `botclans:snapshot:raid-members:<clanTag>`. It exists only to enumerate the
  prior response's mappings without a JSON-search module.
- Each reverse lookup is a Valkey string at
  `botclans:snapshot:raid-member:<playerTag>` whose value is the owning clan
  tag. Empty and duplicate participant tags are omitted.
- The response value is the raw Clash API JSON encoded with
  `utils.Compress`, the same `github.com/golang/snappy` block encoding used by
  player and clan tracking snapshots. Reads use `utils.Decompress` before
  comparison or JSON decoding.
- The response, participant set, and every reverse mapping use the same
  absolute millisecond expiry: the response's parsed Raid Weekend `endTime` in
  UTC plus exactly ten minutes. The Valkey replacement uses `PXAT` for strings
  and `PEXPIREAT` for the set, so repeated polling does not extend the grace
  window.
- One Valkey Lua replacement removes the old participant mappings only when
  their current value still owns the replaced clan, deletes the old response
  and participant set, then writes the Snappy response, new participant set,
  and new reverse mappings with the shared absolute expiry. This removes
  departed participants without deleting a mapping that a newer clan response
  has claimed.
- Unchanged responses still run the idempotent replacement so legacy
  non-expiring raid snapshot keys acquire the deterministic expiry and reverse
  mappings. Missing, zero, or elapsed `endTime + 10m` values run the matching
  ownership-safe cleanup and create no cache state.
- Required reminder scheduling and change events complete before the cache
  replacement advances the previous response. Final reminder reads use the
  expiring Capital Raid cache; other clan/war/CWL snapshots keep their existing
  lifecycle.
- Tracking contains no reads or writes for `public.capital_raid_cache` or
  `public.capital_raid_members`; reminder and target SQL remains unchanged.

Validation:

- `env GOCACHE=/tmp/clashking-tracking-go-cache go test -tags 'script_internal_tests platform_internal_tests' ./scripts -run 'Test(CapitalRaid|BotClansHasNoCapitalRaidSQLQueries)' -count=1`
  — passed.
- `env GOCACHE=/tmp/clashking-tracking-go-cache-tagged go test -tags 'script_internal_tests platform_internal_tests' ./...`
  — passed across all packages.
- `env GOCACHE=/tmp/clashking-tracking-go-cache-full go test ./...` — passed
  across all packages.
- `env GOCACHE=/tmp/clashking-tracking-go-cache-race go test -race ./...` —
  passed across all packages.
- `env GOCACHE=/tmp/clashking-tracking-go-cache-vet go vet ./...` — passed
  with no findings.
- `env GOCACHE=/tmp/clashking-tracking-go-cache-build go build ./...` —
  passed.
- Targeted source audit and the focused static regression test confirm no
  active Go reference to either removed Capital Raid SQL table.
- `git diff --check` — passed in ClashKing Tracking.

### Decision 10 clan rankings and typed clan points

Status: complete in persistent Tracking task
`019f94ba-972b-7171-ad08-0f4f86796eef`, which remains available for later
database-cleanup decisions. No API, Dashboard, App, player-ranking, migration,
fixture, or Valkey ranking work was added.

Files:

- `/Users/matthewanderson/PycharmProjects/clashking_tracking/scripts/scheduled.go`
- `/Users/matthewanderson/PycharmProjects/clashking_tracking/scripts/scheduled_test.go`
- `/Users/matthewanderson/PycharmProjects/clashking_tracking/scripts/global_clans.go`
- `/Users/matthewanderson/PycharmProjects/clashking_tracking/scripts/global_clans_test.go`
- `/Users/matthewanderson/PycharmProjects/clashking_tracking/models/global_clans.go`

Schedule and official scope discovery:

- The current Go `scheduled` domain runs one cycle immediately when the process
  starts, then sleeps for `scheduled.interval_seconds` after each completed
  cycle. The checked-in production configuration is `86400`, so this is one
  run per day without a fixed wall-clock anchor. Existing historical
  leaderboard snapshot and ranked-player discovery scheduling remains
  unchanged.
- Each cycle calls the official locations endpoint once through the existing
  Clash retry policy. It keeps every unique nonzero numeric official location
  ID in response order, encodes each as decimal text, and appends the
  `global` scope. Historical snapshots and current clan rankings share that
  discovered scope list. A failed location discovery changes no ranking group.
- For every location/scope, Tracking requests `limit=200` from the official
  Home Village clan, Builder Base clan, and Clan Capital clan ranking
  endpoints. These map only to `home`, `builder_base`, and `capital`;
  current player-ranking behavior was not changed.

Completeness and replacement contract:

- The current `clashy.go` ranking methods return only `[]RankedClan` and do not
  expose response paging cursors or other pagination metadata. Tracking
  therefore treats a successful transport/API response as the authoritative
  complete group and accepts every returned size from zero through 200. A
  valid small location is replaced with its full short list, and a successful
  empty response clears stale rows for that exact group.
- A response is rejected before storage if it exceeds 200 rows, contains an
  empty or duplicate clan tag, contains a duplicate or out-of-range rank, or
  contains a negative type-specific score. Zero is accepted because the
  authoritative typed fields and database schema permit it. Home Village uses
  `clanPoints`, Builder Base uses `clanBuilderBasePoints`, and Capital uses
  `clanCapitalPoints`.
- A failed/retry-exhausted fetch or rejected response never opens the
  replacement transaction, so the prior `(ranking_type, location_id)` group
  remains unchanged. Other groups continue independently and can still
  complete during that cycle.
- Each accepted group opens its own PostgreSQL transaction, creates an
  on-commit-drop temporary stage table, copies every returned
  `(clan_tag, rank, points, updated_at)` row, upserts into
  `clan_rankings_current` on
  `(clan_tag, ranking_type, location_id)`, then deletes rows absent from the
  stage only where both `ranking_type` and `location_id` match the current
  group. Upsert, stale deletion, and empty-group clearing commit atomically;
  one group cannot delete or update another.
- PostgreSQL is the only current-ranking store. No Valkey ranking keys or
  payloads were introduced.

Global clan ingestion:

- Official clan-profile ingestion now maps `clanPoints`,
  `clanBuilderBasePoints`, and `clanCapitalPoints` into
  `basic_clan.clan_points`, `builder_base_points`, and `capital_points`.
- Previous-row loads, inserts, conflict updates, and distinct-change checks
  include all three required integer fields, so every successful global clan
  refresh keeps them current.

Validation:

- `env GOCACHE=/tmp/clashking-tracking-go-cache-decision10 go test -tags 'script_internal_tests platform_internal_tests' ./scripts -run 'Test(CurrentClanRanking|LeaderboardLocationIDs|MemoryScheduledStore|BasicClan.*TypedPoint)' -count=1`
  — passed. Coverage includes exact ranking types, numeric/global scopes,
  type-specific point selection, successful 200-row, short, empty, and
  zero-point groups, oversized/duplicate/invalid rejection, group-isolated
  replacement, authoritative empty clearing, SQL scope predicates, and all
  three `basic_clan` fields.
- `env GOCACHE=/tmp/clashking-tracking-go-cache-d10-tagged-final go test -tags 'script_internal_tests platform_internal_tests' ./...`
  — passed across all packages.
- `env GOCACHE=/tmp/clashking-tracking-go-cache-d10-full-final go test ./...`
  — passed across all packages.
- `env GOCACHE=/tmp/clashking-tracking-go-cache-d10-race-final go test -race ./...`
  — passed across all packages.
- `env GOCACHE=/tmp/clashking-tracking-go-cache-d10-vet-final go vet ./...`
  — passed with no findings.
- `env GOCACHE=/tmp/clashking-tracking-go-cache-d10-build-final go build ./...`
  — passed.
- `git diff --check` — passed in ClashKing Tracking and DevKit.

### Decision 13 current-war player lookup

Status: complete in persistent Tracking task
`019f94ba-972b-7171-ad08-0f4f86796eef`, which remains available for later
database-cleanup decisions. The implementation adds no Valkey, API,
Dashboard, App, migration, or fixture work.

Files:

- `/Users/matthewanderson/PycharmProjects/clashking_tracking/models/wars.go`
- `/Users/matthewanderson/PycharmProjects/clashking_tracking/scripts/wars.go`
- `/Users/matthewanderson/PycharmProjects/clashking_tracking/scripts/wars_store.go`
- `/Users/matthewanderson/PycharmProjects/clashking_tracking/scripts/wars_test.go`

Writer, reader, and expiry contract:

- Every active regular-war and CWL ingest creates a durable schedule and one
  `current_war_timers` row for every nonempty participant tag on both API war
  sides. A participant's `clan_tag` is that participant's own side and
  `opponent_tag` is the other side; both share the generated schedule `war_id`
  and the official UTC war `end_time`. Duplicate participant tags in one API
  response are suppressed.
- The writer uses one transaction and one array-`unnest` bulk statement:
  `INSERT INTO current_war_timers (player_tag, war_id, clan_tag, opponent_tag,
  end_time) SELECT * FROM unnest(...) ON CONFLICT (player_tag) DO UPDATE`.
  Its conflict action replaces all four current-war fields, so a refreshed or
  newly discovered war atomically supersedes that player's prior war without
  per-player SQL inserts.
- Tracking's reverse-lookup store selects by `player_tag` with
  `end_time > now()`; expired rows are never returned even if the cleanup has
  not executed. The scheduled cleanup worker runs every five minutes and uses
  `DELETE FROM current_war_timers WHERE end_time <= now()`, retaining the
  DevKit end-time index for that operation.

Maintenance contract:

- The existing Global War Tracking maintenance probe calls the official Gold
  Pass endpoint once per minute. Only `clashy.GatewayError` with official HTTP
  status `500` starts an interval; transport failures, `502`, `503`, `403`,
  and every other error return normally to the domain error path and never
  shift schedules or timer rows.
- On the first qualifying `500`, Tracking records UTC start time and polls at
  15-second intervals. A successful recovery computes the positive elapsed
  duration exactly once. In one PostgreSQL transaction, a CTE updates only
  `war_schedule` rows where `end_time > now()` and returns their `war_id`s;
  the following bulk update adds that same interval only to
  `current_war_timers` whose `war_id` is in that returned set and whose own
  `end_time > now()`. This uses the new `war_id` index and cannot revive stale
  timer rows or shift a war that was not active at the transaction's start.

Validation:

- `env GOCACHE=/tmp/clashking-tracking-go-cache-decision13 go test -tags script_internal_tests ./scripts -run 'Test(BuildWarIngestSchedulesActiveWar|MemoryWarStoreCurrentWarTimerConflictReplacesPriorWar|CurrentWarTimer|MemoryWarStoreShiftMaintenance|OfficialMaintenance500Only|MaintenanceShiftDuration|ShiftActiveWarMaintenanceSQL)' -count=1`
  — passed. Coverage includes both-side participant rows, conflict replacement,
  bulk-upsert shape, five-minute cleanup, active-only reads, only-500
  detection, exact elapsed duration, and active-only schedule/timer shifting.
- `env GOCACHE=/tmp/clashking-tracking-go-cache-d13-tagged go test -tags 'script_internal_tests platform_internal_tests' ./...`
  — passed across all packages.
- `env GOCACHE=/tmp/clashking-tracking-go-cache-d13-full go test ./...` —
  passed across all packages.
- `env GOCACHE=/tmp/clashking-tracking-go-cache-d13-race go test -race ./...`
  — passed across all packages.
- `env GOCACHE=/tmp/clashking-tracking-go-cache-d13-vet go vet ./...` —
  passed with no findings.
- `env GOCACHE=/tmp/clashking-tracking-go-cache-d13-build go build ./...` —
  passed.

### Decision 16 giveaway event payloads

Status: complete in persistent Tracking task
`019f94ba-972b-7171-ad08-0f4f86796eef`. Migration 026 drops only
`public.giveaways.data`; no Bot, Dashboard, or App change was required by the
Tracking implementation. The separate persistent API task owns its required
typed SQL and response-model migration.

Files:

- `/Users/matthewanderson/PycharmProjects/clashking_tracking/scripts/giveaways.go`
- `/Users/matthewanderson/PycharmProjects/clashking_tracking/scripts/giveaways_test.go`

Event contract:

- All four giveaway event query paths—pending replay, scheduled start, normal
  end, ongoing update, and the race-safe transition `RETURNING` path—now use
  one explicit `jsonb_build_object` projection. There is no database-row
  serialization and no read of the dropped `data` column.
- The nested `giveaway` event object keeps the existing snake_case column-key
  contract: `id`, `server_id`, `prize`, `channel_id`, `status`, `start_time`,
  `end_time`, `winners`, `mentions`, `text_above_embed`, `text_in_embed`,
  `text_on_end`, `image_url`, `profile_picture_required`,
  `coc_account_required`, `roles_mode`, `roles`, `boosters`, `entries`,
  `winners_list`, `updated`, `message_id`, `event_pending`,
  `event_pending_at`, `created_at`, and `updated_at`.
- The outer event remains `{type, giveaway}` with the existing giveaway topic
  and transition type, so bot consumers retain the event envelope while all
  retained typed giveaway data—including eligibility, role, entrant/winner,
  pending-event, and audit metadata—continues to be available.

Validation:

- `env GOCACHE=/tmp/clashking-tracking-go-cache-d16 go test -tags script_internal_tests ./scripts -run 'Test(GiveawayTransitionEventShape|GiveawayEventPayloadUsesEveryRetainedTypedColumn|ValidateGiveawaysConfig)' -count=1`
  — passed. The focused test proves no implicit row serializer remains and
  asserts all retained event fields are projected.
- `env GOCACHE=/tmp/clashking-tracking-go-cache-d16-tagged go test -tags 'script_internal_tests platform_internal_tests' ./...`
  — passed across all packages.
- `env GOCACHE=/tmp/clashking-tracking-go-cache-d16-full go test ./...` —
  passed across all packages.

### Active migration 003 Town Hall materialized-view refresh

Status: complete and local/uncommitted in persistent Tracking task
`019f94ba-972b-7171-ad08-0f4f86796eef`. No Builder Hall support, API work,
new scheduler, or separate task was added.

Files:

- `/Users/matthewanderson/PycharmProjects/clashking_tracking/scripts/leaderboards.go`
- `/Users/matthewanderson/PycharmProjects/clashking_tracking/scripts/leaderboards_test.go`

Refresh contract:

- The existing `leaderboards` domain still runs every
  `leaderboards.interval_seconds`; the checked-in value is 600 seconds. Its
  independent materialized-view deadline remains 3,600 seconds and is checked
  after every normal leaderboard cycle.
- The hourly refresh set is now exactly three views:
  `clan_leaderboards`, `war_league_counts`, and `townhall_counts`.
  `townhall_counts` runs as
  `REFRESH MATERIALIZED VIEW CONCURRENTLY townhall_counts`, so its last
  populated `(level integer, total_count bigint)` snapshot remains readable
  while PostgreSQL rebuilds it from `basic_player.townhall_level`.
- The existing first-population fallback for `clan_leaderboards` is unchanged;
  `war_league_counts` keeps its existing refresh statement. Tracking adds no
  Builder Hall source, query, metric, or cache.
- Store metrics now record one batch with three requested and three affected
  materialized views after the entire set succeeds.
- The next hourly deadline advances only after all three refreshes succeed. Any
  refresh error is returned through the existing cycle error path without
  changing the deadline, so the prior readable snapshot stays in place and
  the next 600-second leaderboard cycle retries the refresh set.

Validation:

- `env GOCACHE=/tmp/clashking-tracking-townhall-focused go test -tags 'script_internal_tests platform_internal_tests' ./scripts -run 'TestLeaderboardMaterializedView' -count=1`
  — passed. Coverage proves the exact three-query set, concurrent Town Hall
  refresh, 3/3 store metrics, failure-without-deadline-advance, retry at the
  next 600-second cycle, and the 3,600-second post-success deadline.
- `env GOCACHE=/tmp/clashking-tracking-townhall-tagged go test -tags 'script_internal_tests platform_internal_tests' ./...`
  — passed across all packages.
- `env GOCACHE=/tmp/clashking-tracking-townhall-full go test ./...` — passed
  across all packages.
- `git diff --check` — passed for the Tracking implementation and shared
  report.

## Final review

Status: decisions 1–14 and the authorized Bases feature, including the final
server-generated create lifecycle and manager delete lifecycle, are complete
in DevKit/API where assigned. Persistent Tracking implementations for
decisions 10 and 13 are complete. Decisions 15 and 16 are appended and
validated in DevKit, and Decision 16's API, Tracking, and required Dashboard
caller work is complete. Persistent owners remain available while DevKit
continues the table review.

### Decision 16 giveaway typed storage

Status: complete. DevKit schema/importer changes are appended and
validated. The existing persistent API task `019f92a8-f4b8-74a2-ab70-cf25481fd6d1`,
persistent Tracking task `019f94ba-972b-7171-ad08-0f4f86796eef`, and required
persistent Dashboard task `019f929f-bd3f-7ca0-ab74-f6ad08ddec1e` completed the
authorized follow-through; no new task was created.

Migration and import contract:

- Up drops only `public.giveaways.data`. It retains every existing typed
  giveaway field: identity/server/prize/channel/status, schedule and winner
  count, message text and mentions, image and eligibility flags, role rules,
  boosters/entries/winners lists, update/message/event state, and timestamps.
  Down restores the exact old `data jsonb DEFAULT '{}'::jsonb NOT NULL`
  definition.
- `bot_server_settings.go` no longer copies a whole legacy Mongo document into
  `data`; it imports all typed configuration, runtime event metadata, and
  timestamps directly and its conflict update refreshes the same typed shape.
- The importer intentionally preserves typed JSON payload columns
  (`boosters`, `entries`, and `winners_list`) because those are approved
  structured fields, not the removed catch-all JSONB column.

DevKit validation:

- `goose -dir database/timescale validate` — passed.
- `env GOCACHE=/tmp/clashking-devkit-go-cache go test ./...` and
  `go build -o /tmp/bot-server-settings-check bot_server_settings.go` from
  `database/migrations` — passed.
- DevKit `git diff --check` plus untracked migration/report diff checks —
  passed. Focused stale-reference audits found no `giveaways.data` or
  `to_jsonb(giveaways)` in DevKit's giveaway importer path.

Completed downstream contract:

- API replaced its `data` merge/select/write path with explicit
  typed SQL and response-specific camelCase models across list/detail/create,
  update, entry, reroll, and delete flows. It must keep the complete public
  giveaway semantics rather than silently dropping eligibility, text, message,
  event, or timestamp fields.
- Tracking stopped serializing database rows through `to_jsonb(giveaways)` and
  builds the giveaway event payload from an explicit typed projection,
  including message/event state and audit timestamps, so the bot receives a
  complete stable event shape.
- Dashboard completed the API-required camelCase response migration. Bot and
  App had no affected contract, so neither received work.

### Decision 16 API implementation

Status: complete in the persistent ClashKing API task
`019f92a8-f4b8-74a2-ab70-cf25481fd6d1`; no commit, push, or PR was created.

- `internal/routes/server/giveaways.go` now selects and persists the complete
  retained typed shape in `giveawayList`, `giveawayGet`, `giveawayScan`, and
  `giveawaySave`: identity/server/prize/channel/status, schedule/winner count,
  mentions and all three text fields, image and eligibility flags, role rules,
  boosters/entries/winners list, update/message/event state, and audit
  timestamps. It no longer selects, decodes, merges, inserts, or updates
  `giveaways.data`. Update preserves runtime entries/winners/message/event and
  creation state while replacing manager-editable configuration; reroll saves
  its typed winners list; create initializes the typed runtime fields; list,
  detail, entries, and delete all use the same server-scoped typed lookup.
- `internal/models/v2/giveaways.go` now defines response-specific camelCase
  giveaway, mutation, entries, entrant, winner, and reroll responses. List and
  detail expose the full typed giveaway representation, including `serverId`,
  `entries`, `winnersList`, `eventPending`, `eventPendingAt`, `createdAt`, and
  `updatedAt`; no removed catch-all data is returned. Existing multipart form
  request keys and the reroll `user_ids_to_replace` request remain unchanged.
- `internal/routes/server/giveaways_test.go` covers a complete typed row scan,
  response JSON field names, and static regression guards spanning
  list/detail/create/update/reroll/entries/delete SQL paths. It rejects stale
  `data` selection, decoding, or upsert references. `internal/routes/server/roles.go`
  now preserves native SQL text arrays when converting typed giveaway role and
  mention values.
- Swagger/OpenAPI was regenerated (`internal/docs/docs.go`,
  `internal/docs/swagger.json`, and `internal/docs/swagger.yaml`). The runtime
  Swagger builder continues to preserve all six custom RFC QUERY operations as
  `x-query` extensions.

Validation:

- `env GOCACHE=/tmp/clashking-api-go-cache-d16 go test ./internal/routes/server ./internal/models/v2` — passed.
- `env GOCACHE=/tmp/clashking-api-go-cache-d16 go vet ./...` — passed.
- `env GOCACHE=/tmp/clashking-api-go-cache-d16 go test ./...` — passed with
  localhost binding enabled outside the filesystem sandbox.
- `git diff --check` — passed.
- Static API audit found no `giveaways.data` SQL/JSONB dependency; generated
  OpenAPI includes the complete camelCase giveaway fields.

Downstream relevance: Dashboard has an active giveaway client and currently
consumes snake_case giveaway responses, so the API-required camelCase response
contract is a genuine caller change. Reuse its persistent task
`019f929f-bd3f-7ca0-ab74-f6ad08ddec1e` for those type/client/proxy/UI updates;
no App work is needed. The Bot's active reroll caller decodes a generic action
response and continues sending the unchanged snake_case request body, so no
Bot task is warranted.

### Decision 17 CWL group snapshots and persisted standings

Status: schema, importer, API compatibility, Tracking compatibility, and the
local-only database application are complete. Durable standings aggregation
and rank refresh remain deferred pending the scoring/comparator decisions
below.

Confirmed selected data shape:

- `cwl_groups` retains exactly the stable group identity, canonical official
  season, nullable frozen league ID, lifecycle state, nullable real-war size,
  and canonical `rounds` JSONB. It has no `created_at`, `updated_at`, or
  `ended_at` column.
  The redundant `clan_tags` and catch-all `data` columns are removed. There is
  no round table, group-war bridge, or duplicate war-tag array.
- `cwl_group_clans` is keyed by `(cwl_id, clan_tag)` and contains the
  event-time clan name, level, and one badge token. It has no roster JSONB.
- `cwl_group_members` contains exactly `cwl_id`, `clan_tag`, member `name`,
  member `tag`, and `town_hall`. Its `(tag, cwl_id)` primary key permits one
  player registration per CWL group and directly serves player-history reads.
  Its composite foreign key scopes every member to a real group-clan snapshot,
  and the importer builds `(cwl_id)` as the group-scoped lookup index after
  loading.
- `cwl_standings` is keyed by `(cwl_id, clan_tag)` with frozen
  season/league/war-size dimensions, stars, destruction, W/L/T, finished-war
  count, group clan count, current group/global ranks, and timestamp. It is
  indexed for group order, configured league partition order, and clan
  season history.

Required policy decisions:

- **Competitive ordering and exact ties:** Supercell's CWL Results support
  page describes leaderboard ordering by War Stars then total destruction, and
  says an exact equality is randomized. An older Supercell Top 10 CWL post
  describes wins first, then attack stars, then destruction. The product must
  choose the stored comparator for `group_rank` and `global_rank`, and whether
  exact equality shares a rank (`RANK`) or has a deterministic display-only
  order while retaining the same competitive rank. A random tie break cannot
  be reproduced from stored facts.
- **Destruction aggregation:** `wars` stores a percentage for each side, but
  the persisted table needs one durable aggregate. The product must choose sum
  of finished-war percentages or average percentage; the latter normalizes
  differently when groups have a different number of completed wars. This
  choice controls both totals and tie breaks.
- **Win bonus source:** Community evidence consistently reports a ten-star CWL
  win bonus awarded only to the winner, but the official material inspected
  establishes the existence of bonus stars without publishing its exact value.
  The implementation needs confirmation that `10` is the approved frozen
  product constant, or an authoritative source supplied by the product owner.

Implementation ownership:

- Persistent Tracking task `019f94ba-972b-7171-ad08-0f4f86796eef` owns live
  group/snapshot refresh and now writes the final schema. Future aggregate and
  15-minute rank work remains with that task after policy is accepted.
- Persistent API task `019f92a8-f4b8-74a2-ab70-cf25481fd6d1` owns the typed
  CWL history/ranking readers and is compatible with the final schema. Its
  caller audit found no Dashboard/App change.

Decision 17 addendum:

- Player CWL history filters `cwl_group_members.tag`, then joins through its
  `(cwl_id, clan_tag)` scope to `cwl_group_clans`, `cwl_groups`, and
  `cwl_standings`. After import completion, the `(tag, cwl_id)` primary-key
  B-tree serves that lookup without JSON extraction or a GIN index; a separate
  `(cwl_id)` B-tree serves group reads.
- The dedicated `cwl_groups` importer is an offline one-shot load and converts
  only legacy group metadata, official rounds, and faithful clan
  roster snapshots. It will not create or fabricate historical
  `cwl_standings`; durable standings begin when newly stored/recomputed war
  facts are available.
- Local-only schema application was authorized. No remote/production apply,
  commit, push, or PR is authorized.

Sequencing correction:

- The accepted Decision 17 redesign was first implemented in migration 026
  and is now part of `002_initial_settings.sql`. After that application, the user
  removed all three `cwl_groups` timestamps and approved discarding the
  partially imported local CWL rows. The former migration 027 performed the
  narrow final reset; that final shape is also in `002_initial_settings.sql`.
- The consolidated baseline creates `cwl_group_clans` and empty `cwl_standings`, reshapes
  `cwl_groups` to canonical rounds plus lifecycle metadata, removes its
  `clan_tags` and catch-all `data`, makes `cwl_league_id` nullable for legacy
  imports, and adds the selected snapshot/history/rank indexes. It does not
  create standings rows or scoring logic while policy remains unresolved.
- `database/migrations/cwl_groups.go` is the dedicated one-shot Mongo import
  command. It preserves official rounds JSONB, imports clan name/level/badge
  token/member snapshots, and accepts missing legacy league IDs as SQL NULL.
  It must be run manually from `database/migrations` with
  `go run cwl_groups.go`; it reads Mongo and writes Timescale only.

Decision 17 completion status:

- **Historical pre-consolidation local schema:** migration 027 was rolled back
  at the user’s request after
  confirming that a completed local import had populated 598,000 groups and
  4,769,356 clan snapshots. Those disposable local CWL rows were truncated;
  the normalized member-table revision of 027 was validated and reapplied, and
  Goose reported version 27 at that validation point. This work was later
  consolidated into the current baseline; no production/remote database or
  Mongo data was contacted.
- **Local verification:** `cwl_groups`, `cwl_group_clans`,
  `cwl_group_members`, and `cwl_standings` each contain zero rows after the
  authorized reset. The next approved one-shot import always begins at the
  first Mongo document. Before import, the three
  loaded CWL tables have zero indexes and no primary/foreign-key constraints.
- **Importer:** created, compiled, and run by the user against the earlier
  roster-JSON shape before the reset. From
  `database/migrations`, run `go run cwl_groups.go` only when the user wants to
  import Mongo snapshots. It has no checkpoint or resume path, reads
  `looper.cwl_group`, and writes only Timescale group/snapshot rows. Legacy
  rows without a source league ID stay NULL; it never creates standings. Every
  invocation drops the loader-owned constraints/indexes, truncates only the
  four CWL tables, and starts from the first Mongo document. Interruption
  recovery is simply to run the same command again.
- **Tracking:** complete in persistent task
  `019f94ba-972b-7171-ad08-0f4f86796eef`. Live CWL writes now target the new
  group and clan-snapshot tables, retain real official league IDs, derive war
  size from a fetched official war, and leave standings untouched. Focused,
  tagged/full tests and diff checks passed.
- **API:** complete in persistent task
  `019f92a8-f4b8-74a2-ab70-cf25481fd6d1`. It provides typed camelCase player
  roster history, clan CWL history, and league-ranking retrieval with 200/empty
  `items` for absent standings. Player lookup uses the normalized
  `cwl_group_members(tag, cwl_id)` primary-key B-tree path. Old `cwl_groups.data`,
  `clan_tags`, and roster-JSON readers were removed; no Dashboard/App caller is
  affected. Focused/full tests, vet, generated OpenAPI validation, and diff
  checks passed.
- **Deferred intentionally:** no `cwl_standings` writes, scoring totals,
  rank recomputation, or periodic rank job exists until the outstanding
  comparator, destruction aggregation, and official bonus policy is decided.

Importer environment-path correction:

- `database/migrations/migrateutil.LoadConfig` now resolves connection settings
  from the repository-root `.env`, while retaining `database/.env` only as a
  compatibility fallback. Only `clan_wars.go` uses the repository-root
  `migration_state.json`; CWL intentionally does not resume. This fixes
  `go run cwl_groups.go` from `database/migrations` without moving or copying
  the root `.env`.
- `migrateutil_test.go` covers root-file preference, database-directory
  fallback, the fixed 12-character hash fixture, and badge URL normalization.
  The importer compiled and the migration utility test suite passed.
- CWL import batching is capped at 1,000 group documents per transaction even
  when the generic `MIGRATION_BATCH_SIZE` remains 50,000. Each CWL document
  fans out into group-clan and typed member rows, so the original generic batch
  deferred a very large transaction before the first visible
  commit. The bounded batch keeps memory, commit latency, progress,
  and visibility predictable. A lower explicitly configured generic batch is
  still honored.
- Duplicate group/snapshot/member keys inside one Mongo batch collapse before
  PostgreSQL COPY/plain INSERT, and flush start/end timing is printed
  explicitly. There is no conflict-update or resume path.
- The consolidated `002_initial_settings.sql` baseline leaves the loaded CWL
  tables without indexes, primary keys, or dependent foreign keys while data
  loads. After the final successful batch, the importer creates all
  three primary keys, restores the group-clan/member/standings foreign keys,
  and builds
  `idx_cwl_groups_season_league`,
  `idx_cwl_groups_season_league_size`,
  `idx_cwl_group_clans_clan_cwl`,
  `idx_cwl_group_members_cwl_id`, printing the duration of its build. The
  `(tag, cwl_id)` primary key covers player lookups, so the importer does not
  build redundant player-tag or `(cwl_id, clan_tag)` member indexes.
  Until that finalization succeeds, Tracking writes and indexed API reads
  remain offline.
- Group identity is SHA-256 over the legacy canonical identity, first nine
  bytes encoded with unpadded URL-safe base64 (12 characters). For example,
  `2023-09-2002C8PC-2L292Y80C-2YPJUCRYP-92QJ9RR8-9RR8UL2Y-JU2QLQ8L-P8YLGLGL-YQLJUQ8U`
  maps to `F1PPW_hG-A3h`. `badge_token` stores only the final token segment
  without `.png`.
- **DevKit validation:** the revised importer compiles, `go test ./...`,
  `goose -dir database/timescale validate`, and `git diff --check` pass.
  The repository again contains exactly the two consolidated Goose SQL files.
  Before migration 003 application, the local database was at Goose version 2
  and retained all 914,735,913
  `cwl_group_members` rows while its primary key changed to `(tag, cwl_id)`;
  its only secondary index is now `(cwl_id)`. The removed player-tag and
  group-clan indexes reduced combined CWL index storage from 79 GB to 43 GB
  and combined CWL storage from 152 GB to 117 GB. An actual
  `#8GLYGGJQ` member-history lookup returned 35 rows through the new primary
  key in 7.765 ms with heap reads and 0.034 ms on the immediate warm repeat.

## Active migration 003 — `hall_counts` replacement

- `public.hall_counts` is removed and replaced by the materialized view
  `public.townhall_counts`. Its complete external SQL contract is
  `level integer, total_count bigint`; it groups only
  `basic_player.townhall_level` and has no `village_type` or Builder Hall
  representation.
- Migration 003 creates the view `WITH DATA`, so readers have a complete
  snapshot as soon as the migration commits. The unique
  `townhall_counts_level_idx(level)` index supports nonblocking concurrent
  refreshes.
- The established Tracking leaderboards owner refreshes the view concurrently
  with its other materialized views on the existing 3,600-second cadence. A
  refresh keeps the prior snapshot readable, and a failure leaves that
  snapshot intact and retries on the next 600-second leaderboard cycle because
  the hourly deadline advances only after full refresh success. The API never
  owns or triggers refresh.
- No dedicated importer or other DevKit writer exists. The Down migration
  faithfully restores the old table
  columns and composite primary key, preserving the materialized Town Hall
  snapshot as `village_type = 0`; it does not invent Builder Hall rows that the
  approved source cannot provide.
- Caller audit found only the Go API Town Hall and Builder Hall count handlers.
  Town Hall readers move to `townhall_counts(level, total_count)`. Registered
  `/v2/counts/players/builder-halls` remains present but returns an explicit 501
  unsupported response until a later Builder Hall data decision, rather than
  empty or fake counts. The already-unregistered `/v2/global/builderhalls`
  stays absent and its dead handler is removed. No Bot, Dashboard, App, or
  other active Tracking caller reads `hall_counts`.
- DevKit owns migration 003. Persistent API task
  `019f92a8-f4b8-74a2-ab70-cf25481fd6d1` owns query/contract/docs changes;
  persistent Tracking task `019f94ba-972b-7171-ad08-0f4f86796eef` owns the
  hourly refresh integration. All work remains local and uncommitted.
- **API complete:** active `GET /v2/counts/players/town-halls` selects
  `level, total_count` from `townhall_counts`; active
  `GET /v2/counts/players/builder-halls` returns structured HTTP 501
  `{"code":"not_implemented","message":"Builder Hall counts are not implemented"}`
  and advertises no 200 response. The already-removed
  `/v2/global/builderhalls` remains absent and its dead handler is removed.
  The unsupported `GroupedCountItem.builderhall_level` field is removed, and
  no API refresh operation exists. Changed API routes, response/error models,
  focused tests, generated OpenAPI, and Swagger assertions all pass focused
  validation, regeneration, full `go test ./...`, full `go vet ./...`, stale
  SQL/model audit, and `git diff --check`. Dashboard/App route audit found no
  callers, so no downstream task or code change is needed.
- **Migration validation:** Goose validation and the Go migration tests/importer
  build pass. A disposable database applied 001–003, confirmed the exact
  `integer`/`bigint` view types and unique level index, refreshed concurrently
  after source changes, and rolled Down to the exact legacy table shape while
  preserving the Town Hall snapshot as `village_type = 0`. The disposable
  database was removed. The real local database now has migration 003 applied:
  `townhall_counts` is present and `hall_counts` is absent.

## Active migration 003 — leaderboard history rebuild

- Migration 003 drops the rejected generic
  `leaderboard_snapshot_items(kind,...,data jsonb)` table and creates five
  source-specific typed tables. There is no shared discriminator and no JSONB:
  `leaderboard_history_player_home`, `leaderboard_history_player_builder_base`,
  `leaderboard_history_clan_home`, `leaderboard_history_clan_builder_base`, and
  `leaderboard_history_clan_capital`.
- Every table retains the official leaderboard scope as `location_id text`
  (`global` or a positive numeric ID), the UTC snapshot `date`, the entity
  identity/name, `rank`, and nullable `previous_rank`. Player tables retain
  experience, their typed trophy/win fields, nullable all-or-none clan
  tag/name/badge-token snapshots, and one nullable `league_id`. Home-player
  rows prefer newer `leagueTier.id` and fall back to legacy `league.id`;
  observed families include `105...` and `290...`, which lets API static-data
  reconstruction choose the correct catalog. Builder Base rows use
  `builderBaseLeague.id` and normalize legacy
  `versusTrophies`/`versusBattleWins` into the current typed columns.
- Clan tables retain tag/name/badge token, clan level, members, nullable
  official `clan_location_id`, and exactly one typed score:
  `clan_points`, `builder_base_points`, or `capital_points`. Location names,
  country fields, badge URLs, and league objects are reconstructible static
  metadata and are not duplicated.
- Each primary key is `(location_id,date,player_tag)` or
  `(location_id,date,clan_tag)`. Each table has a
  `(location_id,date DESC,rank)` snapshot index and an
  `(player_tag|clan_tag,date DESC)` entity-history index. Checks reject invalid
  scopes, blank required identities, negative counters, impossible member
  counts, partial player-clan snapshots, and invalid positive IDs/ranks.
- Down drops the five typed tables and recreates the exact prior
  `leaderboard_snapshot_items` columns, primary key, and two indexes. Discarded
  generic or newly imported typed rows are intentionally not reconstructed.
- `database/migrations/leaderboard_history.go` is the dedicated one-shot,
  read-only Mongo importer. Low-impact source estimates on 2026-07-30 found
  approximately 211,672 `player_trophies`, 211,673
  `player_versus_trophies`, 226,816 `clan_trophies`, 212,992
  `clan_versus_trophies`, and 212,992 `capital` snapshot documents in the
  `ranking_history` database. They map one-to-one to the five typed tables.
  Each `data.items` object is projected into typed columns; badge URLs become
  one stable filename token, league/location objects become authoritative
  IDs, and derived names/icons/URLs are omitted.
- Capital history retains only source documents dated Tuesday and stores each
  accepted snapshot under the immediately preceding Monday date. Other
  Capital days are skipped. `ranking_history.legends` and
  `ranking_history.league_history` remain explicitly ignored. The separate
  `player_leaderboard` and `clan_leaderboard` collections are also not loaded:
  their documents contain seasonal `{rank, season, tag, type, value}` facts
  but no snapshot date, location, or full official response item, so they
  cannot truthfully satisfy this table's contract.
- The importer is intentionally not resumable. On every start it drops all ten
  secondary indexes and truncates only these five typed destinations, then
  streams and bulk-upserts each source with `COPY`-backed batches. It rebuilds
  indexes only after all five sources succeed. Interruption leaves partial
  typed tables without secondary indexes; rerunning clears and restarts them.
  It never changes Mongo.
- Persistent Tracking task `019f94ba-972b-7171-ad08-0f4f86796eef` owns the
  authoritative typed daily writes for the five official categories across
  global and official numeric locations. Persistent API task
  `019f92a8-f4b8-74a2-ab70-cf25481fd6d1` owns all renamed SQL readers and
  response-specific typed reconstruction contracts. API and Tracking are
  complete in their existing persistent tasks. No new tasks were created.
- **Tracking complete:** `models/runtime_scripts.go`, `scripts/scheduled.go`,
  and `scripts/scheduled_test.go` now contain five explicit row models and
  write only the five typed tables/column lists above. In particular,
  `typedLeaderboardHistorySpecs` targets exactly
  `leaderboard_history_player_home`,
  `leaderboard_history_player_builder_base`,
  `leaderboard_history_clan_home`,
  `leaderboard_history_clan_builder_base`, and
  `leaderboard_history_clan_capital`; there are no compatibility aliases,
  views, or fallback table names. The scheduled flow
  discovers every unique positive official location plus `global`, calls the
  same five official leaderboard endpoints, and maps each successful response
  directly to its table. Home players prefer `leagueTier.id` and fall back to
  legacy `league.id`; Builder Base uses `builderBaseLeague.id`, maps the
  available Builder/legacy trophy and battle-win values, and leaves optional
  values NULL when absent. Player/clan badge URLs become only the stable token.
  Player clan fields are all NULL or all populated, and clan rows retain typed
  level, members, official location ID, previous rank, and their one
  table-specific score. No generic `kind`, `data`, JSONB, recursive JSON badge
  transformer, or standalone `leaderboard_history` table SQL remains.

  All successful `(table,location_id,date)` groups are validated before one
  PostgreSQL transaction creates five table-specific typed stages. Each stage
  bulk-copies its rows, upserts on that table's exact
  `(location_id,date,player_tag|clan_tag)` primary key, and deletes stale
  entities only for the successful scopes listed in its matching group stage.
  A failed or invalid official response never enters the group stage and
  therefore cannot erase its last-good snapshot; successful groups still
  persist, an authoritative empty response clears only its exact scope, and
  one table never touches another. Capital is fetched only on Tracking's
  established Tuesday schedule and is stored under that official Tuesday UTC
  date. The Mongo importer's Tuesday-to-prior-Monday remap is not applied to
  live Tracking writes.
- **API complete:** the three existing routes and five external type values
  remain unchanged. Snapshot reads return
  `{type,locationId,date,items}`; player/clan entity reads retain their typed
  wrappers and `{date,locationId,name,rank,details}` history items. The
  `items`/`details` payload is now a response-specific camelCase typed union
  containing only fields applicable to the selected table; arbitrary JSON,
  internal table kinds, and badge tokens are never exposed.
- `internal/routes/leaderboard_history.go` maps each external type directly to
  its final prefixed typed table:
  `leaderboard_history_player_home`,
  `leaderboard_history_player_builder_base`,
  `leaderboard_history_clan_home`,
  `leaderboard_history_clan_builder_base`, or
  `leaderboard_history_clan_capital`. Exactly five snapshot and five entity
  query constants use those names; no aliases or compatibility views exist.
  Snapshot SQL fixes `(location_id,date)` and orders by rank; entity SQL fixes
  player/clan tag and orders
  `date DESC,location_id,rank`. Nullable previous rank, Builder battle wins,
  clan snapshot, league ID, and clan location ID scan without sentinels.
  Badges reconstruct as official 70/200/512 URLs. Clan location metadata comes
  from the canonical official location catalog, with truthful ID-only fallback.
  Home-player `105000000..105999999` IDs become `leagueTier`, while
  `29000000..29999999` IDs become legacy `league`; unknown families produce
  neither object. Builder IDs become `builderBaseLeague`. Static metadata
  enriches known IDs without inventing missing names or icons.
- API files are `internal/models/v2/leaderboard_history.go` and its new tests;
  `internal/routes/leaderboard_history.go` and tests; generated
  `internal/docs/{docs.go,swagger.json,swagger.yaml}`; and
  `test/api/swagger_test.go`. The superseded recursive
  `internal/routes/history_badges.go` is removed. Focused route/model/Swagger
  tests, full `go test ./...`, `go vet ./...`, clean `go build ./...`,
  Swagger regeneration and six custom QUERY guards, stale generic SQL/JSON
  scans, and `git diff --check` pass. The naming-only correction reran focused
  tests, full `go test ./...`, `go vet ./...`, `go build ./...`, formatting,
  and diff/stale-name checks; OpenAPI did not change and was not regenerated.
  Dashboard/App have no active consumer, so neither persistent downstream task
  was reopened.
- **Current DevKit validation:** focused importer mapping/index tests pass and
  confirm all five typed destinations, legacy/current field normalization,
  league-tier precedence, token-only badges, and Tuesday-to-Monday Capital
  handling. Migration-module tests, entrypoint compilation, Goose validation,
  and `git diff --check` pass. A disposable local database applied 001–003 and
  exposed exactly the five typed column/index sets above; rolling 003 Down
  restored the exact seven-column JSONB `leaderboard_snapshot_items` shape,
  primary key, and two indexes. A final naming validation confirmed that every
  table, primary key, and secondary index uses the shared
  `leaderboard_history_` prefix. The disposable databases were removed.
  A second disposable database ran the real importer with
  `MIGRATION_LIMIT_DOCS=1`: one Mongo document from each source scanned
  successfully, and the four daily sources each wrote 200 typed rows. The
  arbitrary first Capital document was not a Tuesday and correctly wrote zero;
  focused mapping coverage separately proves Tuesday-to-prior-Monday storage.
  That disposable database was also removed.
- **Real local application:** after API and Tracking compatibility completed,
  the user selected a clean naming break. The local version-3 `tracking`
  database created the five final prefixed tables, then dropped all five
  superseded typed tables with no aliases/views or row preservation. This
  intentionally discarded 6,214,431 partial old Home-player import rows; the
  other four superseded tables were empty. All five final tables are empty and
  ready for the one-shot Mongo importer. Live inspection confirms their exact
  column sets, five prefixed primary keys, ten prefixed secondary indexes, and
  the absence of every superseded typed/generic table. Goose remains version 3
  and `player_links` remains unchanged at 175,634 rows. No remote or
  production database was touched.

## Active migration 003 — Legend History rebuild

- `public.legend_history_snapshots` is renamed to
  `public.legend_history`, then truncated because its existing SQL contents
  are explicitly rejected. Migration Up preserves no old SQL row and drops
  `created_at`; the separate one-shot Mongo importer below loads the approved
  historical `looper.legend_history` source into the final shape.
- The final row is fully typed with no JSONB: `season`, `player_tag`,
  `player_name`, `exp_level`, `trophies`, `attack_wins`, `defense_wins`,
  `rank`, nullable `clan_tag`, `clan_name`, `clan_badge_token`, and nullable
  `league_tier_id`. Numeric gameplay values are nonnegative, rank is positive,
  names/tokens are nonblank, and clan snapshot fields are either all null or
  all populated. Only the league-tier ID is stored because API/static data can
  reconstruct its name and icons.
- `season` preserves the authoritative source identifier verbatim. Legacy
  rows use values such as `2018-07`, while current source rows use values such
  as `v2-2026-07-06T05:00:00Z`; the importer does not guess a month label from
  a season-end timestamp.
- `legend_history_pkey(season, player_tag)` preserves one final-season row per
  player. `idx_legend_history_season_rank(season, rank)` serves full season
  leaderboard reads, and
  `idx_legend_history_player_season(player_tag, season DESC)` serves player
  history. The partial
  `idx_legend_history_clan_rank(clan_tag, rank, season DESC)` serves up to
  1,000 best historical finish rows for one clan without scanning other clans.
- `database/migrations/legend_history.go` reads the dedicated
  `looper.legend_history` collection, whose low-impact estimated count on
  2026-07-30 was approximately 70,693,940 documents. It accepts nonblank
  authoritative seasons, player tags/names, positive ranks, and nonnegative
  typed counters. Clan tag/name and one badge token are extracted from the
  optional clan snapshot, and only `leagueTier.id` is retained from newer
  league-tier objects. Mongo `_id`, repeated badge URLs, league-tier
  name/icons, and every JSON catch-all are discarded.
- This importer is intentionally a one-shot bulk load rather than a
  checkpointed migration. Each start drops the three secondary indexes and
  truncates only `legend_history`, bulk-copies/upserts the source in batches,
  and recreates the season/rank, player/season, and clan/rank indexes only
  after the entire collection succeeds. An interruption leaves a partial
  target without secondary indexes, and rerunning restarts clean. It never
  changes Mongo.
- Down restores `legend_history_snapshots`, its original primary-key/index
  names, `data jsonb`, and
  `created_at timestamp with time zone NOT NULL DEFAULT now()`. It reconstructs
  the prior JSON item from typed values, using token-only badge/tier-ID
  objects because removed CDN URLs and tier display metadata are intentionally
  not stored. Newly written rows survive rollback; intentionally discarded
  pre-003 rows cannot be reconstructed.
- Persistent Tracking task `019f94ba-972b-7171-ad08-0f4f86796eef` owns the Go
  final-season writer. Persistent API task
  `019f92a8-f4b8-74a2-ab70-cf25481fd6d1` owns renamed readers and
  response-specific season/player/clan history contracts. Tracking is complete
  for the superseding typed contract; API compatibility remains with its
  persistent owner, and no new tasks were created.
- **Tracking complete:** `models/runtime_scripts.go`, `scripts/scheduled.go`,
  and `scripts/scheduled_test.go` implement completed-season ingestion for
  official Legend league `29000022`. Each scheduled cycle treats every
  official season ID as opaque. Legacy `YYYY-MM` completion uses the
  established season-window helper; `v2-<RFC3339>` is parsed only internally,
  with the embedded timestamp treated as the authoritative season end and
  completion defined as `embedded_end <= now`. The original identifier is
  passed unchanged into the official fetch URL and SQL, and only seasons not
  already complete in SQL are fetched. Ranking requests use the official
  season endpoint with `limit=25000` and follow every returned `after` cursor
  to exhaustion; no API read limit truncates storage. Empty pages with
  continuation cursors, repeated cursors, transport failures, invalid
  responses, empty final results, duplicate tags/ranks, and noncontiguous
  ranks reject the season without changing its prior rows.

  Each valid row writes only the twelve normalized columns: opaque season,
  player tag/name, experience, trophies, attack/defense wins, rank, nullable
  all-or-none clan tag/name/token, and nullable positive `league_tier_id`.
  Clan badges use Tracking's existing token-only convention and only
  `leagueTier.id` is retained; the legacy `league` object is not substituted.
  Legend has no JSONB write and no history JSON badge-transformer dependency.
  One transaction bulk-copies the complete season, upserts
  `(season, player_tag)`, deletes stale players only for that exact opaque
  season, and commits atomically; failed fetches or writes remain missing and
  retry on the next cycle. Focused coverage proves legacy no-tier and new
  league-tier rows, nullable clans, token-only clans, exact legacy/v2 ID
  preservation, the v2 embedded-end completion boundary, 300-row ingestion
  beyond the API read cap, cursor exhaustion, idempotency,
  failure-without-partial-write retry, and the absence of Legend JSONB.
- **API complete:** every Legend reader selects only the exact twelve typed
  columns; no `data`, `created_at`, or JSON decoder remains. `season` is an
  opaque nonblank, path-safe identifier up to 128 characters and is passed to
  SQL/returned unchanged, including both legacy `YYYY-MM` and newer
  `v2-<RFC3339>` values.
- `GET /v2/legends/history/{season}?limit=` remains default 25/max 200 ordered
  by rank. `GET /v2/player/{player_tag}/legend-history` remains descending
  season. New
  `GET /v2/clan/{clan_tag}/legend-history?limit=` returns default 200/max
  1,000 best historical finishes ordered by rank then descending season,
  matching the partial clan index. Empty results are HTTP 200
  `{items:[]}`.
- The response-specific camelCase item is exactly `season`, `tag`, `name`,
  `expLevel`, `trophies`, `attackWins`, `defenseWins`, `rank`, nullable
  `clan`, and nullable `leagueTier`. Clan returns tag/name and reconstructs
  standard 70/200/512 `badgeUrls` from `clan_badge_token`; the internal token
  never leaks. League tier always includes the stored authoritative ID and
  adds name/icon URLs only when canonical Clash `league_tiers` static data
  contains that ID. Removed JSON-only `previousRank`, `townHallLevel`, old
  `league`, and arbitrary stored-field preservation are not fabricated. The
  active mobile helper scans the same typed columns and produces the same
  normalized item.
- API focused typed-SQL/model/opaque-season/clan-order/1,000-limit/static-tier/
  badge/mobile/stale-reader and OpenAPI tests pass, as do full
  `go test ./...`, `go vet ./...`, `go build ./...`, Swagger regeneration,
  all six custom QUERY-operation guards, stale JSON/data scans, and
  `git diff --check`. Dashboard/App have no active caller.
- **Migration validation:** Goose syntax validation passed. A disposable local
  database applied migrations 001–003, accepted both `2018-07` and
  `v2-2026-07-06T05:00:00Z` unchanged, exposed exactly the twelve typed
  columns and the primary key plus all three secondary indexes, then rolled
  003 Down. Down restored the exact six-column
  `legend_history_snapshots` shape and reconstructed name, clan badge token,
  and league-tier ID in its JSON. The disposable database is removed after
  final local application. Because the real database was already at Goose
  version 3, its typed shape is applied separately in place below.
- **Real local application:** on 2026-07-30, the normalized Legend block was
  applied atomically in place to the local `tracking` database. Per explicit
  user authorization, the 400,000 superseded JSON-backed Legend rows were
  discarded rather than backfilled; `legend_history` is now empty and ready
  for the one-shot Mongo importer. Live inspection confirms the exact twelve
  typed columns, primary key, and three secondary indexes. Rollback-only smoke
  inserts accepted both legacy and v2 opaque season identifiers plus nullable
  clan/tier shapes. Goose remains version 3 and `player_links` remains
  unchanged at 175,634 rows. No production or remote database was touched.

## Active migration 003 — iOS Live Activities removal

- Migration Up drops `public.mobile_live_activities`, including its primary
  key, two unique constraints, two checks, and two partial indexes. The later
  accepted mobile-notification normalization also drops the complete legacy
  `mobile_war_subscriptions` table, so no standalone
  `live_activity_enabled` preference survives.
- Ordinary APNs/FCM push delivery remains, but its device/preferences/account
  schema is governed by the later normalization sections below rather than
  being frozen at the former subscription shape.
- No dedicated Live Activity importer exists. The Timescale README and privacy
  inventory no longer describe the removed store.
- Down restores `live_activity_enabled boolean NOT NULL DEFAULT true` within
  the old war-subscription table and restores the
  exact prior 16-column `mobile_live_activities` table, UUID/defaults, status
  and environment checks, primary key, unique constraints, and partial
  clan/war active indexes. Deleted Live Activity and subscription rows cannot
  be reconstructed.
- Persistent API task `019f92a8-f4b8-74a2-ab70-cf25481fd6d1` owns privacy and
  API SQL/model cleanup; persistent Tracking task
  `019f94ba-972b-7171-ad08-0f4f86796eef` owns removal of Live Activity
  delivery while preserving ordinary push; persistent App task
  `019f92aa-b5fb-77f1-8370-85a80d9cfb3a` owns ActivityKit/UI/project cleanup.
  API, App, and Tracking Live Activity cleanup are complete and validated
  locally/uncommitted. No new task was created.
- **Tracking Live Activity cleanup complete:** `scripts/mobile_events.go` and
  `scripts/mobile_events_test.go` remove the Live Activity row/type, every
  `mobile_live_activities` select/update, payload/hash/content-state builder,
  ActivityKit push token path, `liveactivity` APNS push type/topic, and the
  `mobile_war_subscriptions.live_activity_enabled` read/scan. Event processing
  now ends after the existing ordinary APNS/FCM notification loop. Ordinary
  APNS still uses the app bundle topic, `apns-push-type: alert`, and the
  existing alert/sound payload; FCM and the existing war/CWL preference
  predicates are unchanged. Focused coverage proves the subscription query
  needs no removed Live Activity column, war/CWL preferences still select
  their existing event types, and a normal sandbox APNS request retains the
  exact alert headers and payload without ActivityKit content state.
- **Separate Tracking normalization dependency:** the preserved ordinary
  war/CWL event query still targets `mobile_war_subscriptions`, as required by
  the narrow Live Activity authorization. The later migration-003
  notification normalization now drops that table entirely and replaces its
  event-specific booleans with a different eight-boolean, enabled-account
  model. Applying that later schema without a separately approved mapping
  would break the `mobilepush` domain. Tracking has not invented a mapping
  from `war_start_enabled`, `score_change_enabled`, `war_end_enabled`, and
  `cwl_rank_enabled` into the final preferences; this remains an explicit
  coordinator decision.
- **API complete:** privacy export/erase no longer selects or deletes
  `mobile_live_activities` and no longer reads
  `mobile_war_subscriptions.live_activity_enabled`. The API had no Live
  Activity handler/model surface to remove; the later notification contract
  owns the surviving ordinary push behavior. Focused privacy/removal/Swagger tests,
  OpenAPI regeneration, full `go vet ./...`, full `go test ./... -count=1`,
  production stale-reference audit, and `git diff --check` pass.
- **Migration validation:** the current consolidated disposable Up removes
  Live Activities and the later-approved legacy notification subscriptions.
  Down restores the exact legacy Live Activity, notification-preference,
  notification-subscription, war-subscription, and push-device structures;
  table-specific schema dumps match a clean version-2 baseline. The real local
  database now has migration 003 applied.

Tracking validation for the migration-003 slices:

- Final typed-table naming correction:
  `env GOCACHE=/tmp/clashking-tracking-history-names-focused go test -tags
  'script_internal_tests platform_internal_tests' ./scripts -run
  '^(TestLeaderboardHistory.*|TestTypedLeaderboardHistory.*|TestValidateAndFlattenLeaderboardHistory.*|TestMemoryScheduledStoreAuthoritativelyUpsertsLeaderboardHistory|TestCapitalHistoryUsesOfficialTuesdayDateWithoutImporterRemap)$'
  -count=1` passed. The same final state passed tagged full tests with
  `/tmp/clashking-tracking-history-names-tagged`, untagged full tests with
  `/tmp/clashking-tracking-history-names-full`, `go vet ./...` with
  `/tmp/clashking-tracking-history-names-vet`, and `go build ./...` with
  `/tmp/clashking-tracking-history-names-build`. An exact stale-name audit
  found no superseded typed table name in Tracking, the migration, or this
  report.
- Typed leaderboard-history follow-up:
  `env GOCACHE=/tmp/clashking-tracking-typed-history-focused go test -tags
  'script_internal_tests platform_internal_tests' ./scripts -run
  '^(TestLeaderboardHistory.*|TestTypedLeaderboardHistory.*|TestValidateAndFlattenLeaderboardHistory.*|TestMemoryScheduledStoreAuthoritativelyUpsertsLeaderboardHistory|TestCapitalHistoryUsesOfficialTuesdayDateWithoutImporterRemap)$'
  -count=1` passed. Coverage proves all five table mappings across global and
  numeric scopes, home-league precedence/fallback, Builder league/nullable
  values, token-only badges, typed clan/location/score fields, exact PK/scoped
  deletion SQL, partial-success preservation, authoritative empty clearing,
  cross-table isolation, and Tuesday Capital dates without importer remapping.
- `env GOCACHE=/tmp/clashking-tracking-typed-history-tagged go test -tags
  'script_internal_tests platform_internal_tests' ./... -count=1`,
  `env GOCACHE=/tmp/clashking-tracking-typed-history-full go test ./...
  -count=1`, `env GOCACHE=/tmp/clashking-tracking-typed-history-vet go vet
  ./...`, and `env GOCACHE=/tmp/clashking-tracking-typed-history-build go
  build ./...` passed across all packages.
- Normalized Legend follow-up:
  `env GOCACHE=/tmp/clashking-tracking-legend-normalized-focused go test -tags
  'script_internal_tests platform_internal_tests' ./scripts -run
  '^(TestMissingCompletedLegendSeasonsUsesExactOfficialIDs|TestLegendHistoryRowsStoreNormalizedTypedFieldsBeyondAPIReadCap|TestFetchAllLegendSeasonRankingPagesPaginatesToExhaustion|TestMemoryScheduledStoreLegendSeasonReplacementIsIdempotent|TestLegendHistoryPartialFailureRemainsMissingAndRetries|TestLegendHistorySQLUsesFinalTableAndTransactionalSeasonReplacement)$'
  -count=1` passed.
- `env GOCACHE=/tmp/clashking-tracking-legend-normalized-tagged-all go test
  -tags 'script_internal_tests platform_internal_tests' ./... -count=1`,
  `env GOCACHE=/tmp/clashking-tracking-legend-normalized-full go test ./...
  -count=1`, `env GOCACHE=/tmp/clashking-tracking-legend-normalized-vet go vet
  ./...`, and `env GOCACHE=/tmp/clashking-tracking-legend-normalized-build go
  build ./...` passed across all packages after the normalized Legend change.
- `env GOCACHE=/tmp/clashking-tracking-history-full go test ./... -count=1`
  passed across all packages after the badge-storage change.
- `env GOCACHE=/tmp/clashking-tracking-history-vet go vet ./...` passed, and
  `git diff --check` passed in both ClashKing Tracking and DevKit after the
  shared-report update.
- `env GOCACHE=/tmp/clashking-tracking-m003-focused go test -tags
  'script_internal_tests platform_internal_tests' ./scripts -run
  'Test(LeaderboardHistory|MemoryScheduledStoreAuthoritativelyUpsertsLeaderboardHistory|ValidateAndFlattenLeaderboardHistory|MissingCompletedLegendSeasons|LegendHistory|FetchAllLegend|MobileSubscriptions|SubscriptionWants|APNSNotification|LeaderboardMaterialized)'
  -count=1` — passed.
- `env GOCACHE=/tmp/clashking-tracking-m003-tagged go test -tags
  'script_internal_tests platform_internal_tests' ./... -count=1` — passed
  across all packages.
- `env GOCACHE=/tmp/clashking-tracking-m003-full go test ./... -count=1` —
  passed across all packages.
- `env GOCACHE=/tmp/clashking-tracking-m003-race go test -race ./...
  -count=1` — passed across all packages.
- `env GOCACHE=/tmp/clashking-tracking-m003-vet go vet ./...` and
  `env GOCACHE=/tmp/clashking-tracking-m003-build go build ./...` — passed
  with no findings.
- The production Go stale-reference audit found no
  `leaderboard_snapshot_items`, `legend_history_snapshots`,
  `mobile_live_activities`, `live_activity_enabled`, or Live Activity APNS
  reference in the changed runtime files. Intentional negative test literals
  guard against their return.

Tracking writer compatibility:

- `/Users/matthewanderson/PycharmProjects/clashking_tracking/models/wars.go`,
  `models/global_clans.go`, `scripts/wars.go`, `scripts/wars_store.go`, and
  `scripts/global_clans.go` now write only the final group, group-clan, and
  normalized group-member shapes. `cwl_groups` upserts `cwl_id`, official
  `season`, nullable `cwl_league_id`, lifecycle `state`, nullable `war_size`,
  and canonical `rounds`; it reads or writes none of `clan_tags`, `data`,
  `created_at`, `updated_at`, or `ended_at`. Legacy NULL league IDs are valid,
  while live groups use the tracked clan's real nonzero league ID.
- Tracking builds the same canonical legacy identity as the importer:
  official season plus sorted clan tags with leading `#` removed, joined by
  hyphens. It SHA-256 hashes that identity, takes the first nine bytes, and
  encodes them with unpadded URL-safe base64, producing the final deterministic
  12-character `cwl_id`.
- The official group endpoint supplies state, identity, clan snapshots, and
  rounds but no team size or roster. Tracking takes a positive real war size
  from the official CWL war responses it already fetches, leaving it NULL when
  no war response is available. It upserts group clans with exactly `cwl_id`,
  `clan_tag`, `name`, `clan_level`, and token-only `badge_token`; there is no
  group-clan roster JSONB.
- Global clan ingestion now retains member `town_hall` alongside tag/name in
  the typed `basic_clan.members` source snapshot. Inside the CWL transaction,
  Tracking locks that source roster, bulk upserts `cwl_group_members(cwl_id,
  clan_tag, name, tag, town_hall)` on `(cwl_id, tag)`, then deletes rows absent
  from the source for that exact `(cwl_id, clan_tag)`. An empty or missing
  source roster therefore clears prior members instead of leaving stale rows.
- Group, group-clan, member replacement, and existing war writes share the
  existing transaction. They do not
  create/populate `cwl_standings`, read it, or aggregate score/rank data.
- `cwl_group_clans.badge_token` is the token only: Tracking removes the URL
  path and trailing `.png` from the official badge URL before persistence.

- `env GOCACHE=/tmp/clashking-tracking-go-cache-d17-members go test -tags script_internal_tests ./scripts -run 'Test(CWLGroup|CWLWarTags|BasicClanMemberSnapshotIncludesTownHall|BasicClan)' -count=1`
  — passed. Coverage proves the exact normalized table projections,
  transaction-scoped authoritative stale deletion, typed Town Hall capture,
  deterministic group IDs, and token-only badges.
- `env GOCACHE=/tmp/clashking-tracking-go-cache-d17-members-tagged go test -tags 'script_internal_tests platform_internal_tests' ./...`
  — passed across all packages.
- `env GOCACHE=/tmp/clashking-tracking-go-cache-d17-members-full go test ./...`
  — passed across all packages.
- `git diff --check` — passed for the Tracking files and shared report.

API implementation (task `019f92a8-f4b8-74a2-ab70-cf25481fd6d1`): complete,
uncommitted, and compatible with the locally applied final tables.

- `internal/routes/war.go` and `internal/models/v2/war_responses.go` implement
  response-specific camelCase retrieval: the existing
  `GET /v2/cwl/{clan_tag}/ranking-history` now returns typed clan history;
  `GET /v2/player/{player_tag}/cwl/history` joins normalized
  `cwl_group_members` on `cwl_id`, `clan_tag`, and the indexed exact
  `player_member.tag = $1` predicate; and
  `GET /v2/cwl/leagues/{league_id}/rankings` reads one required
  `season`/`war_size` standings partition. The history query joins
  `cwl_groups`, `cwl_group_clans`, normalized member rows, and
  `cwl_standings` by actual keys.
- Public CWL history items deliberately hide internal deterministic `cwl_id`
  and contain no `createdAt`, `updatedAt`, or `endedAt` group metadata. API,
  legacy-group, and stats readers select none of the dropped
  `cwl_groups.created_at`, `updated_at`, or `ended_at` columns.
- Empty histories and standings are HTTP 200 with empty `items`. Legacy groups
  with a NULL `cwl_league_id`, and every group with no persisted standing, omit
  those values rather than inventing a league, score, or rank. No API scoring,
  destruction aggregation, tie-break, or rank aggregation policy was added.
- `internal/routes/legacy_war.go` rebuilds legacy group output from typed group
  and clan rows plus `cwl_group_members`; both typed history and legacy group
  output aggregate normalized name/tag/town-hall rows into the unchanged
  external `members` array. Its legacy ranking output reads only stored standings.
  `internal/routes/stats.go` replaces obsolete `cwl_groups.clan_tags` lookup
  with `cwl_group_clans` attribution. No active API reader retains a
  `cwl_groups.data`, `clan_tags`, `cwl_group_clans.members`, or JSON-path
  roster dependency.
- `internal/routes/cwl_history_test.go` verifies camelCase empty-standing
  behavior and static final-schema query guards; `internal/routes/register_test.go`
  covers all three routes. The public response model and route annotations did
  not change in this correction, so Swagger regeneration was unnecessary; the
  existing generated `CWLHistoryItem` definition was revalidated and still
  omits internal `cwlId` and removed group timestamps.

API validation:

- `env GOCACHE=/tmp/clashking-api-go-cache-d17-members go test ./internal/routes -run 'Test(CWL|Register)'` — passed.
- `env GOCACHE=/tmp/clashking-api-go-cache-d17-members go vet ./...` — passed.
- `env GOCACHE=/tmp/clashking-api-go-cache-d17-members go test ./...` — passed with
  localhost binding enabled outside the filesystem sandbox.
- `git diff --check` — passed.

Player-history contract redesign (persistent API task
`019f92a8-f4b8-74a2-ab70-cf25481fd6d1`): complete and uncommitted.

- `GET /v2/player/{player_tag}/cwl/history` now has the dedicated outer
  response `{"items":[...]}`; the redundant top-level `playerTag` and the
  generic player-item `state`, `rounds`, `standing`, roster `members`, and
  `clanLevel` fields are removed. Clan history and league-ranking wrappers are
  unchanged.
- `internal/models/v2/war_responses.go` defines the response-specific camelCase
  player history, clan, war record, clan/player placement, opponent, defender,
  and attack models. Each item contains `season`, normalized snapshot
  `townHallLevel`, nullable `cwlLeagueId`, nullable stored/observed `warSize`,
  `clan`, `attacks`, nullable player `placement`, and `missedAttacks`.
  `clan.badgeUrls` is rebuilt from the token-only snapshot through the existing
  official 70/200/512 badge URL pattern.
- `internal/routes/war.go` first uses the finalized
  `cwl_group_members(tag,cwl_id)` lookup from cumulative applied migrations
  026+027 and joins the exact group-clan snapshot and optional stored
  standing. It then expands canonical `cwl_groups.rounds[*].warTags`, joins
  those tags to completed `wars.war_tag`, requires an actual `war_members`
  lineup for the player, and reads attack facts from `war_attacks`.
- Each compact attack exposes only `warTag`, one-based `round`, opponent
  tag/name, defender tag/name/town-hall/map-position, stars, destruction
  percentage, order, and duration. It omits redundant attacker identity and
  invents no timestamp. `missedAttacks` is the sum of each completed,
  participated lineup's stored `attacks_per_member` minus that player's
  recorded attacks; mere registration in `cwl_group_members` never creates a
  missed opportunity.
- Player earned-star placement uses `RANK()` over recorded attack-star totals
  within the played clan and full CWL group, so equal star totals share the
  same rank and no unstored tiebreak is invented. It is returned only when the
  group is ended, every non-placeholder round war tag resolves to a completed
  stored war, the stored aggregate attack counts match the durable attack
  rows, and the player has an actual lineup; otherwise `placement` is null.
- Clan `wars`, `totalStars` (including any approved win bonus), and
  group/global placement read only `cwl_standings`. Until Tracking's deferred
  standings policy populates that row, they remain null rather than being
  synthesized from query-time scoring. A legacy NULL group league remains
  `cwlLeagueId:null`; war size remains null only when neither group/standing nor
  a consistent participated-war size supplies it. Registered players with no
  actual lineup return `attacks:[]`, `missedAttacks:0`, and null player
  placement.
- `internal/routes/cwl_history_test.go` covers the exact outer/item JSON,
  explicit null empty state, absence of the generic/internal fields, compact
  attack contract, official badge reconstruction, persisted standing
  projection, normalized/participation SQL joins, actual missed-opportunity
  calculation, and the completeness-gated rank queries.
- Swagger/OpenAPI was regenerated in `internal/docs/docs.go`,
  `internal/docs/swagger.json`, and `internal/docs/swagger.yaml`; the nullable
  player-history fields are marked `x-nullable`, and all six custom
  `x-http-method: QUERY` operations remain present.
- Validation passed:
  `/Users/matthewanderson/go/bin/swag init -g main.go -o internal/docs --parseInternal`;
  `env GOCACHE=/tmp/clashking-api-go-cache go test ./internal/routes -run
  'CWL|RegisterV2Routes|RouteContract' -count=1`;
  `env GOCACHE=/tmp/clashking-api-go-cache go vet ./...`;
  `go test ./...` with localhost test binding enabled outside the filesystem
  sandbox; `env GOCACHE=/tmp/clashking-api-go-cache go test ./test/api -run
  'Swagger|OpenAPI' -count=1`; both generated Swagger files retained six QUERY
  extensions; and `git diff --check`.
- Precise deferred dependency: Tracking standings aggregation/rank population
  is still required before `clan.wars`, `clan.totalStars`, or clan
  group/global placement can be populated. This API adds no standings scoring,
  win-bonus, destruction, comparator, or refresh policy. Existing durable
  `wars`/`war_members`/`war_attacks` facts are sufficient for attacks, actual
  missed opportunities, and completeness-gated player earned-star ranks, so
  those fields require no new Tracking policy.

Downstream relevance: Dashboard has only an unused generic client/proxy for
the existing clan-history path and no CWL history/rankings UI; no Dashboard
task was started. App and Bot have no active typed caller of these responses.

## Active migration 003 — mobile notification normalization

- `mobile_notification_preferences` is reduced to the natural identity
  `(user_id, device_id, environment)`, eight explicit booleans, and
  `reminder_timings integer[] NOT NULL DEFAULT '{}'`. The booleans are
  `league_battles_enabled`, `war_attacks_enabled`, `war_state_enabled`,
  `war_reminders_enabled`, `events_enabled`, `announcements_enabled`,
  `upgrade_finishes_enabled`, and `monthly_support_enabled`; each defaults to
  false. There is no preference-level master switch.
- The reminder check allows at most three non-null integer minute values, each
  from 1 through 2,820 inclusive. Legacy `Nh`/`Nm` values are converted while
  preserving order, invalid values are discarded, and only the first three
  valid in-range values survive.
- `mobile_notification_accounts(user_id, player_tag, source)` is the
  user-wide enabled-account relation. Its primary key is
  `(user_id, player_tag)`, `source` is exactly `verified` or `bookmarked`, and
  `(player_tag, user_id)` supports reverse lookup. Verified links take
  precedence over bookmarks. Legacy all-account preferences select all
  verified links; selected preferences and enabled per-player subscriptions
  migrate only authoritative verified links or player bookmarks.
- No paid entitlement or authoritative numeric bookmark limit exists in the
  current product. Migration 003 and the API therefore enforce source
  eligibility atomically but do not invent a count cap. A product-supplied
  limit can be added later without changing the normalized identity.
- `mobile_notification_subscriptions` and `mobile_war_subscriptions` are
  dropped. Clan notification eligibility derives from enabled players'
  current `basic_player.clan_tag`; there is no independent clan selector.
  Down reconstructs the prior preference/subscription schemas from the
  surviving normalized state but cannot recover discarded per-event,
  town-hall, clan, or device-specific account-filter choices.
- **App complete:** the App uses the combined camelCase preference/device/account
  response, atomically PUTs the device master plus eight booleans, integer
  reminder minutes, and user-wide account tags, and consumes only
  server-derived `verified|bookmarked` sources. Legacy arrays, subtype modes,
  per-type audiences, Town Hall/clan filters, and subscription payloads are
  removed from active code and local state.

## Active migration 003 — `mobile_push_devices` cleanup

- The final columns are `user_id`, `device_id`, `platform`, `provider`,
  `environment`, `token_ciphertext`, `token_hash`, `app_version`, `locale`,
  `authorization_status`, `enabled`, and `last_seen_at`. The natural identity
  `(user_id, device_id, provider, environment)` is the primary key and
  `token_hash` remains unique.
- Migration Up drops `id`, `timezone`, `created_at`, `updated_at`,
  `disabled_at`, `device_model`, `os_version`, and `build_number`. The
  redundant user/device index is removed; the delivery index is
  `(provider, environment, authorization_status) WHERE enabled = true`.
- `enabled` is the sole per-device master switch. Delivery additionally
  requires a stored token and `authorization_status` of `authorized` or
  `provisional`, followed by the relevant per-type preference. Disabling
  notifications keeps the token row and sets `enabled=false`; explicit
  unregister/logout may delete it.
- Down rebuilds the exact prior UUID-keyed table, constraints, defaults, and
  indexes, preserving every retained value and assigning fresh defaults to
  columns that no longer exist in the final schema.
- **App complete:** device registration retains the existing path and ordinary
  FCM lifecycle but sends only token, device identity, provider, platform,
  environment, app version, locale, and authorization status. The master PUT
  toggles `enabled` without unregistering; build number, OS version, device
  model, timezone, and APNS-token request fields are absent.

## Active migration 003 — retired authentication, ticket, and player stores

- `one_time_login_tokens` is dropped with no compatibility route or table.
  The caller audit found no active current login dependency. Down faithfully
  restores its UUID primary key, token-hash uniqueness, expiry/user indexes,
  columns, and defaults, but deleted token rows cannot be reconstructed.
  The App audit likewise found no one-time-login route, model, flow,
  documentation, or test, so no compatibility caller was retained or added.
- `open_tickets` is dropped only after its operational values are copied into
  the canonical `tickets` system. Canonical tickets now retain the applicant
  Discord user, optional thread, textual lifecycle status, naming convention,
  assigned clan, opted-in Discord users, applicant account tags, number,
  channel, server, and panel identity. Migration Up creates deterministic
  fallback panel rows for existing SQL rows before copying them; Down rebuilds
  the legacy row and JSON representation from canonical typed values before
  removing the added columns.
- The one-shot `bot_server_settings.go` importer now reads Mongo
  `usafam.open_tickets` and writes those same typed canonical ticket fields.
  It also creates stable canonical `ticket_panel` and
  `ticket_panel_buttons` identities from `usafam.tickets`, including button
  custom ID/label/style/emoji and the existing typed panel behavior, while
  continuing to retain the complete source panel document in legacy
  `ticket_panels` for source fields that do not yet have normalized columns.
  Existing `usafam.custom_embeds` rows continue to populate
  `server_custom_embeds`; canonical panel embed references are set only when
  that scoped template exists, so no cross-server or invented embed reference
  is created.
- Mongo open-ticket creation time is taken from an explicit source timestamp
  when present, otherwise from the Mongo ObjectID timestamp. Documents with
  neither source use the required SQL insertion-time fallback because the
  canonical column is non-null; no fake close time is generated.
- `player_current_stats` is dropped and its current-row Mongo importer path is
  removed. `player_season_stats` and its Mongo importer are also retired rather
  than backfilled. The
  dependent `api_global_counts` materialized view now counts authoritative
  `basic_player` rows. Down restores the prior table, clan and Legends indexes,
  and the old materialized-view source without reconstructing retired rows.
- `player_equipment`, `player_heroes`, `player_spells`, and `player_troops`
  are dropped with their primary/foreign keys. No compatibility tables or
  silent relocation is created. Tracking owns removal of the four active
  detail writers; any response field whose only source was one of these tables
  must be removed rather than fabricated. Down restores the exact typed
  columns, composite primary keys, and cascading `basic_player` foreign keys.
- `ranking_snapshots` is dropped with its composite primary key and
  type/date index. The one stale API reader is being retired. This decision
  does not alter canonical `leaderboard_history` or `legend_history`.
- `player_history_events` is dropped with its three indexes and dedicated
  ignored Mongo importer/checkpoint mapping. The API readers tied to this
  generic legacy event store are being removed or narrowed only where another
  authoritative current source exists. Down restores the exact seven-column
  table as a 30-day Timescale hypertable with default indexes disabled, then
  restores the clan/season, player/time, and event-time indexes. Other player
  histories and canonical leaderboard/Legend history remain untouched.

## Active migration 003 — player change-history rename

- `player_profile_changes` is renamed in place to
  `player_change_history`; this is a data-preserving name change with no
  column, type, default, Timescale partitioning, or response-semantic change.
- Its indexes become `idx_player_change_history_player_time`,
  `idx_player_change_history_type_time`, and
  `player_change_history_event_time_idx`. Down reverses the index and table
  names exactly.
- The only active SQL writer is Tracking's player-change ingestion and the only
  API SQL reader is the existing public stats history query. Existing
  persistent Tracking/API owners are updating those literals and stale docs;
  no downstream response contract changes are expected.

### Tracking player-stat delta writer

Migration 003 replaces `player_season_stats` with
`player_stat_changes(event_time, player_tag, clan_tag, stat_type,
previous_value, current_value, delta)`. It is a seven-day Timescale hypertable
with no JSONB, season, profile metadata, or synthetic baseline row. The
database accepts only `donated`, `received`, `clan_games`, and
`capital_gold_donated`, requires nonnegative before-values and a strictly
positive exact delta, and indexes player/type/time plus non-null
clan/type/time. There is intentionally no primary or unique event key because
the existing serialized `ps:<tag>` snapshot workflow owns comparison/retry
sequencing and distinct observations may share a timestamp.

Status: complete and local/uncommitted in persistent Tracking task
`019f94ba-972b-7171-ad08-0f4f86796eef`. No Bot, API, Dashboard, App,
migration, Mongo, or `basic_player` baseline-column work was added.

Files:

- `/Users/matthewanderson/PycharmProjects/clashking_tracking/models/bot_players.go`
- `/Users/matthewanderson/PycharmProjects/clashking_tracking/scripts/bot_players.go`
- `/Users/matthewanderson/PycharmProjects/clashking_tracking/scripts/bot_players_test.go`
- `/Users/matthewanderson/PycharmProjects/clashking_tracking/implementation-notes.md`

Writer and snapshot contract:

- `bot_players` no longer has a `PlayerSeasonStatRow`, `SeasonStats`, seasonal
  aggregation helper, or any `player_season_stats` SQL. Its replacement
  `PlayerStatChangeRow` contains only `event_time`, `player_tag`, nullable
  current `clan_tag`, `stat_type`, `previous_value`, `current_value`, and
  `delta`, matching `public.player_stat_changes` exactly.
- The only emitted `stat_type` values are `donated`, `received`,
  `clan_games`, and `capital_gold_donated`. Donations and received values come
  from the typed player response counters, Clan Games comes from the
  `Games Champion` achievement value, and Capital Gold comes from
  `clanCapitalContributions`.
- The existing Snappy-compressed Valkey `ps:<playerTag>` response remains the
  only before-state. A missing first snapshot writes the normal basic-player
  ingest and snapshot but no stat event. Tracking adds no SQL baseline or new
  `basic_player` counter column.
- Every later observation compares the typed current counter with the typed
  value decoded from the prior snapshot. A row is accepted only when both
  values are nonnegative and `current_value > previous_value`; `delta` is
  exactly their difference. Equal values and decreases/resets write no stat
  event. A player without a current clan still emits a valid positive delta
  with SQL `clan_tag = NULL`.
- The four possible stat rows share the observation's UTC event time and are
  inserted in the existing bot-player transaction after the basic-player and
  profile-change writes. Invalid stat rows fail the transaction instead of
  being silently skipped. The existing player event must still publish
  successfully before the compressed snapshot advances, so a failed required
  SQL/event effect retains the old before-state for retry; equal and reset
  observations advance the snapshot after the normal successful ingest.
- Tracking closes the cross-store retry window with one internal Valkey marker
  at `ps:stat-pending:<playerTag>`. Before opening SQL, it atomically reserves
  a PostgreSQL-microsecond-safe event time for the SHA-256 hash of the current
  prior `ps:<playerTag>` snapshot. The stored marker value is
  `<previous-snapshot-sha256>|<event-time-unix-nanoseconds>`. Repeated attempts
  against the same prior snapshot reuse that exact event time even when the
  live counters advance further. A different prior-snapshot hash replaces the
  marker; the marker deliberately has no TTL so an arbitrarily long SQL/event
  failure cannot reopen the duplicate window.
- The SQL transaction takes a per-player advisory transaction lock. For each
  `(event_time, player_tag, stat_type)` it updates the existing guarded row
  only when the retried `current_value` is greater, recalculating `delta`;
  otherwise it inserts only when no guarded row exists. Therefore a committed
  stat transaction followed by a failed required event publish, process exit,
  or snapshot write retries the same rows without appending duplicates. If the
  live counter advanced during the failure, the one pending row grows to the
  latest current value rather than creating an overlapping delta; a lower or
  equal retry never shrinks or duplicates it.
- After SQL commits and the required player event publishes, one Valkey Lua
  operation atomically writes the new compressed `ps:<playerTag>` snapshot and
  deletes `ps:stat-pending:<playerTag>`. If that operation fails, neither
  Valkey change applies and the retry guard remains. A successful snapshot
  advancement clears the reservation so a later genuine counter cycle can
  reserve a new event time.
- The existing profile-change payload and behavior are unchanged; its INSERT
  now targets the canonical renamed `player_change_history` table. The stat
  writer adds no season, Town Hall, trophies, loot, activity/activity-score,
  attack-wins, JSON data, or last-online field. Existing non-stat
  bot-player activity/TTL behavior remains separate and unchanged.

### ClashKing API player-stat readers

Status: complete and local/uncommitted in persistent API task
`019f92a8-f4b8-74a2-ab70-cf25481fd6d1`. A later `go run .` compile check
exposed that removal of the dead clan-season decoder had also removed the
generic `clanDecodeJSONValue` helper still required by
`scanBasicClanData` for the surviving typed `basic_clan.members` JSON. The API
restored that fallback decoder and its `encoding/json` import in
`internal/routes/legacy_clan.go`; no retired season-stat reader was restored.
Final validation passed: focused `go test ./internal/routes/...` after a
permitted rerun of an existing sandbox-blocked IPv6 `httptest` listener, full
`go test ./...` across every package and generated OpenAPI test, empty
`gofmt -l`, and `git diff --check`. No migration or database operation was run
by the API task.

Contract and query behavior:

- `GET /v2/player/{player_tag}/stat-history` accepts optional inclusive Unix
  `timestamp_start`, exclusive Unix `timestamp_end`, exact optional
  `stat_type=donated|received|clan_games|capital_gold_donated`, and `limit`
  with default/max 500. It returns newest-first
  `{items:[{eventTime,clanTag,statType,previousValue,currentValue,delta}]}`
  using a response-specific camelCase model, nullable `clanTag`, and a non-nil
  empty array. Range, type, and limit validation are strict.
- The stat-type-filtered SQL fixes `player_tag` and `stat_type` before its time
  range so it matches `idx_player_stat_changes_player_type_time`; the
  unfiltered query remains player-scoped. Neither shape exposes a season,
  JSONB payload, trophies, loot, activity/activity score, attack wins, Town
  Hall, last-online value, or a redundant top-level player tag.
- Registered
  `/v2/server/{server_id}/leaderboards/donations` aggregates `sum(delta)` for
  only `donated` and `received`, while
  `/v2/server/{server_id}/leaderboards/clan-games` aggregates only
  `clan_games`. Both use the exact `clashy.GetSeasonByID` start/end window;
  omitted season uses `clashy.GetSeasonID`, and an invalid season is HTTP 400.
  Dedicated response models prevent donation and Clan Games fields from
  leaking into each other's contracts.
- Capital Gold remains available through raw player stat history as
  `capital_gold_donated`; no unrequested leaderboard was invented. Registered
  activity and looting leaderboards and their exports/models/docs were
  removed, together with dead multi-clan donation, player-summary/top, legacy
  capital/player-season helpers, and the retired V1 player stats/loot model.
  Production API code has no `player_season_stats` reference.
- Dashboard and App have no runtime caller for the two retained server
  leaderboards, the retired activity/looting routes, or the new raw-history
  route, so neither persistent client task required implementation. Dashboard
  still has unused stale wrappers/README examples for routes that were already
  unregistered; these are not live proxies or UI invocations. Bot remained
  untouched under the user's explicit ownership boundary.

API files:

- `MIGRATION.md`
- `internal/models/v1/player.go`
- `internal/models/v2/leaderboards.go`
- `internal/models/v2/player_stat_history.go`
- `internal/models/v2/player_stat_history_test.go`
- `internal/routes/clan.go`
- `internal/routes/legacy_clan.go`
- `internal/routes/player.go`
- `internal/routes/legacy_admin_stats.go`
- `internal/routes/player_stat_history.go`
- `internal/routes/player_stat_history_test.go`
- `internal/routes/register.go`
- `internal/routes/register_test.go`
- `internal/routes/schema_cleanup_decisions_11_12_test.go`
- `internal/routes/server/leaderboards.go`
- `internal/routes/server/exports.go`
- `internal/routes/server/player_stat_leaderboards_test.go`
- `internal/docs/docs.go`
- `internal/docs/swagger.json`
- `internal/docs/swagger.yaml`
- `test/api/swagger_test.go`

### Mongo importer restart and index lifecycle

Status: implemented locally and uncommitted in DevKit. No Mongo query, importer,
Goose migration, database mutation, test suite, build, commit, or push was run
for this pass. Source-level tests were added for the shared one-shot lifecycle;
only `gofmt`, stale-reference scans, and `git diff --check` were executed.

- `clan_wars.go` is the only resumable importer and the only program allowed to
  read/write the shared migration checkpoint. It drops its secondary history
  indexes while importing or resuming and recreates them only after the source
  stream completes successfully.
- Every other executable importer is a one-shot rebuild. At startup it removes
  the rows owned by that importer and drops its delayable secondary indexes;
  it never recreates those indexes on an interrupted or failed run. A clean
  restart repeats the reset and starts Mongo from the beginning.
- Primary keys, unique constraints, and foreign keys are not treated as
  delayable indexes when they are needed for conflict identity or referential
  integrity. The CWL loader is the existing intentional exception: migration
  002 leaves its load-time PK/FK/index set absent, and the importer restores
  the exact constraints and indexes after the final batch.
- The safe settings order is `server_settings.go`, `server_clans.go`,
  `rosters.go`, then `bot_server_settings.go`. `server_settings.go` owns the
  canonical `servers` rebuild and therefore runs before importers whose rows
  reference servers. Basic clan data must likewise exist before
  `server_clans.go`, which deliberately skips untracked clan tags.
- The retired `player_stats.go` program and its transform package are deleted.
  Mongo `new_looper.player_stats` is not scanned or backfilled; the new
  positive-delta series starts only from live Tracking observations.

DevKit files:

- `database/timescale/003_v2_schema_cleanup.sql`
- `database/migrations/migrateutil/migrateutil.go`
- `database/migrations/migrateutil/migrateutil_test.go`
- `database/migrations/basic_clans.go`
- `database/migrations/bot_server_settings.go`
- `database/migrations/clan_change_history.go`
- `database/migrations/clan_records.go`
- `database/migrations/clan_wars.go`
- `database/migrations/cwl_groups.go`
- `database/migrations/join_leave_history.go`
- `database/migrations/player_links.go`
- `database/migrations/player_online_events.go`
- `database/migrations/rosters.go`
- `database/migrations/server_clans.go`
- `database/migrations/server_settings.go`
- `database/migrations/player_stats.go` (removed)
- `database/README.md`

Static coverage and validation:

- `scripts/bot_players_test.go` adds focused source/behavior coverage for all
  four exact types and values, full `Games Champion` extraction, nullable
  current clan, positive-only generation, equal/reset suppression, no
  first-observation event, post-success reset snapshot advancement, the exact
  seven-column INSERT, stable retry event-time reservation and atomic cleanup,
  guarded SQL update-or-insert plus per-player advisory locking, the canonical
  profile-history table, forbidden-field absence, and stale season-stat
  runtime symbols.
- Per explicit authorization, no Go tests, builds, vet commands, or migrations
  were run. `gofmt` was applied to the three changed Go files,
  `gofmt -d` returned no output, the runtime stale-reference audit passed, and
  `git diff --check` passed for Tracking and this shared report.

## Active migration 003 — player online events

- `player_online_events` remains the durable last-seen/activity Timescale
  hypertable and retains exactly `seen_at timestamptz NOT NULL DEFAULT now()`,
  `tag text NOT NULL`, and `clan_tag text NOT NULL`.
- Migration 003 drops duplicated `townhall_level`, changes the chunk interval
  from Timescale's prior seven-day default to an explicit three months, and
  retains the two access-path indexes `(tag, seen_at DESC)` and
  `(clan_tag, seen_at DESC)`. The standalone `seen_at` index is removed as
  redundant for the approved player/clan history queries.
- Down restores the prior seven-day chunk interval, standalone time index, and
  non-null smallint Town Hall column. Because Up intentionally discards that
  duplicated value, rows surviving a rollback receive `0`; the restored column
  has no permanent default, matching the prior schema.
- The DevKit Mongo importer now writes only the retained event timestamp and
  player/clan tags. Existing persistent Tracking/API owners are auditing
  runtime SQL and tests; no retention, compression, summary, or public
  response change is authorized.

## Active migration 003 — demo seed retirement

- `database/seed_demo_data.sql` is deleted outright. No replacement fixture or
  seed mechanism is added, and documentation/reporting no longer treats a
  demo seed as a schema-compatibility target.
- This source removal does not delete or modify rows previously inserted into
  any local database. Applying migration 003 did not perform a separate demo
  seed data deletion.

## Active migration 003 — normalized player current rankings

- `player_rankings_current` is rebuilt as typed rows keyed by
  `(player_tag, ranking_type, location_id)`. Its only columns are those three
  identity fields plus nullable `rank` and nullable `points`; it has no
  country name/code, dedicated global/local rank, JSONB, or timestamp.
- Ranking types are exactly `home` and `builder_base`. Location is `global` or
  an official numeric location ID encoded as text. A placement check requires
  rank and points to be simultaneously present or absent, positive/nonnegative
  when present, and global rows to have a current rank.
- A partial unique index on `(player_tag, ranking_type)` for numeric locations
  enforces at most one retained country row per player/type, plus the optional
  global row. A partial `(ranking_type, location_id, rank)` index serves
  current scoped leaderboard reads.
- Migration backfill preserves only an explicit legacy Home Village global
  rank with current typed `basic_player.trophies`; it does not invent a numeric
  location from country names/codes or retain stale JSON. Down restores the
  prior one-row table, but cannot reconstruct discarded country metadata,
  full JSON, Builder Base placement, or timestamps.
- Tracking owns complete staged refreshes: global batches upsert and delete
  absent global rows; numeric batches upsert observed players, replace their
  older numeric location, and null both rank and points for players absent
  from that exact refreshed location. API must return a retained location ID
  even when its local rank is null and resolve display metadata from canonical
  static locations without fabricating global placement.
- The ClashKing App consumes the final response-specific camelCase contract as
  `{tag,homeVillage,builderBase}`, with nullable points/global rank/location
  metadata/local rank fields per category. Its shared direct/mobile-init
  parser preserves retained-location null placement and keeps Home Village and
  Builder Base independent; no legacy snake_case/data/timestamp fallback or
  fabricated global placement remains.
- `clan_rankings_current.updated_at` is also removed. Its typed ranking data,
  primary key, and scope/rank index otherwise remain unchanged.

## Active migration 003 — typed short links

- `short_links` retains `id`, `url`, and `created_at` and drops only the
  catch-all `data jsonb`. Its primary key and link behavior are unchanged;
  Down restores `data jsonb NOT NULL DEFAULT '{}'`.
- The DevKit Mongo importer now writes and conflict-updates only `id` and
  `url`. The active API create/read paths already use only those typed fields;
  the persistent API owner is confirming models/docs/tests contain no JSON
  fallback. Tracking, Bot runtime, Dashboard, and App have no SQL caller.

## Active migration 003 — blacklisted-role retirement

- `server_blacklisted_roles` is dropped outright with its
  `(server_id, role_id)` primary key and cascading server foreign key. Rows are
  not copied into `server_roles`, no new role type is introduced, and no
  compatibility view or equivalent behavior remains.
- The DevKit server-settings importer no longer deletes or inserts this table
  from legacy `blacklisted_roles`. Down restores the exact empty table,
  primary key, and foreign key but cannot reconstruct retired rows.
- The persistent API owner is removing the settings write/read/model/docs/test
  field and coordinating only proven downstream callers. Existing canonical
  `server_roles` behavior is explicitly unchanged.

## Active migration 003 — `raid_weekends` retirement

- The legacy Postgres `raid_weekends` table is dropped with its composite
  `(clan_tag, start_time)` primary key, end-time index, and members GIN index.
  No compatibility table/view or data relocation is created. Down restores
  the exact typed/JSON columns, defaults, primary key, and indexes empty.
- The live audit found no current Go Tracking SQL writer or DevKit importer;
  legacy Python and Bot matches target Mongo. No replacement persistence is
  required.
- The user reviewed and explicitly approved removing the API-only consumers:
  clan and player Raid Weekend history, capital aggregate statistics, server
  capital-raids leaderboard, and mobile Raid Weekend responses wherever this
  table is their only source. Models/docs/tests and proven downstream callers
  are removed with those surfaces rather than fabricated from another store.
- The separate expiring Valkey current Capital Raid snapshot and
  player-to-clan mapping remain untouched and are not treated as historical
  storage.
- ClashKing App task `019f92aa-b5fb-77f1-8370-85a80d9cfb3a` removed the
  mobile-initialization `raid_data`/`PlayerRaids` parser and every dependent
  player/home to-do metric, card/chip/explanation/mock, timing helper, and
  raid-only localization artifact. It does not add a replacement or
  compatibility path, so missing retired history can no longer appear as
  fabricated `0/5` progress. Official/live clan Capital Raid data and the
  separate current snapshot behavior remain intact.

## Active migration 003 — canonical servers and server configuration

- The old `servers` and `server_settings` relations are consolidated into one
  canonical `servers` table keyed by `id`. It retains `name`, `joined_at`,
  `left_at`, the still-undecided `embed_color`, and every surviving approved
  server-setting column. `embed_color` is preserved because no removal decision
  has been made for it.
- Migration Up rebuilds `servers`, maps each settings row to the same server
  ID, preserves every old server row, and supplies the established setting
  defaults only when a server had no settings row. The settings timestamp wins
  when present; otherwise the old server timestamp survives. Every foreign key
  referencing the old physical servers relation is recreated against the
  canonical table with its existing name and delete behavior before the old
  relations are removed.
- The retired per-server fields are `use_api_token`, `banlist_channel_id`,
  `strike_log_channel_id`, `reddit_feed_channel_id`, and `greeting`. They are
  not represented by compatibility columns or views. API-token verification,
  ban and strike data, link parsing, and other unrelated product behavior are
  not removed merely because these obsolete configuration fields disappear.
- `server_link_parse_channels` is dropped. The five independent link-parse
  booleans remain on `servers`, but no per-channel filter, migrated channel
  list, compatibility response field, or importer path remains.
- Down reconstructs the exact version-2 `servers` and `server_settings`
  columns, defaults, primary/foreign keys, and surviving values. Retired
  nullable settings return empty and `use_api_token` returns its old true
  default; discarded legacy values cannot be reconstructed.

## Active migration 003 — server clans and canonical alert/feed logs

- `server_clan_settings` is dropped completely. Its greeting,
  `auto_greet_option`, dedicated ban-alert channel, timestamp, and identity row
  are not preserved in another clan-settings table or compatibility view.
- `server_clans` retains `tag`, `server_id`, `category_id`, `abbreviation`, and
  `updated_at`. `clan_channel_id` is removed without replacement, and the
  duplicated `name` is removed; callers that need the current clan name must
  join `basic_clan` by tag.
- `server_logs` adds webhook-backed `ban_alert` and `reddit_feed`. A database
  scope check requires `ban_alert` to have a clan tag and `reddit_feed` to have
  no clan tag. The normal API configuration flow accepts a Discord channel,
  finds or creates the bot-owned webhook, and persists its webhook ID.
- Legacy `ban_alert_channel_id` and `reddit_feed_channel_id` values contain only
  channel snowflakes. SQL has no channel-to-webhook relation and cannot create
  a Discord webhook, so migration 003 deliberately does not copy those values
  into `webhook_id` or perform an out-of-band Discord action. Existing channel
  values are discarded and must be reconfigured through the canonical log
  flow. The DevKit importers accept only real webhook-backed `ban_alert` or
  `reddit_feed` log objects in the canonical log source.
- Down removes the two new log rows/types, restores the prior log-type check,
  and recreates the dropped version-2 clan settings/link-channel schemas empty.
  It restores the removed `server_clans` columns with their old null/default
  behavior, but cannot reconstruct intentionally discarded values.
- **Deferred Bot compatibility break:** the user directed this initiative not
  to create, reuse, message, or edit a Bot task. The live Bot still reads the
  retired blacklist-role, server/clan greeting, auto-greet, clan-channel,
  dedicated ban/reddit channel, and link-parse-channel settings; its setup,
  evaluation/autorefresh, link-parser, ban-alert, and Reddit jobs use them.
  It also calls the retiring server capital-raids API route. DevKit/API/
  Dashboard/App work proceeds without compatibility aliases, so Bot follow-up
  is explicitly deferred and required before those paths can be considered
  compatible with the final schema/API.

## Active migration 003 — Logs and Reminder Discord destinations

- Scope is deliberately limited to `server_logs` and `reminders`; ticketing,
  panels, giveaways, autoboards, rosters, embeds, and every other channel
  selector are unchanged by this decision.
- `server_logs` already has the final typed destination shape:
  `webhook_id text NOT NULL` identifies the bot-owned webhook in the parent
  channel and nullable `thread_id text` identifies an optional child
  thread/post. The existing server-log importers, API, and Dashboard already
  preserve both values, so migration 003 adds no log DDL.
- `reminders` already has the final typed destination shape:
  `channel_id text` stores the parent channel and nullable `thread_id text`
  stores the selected child thread/post. Migration 003 adds no reminder DDL.
  The DevKit `bot_server_settings` importer now copies Mongo `thread_id` or
  legacy `thread` into the typed column, preferring `thread_id`, while leaving
  it null when the source reminder has no child destination.
- The persistent API task
  `019f92a8-f4b8-74a2-ab70-cf25481fd6d1` completed the shared destination
  contract in `internal/routes/server/destinations.go`. Text and announcement
  parents may be used directly or with an exact child thread; forum parents
  require an exact child post. Both parent and child must belong to the
  requested guild and the child must name that exact parent. Validation
  failures are structured HTTP 400 `validation_failed` responses with field
  details; Discord non-404/upstream webhook failures remain HTTP 502.
- API Logs now run that validator before parent-webhook reuse/creation while
  retaining `server_logs(webhook_id, thread_id)`. Reminder create, update,
  select, scan, and response paths now persist and expose
  `reminders(channel_id, thread_id)`. Channel discovery adds only the real
  `forum` type needed by the destination control; no other selector semantics,
  DDL, refresh path, or compatibility JSON was added.
- Exact API files are
  `internal/routes/server/{destinations.go,destinations_test.go,logs.go,reminders.go,reminders_test.go,discord.go,discord_test.go}`,
  `internal/models/v2/{logs.go,reminders.go,server_responses.go}`,
  regenerated `internal/docs/{docs.go,swagger.json,swagger.yaml}`, and
  `test/api/swagger_test.go`. Focused destination/reminder/log/channel and
  Swagger tests passed; generated docs retain exactly six custom QUERY
  operations; full `go test ./...`, `go vet ./...`, `go build ./...`, and
  `git diff --check` passed. The full suite was rerun successfully outside the
  sandbox after the first attempt hit only an environment restriction binding
  an IPv6 `httptest` listener.
- The persistent Dashboard task
  `019f929f-bd3f-7ca0-ab74-f6ad08ddec1e` completed Logs and Reminders using
  one shared destination helper imported only by those two surfaces. Text/news
  parents support direct delivery or an optional exact child; forum parents
  require a selected child post. Atomic parent-plus-thread saves, parent
  changes clearing stale children, and forum-direct or mismatched-child
  rejection are covered.
- Dashboard Logs now correctly resolves the migrated
  guild/webhook/forum-parent configuration documented in the Dashboard
  section above instead of falsely reporting that its parent disappeared.
  Active Logs and Issues use family-wide server/clan counts with explicit
  EN/FR/NL labels. Focused validation passed 3 files/14 tests; the full suite
  passed 52 files/340 tests, plus lint, TypeScript, the 23-page production
  build, locale parsing, and diff checks. Forum support remains limited to
  Logs and Reminders; every other selector remains unchanged.
- **Deferred delivery compatibility gap:** active Tracking raid-reminder SQL
  currently reads `channel_id` but not `thread_id` before publishing the
  reminder event. The active Bot reminder model and send paths resolve only
  the parent `channel` value and do not consume a typed child thread. The user
  explicitly prohibited Bot coordination or edits, so the schema/importer/API/
  Dashboard work does not claim end-to-end thread delivery until a separately
  authorized Bot/Tracking follow-up carries `thread_id` through the event and
  sends into that child destination.

## Active migration 003 — typed Autoboards clean break

- Migration 003 intentionally drops the unfinished `autoboards` rows and
  rebuilds the table without `identifier`, legacy `type`, `channel_id`,
  `button_id`, `days`, `locale`, or `data jsonb`. No legacy Mongo or SQL
  backfill, alias, compatibility view, or inferred board type is created.
  Down faithfully restores the complete pre-003 table, constraints, and
  indexes empty because the discarded rows cannot be reconstructed.
- Final `autoboards` identity/configuration is `id`, `server_id`,
  nonblank registry-owned `board_type`, `target_scope` (`family|custom`),
  `delivery_mode` (`refresh|send`), `enabled`, and timestamps. The API-owned
  registry, rather than a hard-coded database enum, defines each configured
  board type's target kind, minimum/maximum targets, supported modes,
  type-specific refresh interval bounds, and Dashboard capabilities. The
  eventual permanent product catalog remains undecided and migration 003 does
  not invent database enum values. The API currently exposes five clearly
  `sample-*` definitions—family overview, clan activity, player leaderboard,
  location rankings, and war summary—solely as demonstrable, non-permanent
  registry entries across the supported scopes, target kinds, cardinalities,
  and delivery modes.
- Canonical Discord state is required nonblank `webhook_id`, nullable
  `thread_id`, and nullable `message_id`. Dashboard submits a parent
  channel/thread selection; API validates guild ownership and parent-child
  semantics, resolves or creates the bot-owned parent webhook, and persists no
  `channel_id`. Text/announcement parents support direct delivery or an exact
  child thread; a forum parent requires an exact child post. The public
  `messageId` field is read-only operational response state and is never
  accepted from Dashboard
  POST/PUT payloads. API creation stores it null and full replacement clears it
  so the future executor owns establishing refresh state; send rows keep it
  null. This forum/thread extension applies only to Logs, Reminders, and
  Autoboards; no other selector changes.
- Refresh scheduling uses positive `interval_minutes` and requires all send
  schedule columns null. Send scheduling requires an IANA
  `schedule_timezone`, local `schedule_time`, and exactly one
  `schedule_kind`: `daily`, `weekdays` with one through seven ISO weekday
  integers (`1..7`), or `day_of_month` with a value from `1..31`. Send rows
  cannot have an interval or persistent message. No sub-daily send recurrence,
  Clash-event trigger, or movable event schedule is represented.
- Scheduler state is nullable `next_run_at` and `last_run_at`; every enabled
  row must have `next_run_at`. Separate partial
  `(next_run_at, id)` indexes serve enabled refresh and send work, while
  `(server_id, created_at, id)` serves the management list.
- Ordered custom targets live in
  `autoboard_targets(autoboard_id, position, target)`. The generic public name
  is `targets`; there is no tag/tags alias because values may be clan tags,
  player tags, war tags, or location IDs. The primary key prevents duplicate
  targets per board, the position key preserves a unique order, and the
  cascading foreign key removes children with their board. Deferred database
  constraint triggers enforce the final transaction state: family scope has
  zero target rows and custom scope has at least one. The API registry applies
  the more specific kind and cardinality rules.
- The DevKit settings importer retains the separate server
  `autoboard_limit`, but deliberately does not scan legacy Mongo
  `clashking.autoboards`; the old button/data/day shape cannot be mapped
  truthfully to the undecided registry. A source-level regression test locks
  that no-backfill boundary and the exact typed schema.
- Bot execution work is explicitly out of scope. Existing Bot Mongo
  autoboard refresh/send jobs do not consume this SQL scheduler, registry, or
  normalized targets, so runtime execution remains a disclosed deferred
  compatibility gap rather than a compatibility alias in DevKit/API.
- DevKit validation passed: focused schema/no-import tests and the full
  migration Go module, Goose validation, formatting, and `git diff --check`.
  A disposable Timescale database applied migrations 001-003, accepted valid
  family/send and custom-target/refresh rows, rejected send rows with a
  persistent message and custom scope without a target, then rolled 003 Down.
  Down restored all 17 prior autoboard columns, its primary/identifier keys and
  due/server-type indexes, and removed `autoboard_targets`. The explicitly
  named disposable database was deleted afterward.
- On 2026-07-30, the exact Autoboards Up block from the current migration 003
  was applied atomically in place to the real local `tracking` database because
  Goose had already recorded version 3 before this clean-break block was added.
  The five unfinished legacy Autoboards rows were intentionally discarded as
  approved; no compatibility copy or backfill remains. The live database now
  has the 19-column typed `autoboards` table, normalized
  `autoboard_targets`, both deferred scope triggers, and all six expected
  primary/unique/due/list indexes. Goose remains at version 3.
- `public.player_links` contained 175,634 rows immediately before the in-place
  Autoboards transaction and the same 175,634 rows afterward. The applied SQL
  touched only `autoboards`, its new child table, function, triggers, and
  indexes; no other relation was rebuilt or modified. No production or remote
  database was touched.


## Current migration-003 DevKit validation

- `goose -dir database/timescale validate`, migration-module `go test ./...`,
  `go vet ./...`, builds of every ignored Go importer, `gofmt`, and
  `git diff --check` pass.
- A clean disposable Timescale database applied 001, 002, and the current 003,
  then rolled 003 Down successfully. Table-specific schema dumps after
  rollback match a separate clean version-2 database for every affected
  mobile, authentication, ticket, player, ranking, and materialized-view
  relation.
- The latest server pass also applied and rolled back the full current 003 on a
  disposable database. After Up, all 17 surviving foreign keys that formerly
  targeted the old physical servers table target canonical `servers`, with no
  `servers_legacy`/`servers_v3` target. After Down, 20 version-2 foreign keys
  target restored `servers`, again with no stale temporary target. Schema dumps
  for `servers`, `server_settings`, `server_clan_settings`,
  `server_link_parse_channels`, and `server_logs` match the clean version-2
  baseline; `server_clans` has the same restored columns, defaults,
  constraints, and data semantics with the two restored columns physically
  appended.
- A populated version-2 server fixture proved that name/lifecycle/embed color,
  every surviving nondefault setting, settings timestamp, clan/category
  identity, abbreviation, existing log, and dependent foreign-key rows survive
  Up. A server without a settings row received only the established defaults.
  Legacy greeting/channel values disappeared, no fake ban/reddit webhook row
  was manufactured, and Down retained every surviving value while recreating
  discarded settings empty/defaulted.
- The database accepts clan-scoped `ban_alert` and server-scoped `reddit_feed`
  rows, rejects server-scoped `ban_alert` and clan-scoped `reddit_feed`, and
  removes both new types before restoring the old log-type constraint in Down.
- A populated version-2 disposable database proved the notification backfill:
  the preference master switch moved to the device row, legacy types became
  the exact booleans, `15m/1h/47h` became `{15,60,2820}`, selected verified
  and bookmarked accounts became authoritative normalized rows, and
  ineligible selected tags were excluded. The database rejected zero, 2,821,
  four-value, and null-element reminder arrays while accepting `{1,2820}`.
- The populated pass retained player change-history and online-event rows,
  removed every retired table, and rebuilt `api_global_counts.player_count`
  from the three authoritative `basic_player` rows. Down restored all retired
  schemas empty, preserved retained rows, and restored mobile push/preference
  values where representable.
- Forced query plans use
  `idx_mobile_notification_accounts_player`,
  `idx_mobile_notification_preferences_announcements`,
  both approved player-online tag/clan time indexes, and
  `idx_player_change_history_player_time`. Timescale reports a 90-day
  (`INTERVAL '3 months'`) online-event chunk in Up and the original seven-day
  interval after Down.
- The real local Timescale database passed this disposable validation before
  application and was subsequently migrated to Goose version 3 on 2026-07-27.
  No production/remote database, commit, push, or publication action occurred.
