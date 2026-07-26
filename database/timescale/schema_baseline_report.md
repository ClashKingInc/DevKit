# Schema Baseline Coordination Report

This report tracks the coordinated implementation of
the V2 cleanup now consolidated in `001_initial_stats.sql` and
`002_initial_settings.sql` across DevKit and its consumers. Every task that
changes an affected surface must update its section before reporting
completion.

## DevKit

Status: consolidated into the two-file baseline.

Validation:

- A fresh database migrates successfully to Goose version 2.
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
- Remove the password-reset fixture rows from `database/seed_demo_data.sql`.
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
- Update Discord demo users in `database/seed_demo_data.sql` so they no longer
  write removed profile/account-display fields.

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
- Update demo base rows with explicit server/channel ownership, images, and
  description values.

#### 7. `bot_settings`

- Drop the legacy table entirely; no API, bot, Dashboard, or App runtime caller
  exists.
- Remove its demo placeholder rows and its dedicated Mongo-to-Timescale
  importer, including the now-dead checkpoint and collection references.
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
- Remove only the two tables' demo rows. The DevKit migration audit found no
  dedicated Mongo importer or other generated fixture/schema consumer to
  remove.
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
- Demo fixtures now use the three typed global ranking groups, add one
  location-scoped Home Village row when the existing clan has a numeric
  location, and populate the two new typed basic-clan point values without
  overwriting existing nonzero values.
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
- Remove its demo fixture. The DevKit migration audit found no dedicated
  importer, checkpoint, or other fixture path for this table.
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
  renamed table. No demo fixture uses this table.
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
  row-history semantics. Update demo rows to write only the retained columns.
  The DevKit audit found no dedicated importer.
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
- Update the DevKit custom-embed importer and demo fixture to write
  `server_custom_embeds`. The legacy Mongo collection remains named
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
- The demo fixture now creates only `server_custom_embeds` rows and stores the
  new composite template references. The DevKit importer has no UUID-embed or
  singular-ticket-panel path to update.
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

Status: decisions 1–6, decisions 9–14, and the final authorized Bases feature
are complete in the persistent API task.

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

Validation:

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
category management, and decision 16 typed giveaway caller migration,
including the final server-generated create and manager-delete contracts. Task
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

Status: complete for Discord OAuth caller compatibility and decision 4 refresh
token rotation. Task `019f92aa-b5fb-77f1-8370-85a80d9cfb3a` is the persistent
App owner for this initiative and remains unarchived for future relevant
follow-ups.

Tasks:

- `019f929f-be56-7fe2-8b16-a28d3872ba6e`: Discord OAuth caller compatibility
- `019f92aa-b5fb-77f1-8370-85a80d9cfb3a`: decision 4 refresh-token rotation

Files:

- `/Users/matthewanderson/IdeaProjects/ClashKingApp/lib/features/auth/data/auth_service.dart`
- `/Users/matthewanderson/IdeaProjects/ClashKingApp/test/features/auth/data/auth_service_test.dart`
- `/Users/matthewanderson/IdeaProjects/ClashKingApp/lib/core/services/token_service.dart`
- `/Users/matthewanderson/IdeaProjects/ClashKingApp/test/core/services/token_service_test.dart`

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

## Final review

Status: decisions 1–14 and the authorized Bases feature, including the final
server-generated create lifecycle and manager delete lifecycle, are complete
in DevKit/API where assigned. Persistent Tracking implementations for
decisions 10 and 13 are complete. Decisions 15 and 16 are appended and
validated in DevKit, and Decision 16's API, Tracking, and required Dashboard
caller work is complete. Persistent owners remain available while DevKit
continues the table review.

### Decision 16 giveaway typed storage

Status: complete. DevKit schema/importer/fixture changes are appended and
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
- Demo data now writes its representative giveaway through typed columns only.
  `bot_server_settings.go` no longer copies a whole legacy Mongo document into
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
  `to_jsonb(giveaways)` in DevKit's giveaway fixture/importer path.

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
  member `tag`, and `town_hall`. Its `(cwl_id, tag)` primary key permits one
  player registration per CWL group, its composite foreign key scopes every
  member to a real group-clan snapshot, and the importer builds
  `(tag, cwl_id)` as the direct player-history lookup index after loading.
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
  `cwl_standings`. After import completion, the `(tag, cwl_id)` B-tree index
  serves that lookup without JSON extraction or a GIN index.
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

- **Local schema:** migration 027 was rolled back at the user’s request after
  confirming that a completed local import had populated 598,000 groups and
  4,769,356 clan snapshots. Those disposable local CWL rows were truncated;
  the normalized member-table revision of 027 was validated and reapplied, and
  local Goose now reports version 27. No production/remote database or Mongo
  data was contacted.
