# Component guidance

This document describes the shared component vocabulary. The Flutter package is
the source for mobile primitives. The CSS package is the source for web/admin
primitives.

## Mobile primitives

### `CKMetricChip`

Use for compact label/value stats such as war stars, attacks, trophies, or
capital metrics.

Rules:

- Keep labels short.
- Provide either `icon` or `iconData`.
- Use `color` only when the value represents a meaningful status or stat type.
- Let `semanticLabel` override the default screen-reader label when the visual
  label is abbreviated.
- The component exposes one combined semantic label and excludes its visual
  icon/text descendants to avoid duplicate screen-reader announcements.

### `CKMetricChipGrid`

Use when multiple metric chips need equal-width rows.

Rules:

- Default to two columns in hero/header panels.
- Use three or more columns only when labels are very short.
- Avoid wrapping free-form text inside chips.

### `CKStatTile`

Use for dense, many-per-row stat breakdowns.

Rules:

- Prefer numeric values.
- Keep icons simple and recognizable.
- Do not use for long labels or explanatory copy.
- The component exposes one combined semantic label and excludes its visual
  descendants from the semantics tree.

### `CKGlassPanel`

Use as the token-driven panel shell for floating or elevated sections.

Rules:

- Reserve it for floating hero, navigation, or elevated functional material.
- Avoid stacking glass panels or using glass for every ordinary list section.
- Use `tint` sparingly for identity/status emphasis.
- Native clients may layer platform glass behind this shape when needed.

### `CKSectionPanel`

Use for ordinary list, grid, and explanatory sections. It is deliberately
quieter than `CKGlassPanel` so material depth continues to communicate
hierarchy. Use one outer panel per logical section and avoid card-in-card
nesting.

### `CKSegmentedControl`

Use for switching between local modes or filters.

Rules:

- Use 2–5 options.
- Keep labels short.
- Reduced motion is respected through `MediaQuery.disableAnimations`.
- Use standard density by default. Compact density remains at least 44dp high
  and is appropriate when nearby content already provides strong context.

### Upgrade tracker primitives

- `CKUpgradeRow` keeps game artwork primary and uses one narrow semantic queue
  accent rather than a field of metric chips.
- `CKResourceCost` presents an icon and amount inline without another framed
  surface.
- `CKCollectionTile` is artwork-first and uses opacity plus text/semantics for
  missing state instead of color alone.
- `CKProgressBadge` is a compact supporting treatment, not a replacement for
  the hero progress visualization.

Queue accents come from `CKUpgradeColors`: builders, research, and pets.
State accents cover active, scheduled, complete, and unavailable. User-facing
state labels remain owned by the localized client.

## Web/admin primitives

The CSS package exposes:

- `.ck-card`
- `.ck-card-flat`
- `.ck-button`
- `.ck-badge`
- `.ck-toggle`
- `.ck-icon-tile`
- `.ck-table`

CSS primitives may use web-specific affordances such as hover and table
overflow. Do not copy those assumptions into native mobile components.

## Anti-patterns

- Raw hex colors for recurring brand/stat values.
- New radius values outside `12 / 16 / 20 / 28 / 999`.
- Icon-only actions without labels or tooltips.
- Emoji as structural icons.
- Nested framed cards when one section panel would work.
