# Final battle and army analytics contract

Migration 017 is the destructive finalization after migrations 008–016. It keeps raw battle history, replaces hash identity with canonical share codes, removes all `*_v2` tables, and establishes one unsuffixed aggregate contract. It is intentionally irreversible because removed hashes, legacy family provenance, and incompatible aggregate dimensions cannot be reconstructed.

## Codes and day boundary

| Field | Code | Meaning |
|---|---:|---|
| `battle_mode` | `1` | Ranked |
| `battle_mode` | `2` | Legend |
| `direction` | `1` | Attack; the only direction included in aggregates |
| `direction` | `2` | Defense |
| `cohort` | `legend_i` | All observed Legend I attackers |
| `cohort` | `top_1000` | The global top 1,000 subset |
| `cohort` | `top_200` | The global top 200 subset |

Day D is the half-open interval `[D 05:10:00 UTC, D+1 05:10:00 UTC)`. Cohorts overlap by design, so one attack may contribute once to each qualifying cohort. No defense aggregate or direction dimension exists.

## Raw battles

`battles_farming` keeps `(player_tag,battle_time)` identity, `stars`, `destruction_percentage`, `looted_resources`, and nullable `share_code`. `duration_seconds` is `smallint NOT NULL DEFAULT 0`; migration 017 maps historical NULL to zero and refuses values outside `0..32767`.

`battles_ranked` keeps `(player_tag,battle_time)` identity plus opponent, mode, direction, Town Hall, stars, destruction, loot, and nullable share code. Attack rows require a valid loot object; defense rows require SQL NULL. `duration_seconds` has the same non-null smallint contract. There is no army hash or parser version.

```sql
INSERT INTO battles_ranked(
  player_tag,opponent_tag,battle_time,direction,battle_mode,
  player_town_hall,opponent_town_hall,stars,destruction_percentage,
  duration_seconds,looted_resources,share_code
) VALUES (
  '#P0Y','#P0L','2026-09-10T12:00:00Z',1,2,
  18,18,3,100,121,'{"gold":1000,"elixir":900}','u1x1'
);
```

Tracking writes the actual requested-player perspective and never synthesizes the opposite perspective. It writes duration directly, including zero; `NULLIF(duration_seconds,0)` is invalid under this contract.

## Compositions and families

`army_compositions` is keyed by `share_code` and stores `main_troops`, `clan_castle_troops`, `spells`, sorted hero IDs, equipment assignments, pet assignments, optional siege-machine ID, and creation time. A share-code upsert may use `ON CONFLICT (share_code) DO NOTHING`; no hash calculation or compatibility row is allowed.

```sql
INSERT INTO army_compositions(
  share_code,main_troops,clan_castle_troops,spells,heroes,
  equipment,pet_assignments,siege_machine_id
) VALUES (
  'u1x1','[{"id":1,"quantity":10}]','[{"id":2,"quantity":1}]',
  '[{"id":3,"quantity":2,"clanCastle":false}]','{4}',
  '[{"equipmentId":5,"heroId":4}]','[{"petId":6,"heroId":4}]',7
) ON CONFLICT (share_code) DO NOTHING;
```

`army_families` uses generated bigint `family_id`, one representative share code, optional normalized name, and timestamps. `army_family_members` is only `share_code`, `family_id`, and `assigned_at`; matching scores and versions are application logic, not durable identity.

## Daily aggregates

`army_family_daily_stats` has primary key `(day,cohort,family_id)` and these totals: `attack_count`, `distinct_player_count`, four star counts, `destruction_percentage_sum`, and `duration_seconds_sum`.

`legend_daily_stats` has primary key `(day,cohort)`, the same totals, and JSON arrays `hero_stats`, `pet_stats`, `equipment_stats`, and `pet_hero_assignments`. Item rows are sorted and use these exact shapes:

```json
{
  "heroStats": [{"id": 4, "uses": 120, "triples": 45}],
  "petStats": [{"id": 6, "uses": 90, "triples": 38}],
  "equipmentStats": [{"id": 5, "uses": 100, "triples": 40}],
  "petHeroAssignments": [{"petId": 6, "heroId": 4, "uses": 80, "triples": 35}]
}
```

Every JSON row satisfies `0 <= triples <= uses <= attack_count`. Duration averages divide `duration_seconds_sum` by `attack_count`; there is no `duration_count`. The migration does not relabel old aggregates because they lack the cohort dimension and use incompatible day semantics; Tracking rebuilds all three cohorts from retained raw attacks.

Family IDs cross JSON boundaries as decimal strings:

```json
{
  "day": "2026-09-10",
  "cohort": "top_200",
  "familyId": "42",
  "attackCount": 200,
  "distinctPlayerCount": 190,
  "starCounts": {"zero": 1, "one": 9, "two": 70, "three": 120},
  "destructionPercentageSum": 18450,
  "durationSecondsSum": 24200
}
```

The API, Dashboard, and App use only the unsuffixed tables and these names. There are no `_v2` aliases, direction aggregates, per-player daily statistics, army hashes, or parser versions.
