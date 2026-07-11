# Design drift checks

`scripts/drift-check.mjs` scans a Flutter app for common design-system drift.

Default target from `design/`:

```bash
npm run drift:app
```

Equivalent explicit command:

```bash
node scripts/drift-check.mjs --target ../../clashking-app
```

Strict mode fails when high-severity findings exist:

```bash
npm run drift:app:strict
```

Keep strict mode out of CI until the current app migration reduces the backlog.
Use warning mode during active migration.

## Checks

| Check | Severity | What it catches |
|---|---|---|
| `raw_hex_color` | High | `Color(0x...)` outside theme/token files. |
| `raw_material_color` | Medium | `Colors.*` values that may bypass semantic theme roles. |
| `literal_radius` | High | `BorderRadius.circular(...)` literals outside the accepted scale. |
| `literal_spacing` | Medium | `EdgeInsets.*(...)` literals. |
| `emoji_icon` | High | Emoji-like structural icons in Dart UI. |
| `icon_button_missing_tooltip` | High | `IconButton(...)` without a nearby `tooltip:` argument. |

## How to use results

Treat the report as a migration backlog, not as a build failure.

Recommended order:

1. Fix high-severity findings in files already being touched.
2. Move recurring colors into `CKColors` or `StatColors`.
3. Replace non-scale radii with `CKRadius` or `AppRadius`.
4. Add missing `tooltip:` values to icon-only actions.
5. Replace emoji icons with Material or `lucide_icons_flutter`.

