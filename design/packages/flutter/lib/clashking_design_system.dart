library clashking_design_system;

import 'package:flutter/material.dart';

class CKColors {
  CKColors._();

  static const Color primaryRed = Color(0xFFD90709);
  static const Color secondaryBlue = Color(0xFF026CC2);
  static const Color legendBlue = Color(0xFF4E7DF2);
  static const Color warGold = Color(0xFFE8A524);
  static const Color capitalPurple = Color(0xFF8D63D9);
  static const Color builderBlue = Color(0xFF2A9FD6);
  static const Color donationGreen = Color(0xFF14A37F);
  static const Color lossRed = Color(0xFFE35D4F);
  static const Color capitalOrange = Color(0xFFE56B2F);
  static const Color capitalTrophy = Color(0xFFD8891F);
  static const Color discordBlurple = Color(0xFF5865F2);
}

class CKRadius {
  CKRadius._();

  static const double control = 12;
  static const double chip = 16;
  static const double tile = 20;
  static const double card = 28;
  static const double panel = 28;
  static const double pill = 999;
}

class CKOpacity {
  CKOpacity._();

  static const double border = 0.28;
  static const double borderStrong = 0.32;
  static const double fillMuted = 0.45;
}

class CKSpacing {
  CKSpacing._();

  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
}

/// Shared motion durations and curves for ClashKing interfaces.
///
/// Resolve durations through [durationOf] inside widgets so the system
/// reduced-motion preference is always respected. Continuous or decorative
/// animations should be removed entirely when [animationsDisabled] is true.
class CKMotion {
  CKMotion._();

  static const Duration fast = Duration(milliseconds: 160);
  static const Duration standard = Duration(milliseconds: 220);
  static const Duration slow = Duration(milliseconds: 360);

  static const Curve standardCurve = Curves.easeOutCubic;

  static bool animationsDisabled(BuildContext context) =>
      MediaQuery.disableAnimationsOf(context);

  static Duration durationOf(BuildContext context, Duration duration) =>
      animationsDisabled(context) ? Duration.zero : duration;
}

/// Compact metric chip: an icon in a small circle, a short label, and a
/// stronger value. This is the reusable package version of the app's
/// `MetricChip` visual language.
class CKMetricChip extends StatelessWidget {
  const CKMetricChip({
    super.key,
    required this.label,
    required this.value,
    this.icon,
    this.iconData,
    this.color,
    this.semanticLabel,
  }) : assert(icon != null || iconData != null);

  final String label;
  final String value;
  final Widget? icon;
  final IconData? iconData;
  final Color? color;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final resolvedColor = color ?? colorScheme.onSurfaceVariant;

    final chip = Container(
      padding: const EdgeInsets.fromLTRB(
        CKSpacing.sm - 2,
        CKSpacing.xs + 1,
        CKSpacing.md - 2,
        CKSpacing.xs + 1,
      ),
      decoration: BoxDecoration(
        color: color != null
            ? color!.withValues(alpha: isDark ? 0.26 : 0.34)
            : colorScheme.surfaceContainerHighest.withValues(
                alpha: CKOpacity.fillMuted,
              ),
        borderRadius: BorderRadius.circular(CKRadius.control),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              color: colorScheme.surface.withValues(alpha: 0.72),
              shape: BoxShape.circle,
            ),
            child: SizedBox.square(
              dimension: 26,
              child: Padding(
                padding: const EdgeInsets.all(CKSpacing.xs),
                child: icon ?? Icon(iconData, size: 14, color: resolvedColor),
              ),
            ),
          ),
          const SizedBox(width: CKSpacing.sm - 2),
          Flexible(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: color ?? colorScheme.onSurface,
                    fontWeight: FontWeight.w900,
                    height: 1.1,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );

    return Semantics(
      label: semanticLabel ?? '$label: $value',
      excludeSemantics: true,
      child: chip,
    );
  }
}

/// Equal-width metric chip grid. Use this for compact stat panels where chips
/// should not wrap into uneven rows.
class CKMetricChipGrid extends StatelessWidget {
  const CKMetricChipGrid({
    super.key,
    required this.chips,
    this.spacing = CKSpacing.sm - 2,
    this.columns = 2,
  }) : assert(columns > 0);

  final List<Widget> chips;
  final double spacing;
  final int columns;

  @override
  Widget build(BuildContext context) {
    if (chips.isEmpty) return const SizedBox.shrink();

    final rows = <Widget>[];
    for (var i = 0; i < chips.length; i += columns) {
      if (i > 0) rows.add(SizedBox(height: spacing));
      final rowChips = chips.skip(i).take(columns).toList();
      final rowChildren = <Widget>[];
      for (var j = 0; j < rowChips.length; j++) {
        if (j > 0) rowChildren.add(SizedBox(width: spacing));
        rowChildren.add(Expanded(child: rowChips[j]));
      }
      rows.add(Row(children: rowChildren));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: rows,
    );
  }
}

