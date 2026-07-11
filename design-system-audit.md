# ClashKing Design System Audit

Audit conducted: 2026-07-10  
Scope: `clashking-devkit/design` as the shared design system, using `clashking-app` as the product reference implementation.  
Method: `design-system` skill audit framework — inventory, gaps, fragmentation, drift, remediation, governance.

## Implementation update - 2026-07-10

Completed after the initial audit:

- Fixed radius semantics: `CKRadius.card` is now `28`; the old 20px value is
  preserved as `CKRadius.tile`.
- Added first reusable Flutter primitives:
  - `CKMetricChip`
  - `CKMetricChipGrid`
  - `CKStatTile`
  - `CKGlassPanel`
  - `CKSegmentedControl`
- Added docs:
  - `design/docs/flutter.md`
  - `design/docs/components.md`
  - `design/docs/governance.md`
  - `design/docs/decisions/DSDR-001-radius-semantics.md`
  - `design/CHANGELOG.md`
- Expanded `design/scripts/check.mjs` so CI validates these docs and Flutter
  primitives exist.
- Added missing root `docs/skills-catalog.md` referenced by the DevKit README.
- Synced the app copy of `design-system/clashking/MASTER.md` from DevKit after
  the radius/spacing documentation update.
- Added warning-mode design drift checks:
  - `npm run drift:app`
  - `npm run drift:app:strict`

Initial warning-mode baseline:

| Check | Severity | Findings |
|---|---|---:|
| `raw_hex_color` | High | 72 |
| `raw_material_color` | Medium | 265 |
| `literal_radius` | High | 107 |
| `literal_spacing` | Medium | 626 |
| `emoji_icon` | High | 32 |
| `icon_button_missing_tooltip` | High | 31 |
| **Total** |  | **1133** |
| **High severity total** |  | **242** |

## 1. Inventory of what exists

### Foundations / tokens

| Area | Current source | Notes |
|---|---|---|
| Flutter tokens | `design/packages/flutter/lib/clashking_design_system.dart` | 9 colors, 5 radii, 3 opacity levels, 6 spacing values. |
| CSS tokens | `design/packages/css/tokens.css` | 69 CSS variables: 42 color, 12 font, 7 spacing, 4 radius, 2 shadow, 1 blur, 1 transition. |
| App compatibility layer | `clashking-app/lib/common/theme/app_tokens.dart` | Bridges app names (`AppRadius`, `StatColors`) to shared `CK*` tokens. |
| App theme reference | `clashking-app/lib/core/app/my_app.dart` | Material 3 light/dark themes, ColorScheme seed values, card/button/input themes. |
| Design reference doc | `design/docs/MASTER.md` | Exact copy of `clashking-app/design-system/clashking/MASTER.md`. |

### Primitives / elements

Shared package:

- CSS: `.ck-card`, `.ck-card-flat`, `.ck-button`, `.ck-badge`, `.ck-toggle`, `.ck-icon-tile`, `.ck-table`.
- Flutter: token-only package currently; no reusable Flutter widgets exported.

App reference primitives:

- `HeaderIconButton`
- `MetricChip`
- `MetricChipGrid`
- `GlassPanel`
- `NativeLiquidGlassBar`
- `NativeLiquidGlassTabBar`
- `NativeLiquidGlassSegmentedControl`
- `ImageChip`, `IconChip`, `CustomChip`
- `StatTile`
- `ClanSummaryChip`, `ClanFilterChip`

### Patterns

Documented or visible patterns:

- Hero header with image backdrop, scrim, identity row, and floating glass stats panel.
- Metric chip grids for clan/player/war/legend summaries.
- Glass segmented controls for tab/filter selection.
- Flat card/panel layout with radius and outline-based depth.
- Settings/list tile patterns exist in app code but are not yet formalized in DevKit.

### Templates

No first-class templates in DevKit yet.

Strong candidates from app:

- Detail page hero template.
- Stats tab / summary page template.
- Settings section template.
- Empty/error/loading state template.

### Documentation and tooling

Present:

- `design/README.md`
- `design/docs/MASTER.md`
- `design/scripts/check.mjs`
- `npm run check`

Missing:

- Component usage docs per primitive/pattern.
- Contribution model.
- Changelog/versioning policy.
- Migration guide from old standalone `clashking-design-system`.
- Flutter package usage guide after the repo move.

## 2. Gap analysis

### Critical

1. **The Flutter package is token-only while the app’s real design language is widget-driven.**

   The app’s visual signature is not just tokens; it is `NativeLiquidGlassBar`, hero headers, metric chips, chip grids, and glass segmented controls. DevKit currently exports only `CKColors`, `CKRadius`, `CKOpacity`, and `CKSpacing`.

   Recommendation: promote stable app primitives into `design/packages/flutter`, starting with:

   - `CKMetricChip`
   - `CKMetricChipGrid`
   - `CKGlassPanel`
   - `CKStatTile`
   - `CKSegmentedControl`

2. **The app dependency path was stale after moving the design system.**

   Fixed in this audit:

   ```yaml
   clashking_design_system:
     path: ../clashking-devkit/design/packages/flutter
   ```

### High

3. **Token adoption is partial.**

   App scan excluding generated localization files:

   | Pattern | Count | Files |
   |---|---:|---:|
   | `Color(0x...)` | 102 | 19 |
   | `Colors.*` | 489 | 81 |
   | `BorderRadius.circular(number)` | 306 | 72 |
   | `EdgeInsets.*(...)` | 628 | 118 |
   | `TextStyle(...)` | 108 | 38 |
   | `AppRadius.*` | 41 | 15 |
   | `StatColors.*` | 91 | 16 |
   | `CK*.*` | 175 | 52 |

   This shows good early adoption of `CK*`, `AppRadius`, and `StatColors`, but most UI still uses literals.

