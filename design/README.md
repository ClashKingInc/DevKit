# ClashKing Design System

Shared design language for ClashKing mobile, admin, dashboard, and future product surfaces.

This repo is the source of truth for:

- visual principles
- design tokens
- CSS primitives for web/admin surfaces
- Flutter token constants and first reusable mobile primitives

## Packages

```txt
packages/css      CSS tokens and primitive component classes
packages/flutter  Dart token constants and mobile primitives for Flutter adoption
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
[`docs/MASTER.md`](docs/MASTER.md). Package usage lives in
[`docs/flutter.md`](docs/flutter.md), component guidance in
[`docs/components.md`](docs/components.md), drift checks in
[`docs/drift-checks.md`](docs/drift-checks.md), and governance in
[`docs/governance.md`](docs/governance.md).

## Design rules

- No emojis as structural icons.
- Use semantic tokens before hardcoded colors.
- Radius scale: `12px`, `16px`, `28px`.
- Prefer one outer surface per logical section; avoid nested framed cards.
- Dark and light variants must be considered together.
- Touch/click targets should be at least `44px` high.

The shared radius scale is `12 / 16 / 20 / 28 / 999`. Use `20` for medium
tiles and `28` for section-level cards/panels.

## Drift checks

From this directory:

```bash
npm run drift:app
```

This reports app design-system drift without failing. Use
`npm run drift:app:strict` only after the current backlog is cleaned up.
