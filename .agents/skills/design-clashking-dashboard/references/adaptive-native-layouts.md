# Adaptive native ClashKing layouts

Read with `expo-patterns.md` for iPad and iPhone Duo work. This guide explains the design intent behind the native review decisions. Check the current code and the user's current scope before applying them. A product-specific decision is not a universal tablet rule.

## Design one product across different spaces

The larger display should improve comprehension, not simply enlarge or spread out the phone screen. Preserve ClashKing's familiar identity, controls and information hierarchy while choosing a composition for the space actually available.

- Keep related information together. A date selector belongs with the results it controls; a sort selector belongs with its list. Do not strand a small control in an otherwise empty column.
- Preserve the main guide's primary/supporting hierarchy on larger displays. More space is not a reason to promote a secondary fact into a feature card.
- Use columns when records are independent and remain readable. Choose the count from the minimum useful record width, including long names, values and translated labels. Chronological sequences still need an obvious reading order.
- Let content determine height. Empty card interiors do not make a layout feel spacious; they weaken the connection between labels and values. Increase meaningful type and imagery before adding padding or another column.
- Use larger screens to reveal useful comparisons. A balanced grid or adjacent chart and results can work well. A narrow list beside a large unused area usually means the grouping needs reconsideration.
- Bound charts according to their information density. Give axes and trends enough height and width to read without turning a short series into a shallow strip.
- Keep compact layouts deliberate. Device-specific improvements must not incidentally alter ordinary iPhone or Android behavior. Reuse existing compact branches unless the user explicitly requests a shared change.

## Shared headers, recognizable hierarchy

All illustrated page headers use the shared tint and opaque lower fade in `expo/src/ui/hero-header-scrim.tsx`. That is an intentional consistency rule. Content layout can vary when the page's purpose requires it.

Player and Clan info represent the same kind of object: identity, league context, then supporting facts. Use the same hierarchy and near-identical geometry for both. The current expanded composition follows Player: identity and league cards on the first row, smaller facts in a centered wrapping row below. Keep modest trailing breathing room around the league group; do not push its contents against the edge. Retain the compact phone arrangement.

Other headers should follow the same reasoning rather than blindly copy this composition:

- Give identity and authentic imagery priority. Do not add an unrelated character cutout merely to fill room, or shrink the relevant Town Hall into an incidental icon.
- Use compact facts for supporting numbers. Three short values rarely justify three large filled panels.
- Align the header's content with the page below. Let the final useful row lead naturally into the lower fade, without a large empty spacer.
- Keep action controls secondary and inside the safe area. Background art and its scrim may extend farther than interactive content.

### Edge continuity is a layout contract

Artwork, tint and fade must share the same bounds. The final fade must meet the page or rail continuously, without a bright strip, abrupt color edge or visible resize after rotation. Use the physical rail edge and current native layout; do not assume a fixed right edge or a permanent orientation.

Inspect the complete layout chain before patching a seam: parent padding, fixed or automatic width, negative margins, clipping, artwork bounds and overlay bounds. For example, a fixed `width: '100%'` combined with negative horizontal margins can shift a header instead of expanding it. Increasing the fade cannot correct that geometry error.

Keep reusable edge treatment in the shared primitive. Native-sized overlays, normalized SVGs and small overscan are implementation options, not the design goal. Verify that the chosen approach remains continuous through rotation and on both physical edges.

## Navigation follows the device without losing context

Folding and rotation should preserve the active destination, selection and scroll context. Adapt the controls around the mounted content rather than replacing its navigation tree.

Current ClashKing choices:

| Device state | Intended behavior |
| --- | --- |
| Ordinary iPhone / Android | Existing compact navigation, swipe behavior and page composition. |
| Duo closed | Phone composition at the actual available width, respecting the cover display's system rail. |
| Duo open portrait | Normal full-width, icon-only bottom navigation and horizontal status area. Detail actions remain in the header. |
| Duo open landscape | Use both halves and native icon-only navigation in the rail. Partial opening uses both halves unless an actual occlusion requires avoidance. |
| iPad | Normal bottom navigation, readable tablet type and purposeful layouts in both orientations. Do not copy the Duo rail. |

