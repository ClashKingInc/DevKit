# Design system governance

## Ownership

DevKit owns the shared ClashKing design system.

Current model: **single owner with lightweight contributions**. Move to a
federated model when multiple product surfaces actively contribute components.

## What belongs here

Add to DevKit when a decision or component is reused across ClashKing surfaces:

- brand/stat colors,
- spacing/radius/opacity tokens,
- Flutter mobile primitives,
- CSS web/admin primitives,
- cross-surface pattern documentation,
- migration guidance.

Keep in product repos when the UI is product-specific or depends on local data,
navigation, image loading, or platform services.

Feature-flavored primitives (for example the upgrade-tracker widgets
`CKUpgradeRow`, `CKResourceCost`, `CKCollectionTile`, `CKProgressBadge`) belong
here instead when they encode a reusable visual vocabulary rather than a
single screen's layout: no dependency on tracker-specific data models,
navigation, or business logic, and a second consumer plausible on another
surface. If a widget only makes sense on one screen, or reaches into
product-specific state, it stays in the product repo even if it looks
reusable.

## Contribution checklist

Every public token or component change should include:

- [ ] code implementation,
- [ ] documentation update,
- [ ] changelog entry,
- [ ] migration note if behavior or naming changes,
- [ ] validation with `npm run check`,
- [ ] Flutter formatting for Dart changes.

## Decision levels

### Lightweight decisions

Examples:

- adding a non-breaking token,
- adding a component parameter,
- documenting a new usage example.

These can ship with a normal PR/review.

### Foundation decisions

Examples:

- renaming/removing tokens,
- changing radius or color semantics,
- adding package dependencies,
- deprecating a component.

Record these in `design/docs/decisions/` before implementation.

## Deprecation

Deprecated APIs should stay for at least one minor release when possible.

Each deprecation must include:

- replacement API,
- migration steps,
- planned removal version or condition.

## Review cadence

Monthly:

- scan product repos for drift,
- run `npm run drift:app` from `design/`,
- review raw colors/radii/spacing usage,
- check docs still match production app patterns.

Quarterly:

- run a full design-system audit,
- review token sprawl,
- update roadmap and component priorities.
