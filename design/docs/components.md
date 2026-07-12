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

Use for ordinary list, grid, and explanatory sections. It follows the app's
near-black card surface with a quiet outline, while `CKGlassPanel` remains
reserved for floating controls and elevated chrome. Avoid card-in-card nesting.

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
- Keep selector labels text-only unless a separate, documented control variant
  is introduced. The selected segment is a quiet fill, not a second outlined
  pill inside the control.

### Upgrade tracker primitives

Uniformity contract:

- Detail screens with several peer content domains use the shared profile
  composition established by Player and Clan: scenic identity header, shared
  `InfoProfileTabs`, then tab-owned scroll content. Do not introduce a
  segmented control as competing primary navigation inside an app bar.
- Hero headers own identity and cross-tab summary information. The selected tab
  may change the backdrop, hall artwork, and metrics, while account name, tag,
  freshness, and global actions stay stable. Use `InfoHeroBackdrop`,
  `HeaderIconButton`, and shared header stat panels rather than recreating the
  gradient, action sizing, or glass recipe.
- Scenic sliver headers darken artwork with a clipped gradient overlay, never a
  `ColorFiltered` save-layer. Filter layers can retain oversized compositor
  bounds and dim sibling tab/body slivers until the next scroll repaint.
- Upgrade Tracker uses five integrated profile tabs in this order: Home
  Village, Builder Base, Calendar, Plan, and Collection. Never move tracker content into a
  separate overview page or modal sheet when it belongs in this tab system.
  Completion, remaining levels, finish date, identity, and freshness stay in
  the shared header; ongoing work appears in its village tab; Plan owns its
  Loot Outlook and full plan; Calendar owns the timeline. Gold Pass and
  priority controls are global plan inputs and live in the hero header.
- Home Village and Builder Base expose the shared village completion breakdown
  from an info action in the hero header. Reuse the existing completion-date and
  resource-cost summary; do not duplicate it inside tab content.
  The breakdown uses one near-black dialog surface with flat section rows and
  quiet dividers. Do not nest grey section cards inside a grey modal; resource
  costs remain inline with their real assets.
- Calendar opens directly on its timeline with a 60-day horizon. Its date row
  remains pinned while lanes scroll vertically, and it shares the timeline's
  horizontal coordinate space so dates stay aligned with upgrade bars.
  Its vertical timeline uses the detail page's primary nested-scroll controller
  so pulling down at the top restores the collapsed hero header. Only the
  horizontal calendar axis owns an independent controller.
- Collection categories start collapsed. Entering the tab must not choose or
  open a category on the user's behalf.
- Every searchable profile tab places the shared search field and filter in its
  content surface immediately below the tab bar. The tab owns query/filter
  state; the hero header does not jump when those controls change.
- Tracker search fields use the app's shared `AppSearchField`; do not style a
  raw `TextField` independently in sheets or tabs.
- Editable search fields use the stable dark card surface shared by the main
  Player and Clan search. Never place a platform/native glass view behind a
  `TextField`; focus-time platform composition can detach the glass capsule
  from its editable content. Reserve native glass for non-editable controls.
- Standard collapsible content uses the shared `CollapsibleItemSection`.
  Sliver-backed grids use a dark header card, then reveal their lazy grid
  directly on the page background instead of painting a box around the whole
  expanded section.
- Upgrade and Player Info artwork tiles share the strong square treatment.
  Collection keeps its artwork-specific tile treatment inside the same section
  shell.
- Filters use the text-only `CKSegmentedControl`.
- Do not add one-off search, selector, progress badge, or section-card colors.

- `CKUpgradeRow` keeps game artwork primary and uses one narrow semantic queue
  accent rather than a field of metric chips.
- `CKResourceCost` presents an icon and amount inline without another framed
  surface.
- `CKCollectionTile` is artwork-first. Missing items use grayscale plus reduced
  opacity and text/semantics, applied only to visible lazy-grid children.
- `CKProgressBadge` is a compact supporting treatment, not a replacement for
  the hero progress visualization.
- Upgrade category headers should match the app's main Player, Clan, and War
  cards: near-black surfaces, quiet outlines, and no glass on ordinary list
  content. Expanded artwork grids remain unboxed and lazy.
- The tracker Progress overview is a structural content card, not floating
  chrome. It uses the same near-black `CKSectionPanel` surface as Player and
  Clan cards; do not use `CKGlassPanel` for this hero-sized summary.
- This structural-card rule applies across every tracker tab, including Loot
  Outlook, calendar lanes, plan comparisons, import/empty states, village
  breakdowns, and collapsible headers. Nested metrics may use a subtle
  container tint, but the enclosing card always uses `CKSectionPanel` or the
  exact shared card color and outline tokens.
- Do not place summary cards inside a structural card. Loot Outlook and similar
  grouped summaries use flat regions separated by whitespace or dividers;
  compact resource pills may remain framed because they are atomic values.
- Dense mixed categories use quiet text subheads before their grids. Laboratory
  groups by troop, spell, and siege type; Equipment groups by assigned hero.
  Equipment subheads pair the real hero asset with the hero name. These
  subheads do not introduce another card surface.
- Leveled artwork falls back to the closest available lower-level asset when a
  newer CDN render is unavailable. The tile owns its full hit target, so image
  loading or failure never controls whether details can open.
- Village rows are parent navigation surfaces: keep their height stable and
  communicate expansion through the chevron and revealed hierarchy, without
  adding a second enclosing surface.
- When an expanded header releases its card surface into an unboxed grid, draw
  a quiet animated bottom rule inside the existing fixed header height. The
  rule marks the content breakpoint without changing density or restoring an
  enclosing section box.
- Compact category headers use the 44dp interaction minimum without extra
  vertical card padding. Upgrade and Collection category headers use the same
  shared compact shell, including padding, artwork size, margin, open divider,
  and surface behavior. Phone upgrade grids target five square items per row.
- Tracker tab content uses one horizontal content gutter for search/filter rows,
  village parents, and section headers; do not introduce per-tab 14/18/22px
  variants.
- Lazy section expansion animates only sliver paint extent with the shared
  motion duration and curve. Do not cross-fade stacked grid slivers; their
  overlapping extents make closing feel delayed and disconnected.
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
