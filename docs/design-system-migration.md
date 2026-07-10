# Design-system migration

## Status

The developer-kit repository was renamed from
`ClashKingInc/DatabaseSchemas` to `ClashKingInc/ClashKingDevKit`. The complete
tracked contents and both commits from the public
`ClashKingInc/ClahKingDesignSystem` repository were imported without squashing.

Do not delete or archive `ClashKingInc/ClahKingDesignSystem` until this draft
pull request has been reviewed and every downstream path has been updated.

## File mapping

| Source path | Developer-kit path | Notes |
| --- | --- | --- |
| `README.md` | `design/README.md` | Updated local dependency paths for the developer-kit layout. |
| `package.json` | `design/package.json` | Preserved as the CSS workspace root. |
| `packages/css/**` | `design/packages/css/**` | Preserved without token-value changes. |
| `packages/flutter/**` | `design/packages/flutter/**` | Preserved without token-value changes. |
| `docs/MASTER.md` | `ai/design-system/mobile.md` | Clarified that app-relative paths refer to `ClashKingApp`. |
| `.gitignore` | `design/.gitignore` | Kept scoped to design package output. |

The existing database files moved under `database/`:

- `timescale/` to `database/timescale/`
- `migrations/` to `database/migrations/`
- `.env.example` to `database/.env.example`
- `docker-compose.*.yml` to `database/docker-compose.*.yml`
- the database README to `database/README.md`

Database migration tools remain under `database/migrations/` instead of moving
to a root `scripts/` directory. They share a Go module, database-root discovery,
`.env`, and checkpoint storage with the Timescale schema.

## Intentionally excluded

Nothing tracked in `ClashKingInc/ClahKingDesignSystem` was excluded. The source
repository contains no tracked secrets, binaries, build output, workflows, or
lockfiles. Local ignored outputs such as `node_modules/`, `dist/`, `.dart_tool/`,
and `pubspec.lock` were not copied because they were never tracked.

The source repositories had no GitHub Actions workflows. The combined repository
adds `.github/workflows/validate.yml` and `scripts/validate-repository.sh` so the
database and design surfaces are checked together.

## Review checklist before deleting the source repository

- [ ] Confirm the CSS package imports from `design/packages/css` in each web consumer.
- [ ] Confirm the Flutter package resolves from `design/packages/flutter` in `ClashKingApp`.
- [ ] Review the mobile rules in `ai/design-system/mobile.md` against current `ClashKingApp` code.
- [ ] Decide whether CSS and Flutter donation-green tokens should be normalized.
- [ ] Decide whether the 20px card/table radius should join the documented 12/16/28 scale.
- [ ] Update deployment or local tooling that still points at the old database root paths.
- [ ] Confirm no consumer references `ClahKingDesignSystem` or `ClashKingDesignSystem`.
- [ ] Confirm the draft pull request validation passes.
- [ ] Merge the developer-kit migration pull request.
- [ ] Delete or archive `ClashKingInc/ClahKingDesignSystem` only after explicit approval.