The Duo rail separates destination navigation from page actions. Keep four primary shortcuts in the lower pill, a separate Back circle directly above it with visible separation, and app-link Share higher up when that page offers it. Do not add a duplicate Profile shortcut.

When controls must align with system navigation, prefer the same native layout owner and its separate-background groups/spacers. Measuring a system bar and recreating its position in a second layout system introduces mount, animation and fold timing dependencies. A reliable measurement after the screen settles does not prove initial or rotated alignment. Use independent overlays only when native grouping cannot express the required design, and then verify their actual frames through those transitions. Keep actions inline when a short window cannot fit the rail controls. Preserve Home's avatar and sidebar-opening gesture.

Primary home pages do not need redundant Home, Players, Clans or War headings beside the avatar. The event strip is one browsable collection, including an announcement first when present; choose the visible count for readable event cards rather than a universal number. The current iPad landscape layout allows four.

## Controls and records: reduce effort, retain meaning

Show the state users need before the controls that refine it. Group related filters and selectors into a compact, readable area. Avoid layers of disclosure for a handful of frequently used choices.

Current page decisions illustrate that intent:

- **Clan War Stats:** summary first, an always-visible horizontally scrollable row of icon-bearing filter pills, then period and sort selectors side by side. Use the short Same Townhall label. There is no player search or separate filter-toggle icon. Preserve filter semantics and let the result grid use the available width.
- **Clan Rankings:** show all ranking records without the Current heading or category filter. Within each record, give the metric and World/Country placements separate readable space; never split a number's final digit onto another line.
- **Player History:** omit the redundant Currently tracked badge. Place the category filter above its records; on compact screens it is right-aligned at about half width, provided the translated label still fits. The main page selector remains full width.
- **Clan membership history:** keep the Events/Clans choice, factual counts and filtering together. Avoid decorative count pills separated from the control that determines their meaning.

These choices do not authorize changing data loading, sorting, pagination or record identity to simplify a layout.

## Achievements: progress first, detail on demand

Player Achievements is a continuous page grouped by Home Village, Builder Base and Clan Capital rather than another set of village tabs. Profile achievement badges are a different surface; their grid must use the actual available container width.

The player card should make the achievement, earned stars and remaining progress easy to scan. Its current design uses gold earned stars and a percentage ring on the right; completed rings are green, with no redundant Completed label. Avoid excess lower padding.

Tap the whole card to flip to tier targets and rewards. Keep the flip visually clean without an icon, retain an accessible translated action hint, hide the inactive face from accessibility, and support reduced motion. Size each face to its content; a tall reverse must not force unused space on the front. Completed tier stars use a solid fill.

Total achievement gems are supporting context, not the page's main object. Use the first section heading's trailing space for a small icon/value detail rather than introducing another card, heading or row. Keep the earned/possible relationship clear and preserve the total's page-wide scope in its accessible description. Calculate earned rewards from achieved tiers and possible rewards from the matching authoritative reward metadata. Count duplicate achievement/tier records once. Missing or conflicting data must not masquerade as a complete total. This is earned achievement value, not a claim about the user's current gem balance or whether rewards were claimed. Keep the calculation consistent across device layouts.

## Review the experience, not only the bounds

Visual inspection needs the user's authorization. Once authorized, distinguish source coverage, successful navigation, loaded data and actual visual review; none proves the others.

Inspect hierarchy, readable values, natural grouping, balanced space, safe edges and meaningful interaction. Include long labels/numbers, disclosure states, scroll endpoints, folding and rotation where relevant. Verify that the active context survives a layout change. An accessibility label alone does not establish that its text is painted visibly.

After changing a shared header or control, recheck representative consumers and compact branches. Keep old captures separate from the current build's evidence. Document known coverage limits instead of claiming every possible state or perfection from a screenshot set.
