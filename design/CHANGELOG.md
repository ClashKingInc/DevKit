# Changelog

## Unreleased

- Added a neutral `CKUpgradeRow` variant through `showQueueAccent` for
  recommendations and actions that do not represent a tracker queue.

- Added the ClashKing SemiBold Inter-derived font to the CSS and Flutter
  packages, with `CKFont.family` as the package-qualified Flutter family name.
- Added the shared danger-button variant and disabled toggle state.
- Added operations-theme control surfaces and focus treatment so admin products
  do not need to override DevKit primitives locally.

- Added `.ck-theme-operations`, the shared warm-graphite semantic theme for
  admin and operational dashboards. Consumers keep the common ClashKing
  component, state, spacing, and brand contracts without locally overriding
  the DevKit's default navy surface tokens.

- Added `.ck-select`, a rounded native web/admin select with a shared chevron
  and tokenized hover, focus, disabled, option, and light-theme-compatible
  states.
- Added the missing `--ck-color-border-subtle` and
  `--ck-font-family-mono` web/admin foundation tokens.
- Added `.ck-metric`, `.ck-toolbar`, `.ck-progress`, and `.ck-tabular` for
  data-heavy operational views such as Proxy Health. These primitives keep
  metric hierarchy, filter density, volume tracks, and numeric alignment
  consistent without introducing consumer-owned copies.

- Added `--ck-radius-tile` (20px) to the CSS token package for parity with
  `CKRadius.tile` on Flutter — the previous radius scale was missing this
  step (control 12 / chip 16 / **tile 20** / panel 28 / pill 999).
- Added `.ck-row`, a quiet nested-content surface (radius `tile`, tinted
  fill, no border/shadow) for list rows living inside a `.ck-card` section,
  mirroring the app's `CKUpgradeRow`. Fixes a "card nested inside a card"
  pattern found in `clashking-admin-panel` (announcement/template/campaign
  rows, the flag table wrapper, and delivery-health metric tiles were each
  double-framed inside their section).
- Reduced `--ck-shadow-panel` from `0 24px 80px / 0.34` to
  `0 8px 24px / 0.2`. The shipped app renders every card/panel at
  elevation 0; the previous value was a web-only invention far heavier than
  the rest of the design language.
- Simplified `.ck-app-surface` from three stacked brand-color gradients to
  one faint corner glow, matching the app's flat scaffold background.
- `.ck-table-wrap` no longer draws its own border/radius (table content is
  expected to live inside a `.ck-card` section, which already frames it).
- `.ck-icon-tile` now reads background from `--ck-icon-tile-bg` (falling
  back to the existing gradient) so consumers can tint per-instance instead
  of relying on `:nth-child` position hacks.
- Tokenized `.ck-toggle`/`.ck-toggle-on` thumb colors (`--ck-color-surface-solid`
  / `--ck-color-success-text`) instead of raw hex literals.
- `.ck-button` now resets `text-decoration: none` so an `<a>`-based button
  (e.g. an external link styled as a secondary button) doesn't render an
  underline.
- Documented all of the above in `docs/components.md`, plus explicit
  anti-pattern entries for card-in-card nesting, heavy shadows, decorative
  gradient backgrounds, and locally re-declaring shared `.ck-*` primitives.

- Increased colored metric-chip fills in dark mode so stat accents retain
  their visual hierarchy instead of appearing washed out.
- Added the reusable Discord brand color as `CKColors.discordBlurple`.
- Added the recurring Legend League accent as `CKColors.legendBlue`.
- Added the matching CSS tokens (`--ck-color-discord-blurple`,
  `--ck-color-legend-blue`) so the Flutter and CSS packages stay in parity;
  `check.mjs` now asserts both tokens exist.

- Added `CKMotion` duration/curve tokens and helpers that honor the platform
  reduced-motion preference.
- Updated `CKSegmentedControl` to consume the shared motion foundation.
- Prevented duplicate screen-reader announcements in `CKMetricChip` and
  `CKStatTile` by excluding their visual descendants from semantics.
- Added Flutter widget tests for motion and stat-component semantics.

## 0.2.0 - 2026-07-10

- Changed `CKRadius.card` from `20` to `28` to match the app card/panel
  standard.
- Added `CKRadius.tile = 20` for medium tiles that need the previous 20px
  radius.
- Added first reusable Flutter primitives:
  - `CKMetricChip`
  - `CKMetricChipGrid`
  - `CKStatTile`
  - `CKGlassPanel`
  - `CKSegmentedControl`
- Added Flutter usage, component, and governance documentation.
- Added warning-mode design drift scanner for the Flutter app:
  `npm run drift:app`.

## 0.1.0

- Initial CSS and Flutter token packages.