4. **Radius drift existed between docs and Flutter tokens.**

   The app reference doc says card/panel radius is `28`.

   `CKRadius` has:

   ```dart
   static const double card = 20;
   static const double panel = 28;
   ```

   But `AppRadius.card` maps to `CKRadius.card`, while the app doc says section-level panels and card themes use 28.

   Status: fixed. `CKRadius.card = 28`, `CKRadius.panel = 28`, and the old
   20px value is now `CKRadius.tile`.

5. **Cross-platform token parity is incomplete.**

   CSS has `--ck-color-primary-red-light`, `--ck-color-secondary-blue-light`, text/background semantic tokens, shadows, font sizes, and transitions.

   Flutter lacks:

   - light/dark semantic color aliases,
   - typography tokens,
   - shadow/elevation tokens,
   - transition/motion tokens,
   - breakpoint/layout guidance for web/admin.

### Medium

6. **CSS primitives encode web/admin assumptions that do not map cleanly to mobile.**

   Example: `.ck-button:hover`, `cursor: pointer`, table wrappers, web focus styling.

   This is fine if CSS targets admin/dashboard surfaces, but docs should label CSS as “web/admin” and Flutter as “mobile app”.

7. **Accessibility rules are documented but not enforceable yet.**

   `MASTER.md` requires tooltips, touch targets, contrast, semantics, and reduced-motion behavior. Some app primitives already respect reduced motion (`NativeLiquidGlassSegmentedControl`), but no automated check exists.

8. **The app has page-specific rules outside DevKit.**

   `clashking-app/design-system/clashking/MASTER.md` now matches `clashking-devkit/design/docs/MASTER.md`, but future changes can drift unless DevKit becomes the source of truth.

## 3. Fragmentation analysis

| Fragmentation | Evidence | Impact |
|---|---|---|
| Standalone design-system repo removed, DevKit now owns it | `clashking-design-system` deleted; DevKit has `design/` | Good consolidation, but consumers need path updates. |
| App docs and DevKit docs currently identical | `Compare-Object` count = 0 | Good current state. Needs ownership rule. |
| App has production widgets; DevKit has mostly tokens | App owns glass/chip/header primitives | Other surfaces cannot reuse the true ClashKing visual system yet. |
| CSS and Flutter diverge in semantics | CSS has 69 vars; Flutter has 23 constants | Web/admin and mobile may drift unless documented as separate platform packages. |

## 4. Drift analysis

Top drift points:

1. `CKRadius.card = 20` conflicted with app card/panel guidance of `28`.
   Fixed by `DSDR-001`.
2. `pubspec.yaml` previously pointed to the deleted standalone repo.
3. App production widgets still define many raw colors/radii/spacing values.
4. DevKit `README.md` said `docs/skills-catalog.md` existed, but the file was
   absent. Fixed by adding the catalog.
5. App reference docs mention `AppRadius` “until it exists”; it now exists and maps to `CKRadius`, so the doc should be updated to say it is active.

## 5. Prioritized remediation plan

### Critical

- [x] Fix radius semantics in `CKRadius` and `AppRadius`.
  - Decide whether `card` means `20` or `28`.
  - Update `design/docs/MASTER.md` and app code comments accordingly.

- [ ] Move the core mobile primitives from app to `design/packages/flutter`.
  - Start with token-only, dependency-light primitives:
    - `MetricChip`
    - `MetricChipGrid`
    - `StatTile`
  - Then evaluate glass wrappers, because they depend on native/platform behavior.

### High

- [x] Add a Flutter usage guide in `design/docs/flutter.md`.
  - Include dependency path:
    `../clashking-devkit/design/packages/flutter`
  - Include migration from `AppRadius`/`StatColors` compatibility layer to `CK*`.

- [ ] Add platform ownership docs:
  - CSS package = web/admin/dashboard.
  - Flutter package = native mobile.
  - Shared docs = brand/foundation vocabulary.

- [x] Add lint-style checks for common drift:
  - raw `Color(0x...)` outside allowed files,
  - `BorderRadius.circular(number)` where `AppRadius`/`CKRadius` should be used,
  - missing `tooltip:` on `IconButton`,
  - new emoji icons in UI files.

### Medium

- [x] Add `design/docs/components.md`.
  - Document button, card/panel, chip, metric chip, stat tile, segmented control.
  - For each: usage, variants, anti-patterns, accessibility.

- [x] Add `design/docs/governance.md`.
  - Owner.
  - Proposal process.
  - Decision log.
  - Release cadence.
  - Deprecation process.

- [x] Add changelog and versioning.
  - Start with `0.1.0`.
  - Treat token rename/removal as breaking.

### Low

- [ ] Add visual examples or screenshots for each pattern.
- [ ] Add package readme files for `packages/css` and `packages/flutter`.
- [ ] Add a quarterly design-system audit checklist.

## 6. Governance recommendations

Recommended model: **single owner now, federated later**.

Current repo shape suggests a small team/startup workflow. A single owner should approve foundation changes for now. As more surfaces consume DevKit, move toward a federated model where app/admin/dashboard contributors can propose components, but DevKit remains the review gate.

Minimum governance to add now:

1. `design/docs/governance.md`
2. `design/docs/decisions/`
3. `design/CHANGELOG.md`
4. “Docs required for new public tokens/components” rule.
5. One monthly drift check against the app.

## 7. Audit summary

ClashKing now has the right consolidation direction: DevKit owns the shared design system and the app already consumes the Flutter token package. The biggest issue is that the real mobile design system lives in app widgets while DevKit only exports tokens, so the system cannot yet prevent drift across future clients. Start by fixing radius semantics, documenting package ownership, and promoting the app’s metric/glass primitives into `design/packages/flutter`.
