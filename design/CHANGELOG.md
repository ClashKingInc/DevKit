# Changelog

## Unreleased

- Increased colored metric-chip fills in dark mode so stat accents retain
  their visual hierarchy instead of appearing washed out.
- Added the reusable Discord brand color as `CKColors.discordBlurple`.
- Added the recurring Legend League accent as `CKColors.legendBlue`.

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
