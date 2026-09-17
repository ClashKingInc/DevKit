# Migration 020: player leaderboard snapshots

This is an additive forward Goose migration. Existing history tables and player data are not rewritten or reset by applying it.

| Object | New stored data |
| --- | --- |
| player_townhall_leaderboards | Up to 500 players per TH 7–18: tag, name, townhall_level, trophies, league_id, league_group_tag, clan_tag, rank |
| player_league_leaderboards | Up to 500 players per ranked tier 105000001–105000036, with the same fields |
| tracking_scheduled_jobs | job text + period date primary key, last_tag text cursor, nullable completed_at timestamp |

Town Hall ordering is league descending, trophies descending, tag ascending. League ordering is trophies descending, tag ascending. Unranked and unknown leagues are excluded; ranked players with zero trophies remain eligible. The existing partial player indexes support the per-board queries. Unique board/rank indexes allow concurrent refresh after initial population.

Example snapshot: `#PLAYER, Example, 18, 2300, 105000034, #GROUP, #CLAN, 1`. Example job: `ranked_trophy_reset, 2026-09-21, #LASTPROCESSED, NULL` while in progress, or a completion timestamp when finished.

Apply 020 first, then deploy Tracking to populate both views and refresh them every six hours. Verify `pg_matviews.ispopulated` for both views before deploying the API reader. They intentionally start WITH NO DATA. If separate database roles are used, the API role needs SELECT on both views and Tracking needs refresh ownership/privileges plus read/write access to the jobs table, following the deployment's existing role policy.

The Tracking PR also uses the jobs table for a bounded Monday trophy reset, gated on successful closeout. This migration does not run that job. Roll back the API reader and Tracking writer before a Goose down, which removes only these three new objects.
