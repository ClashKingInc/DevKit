# 0001: Shared Flutter motion foundation

- Status: accepted
- Date: 2026-07-10

## Context

Flutter product surfaces used local animation durations and did not apply the
platform reduced-motion preference consistently. A shared component could
respect the preference while app-owned animations continued moving.

## Decision

Expose `CKMotion.fast`, `CKMotion.standard`, `CKMotion.slow`, and
`CKMotion.standardCurve` from the Flutter package. Widgets must resolve finite
animation durations with `CKMotion.durationOf(context, duration)`. Continuous
or decorative animations must use `CKMotion.animationsDisabled(context)` to
replace motion with a static state when reduced motion is requested.

## Consequences

- Shared and app-owned Flutter widgets can use one duration vocabulary.
- Reduced motion becomes the default behavior when consumers use the helper.
- Existing animations need incremental migration; adding the tokens alone does
  not change app-owned widgets.
- CSS motion tokens remain a separate follow-up so this decision does not imply
  identical timing is appropriate on every platform.
