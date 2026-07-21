# Timescale Privacy Compliance Notes

The DevKit Timescale schemas define personal-data stores used by the ClashKing mobile app, dashboard, tracking service, bot, and admin panel. Schema changes must preserve privacy controls across every client.

## Personal-data tables and fields

- `auth_users`, `auth_discord_tokens`, `auth_refresh_tokens`, `one_time_login_tokens`, `auth_password_reset_tokens`, and `api_tokens` contain account, authentication, and token metadata.
- `player_links`, `player_upgrades`, `player_upgrade_preferences`, `user_settings`, `user_bookmarks`, `user_recent_searches`, `search_groups`, rosters, reminders, tickets, and moderation records can link Discord users to Clash of Clans player tags, app activity, preferences, and server workflows.
- `mobile_push_devices`, `mobile_notification_preferences`, `mobile_notification_subscriptions`, and `mobile_live_activities` contain device identifiers, encrypted push tokens, account filters, and notification preferences.
- `admin_users`, `admin_sessions`, and `admin_audit_events` contain administrator identity, session, IP address, user-agent, action, and resource data.

## Required schema practices

- Store raw push tokens only encrypted (`*_ciphertext`) and use hashes (`*_hash`) for lookup and dedupe.
- Add expiry indexes or retention policies to session, one-time-login, password-reset, recent-search, telemetry, and process-stat tables.
- Prefer cascading deletes from authenticated user tables for tokens and device rows.
- Cascade player upgrade data and preferences from `player_links` so unlinking removes the app-owned player data.
- Keep audit tables append-only for accountability, but mask/minimize IP and user-agent values in exports.
- Do not add advertising IDs, contact-list data, precise location, health, biometric, or other sensitive categories without a dedicated legal/design review.

## Request handling

Verified access/export requests should include account, token metadata without secrets, preferences, bookmarks, recent searches, player links, device registrations without raw tokens, notification settings, and relevant dashboard/bot records.

Verified erasure requests should delete or anonymize user-owned rows while preserving records needed for security, abuse prevention, tax/accounting, or legal obligations. Public Clash of Clans history may remain only after account links are removed.
