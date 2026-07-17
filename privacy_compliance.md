# Database Privacy Compliance Notes

These SQL schemas define ClashKing account, Discord-link, push, audit, ticketing, and dashboard data. They are in scope for global mobile-app privacy compliance even though this repository does not run an application by itself.

## Personal-data stores

- `auth_users`, Discord OAuth token tables, refresh tokens, one-time login tokens, password reset tokens, and API tokens.
- `player_links`, `user_settings`, `user_bookmarks`, `user_recent_searches`, `search_groups`, reminders, rosters, tickets, strikes, giveaways, and audit history.
- `mobile_push_devices`, `mobile_war_subscriptions`, and live-activity push token tables.
- Webhook tokens, admin/audit records, and server configuration that can identify Discord users or guilds.

## Required controls

- Store raw tokens encrypted or hashed. Never expose token ciphertext, hashes, webhook tokens, or OAuth tokens in exports.
- Keep expiry indexes and retention policies for short-lived auth, recent-search, and telemetry tables.
- Use `ON DELETE CASCADE` for child token/device rows where account deletion must remove dependent data.
- Keep moderation/security/audit records access-restricted and retain them only for the operational/legal limitation period.
- Treat player tags and clan tags as personal data when linked to a Discord user or ClashKing account.

## Export and deletion

Exports should provide readable account/profile, preferences, bookmarks, links, reminders, notification settings, and audit summaries without secrets. Deletion should remove or anonymize user-linked rows, unlink Clash of Clans player tags from Discord identities, remove mobile push tokens, and preserve only the minimum audit/security evidence required by law or abuse-prevention needs.
