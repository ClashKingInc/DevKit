# CWL season statistics

Migration `010_cwl_season_statistics.sql` adds one ordinary PostgreSQL table.
It does not add archive storage, refresh state, or finalized-state columns.

| Column | Type | Rule |
|---|---|---|
| `season` | `text` | PK; `YYYY-MM` |
| `cwl_league_id` | `integer` | PK; positive |
| `war_size` | `smallint` | PK; 1–50 |
| `group_count` | `bigint` | nonnegative eligible groups |
| `clan_count` | `bigint` | nonnegative distinct group/clan registrations |
| `registered_player_count` | `bigint` | nonnegative distinct group/player registrations |
| `town_halls` | `jsonb` | descending unique `[{"level":17,"count":10}]` values |
| `refreshed_at` | `timestamptz` | replacement time |

`reconcile_cwl_season_statistics(text[])` takes advisory transaction lock
`4850467623902124044`, then deletes and rebuilds each selected season inside the
calling transaction. It calculates groups, clans, members, and town halls in
separate CTEs so joining source tables cannot multiply totals. Groups without a
positive league ID or a 1–50 war size are excluded; incomplete groups otherwise
contribute the partial data currently stored.

Run one of the explicit rerunnable scopes with the same database connection
settings used for Goose:

```sh
psql "$DATABASE_URL" --set scope=current --file scripts/reconcile-cwl-season-statistics.sql
psql "$DATABASE_URL" --set scope=previous --file scripts/reconcile-cwl-season-statistics.sql
psql "$DATABASE_URL" --set scope=current_previous --file scripts/reconcile-cwl-season-statistics.sql
psql "$DATABASE_URL" --set scope=all --file scripts/reconcile-cwl-season-statistics.sql
```

Passing `NULL` directly to the procedure reconciles every source or previously
materialized season. A specific `text[]` reconciles exactly those seasons and
removes stale rows if an eligible source group no longer exists.
