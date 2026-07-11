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

- Use one outer panel per logical section.
- Avoid card-in-card nesting.
- Use `tint` sparingly for identity/status emphasis.
- Native clients may layer platform glass behind this shape when needed.

### `CKSegmentedControl`

Use for switching between local modes or filters.

Rules:

- Use 2–5 options.
- Keep labels short.
- Reduced motion is respected through `MediaQuery.disableAnimations`.

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
