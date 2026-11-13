---
name: design-clashking-dashboard
description: Design, redesign, or review ClashKing Dashboard and Expo app interfaces using ClashKing's calm visual language and authentic game imagery. Use for information hierarchy, shared controls, player and clan headers, operational data, responsive polish, or bringing a page into the current ClashKing design system.
---

# Design ClashKing Dashboard and Expo

Build calm ClashKing interfaces with rounded geometry, soft elevation, breathable layouts, and authentic Clash assets. Preserve functionality while removing visual scaffolding users do not need. Keep Dashboard controls operational and dense; use the Expo app's established player and clan patterns for mobile information pages. Do not transplant web-only components into native screens.

## Establish the source of truth

Before editing:

1. Inspect the current checkout, dirty files, page behavior, API types, localization, tests, and shared components. Preserve unrelated work and never use a worktree.
2. Read the current Expo tokens at `ClashKingApp/expo/src/ui/tokens.ts` and theme at `expo/src/ui/theme.ts` in that repo. For Expo work, read [Expo references and page patterns](references/expo-patterns.md), then inspect the relevant shared components and finished player/clan pages it identifies. For iPad, iPhone Duo, or device-wide layout work, also read [Adaptive native layouts and review](references/adaptive-native-layouts.md). These TypeScript sources replace the retired Flutter design-system and Dart token references. Verify paths against the current checkout rather than reviving old files.
3. Use [shadcn/ui Luma](https://ui.shadcn.com/docs/changelog/2026-03-luma) as the web baseline where ClashKing guidance is silent: rounded geometry, soft elevation, breathable spacing, softer surfaces, and calm rhythm.
4. Treat `ClashKingAssets` as authoritative for Clash of Clans artwork. Inspect real filenames before constructing a URL.
5. Search the target application's shared UI primitives before creating a component. Reuse or extend existing buttons, tabs, popovers, selects, comboboxes, and asset helpers. The Dashboard-specific recipes below remain web references; Expo equivalents and product-specific data presentation are routed through the Expo reference.

When sources disagree, preserve the shipped product behavior and follow the current ClashKing brand system. Use Luma for geometry and rhythm, not as permission to erase product identity.

## Give the product character without adding clutter

ClashKing interfaces should feel alive and have character. Calm must not become sterile. Build character through coherent backgrounds, authentic imagery, useful icons, tactile controls, and well-judged motion. Do not substitute slogans, welcome paragraphs, feature summaries, decorative status pills, or extra panels for visual craft.

Actively consider generated imagery and bespoke animation when they can materially improve the result. Use image generation for an original bitmap, atmosphere, texture, or illustration when appropriate; use code-native drawing and animation when responsiveness, theme adaptation, interaction, or small asset size make that the better choice. For Clash of Clans subjects, preserve authoritative assets and recognizable models rather than replacing them with invented game art. 

Tie interaction motion to the user's action. Prefer interruptible, restrained press/sheet/selection feedback; reserve ambient motion for places where it will not compete with reading or work. Respect reduced motion and pause unnecessary animation when the app or surface is inactive. Personality must preserve contrast, touch targets, responsiveness, and reliable state feedback.

## Compare approaches before committing

For substantive UI/UX work, use this decision process:

1. Define the problem and the result the user needs.
2. Consider established practices and current best practices for that problem and platform.
3. Develop five meaningfully different solutions rather than five cosmetic variations.
4. Select the best solution or combine the strongest parts.
5. Simplify the result; remove unnecessary copy, controls, steps, and containers.
6. Check consistency with the good parts of the existing design. Do not preserve known bad design merely for consistency.
7. Check the real user experience: intent, navigation, accessibility, errors, offline behavior, and performance.
8. Check the user's expectations of the agent: do the work thoroughly, use judgment, and deliver a professional result.
9. Use the tools that help the goal, including authoritative research, visual references, icons, image generation, custom animation, and concise user input when it is genuinely useful.
10. Add the final life, soul, and polish through animation, color, imagery, responsive interactions, and a coherent design language. Keep the simplified structure intact.

Keep this deliberation in implementation notes or the review, not in product copy. Routine tiny edits do not need an artificial ten-step ceremony.

## Shape the page

Decide what the user is primarily here to read or do before choosing containers. A newly requested fact is not automatically a new feature card. Give supporting information less visual weight, and first look for relevant space beside an existing heading or control. A familiar, unambiguous icon can convey the unit without repeating it in a visible label; keep the complete meaning accessible. Judge the result by its relationship to the page's main content, not by whether the new element looks polished in isolation.

Choose the alignment anchor explicitly for adjacent content. A trailing value beside a title should align with that title's text row, not accidentally with the subtitle or the bottom of a taller wrapper. Keep logically paired elements in the same layout row when possible. Check their rendered centers or baselines, including icons and multiline labels; a container-level alignment rule alone does not prove the text is aligned.

### Illustrated page headers

Illustrated Expo page headers should use the shared `expo/src/ui/hero-header-scrim.tsx` treatment by default: the same subdued artwork tint and fully opaque lower fade used by Ranked and Legends. Apply the scrim inside the artwork's bounds, below the controls and content. Edge-pin its outer wrapper with top/right/bottom/left zero; percentage height on a padded header can leave an exposed strip of artwork. Percentage image dimensions are safe inside that unpadded wrapper. Do not add page-local dark overlays or approximate gradients; update the shared primitive when the treatment changes. Leave room after the final title/metadata so the image ends softly rather than cutting at the text. Check existing consumers when changing the primitive, including To-do, Upgrade Tracker, player/clan, war, assets and generic profile headers. Contained illustration cards and explicitly art-directed surfaces can be exceptions, but name and preserve the reason instead of silently diverging. Header consistency is a default, not permission to alter unrelated layouts.

Layout principles apply to both targets. The CSS/Tailwind examples below are Dashboard recipes. In Expo, use unitless React Native dimensions and the existing `ckRadius`, `ckSpacing`, `useCKTheme`, `colorWithAlpha`, and surface primitives instead of CSS utilities or web shadows. Follow current native component behavior rather than copying web implementation details.

- Prefer open section headings followed by content. Do not put every section heading and body inside a bordered card.
- Use one surface per conceptual object. Never put a bordered card inside another bordered card.
- For settings forms, use an open section heading followed by a responsive grid of labels and controls. Do not wrap each field in a card or put those field cards inside a section card; inputs and dropdowns already provide the necessary control boundaries. If a section needs a filled surface, keep its field groups transparent and borderless so it has only one grouping layer.
- Replace divider grids with spacing, quiet fills, and independent rounded rows or tiles.
- Reserve borders for inputs, focus states, destructive boundaries, or dense data that genuinely needs separation. Do not use lines as the default grouping tool.
- Use `20–28px` radii for major surfaces, `12–16px` for controls, and pills for counts or status.
- Use semantic theme colors (`bg-card`, `bg-muted`, `text-muted-foreground`, `primary`) instead of duplicating hardcoded palette values.
- Use subtle `shadow-sm` elevation on filled surfaces. Avoid stacking border, shadow, tinted background, and nested containers on the same element.
- Keep Dashboard pages dense and operational. Remove decorative hero icons, low-value summary cards, and repeated explanatory panels unless they change a decision.
- Put secondary explanations in an existing `InfoPopover`, tooltip, or concise inline hint near the control they explain.
- Make empty states quiet but intentional: a rounded soft surface, one clear sentence, and the relevant action.

## Keep typography natural

- Never force UI copy to uppercase. Do not use Tailwind's `uppercase` utility or CSS `text-transform: uppercase` anywhere in Dashboard UI.
- Never alter letter spacing. Do not use Tailwind `tracking-*` utilities or CSS `letter-spacing` anywhere in Dashboard UI.
- Preserve intentional casing already present in the content, such as `CWL`, player tags, and creator codes, without transforming the surrounding copy.
- Build hierarchy with font size, weight, color, and spacing instead of uppercase labels or expanded and condensed tracking.

## Make interaction states legible

- Do not communicate selection with a barely different dark fill alone.
- Use `components/ui/dashboard-tabs.tsx` as the shared Dashboard tab authority; Role Management in `app/dashboard/roles/page.tsx` is an integration example. For Expo, inspect its profile tabs and destination picker instead.
- Reuse the same shared tab component or styling recipe across Dashboard pages. Search first, extend the existing pattern when needed, and extract repeated page-local implementations instead of creating visually similar variants.
- Give the selected tab a soft filled surface with slightly stronger elevation, a subtle `2px` primary marker, stronger text, and fully opaque brighter artwork. Keep inactive artwork subdued.
- Treat tab counts as optional information, not part of the required visual pattern. Show a primary-tinted count pill only when the number helps users compare or choose between tabs; omit counts when they add noise, as on Links Management. When counts are present, keep inactive counts subdued.
- Preserve the full pattern when reusing it; do not copy only its layout and fall back to a darker black-on-gray fill.
- Use authentic Clash artwork in tabs whenever the tab represents a game concept with a real asset.
- Keep the selected state obvious in both light and dark themes without outlining every tab.
- Keep focus-visible rings intact. Selection styling must not replace keyboard focus styling.
- Use crisp transitions only for color, opacity, transform, or shadow. Keep frequent interactions under 200ms and respect reduced motion.

## Give feedback where the action happened

Dashboard mutations use contextual feedback instead of floating toasts. Keep progress, success and errors beside the control or record that changed. Use a saved checkmark, a brief semantic highlight, or a quiet inline status when appropriate; keep failures visible with a useful retry action. Preserve the record's height and scroll position while saving so feedback does not move the user's target. Announce status changes accessibly without moving focus. Reserve blocking dialogs for decisions that need user input, never routine save confirmation.

## Use calm operational controls

Treat the Links Management controls in `app/dashboard/links/page.tsx` as the approved pattern for search, compact filters, secondary actions, and data chips. Reuse a shared primitive or extract the recipe when it appears on another page.

Referenced Dashboard pages are examples only for the named control or row recipe. Their remaining legacy typography, such as `tracking-tight`, does not override this skill's natural-casing and natural-spacing rules.

- Use a `12–16px` rounded, quiet `bg-muted/55` filled surface with subtle `shadow-sm shadow-black/5` for search fields and closed select triggers. Do not show a default border; preserve a clear `focus-within` or `focus` ring for keyboard interaction.
- Use borderless `bg-muted/65` secondary buttons with a subtle shadow and `hover:bg-muted` for utilities such as export, pagination, and row-level Add actions. Keep primary calls to action visually primary and destructive actions visibly destructive.
- Render selected filters and compact data chips as fully rounded pills with a quiet fill, no border, compact padding, and restrained type. Preserve meaningful source colors, such as Discord role colors, without adding a second outline.
- Render status chips with the same borderless pill geometry. Use a restrained semantic tint only when the distinction changes interpretation; keep neutral states on the quiet muted fill.
- Keep dropdown content elevated and readable, but let the closed trigger match the filled control family so it does not look like a legacy outlined input.
- Do not remove borders globally from shared primitives merely to match this pattern. Add or reuse an explicit variant so forms and dense inputs that genuinely need boundaries retain them.

## Present operational data as rounded rows

Treat the Discord tenure-role rows in `app/dashboard/general/page.tsx` and the member/link rows in `app/dashboard/links/page.tsx` as the approved Dashboard data-list pattern. Reuse this pattern whenever a conventional table is not essential for comparing values across columns.

- Render each record as an independent `20–24px` rounded `bg-card` surface with restrained padding, `shadow-sm shadow-black/5`, and spacing between rows. Do not wrap the list in a bordered table shell or separate records with horizontal rules.
- Keep the primary identity at the leading edge, secondary metadata in muted text or borderless pills, and row actions compact at the trailing edge. Use meaningful artwork or a source-colored dot when it improves recognition.
- Omit column headers when the row structure and content make each value self-explanatory. When labels are necessary, keep them naturally cased and quiet; never use an uppercase legend/header band.
- Put expandable detail inside the same record using a lighter `bg-muted/45` inset with rounded corners, as Links Management does. Do not create a second bordered card inside the row.
- Match loading placeholders and empty states to the final row geometry so the layout does not jump between visual systems.
- Use a semantic `<table>` only when users genuinely need to scan and compare the same field across many rows. Even then, carry over this visual language: natural-case headings, soft surfaces, rounded outer geometry, restrained separators, and no dense divider grid.

## Use authentic Clash assets

Prefer real Clash of Clans artwork whenever the concept exists in `clashking_assets`. Use generic UI icons only for generic actions such as add, delete, help, sorting, search, and navigation.

Do not limit artwork searches to the asset repository's `icons/` directory. Any published asset is suitable when it is the clearest semantic and visual match, including files under `resources/`, `buildings/`, `leagues/`, `landscape/`, or another established asset family. Folder placement describes the source pipeline; it does not determine whether an asset is appropriate for Dashboard UI.

Common CDN mappings, after verifying the asset repo:

```text
Town Hall:       https://assets.clashk.ing/buildings/home-village/town_hall/level_{level}.webp
Builder Hall:    https://assets.clashk.ing/buildings/builder-base/builder_hall/level_{level}.webp
Player league:   https://assets.clashk.ing/leagues/league-tier/{league_slug}.png
Builder league:  https://assets.clashk.ing/leagues/builder-base/{league_slug}.png
```

- Reuse `lib/theme.ts` helpers such as `townHallImageUrl` and `playerLeagueImageUrl` when available.
- Search the full asset manifest or repository tree before choosing artwork, and compare plausible candidates across folders instead of accepting the first icon-shaped file.
- Add a small tested helper when a stable asset family lacks one; do not scatter string construction across JSX.
- On the Dashboard, use its established `next/image` pattern; in Expo, use `MobileWebImage` and `ImageAssets` so platform delivery, fallbacks, and configured asset origins remain consistent.
- Use the same artwork in tabs, select options and selected values, and criteria/data cells when it improves recognition.
- Give decorative images `alt=""`; give informative standalone artwork a localized or accurate accessible label.
- Do not copy assets into the Dashboard or invent URLs when the published CDN path already exists.

## Keep data presentation correct

Inspect the actual wire value before formatting it. Role criteria may arrive as `10`, `"10"`, `"th10"`, or `"bh10"`; `Number("th10")` produces `NaN` and silently hides the value.

- Normalize numeric criteria with a tested digit parser.
- Derive the displayed label and its artwork from the same normalized value.
- Preserve canonical API values even when labels are localized.
- Render an explicit em dash for genuinely missing criteria instead of an unexplained blank cell.
- Keep sorting based on normalized values, not formatted labels where numeric order matters.

## Implementation workflow

1. Audit the page hierarchy and mark every border, nested surface, decorative icon, repeated explanation, and low-value metric.
2. Identify the smallest useful surfaces and controls. Flatten everything else into page spacing.
3. Search for the approved shared component or design recipe for each control, especially tabs, the Links Management filled-control family, and the General Settings/Links rounded-row data pattern, before creating page-local styling.
4. Search `clashking_assets`, then map game concepts to real artwork before accepting Lucide or another generic icon.
5. Preserve routes, API calls, mutation behavior, localization keys, responsive behavior, accessibility, and unrelated dirty work.
6. Follow the repository verification policy. In ClashKing repositories, use the real local application, type checking, linting and builds; do not add isolated or mocked helper/component tests. Visual verification requires the user's authorization.
7. Validate touched files with focused tests, ESLint, and the repository typecheck. For Expo, run `npm run l10n:check` when copy changes; use `npm run web:export` for changes affecting bundling or the web integration. For Dashboard, use its current build and localization-validation scripts. Read the target package scripts rather than assuming a generic production/native build command.
8. Do not run browser automation, screenshots, simulators, or visual testing unless the user explicitly asks for them.

## Review checklist

- Does any area show a border inside a border or multiple equal-weight surfaces?
- Are settings labels and controls placed directly in the section, without a section box around field boxes around inputs?
- Could spacing or a soft fill replace a divider?
- Is every label rendered in its natural casing without `uppercase` or `text-transform: uppercase`?
- Is all letter spacing natural, with no `tracking-*` utilities or CSS `letter-spacing`?
- Is every prominent icon either useful game artwork or a genuine UI action?
- Does tab UI reuse the approved shared component or complete design recipe instead of reproducing a page-specific variant?
- Does the selected tab use the subtle primary marker, brighter artwork, and slightly stronger elevation without becoming loud, with a count pill only when the number is useful?
- Do search, select, chip, and secondary-button controls use the quiet filled family instead of unnecessary default outlines?
- Do operational tables use the General Settings/Links rounded-row pattern unless genuine cross-column comparison requires a semantic table?
- Are data rows free of heavy outer shells, divider grids, and uppercase header bands?
- Do dropdown choices and data cells use the same real asset vocabulary?
- Are wire values normalized before formatting and sorting?
- Does the page remain usable in light, dark, narrow, keyboard, and localized contexts?
- Did focused tests, typecheck, lint, and the target-appropriate localization/build checks pass, with any unperformed checks stated accurately?

## Iterate around information hierarchy

Before choosing a layout, identify the user's primary decision or fact. Make that headline easy to scan. Keep useful secondary information quiet and near its owner; omit information the context already makes obvious. A new field does not automatically deserve a card, heading, label, or paragraph. For example, hit rate can be the headline while a secondary gem reward belongs in a corner.

For meaningful new interfaces or redesigns, compare a few genuinely different options internally. Judge the tradeoffs against the current product, the user's established feedback, clarity, touch behavior, accessibility and performance. Implement the strongest choice, then evaluate the result and make another focused pass where it solves a concrete weakness. Stop when alternatives no longer offer a meaningful improvement; do not churn merely to count iterations. Keep the discarded alternatives as brief working notes only when useful, not as unsolicited reports.

Check integrated controls in their surrounding row or page, not in isolation. A theme selector should read as part of the Settings row, not as a floating pill pasted over another component. Reuse the established visual language while retaining an unmistakable selected state. Ask a focused question when an important product choice remains uncertain; otherwise make the best-supported decision and continue.

Check the actual dimensions of neighboring rows before integrating a control. Keep the standard row height unless its content requires more; a compact theme choice must not make one settings row taller. Treat dataset diagnostics (missing/partial samples, coverage counts) as implementation information unless the user explicitly needs them. Do not retain them just because they can be hidden in a disclosure. Prefer simultaneous offense/defense comparisons over a mode selector when both fit clearly. Validate visual claims against the running current source when authorized, never against an older installed bundle.

Before redesigning an existing statistics page, inventory every metric, comparison and graph. Preserve its accessible user path or explicitly resolve its removal; a component still present in source but bypassed by the default population is a regression. Test entering each tab directly and changing cohorts from that tab, including empty-current-period recovery. When an integrated settings control is requested, use the row geometry itself rather than a smaller rounded track inside it.
