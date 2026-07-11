# DSDR-001: Radius semantics

**Date:** 2026-07-10  
**Status:** Implemented  
**Author:** Codex

## Context

The app design reference says section cards and hero/header panels use a 28px
radius. The Flutter package had `CKRadius.card = 20` and `CKRadius.panel = 28`,
while the app compatibility layer mapped `AppRadius.card` to `CKRadius.card`.
That made `AppRadius.card` resolve to 20 even though the documented standard was
28.

## Decision

Use `28` for `CKRadius.card` and `CKRadius.panel`.

Preserve the old 20px value as `CKRadius.tile`.

## Consequences

- Existing app code using `AppRadius.card` now resolves to the documented 28px
  section radius.
- New medium-tile work can use `CKRadius.tile` instead of inventing another
  value.
- Docs and tokens now agree on the core radius scale:
  `12 / 16 / 20 / 28 / 999`.

## Revisit when

Revisit if app screens reveal a consistent distinction between 20px cards and
28px panels that needs clearer naming than `tile` and `card`.

