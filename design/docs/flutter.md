# Flutter package

The Flutter package is the mobile design-system surface for ClashKing.

## Install locally

From `clashking-app` and sibling Flutter clients:

```yaml
dependencies:
  clashking_design_system:
    path: ../clashking-devkit/design/packages/flutter
```

Then import:

```dart
import 'package:clashking_design_system/clashking_design_system.dart';
```

## Foundations

Use these constants before adding new raw values:

| Class | Owns |
|---|---|
| `CKColors` | Brand and recurring stat colors. |
| `CKRadius` | Control, chip, tile, card/panel, and pill radii. |
| `CKOpacity` | Reusable alpha values for borders and muted fills. |
| `CKSpacing` | Common spacing scale. |
| `CKMotion` | Shared durations/curve and reduced-motion resolution. |

Radius semantics:

| Token | Value | Use |
|---|---:|---|
| `CKRadius.control` | `12` | Buttons, inputs, compact metric chip body. |
| `CKRadius.chip` | `16` | Dense chips and small glass elements. |
| `CKRadius.tile` | `20` | Medium tiles that are visually smaller than section panels. |
| `CKRadius.card` | `28` | Section-level cards/panels. |
| `CKRadius.panel` | `28` | Hero header stat panels and large glass panels. |
| `CKRadius.pill` | `999` | Fully rounded pills. |

Motion semantics:

| Token | Value | Use |
|---|---:|---|
| `CKMotion.fast` | `160ms` | Small state changes such as text emphasis. |
| `CKMotion.standard` | `220ms` | Most control and layout transitions. |
| `CKMotion.slow` | `360ms` | Larger, infrequent entrances or transitions. |

Pass durations through `CKMotion.durationOf(context, duration)`. It resolves
to `Duration.zero` when the platform requests reduced motion. Check
`CKMotion.animationsDisabled(context)` to remove continuous or decorative
animation entirely; shortening an infinite animation to zero is not enough.

## Components

The package now includes the first reusable mobile primitives:

- `CKMetricChip`
- `CKMetricChipGrid`
- `CKStatTile`
- `CKGlassPanel`
- `CKSegmentedControl`

Use these for new work before creating app-local variants.

## Compatibility in the app

`clashking-app/lib/common/theme/app_tokens.dart` keeps older app imports
working through `AppRadius`, `AppOpacity`, and `StatColors`. New shared code
should import and use `CK*` directly.

## Migration order

1. Replace literal radii with `CKRadius` or the app compatibility layer.
2. Replace recurring stat colors with `CKColors`/`StatColors`.
3. Replace app-local metric/stat primitives with package primitives when the
   app-local implementation does not need image loading or native glass.
4. Keep native Liquid Glass wrappers in the app until the package deliberately
   accepts those dependencies.
