# ClashKing Contributor Instructions

## Visual Testing

Do not run visual web or app tests unless the user explicitly asks for them. This includes browser automation, screenshots, simulators, emulators, and manual UI inspection; use code-level tests, linting, type checks, and builds by default.

## Deployment source: origin/main only

Every deployment or release must come from the current, freshly fetched `origin/main` commit. This applies to apps, bots, APIs, workers, websites, native builds, OTA updates, assets, and hotfixes.

- Commit the changes, push them to a PR, satisfy the required checks and reviews, and merge the PR into the remote `main` branch before deploying. Publishing from an unmerged PR is prohibited.
- Fetch `origin/main` immediately before preparing the release. Build from a clean checkout whose `HEAD` exactly matches `refs/remotes/origin/main`. A local branch named `main` is not sufficient.
- Never deploy from a feature branch, a local-only commit, an unmerged commit, a dirty working tree, or locally modified release inputs. Do not cherry-pick a fix into a release artifact before its PR is merged.
- For CI releases or prebuilt artifacts, verify that the recorded source SHA matches the fetched `origin/main` SHA and that the artifact was built from that clean commit. Do not rely on a version label alone.
- If merge conflicts, failing checks, or required reviews block the merge, resolve those blockers first. Do not bypass them by publishing an OTA, manually uploading an artifact, or deploying a local build.
- Report the merged PR and deployed source SHA. Keep local verification, merging, building, and deployment as separate completion claims.

## Review deliverables

For substantial technical reviews, architecture explanations, implementation handoffs, and multi-part plans, provide a polished, self-contained local HTML review alongside a concise chat summary. Use the ClashKing implementation review style: readable light/dark presentation, a clear title and evidence date, jump navigation, numbered sections, concise paragraphs, comparison tables, and small pipeline diagrams where they clarify ownership or data flow. Use expandable detail sections for long schemas and supporting evidence. Include relevant user-supplied screenshots when they add context; do not invent screenshots or run visual verification without permission.

For each new review round or request, create a fresh, scoped HTML review rather than appending to the previous cumulative report. After verifying the new deliverable, remove the explicitly superseded generated review. Do not remove original feedback, screenshots, research inputs, or unrelated reviews. Preserve the established visual style. When the user adds comments, address them in the new review and make its scope clear.

Address each comment, distinguish implemented code from proposals, and distinguish local verification, live read-only observations, and deployed behavior. State remaining work and unverified assumptions explicitly. Explain what is retained, added, changed, and removed; include authorization boundaries, source-to-storage-to-consumer flow, migration/rollback behavior, and the reasons for non-obvious decisions. Never describe an unperformed deployment or production repair as complete.

Make SQL easy to inspect: put every column on its own line, with its type, nullability, default, and key/reference when relevant. Put table-level primary keys, unique constraints, checks, and indexes on separate lines. Do not compress schemas into semicolon-separated paragraphs. Distinguish physical tables from views, generated data, and conceptual labels. Link the authoritative schema/source for exact definitions.

For verification, report the actual application/service path exercised, its environment, and the result. Keep failures and limitations next to the claim they qualify. Finish with the decisions the user must review, actionable next steps, and a clearly marked release order when relevant. An HTML review is a deliverable, not permission to publish, deploy, alter production, or perform visual tests.

# ClashKing Repo Instructions

## Verification policy

For ClashKing repositories, retain and add only end-to-end tests that exercise the actual application or service locally (for example Playwright against the running app). Do not add, maintain, or run unit tests, mocked component tests, or isolated helper tests. Verify changes through the real local implementation, end-to-end checks, type checking, linting, and builds. Do not relabel unit tests as end-to-end tests. Never target production for mutating verification. Browser/device visual verification still requires the user's authorization.

