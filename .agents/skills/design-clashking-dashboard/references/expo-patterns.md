# Expo references and player data patterns

Use for ClashKingApp design work. Paths below are relative to your `ClashKingApp` checkout; verify the symbols in the current checkout before copying a recipe. These are source references, not authorization to change unrelated screens.

## Current source map

| Concern | Source to inspect |
| --- | --- |
| Geometry, spacing, typography, semantic statistic colors | `expo/src/ui/tokens.ts` and `expo/src/ui/theme.ts` |
| Shared illustrated-header tint and complete lower fade | `expo/src/ui/hero-header-scrim.tsx`; use below header content, without an extra page-local dark overlay |
| Text roles and shared surfaces | `expo/src/ui/text.tsx`, `expo/src/ui/surfaces.tsx` (`CKText`, `Surface`, `PillSurface`, `PressableSurface`) |
| Page and profile navigation | `expo/src/ui/destination-picker.tsx`, `expo/src/ui/profile-tabs.tsx`, `expo/src/ui/selection-picker.tsx` |
| Player identity, backdrop, compact statistics | `expo/src/features/player/presentation/player-detail-components.tsx` (`PlayerDetailHeader`, private `QuickStat` recipe) |
| Clan header and chips | `expo/src/features/clan/presentation/clan-info-header.tsx` |
| Compact Legend season-history records | `expo/src/features/clan/presentation/clan-history-tabs.tsx` (`ClanLegendHistoryTab`, private `LegendRow` recipe) |
| Artwork and image delivery | `expo/src/core/assets/image-assets.ts`, `expo/src/ui/mobile-web-image.tsx`, `expo/src/ui/image-delivery.ts` |
| Image-export sizing and capture | `expo/src/ui/horizontal-image-share.tsx` and its tests |

Private page helpers are recipes, not public components. Prefer shared primitives; extract a genuinely repeated helper when justified instead of importing a large feature screen just for its styles. Do not treat an unfinished Legends screen as the visual standard simply because it is the page being edited.

## Headers, spacing, and hierarchy

- Follow player/clan header identity, safe-area, action placement, and compact chip patterns. For a simple player identity, center the town hall image with name/tag as a group; use the actual town hall asset rather than an obsolete league badge. Keep league imagery for league metrics.
- Put secondary header statistics in compact icon/value chips, not a row of large dashboard cards. Preserve accessible labels and enough visible context to distinguish rates from averages. Do not repeat the page name, date, or selected section directly below its navigation control.
- Start with the player header's `ImageAssets.homeBaseBackground` when no better verified landscape exists. Use cover cropping and a readable scrim, never stretch an illustration to fill a tall header. Read `MobileWebImage` before choosing fit behavior.
- Use `CKText` roles and theme colors. Do not shrink meaningful statistics or action text to squeeze in another column; allow wrapping, fewer columns, or disclosure. Align an icon beside its associated number to reduce height. Use quiet fills without removing boundaries globally from shared primitives.
- Preserve the Dashboard's natural casing and unmodified letter spacing. Expo should follow the same brand direction through native text roles, not CSS/Tailwind recipes.

## Data-heavy player pages

These are Legends-specific product choices from user feedback, not universal rules for every screen:

- Daily attack/defense summaries also act as the switch between logs. Do not repeat the selected label underneath. Keep one date-navigation row with semantic red/green net change and that day's rank.
- Default battle records to collapsed. Keep opponent identity/trophies/rank on the left and the result, stars, and destruction on the right. Show relative time and a compact minutes/seconds duration. Expansion reveals the army; opponent navigation and army-stat links must remain independently actionable and must not also toggle the row.
- Army details should distinguish troops, spells, and Clan Castle content. Classify siege from authoritative game metadata or tested IDs even when bundled catalog rows lack type metadata. Keep siege in the CC group, deduplicate equivalent encodings, and do not hide an army just because the opponent's name is unknown. Heroes should be legible with associated pet and equipment, rather than a dense undifferentiated icon strip.
- Model season history on the clan history record: season identity/rank, then compact aligned metrics with real game artwork. Avoid repeating verbose metric labels as separate full-width rows.
- A contribution grid is a calendar grid with consistent weekday rows and week columns, not a horizontal date strip. Tap, hover, or scrub should reveal date, net change, and rank without navigating away. Distinguish missing observations from zero, and keep the perfect-attack-day treatment separate from ordinary gains.
- Season favorites are the most popular troop weighted by housing space, spell, and siege. Show all three together rather than tabs for only three values. Do not calculate season favorites from only the selected day.
- Trophy/rank graphs need readable axes, interaction values, and rank direction/formatting that cannot overlap. Do not add a daily trophy-change graph when the daily log already supplies the requested story.
- Player performance comparisons use top 200 and top 1,000 and a comparison for the player's identified army when data supports it. Label the cohort and coverage; compare matching finalized days. Do not present an exact/narrow composition family as a broader troop-overlap family, invent missing cohort rows, or display unavailable comparisons as zero.

## Reliability and exports

- A perpetual skeleton is not automatically a slow endpoint. Check provider lifetime and effect dependencies: a fresh but equivalent context object must not recreate the provider on every loading notification. Test successful completion and bounded request count as well as error/retry behavior.
- Use semantic tests for selection, disclosure, normalized army groups, calendar placement, and data coverage. Follow repository instructions for localization, typecheck, lint, and build. Do not run visual/browser/simulator tests unless explicitly requested.
- Export images are a separate composition, not a stretched screenshot. Use a stable logical canvas with resolution scaling, bounded text, real game imagery, meaningful graphs, popular items, and known location when available. Avoid redundant branding text and stale league assets. Test sizing and overflow-related constraints without claiming a visual review when none was performed.
- Local analytics experiments stay manual and local until the user authorizes scheduled tracking or production changes. A successful local fixture or build is not deployment evidence.
