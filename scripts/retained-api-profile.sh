# Authoritative local-only retained API profile. Used by tests and interactive
# development; this is not a proposed production migration ordering.
fixture_image='timescale/timescaledb:2.29.2-pg18@sha256:9508616d5b941ed931198504c5db3fb47e8f53f790732ea1e889591f1062057c'
fixture_sources=(
  001_initial_stats.sql
  002_initial_settings.sql
  003_tracking_observability.sql
  004_developer_link_grants.sql
  005_remove_legacy_admin_auth.sql
  006_simplify_developer_applications.sql
  007_app_update_rollouts.sql
  008_discord_cache.sql
  009_clan_capital_gold.sql
  010_app_update_rollback.sql
  012_discord_managed_resources.sql
  013_subject_mutation_locks.sql
  020_player_link_mutation_locks.sql
  022_billing_customer_operations.sql
  023_roster_ai_budget_locks.sql
  027_server_link_token_policy.sql
  028_discord_coordination.sql
)