Use focused code comments to preserve non-obvious behavior and reduce accidental regressions. Put the comment next to the logic it protects. Explain the intended behavior, why it matters, and any invariant, edge case, ordering constraint, or tempting simplification that must be preserved. When removing a test that was the only record of such behavior, preserve that knowledge in the relevant code comment. Do not narrate obvious code or add boilerplate comments. Keep comments accurate when behavior changes. Comments document the contract; they do not replace real local verification or retained end-to-end checks.

Logs, reminders, and autoboards use simple best-effort delivery. Do not introduce occurrence ledgers, delivery leases, retry-state tables, or exactly-once infrastructure for them unless the user explicitly asks. Keep necessary authorization and data-integrity checks.

## Scope

These instructions apply only when working in or referencing the repositories listed in this document. Do not treat this file as permission to edit unrelated repositories.

Inspect affected related repositories when needed to understand contracts. Keep authorized cross-repository edits narrow and explain them clearly; this guide does not itself authorize deployments or unrelated changes.

Before making changes, inspect the actual repository state. Prefer current code, README files, env examples, tests, and existing local patterns over assumptions from this document.

## Cross-Repo Rules

- Check the authoritative repo before duplicating contracts, generated data, schemas, OpenAPI shapes, static assets, or client models.
- Before creating a UI component or control, search the app and its shared design system for an existing equivalent. Reuse or extend the established component whenever possible so behavior and styling stay consistent; introduce a new component only when no suitable reusable option exists.
- Do not invent local migration/schema structure in an app repo when the schema belongs in `DevKit/database/timescale/`.
- Keep generated or derived artifacts in sync only when the repo already has a generation/update workflow.
- Preserve dirty user work. Never revert unrelated local changes.
- When changing a public/API-facing response shape, check downstream clients and docs in the related repos.

## Database Schema

Repository: `ClashKingInc/DevKit`

This is the authoritative source for SQL-backed schema work. Use this repo before changing SQL-backed code in other ClashKing repos. Timescale schema files live under:

`DevKit/database/timescale/`

Do not invent local migration structure in another repo without checking this repo first. You are allowed to update schemas here when asked or when a cross-repo change requires it.

## ClashKing API

Repository: `clashking_api`

ClashKing's backend API for Clash of Clans stats and ClashKing application data. It contains a FastAPI/Python surface and a Go API module. The dashboard depends on this API, and API response/contract changes may require dashboard updates. It uses Clash-related client code such as `clashy-py` and may overlap with `clashy.go` concepts on the Go side.

When changing API routes, models, auth, static-data endpoints, or response shapes, check affected consumers:

- `ClashKingDashboard` for frontend/API-client impact.

## ClashKing Assets

Repository: `ClashKingAssets`

Asset extraction, static-data generation, image/export tooling, and related Clash of Clans asset workflows. This repo is a source for static metadata and generated assets consumed by other ClashKing projects.

Keep asset pipeline changes narrow. Do not touch `update_static.py`, `/assets`, or release/export behavior unless the task calls for it.

## ClashKing Proxy

Repository: `ClashKingProxy`

Lightweight Go proxy for the Clash of Clans API. It rotates official API keys, exposes Clash API-compatible `/v1/` requests, and has built-in request stats. Other local services may use it as `PROXY_URL` or a Clash API stand-in.

If proxy behavior, paths, headers, errors, caching, rate limits, or response passthrough changes, check consumers such as `clashking_api`, `clashy.go`, and any local tracking/API code that points at the proxy.

## ClashKing Dashboard

Repository: `ClashKingDashboard`

React/TypeScript dashboard for configuring ClashKing bot/server settings. Check its current Vite and edge Worker configuration and ClashKing API v2 contracts. Use the repository's documented local development commands.

When changing dashboard API clients, route handlers, or typed response usage, check `clashking_api` for the real backend contract. Keep UI surfaces dense and operational rather than marketing-like. Prefer existing component, shadcn/ui, Tailwind, and localization patterns.

## clashy.go

Repository: `clashy.go`

Go client library for Clash of Clans / ClashKing proxy-style API access, plus static data helpers and models. Downstream Go services may depend on this package.