/// Dense vertical stat tile for compact war/CWL/player breakdowns.
class CKStatTile extends StatelessWidget {
  const CKStatTile({
    super.key,
    required this.label,
    required this.value,
    required this.icon,
    this.semanticLabel,
  });

  final String label;
  final String value;
  final Widget icon;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Semantics(
      label: semanticLabel ?? '$label: $value',
      excludeSemantics: true,
      child: Container(
        width: 56,
        padding: const EdgeInsets.symmetric(
          vertical: CKSpacing.sm - 2,
          horizontal: CKSpacing.xs,
        ),
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.32),
          borderRadius: BorderRadius.circular(CKRadius.chip),
          border: Border.all(
            color: colorScheme.outlineVariant.withValues(
              alpha: CKOpacity.borderStrong,
            ),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Center(child: icon),
            const SizedBox(height: CKSpacing.xs),
            Text(
              label,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              value,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(fontWeight: FontWeight.bold),
            ),
          ],
        ),
      ),
    );
  }
}

/// Token-driven panel shell. Mobile app surfaces can layer native Liquid Glass
/// behind this shape, while non-native clients can use it directly.
class CKGlassPanel extends StatelessWidget {
  const CKGlassPanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(CKSpacing.lg),
    this.radius = CKRadius.panel,
    this.tint,
    this.onTap,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final Color? tint;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final decoration = BoxDecoration(
      color: tint != null
          ? tint!.withValues(alpha: 0.12)
          : colorScheme.surfaceContainerHighest.withValues(alpha: 0.45),
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(
        color: colorScheme.outlineVariant.withValues(
          alpha: CKOpacity.borderStrong,
        ),
      ),
    );

    final panel = DecoratedBox(
      decoration: decoration,
      child: Padding(padding: padding, child: child),
    );

    if (onTap == null) return panel;

    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(radius),
      child: InkWell(
        borderRadius: BorderRadius.circular(radius),
        onTap: onTap,
        child: panel,
      ),
    );
  }
}

/// Lightweight segmented control for filters and view modes.
class CKSegmentedControl<T> extends StatelessWidget {
  const CKSegmentedControl({
    super.key,
    required this.values,
    required this.labels,
    required this.selected,
    required this.onChanged,
    this.height = 52,
    this.color,
  }) : assert(values.length == labels.length);

  final List<T> values;
  final List<String> labels;
  final T selected;
  final ValueChanged<T> onChanged;
  final double height;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final selectedIndex = values.indexOf(selected);
    if (selectedIndex < 0 || labels.length < 2) {
      return const SizedBox.shrink();
    }

    final colorScheme = Theme.of(context).colorScheme;
    final selectedColor = color ?? colorScheme.primary;
    final indicatorDuration = CKMotion.durationOf(context, CKMotion.standard);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(CKRadius.pill),
        border: Border.all(
          color: colorScheme.outlineVariant.withValues(alpha: CKOpacity.border),
        ),
      ),
      child: SizedBox(
        height: height,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final segmentWidth = constraints.maxWidth / labels.length;
            const inset = 5.0;

            return Stack(
              children: [
                AnimatedPositioned(
                  duration: indicatorDuration,
                  curve: CKMotion.standardCurve,
                  left: selectedIndex * segmentWidth + inset,
                  top: inset,
                  bottom: inset,
                  width: segmentWidth - inset * 2,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: colorScheme.surface.withValues(alpha: 0.72),
                      borderRadius: BorderRadius.circular(CKRadius.pill),
                    ),
                  ),
                ),
                Row(
                  children: [
                    for (var index = 0; index < labels.length; index++)
                      Expanded(
                        child: Semantics(
                          button: true,
                          selected: index == selectedIndex,
                          child: InkWell(
                            borderRadius: BorderRadius.circular(CKRadius.pill),
                            onTap: () => onChanged(values[index]),
                            child: Center(
                              child: AnimatedDefaultTextStyle(
                                duration: CKMotion.durationOf(
                                  context,
                                  CKMotion.fast,
                                ),
                                curve: CKMotion.standardCurve,
                                style:
                                    Theme.of(
                                      context,
                                    ).textTheme.labelLarge?.copyWith(
                                      color: index == selectedIndex
                                          ? selectedColor
                                          : colorScheme.onSurface.withValues(
                                              alpha: 0.76,
                                            ),
                                      fontWeight: index == selectedIndex
                                          ? FontWeight.w800
                                          : FontWeight.w600,
                                      height: 1,
                                    ) ??
                                    TextStyle(
                                      color: index == selectedIndex
                                          ? selectedColor
                                          : colorScheme.onSurface.withValues(
                                              alpha: 0.76,
                                            ),
                                      fontWeight: index == selectedIndex
                                          ? FontWeight.w800
                                          : FontWeight.w600,
                                      height: 1,
                                    ),
                                child: Text(
                                  labels[index],
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
