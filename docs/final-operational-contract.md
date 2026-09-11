# Migration 017 consumer contract

Migration 017 finalizes the shared schemas consumed by Tracking, API, Bot, Dashboard, and App. Applied migrations 001–016 stay immutable; the finalization is forward-only and production execution remains a separate approval.

## Legend leaderboards

Tracking atomically replaces `legend_rankings_current` only after its complete refresh loop. Its final columns are `tag`, `name`, `trophies`, `global_rank`, nullable `clan_tag`, and nullable `clan_name`; `tag` is the primary key and `global_rank` is unique. Tracking selects current Legend I players with `basic_player.league_id=105000036`, orders by trophies descending then tag, and joins `basic_clan` for clan identity. If that join does not resolve, both clan fields are NULL.

`leaderboard_history_player_home` is the compact daily all-ranked history with `(day,tag)` primary key and `global_rank,trophies`. Migration 017 retains prior `location_id='global'` rows and removes location, player, league, and clan snapshots.

```json
{
  "current": {"tag":"#P0Y","name":"Player","trophies":6500,"globalRank":12,"clan":{"tag":"#2PP","name":"Clan"}},
  "history": [{"day":"2026-09-10","globalRank":15,"trophies":6420}]
}
```

There are no stored trophy buckets, coverage flags, stale flags, freshness timestamps, or separate Legend per-player daily table.

## Mobile notifications

`mobile_push_devices` owns device/token identity and its per-device `enabled` switch. It has no category or timing fields. `mobile_notification_preferences` owns one user's `war_attacks_enabled`, `war_state_enabled`, `war_reminders_enabled`, `raid_reminders_enabled`, `events_enabled`, `announcements_enabled`, `monthly_support_enabled`, `legend_defenses_enabled`, `reminder_timings`, and `raid_reminder_timings`.

Migration 017 promotes each existing category with logical OR across a user's devices and takes timing arrays from that user's most recently seen device. The new Legend-defense switch starts false. There is no Legend-attack category.

`mobile_notification_accounts` owns user-level per-player enablement. A row is accepted only when `player_links` has the same `(tag,user_id)` and is currently verified. Unlink, unverification, or ownership transfer deletes the enablement before the link changes, so a new owner never inherits it. Every enabled device for that user receives the same currently enabled verified accounts and preferences.

Valkey Streams provide runtime delivery and deduplication. Migration 017 drops `mobile_notification_deliveries`; no SQL outbox or delivery-history table replaces it.

## Base layouts

`bases.id` is generated bigint identity. A valid row has an official HTTPS `OpenLayout` link, Discord `message_id`, optional paired `server_id/channel_id`, description up to 1,000 characters, and creation time. `base_images` owns up to four ordered `https://api.clashk.ing/v2/media/...` URLs. `base_downloaders` stores unique `(base_id,user_id)` identities. `base_votes` privately stores one `-1` or `1` vote per `(base_id,user_id)`; public readers use `base_public_counts`.

Migration 017 imports only valid legacy layout links, assigns bigint IDs in deterministic `(created_at,uuid)` order, filters image URLs to the ClashKing media namespace, and normalizes valid Discord user IDs into downloader/vote rows. It retains no UUID, Mongo ID, or legacy audit field.

First-click conversion is a two-phase state machine without a legacy status column:

1. The API resolves the row by unique `message_id`. Both location fields NULL means incomplete.
2. The API copies attachments and idempotently stages owned URLs in `base_images`. A copy failure leaves the row incomplete.
3. The Bot edits the Discord components. An edit failure leaves staged images intact and the location fields NULL, so retry does not recopy successful images.
4. After the Discord edit succeeds, the API sets `server_id` and `channel_id` together. This is the only completion transition.

```json
{
  "id":"42","messageId":"123456789012345678","serverId":"234567890123456789","channelId":"345678901234567890",
  "baseLink":"https://link.clashofclans.com/en?action=OpenLayout&id=TH17%3AHV%3AAAAA",
  "images":["https://api.clashk.ing/v2/media/base.png"],"description":"Anti-three-star layout",
  "downloadCount":10,"upvotes":8,"downvotes":1
}
```

## War and CWL storage

Migration 017 does not change war or CWL storage. `wars` retains its `archive_pack_id`, `archive_offset`, and `archive_compressed_bytes` locator triple; `war_archive_packs` and `war_archive_pending` remain authoritative for wars.clashk.ing pack publication. Canonical CWL groups, clans, members, rounds, wars, standings, and history remain available to `/v2/stats/cwl`. Migration 016 removes only the rejected `cwl_season_statistics` table, procedure, and validator, so no consumer may write or read that surface.
