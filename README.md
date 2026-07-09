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

From a sibling repo such as `ClashKingAdminPanel`:

```json
{
  "dependencies": {
    "@clashking/design-system-css": "file:../ClashKingDesignSystem/packages/css"
  }
}
```

Then import:

```ts
import '@clashking/design-system-css';
```

## Design rules

- No emojis as structural icons.
- Use semantic tokens before hardcoded colors.
- Radius scale: `12px`, `16px`, `28px`.
- Prefer one outer surface per logical section; avoid nested framed cards.
- Dark and light variants must be considered together.
- Touch/click targets should be at least `44px` high.
