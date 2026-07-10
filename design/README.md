# ClashKing Design System

Shared design language for ClashKing mobile, admin, dashboard, and future product surfaces.

This repo is the source of truth for:

- visual principles
- design tokens
- CSS primitives for web/admin surfaces
- Flutter token constants for the mobile app

## Packages

```txt
packages/css      CSS tokens and primitive component classes
packages/flutter  Dart token constants for Flutter adoption
```

## Install CSS package locally

From a sibling repository such as `ClashKingDashboard`:

```json
{
  "dependencies": {
    "@clashking/design-system-css": "file:../ClashKingDevKit/design/packages/css"
  }
}
```

Then import:

```ts
import '@clashking/design-system-css';
```

## Use the Flutter package locally

```yaml
dependencies:
  clashking_design_system:
    path: ../ClashKingDevKit/design/packages/flutter
```

Agent-facing mobile implementation rules live in
[`../ai/design-system/mobile.md`](../docs/mobile.md). Those rules
reference the concrete widgets and themes in the separate `ClashKingApp`
repository; this directory owns only shared tokens and packages.

## Design rules

- No emojis as structural icons.
- Use semantic tokens before hardcoded colors.
- Radius scale: `12px`, `16px`, `28px`.
- Prefer one outer surface per logical section; avoid nested framed cards.
- Dark and light variants must be considered together.
- Touch/click targets should be at least `44px` high.

The CSS and Flutter token sets currently differ on donation green and include
both 20px and 28px surface radii. These values were preserved from the source
repository for review rather than silently normalized during migration.
