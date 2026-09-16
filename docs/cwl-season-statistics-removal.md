# CWL season-statistics removal

Migration `016_remove_cwl_season_statistics.sql` is the forward removal for the
CWL-only population aggregate introduced by migration 010. Applied migration
010 remains unchanged in Goose history; migration 016 drops its derived table,
reconciliation procedure, and private JSON validator. The canonical
`cwl_groups`, `cwl_group_clans`, and `cwl_group_members` sources remain.

## Consumer cutover

1. Tracking must remove the scheduled refresh and every direct
   `CALL public.reconcile_cwl_season_statistics(...)` invocation. No caller is
   present in the current primary Tracking checkout, so confirm the deployed
   revision has the same boundary before applying the migration.
2. The current API checkout has no query against the removed table. Update its
   hard-coded retained migration inventory in `scripts/local-api-database.mjs`
   to include migration 016 so local database startup accepts the authoritative
   profile.
3. Apply migration 016 through Goose only after both consumers are deployed.

The API's `/v2/stats/cwl` performance route and public war hit-rate and summary
support are separate from this removed population aggregate. Migration 009's
`league_hitrate_stats`, `ranked_league_tier_stats`, `legend_daily_stats`, army
family tables, and their v2 successors remain supported.
