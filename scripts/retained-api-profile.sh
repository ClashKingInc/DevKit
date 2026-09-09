# Canonical migration inventory for retained API tests and local development.
# This is the same contiguous 001-013 sequence used for production upgrades.
fixture_image='timescale/timescaledb:2.29.2-pg18@sha256:9508616d5b941ed931198504c5db3fb47e8f53f790732ea1e889591f1062057c'
fixture_sources=(
  001_initial_stats.sql
  002_initial_settings.sql
  003_tracking_observability.sql
  004_developer_link_grants.sql
  005_remove_legacy_admin_auth.sql
  006_simplify_developer_applications.sql
  007_worker_api.sql
  008_ranked_battle_history.sql
  009_league_army_analytics.sql
  010_cwl_season_statistics.sql
  011_active_verified_players.sql
  012_legend_only_army_compositions.sql
  013_battle_player_time_identity.sql
)