- **Local verification:** `cwl_groups`, `cwl_group_clans`,
  `cwl_group_members`, and `cwl_standings` each contain zero rows after the
  authorized reset. The ignored importer checkpoint is absent, so the next
  approved import begins at the first Mongo document. Before import, the three
  loaded CWL tables have zero indexes and no primary/foreign-key constraints.
- **Importer:** created, compiled, and run by the user against the earlier
  roster-JSON shape before the reset. From
  `database/migrations`, run `go run cwl_groups.go` only when the user wants to
  import Mongo snapshots. It checkpoints through the existing
  `migration_state.json` mechanism, reads `looper.cwl_group`, and writes only
  Timescale group/snapshot rows. Legacy rows without a source league ID stay
  NULL; it never creates standings. Its checkpoint was cleared after the table
  reset, so the next run starts from the first Mongo document. This script
  refuses an existing checkpoint or any nonempty CWL target table;
  interruption recovery is to truncate the CWL tables, clear the checkpoint,
  and restart from zero.
- **Tracking:** complete in persistent task
  `019f94ba-972b-7171-ad08-0f4f86796eef`. Live CWL writes now target the new
  group and clan-snapshot tables, retain real official league IDs, derive war
  size from a fetched official war, and leave standings untouched. Focused,
  tagged/full tests and diff checks passed.
- **API:** complete in persistent task
  `019f92a8-f4b8-74a2-ab70-cf25481fd6d1`. It provides typed camelCase player
  roster history, clan CWL history, and league-ranking retrieval with 200/empty
  `items` for absent standings. Player lookup uses the normalized
  `cwl_group_members(tag, cwl_id)` B-tree path. Old `cwl_groups.data`,
  `clan_tags`, and roster-JSON readers were removed; no Dashboard/App caller is
  affected. Focused/full tests, vet, generated OpenAPI validation, and diff
  checks passed.
- **Deferred intentionally:** no `cwl_standings` writes, scoring totals,
  rank recomputation, or periodic rank job exists until the outstanding
  comparator, destruction aggregation, and official bonus policy is decided.

Importer environment-path correction:

- `database/migrations/migrateutil.LoadConfig` now resolves connection settings
  from the repository-root `.env`, while retaining `database/.env` only as a
  compatibility fallback. Checkpoint files remain under `database/`, although
  this specific import intentionally does not resume. This fixes
  `go run cwl_groups.go` from `database/migrations` without moving or copying
  the root `.env`.
- `migrateutil_test.go` covers root-file preference, database-directory
  fallback, the fixed 12-character hash fixture, and badge URL normalization.
  The importer compiled and the migration utility test suite passed.
- CWL import batching is capped at 1,000 group documents per transaction even
  when the generic `MIGRATION_BATCH_SIZE` remains 50,000. Each CWL document
  fans out into group-clan and typed member rows, so the original generic batch
  deferred a very large transaction before the first visible
  commit/checkpoint. The bounded batch keeps memory, commit latency, progress,
  and visibility predictable. A lower explicitly configured generic batch is
  still honored.
- Duplicate group/snapshot/member keys inside one Mongo batch collapse before
  PostgreSQL COPY/plain INSERT, and flush start/end timing is printed
  explicitly. There is no conflict-update or resume path.
- Migration 027 deliberately removes every index, primary key, and dependent
  foreign key from `cwl_groups`, `cwl_group_clans`, and
  `cwl_group_members` while data loads. After the final successful
  batch/checkpoint, the importer creates all three primary keys, restores the
  group-clan/member/standings foreign keys, and builds
  `idx_cwl_groups_season_league`,
  `idx_cwl_groups_season_league_size`,
  `idx_cwl_group_clans_clan_cwl`,
  `idx_cwl_group_members_player_tag`, and
  `idx_cwl_group_members_group_clan`, printing the duration of each build.
  Until that finalization succeeds, Tracking writes and indexed API reads
  remain offline.
- Group identity is SHA-256 over the legacy canonical identity, first nine
  bytes encoded with unpadded URL-safe base64 (12 characters). For example,
  `2023-09-2002C8PC-2L292Y80C-2YPJUCRYP-92QJ9RR8-9RR8UL2Y-JU2QLQ8L-P8YLGLGL-YQLJUQ8U`
  maps to `F1PPW_hG-A3h`. `badge_token` stores only the final token segment
  without `.png`.
- The CWL `cwl_groups` and `cwl_group_clans` demo inserts were removed from
  `database/seed_demo_data.sql`; unrelated demo fixtures remain unchanged.
- **DevKit validation:** the revised importer compiles, `go test ./...`,
  `goose -dir database/timescale validate`, and `git diff --check` pass.
  Local catalog verification confirms the exact five member columns, zero
  rows, Goose 27, absent checkpoint, zero indexes, and no primary/foreign-key
  constraints on the three loaded tables before import. Static importer
  inspection/build covers all final constraint and index statements; executing
  those statements against the empty local schema inside a rolled-back
  transaction succeeded, and the post-rollback catalog still has zero loaded
  table indexes.

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
