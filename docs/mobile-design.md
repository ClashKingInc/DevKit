# ClashKing mobile implementation guidance

Use this guidance when changing the separate `ClashKingApp` Flutter repository.
If a page-specific guide is added under `ai/design-system/pages/`, it overrides
this file for that page.

---

**Project:** ClashKing
**Platform:** Flutter (iOS + Android), native mobile app — not web
**Category:** Gaming / stats companion (Clash of Clans)

---

## Source of truth

Colors, typography, spacing, radius, motion, component specs, anti-patterns,
and the pre-delivery checklist are owned by DevKit, not this file:

- [`design/docs/MASTER.md`](../design/docs/MASTER.md) — foundations, style
  guidelines, anti-patterns, pre-delivery checklist.
- [`design/docs/components.md`](../design/docs/components.md) — per-component
  usage rules.
- [`design/docs/flutter.md`](../design/docs/flutter.md) — package install and
  migration order (`CKColors`, `CKRadius`, `CKSpacing`, `CKMotion`,
  `CKTypography`, `CKControlDensity`, plus the shared widget set).

Apply those documents directly when touching `ClashKingApp` screens. This file
used to carry its own copy of the same rules; that copy fell out of sync with
DevKit's tokens (it still described the radius scale as "emerging" after
`CKRadius` had already shipped), so the rules now live in one place only.

## What stays here

- The override note above for page-specific guides under
  `ai/design-system/pages/` in the `ClashKingApp` repository.
- Anything specific to editing the `ClashKingApp` repository itself (build
  steps, repo layout, local conventions) rather than to the shared design
  system. Add it below as it comes up.
