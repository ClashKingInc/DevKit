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
- Keep selected labels neutral. Selection comes from the filled indicator and
  weight; brand red is not a generic selected-text color.
- Use compact symbols when options represent status, and use real game assets
  when options represent Home Village or Builder Base. The selected segment is
  a quiet fill, not a second outlined pill inside the control.

### Upgrade tracker primitives

Uniformity contract:

- Tracker search fields use the app's shared `AppSearchField`; do not style a
  raw `TextField` independently in sheets or tabs.
- Standard collapsible content uses the shared `CollapsibleItemSection`.
  Sliver-backed grids use the app's shared sliver section shell with the same
  DevKit panel tokens, so lazy rendering does not create a second visual style.
- Upgrade and Player Info artwork tiles share the strong square treatment.
  Collection keeps its artwork-specific tile treatment inside the same section
  shell.
- Filters use `CKSegmentedControl`; village filters include current Hall assets.
- Do not add one-off search, selector, progress badge, or section-card colors.

- `CKUpgradeRow` keeps game artwork primary and uses one narrow semantic queue
  accent rather than a field of metric chips.
- `CKResourceCost` presents an icon and amount inline without another framed
  surface.
- `CKCollectionTile` is artwork-first and uses opacity plus text/semantics for
  missing state instead of color alone.
- `CKProgressBadge` is a compact supporting treatment, not a replacement for
  the hero progress visualization.
- Upgrade category grids should match Player Info: one quiet rounded section
  panel per category, strong square artwork tiles, and no glass on ordinary
  list content. Preserve lazy sliver construction for long grids.
- Align resource icon, amount, and label on one text baseline. At 100 percent,
  section progress uses `CKUpgradeColors.completion`; incomplete progress keeps
  the normal tracker accent.

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