Prefer explicit API shapes and helper methods over hidden decode-time mutation or compatibility aliases. Static data updates should follow the repo's existing generation/update workflow. If model or behavior changes affect compatibility, check `clashking_api`, and any Go consumer that imports `clashy.go`.

## cocpy

Repository: `cocpy`

Python `coc.py`-style Clash of Clans client library with models, events, iterators, examples, and tests. It is a downstream/client-facing representation of Clash API behavior.

When public Clash API-compatible schemas or docs change elsewhere, check whether `cocpy` needs model, enum, parser, test, or documentation updates. Keep changes compatible with existing tests and library style.

## Mock API

Repository: `MockAPI`

Fixture-backed FastAPI mock Clash of Clans API for local development, demos, integration testing, and Scalar/OpenAPI documentation. It exposes interactive docs at `/` and OpenAPI at `/openapi.json`.

If changes are made to Mock API response models, enum values, route behavior, fixtures, or OpenAPI metadata, inspect `cocpy` and `clashy.go` for downstream model, enum, parser, test, or documentation impact. Always recommend whether each downstream repo should change or can stay unchanged, and explain why. For schema-only response-field work, prefer model/OpenAPI changes over route rewrites when that matches the existing structure.

## Clarity rules adapted from ASD-STE100

Apply these to assistant responses, including progress updates and spoken replies. These are plain-language guidance for ClashKing work; they do not require formal STE compliance. Keep contractions, natural prose, and accurate technical terms. The standard's word limits are editing targets here. GR-3 and GR-4 are recommendations, not numbered STE rules.

1. **Give each sentence one main topic.** Review explanations over 25 words and instructions over 20 words. Split sentences that combine separate findings, actions, or caveats. Keep causal reasoning connected with “because,” “so,” and “but,” instead of creating fragments. (4.1, 4.4, 5.1, 6.3)
2. **Name the actor and use a concrete verb.** Say which service reads, stores, sends, or changes which object. If the actor matters but is unknown, state that limit. Prefer “the worker sends the message” to “message delivery is handled.” (3.6, 3.7)
3. **Use one stable name for each concept.** Define overloaded terms before using them. For “trigger,” specify an event choice, a database trigger, or another exact meaning. For “local,” name the repo, process, or environment when the distinction matters. (1.11, 6.1, 6.2)
4. **Unpack noun clusters.** Prefer at most three words in new noun clusters. Explain how the objects relate instead of stacking technical labels. Preserve exact identifiers, API fields, official names, and code. When a shorter name helps, define it once and use it consistently. (2.1, 2.2)
5. **Make references explicit when they could mean two things.** Replace ambiguous “it,” “this,” “they,” and “the rest” with the object. Replace vague spatial metaphors such as “underneath” with the table, layer, or process they describe. (GR-3, GR-4)
6. **Put the paragraph's answer or finding first.** Keep one topic per paragraph, with its relevant limitation beside it. Introduce unfamiliar concepts gradually, and explain their effect on the user's task before adding implementation details. Before asking for a decision about unfamiliar roles or relationships, give a concrete example. (6.1, 6.4, 6.5)
7. **Make user actions executable.** When the user needs steps, use an imperative and one action per sentence unless the actions must happen together. Put prerequisites before the action or automatic behavior that depends on them. State the expected result afterward, and distinguish the user's action from the assistant's next action. (5.2–5.4; 5.1 supplies the length target)
8. **Give completion claims an explicit scope.** Name what changed, what was checked, and where. Distinguish an edited file, a passing build, a running process, and observed behavior. Put any remaining verification beside the result it limits. This applies the topic-first principle to recurring ambiguity in the sampled chats. (6.4)

## Shared design skill

Use [Design ClashKing Dashboard and App](.agents/skills/design-clashking-dashboard/SKILL.md) for Dashboard and Expo interface work. Its references use repository-relative paths. Locate your own checkouts; no personal workspace layout is required.
