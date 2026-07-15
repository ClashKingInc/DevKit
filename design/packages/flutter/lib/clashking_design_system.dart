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

/// Semantic colors for upgrade planning and collection surfaces.
///
/// These names describe meaning rather than a single screen so queue and state
/// colors remain consistent across the tracker, widgets, and future clients.
class CKUpgradeColors {
  CKUpgradeColors._();

  static const Color builders = CKColors.builderBlue;
  static const Color research = CKColors.capitalPurple;
  static const Color pets = Color(0xFFE85D9E);
  static const Color completion = CKColors.warGold;
  static const Color unavailable = Color(0xFF7C8798);
  static const Color scheduled = CKColors.legendBlue;

  static Color forQueue(CKUpgradeQueueTone queue) => switch (queue) {
    CKUpgradeQueueTone.builders => builders,
    CKUpgradeQueueTone.research => research,
    CKUpgradeQueueTone.pets => pets,
  };

  static Color forState(
    CKUpgradeStateTone state, {
    required ColorScheme colorScheme,
  }) => switch (state) {
    CKUpgradeStateTone.active => colorScheme.primary,
    CKUpgradeStateTone.scheduled => scheduled,
    CKUpgradeStateTone.complete => completion,
    CKUpgradeStateTone.unavailable => colorScheme.onSurfaceVariant.withValues(
      alpha: 0.64,
    ),
  };
}

enum CKUpgradeQueueTone { builders, research, pets }

enum CKUpgradeStateTone { active, scheduled, complete, unavailable }

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

/// Named mobile text roles for consistent hierarchy across features.
///
/// Roles are derived from the active [TextTheme] instead of fixing a second
/// font-size scale. Flutter therefore applies the platform text scaler and the
/// app remains compatible with Dynamic Type and Android font-size settings.
enum CKTextRole {
  heroMetric,
  screenTitle,
  sectionTitle,
  rowTitle,
  body,
  metadata,
  compactLabel,
}

class CKTypography {
  CKTypography._();

  static TextStyle of(BuildContext context, CKTextRole role) {
    final theme = Theme.of(context).textTheme;
    return switch (role) {
      CKTextRole.heroMetric =>
        (theme.displaySmall ?? theme.headlineLarge ?? const TextStyle())
            .copyWith(
              fontWeight: FontWeight.w800,
              height: 0.98,
              letterSpacing: -0.5,
            ),
      CKTextRole.screenTitle =>
        (theme.headlineSmall ?? theme.titleLarge ?? const TextStyle()).copyWith(
          fontWeight: FontWeight.w700,
          height: 1.08,
        ),
      CKTextRole.sectionTitle =>
        (theme.titleMedium ?? const TextStyle()).copyWith(
          fontWeight: FontWeight.w700,
          height: 1.18,
        ),
      CKTextRole.rowTitle => (theme.bodyMedium ?? const TextStyle()).copyWith(
        fontWeight: FontWeight.w600,
        height: 1.22,
      ),
      CKTextRole.body => (theme.bodyMedium ?? const TextStyle()).copyWith(
        fontWeight: FontWeight.w500,
        height: 1.42,
      ),
      CKTextRole.metadata => (theme.bodySmall ?? const TextStyle()).copyWith(
        fontWeight: FontWeight.w500,
        height: 1.34,
      ),
      CKTextRole.compactLabel =>
        (theme.labelSmall ?? const TextStyle()).copyWith(
          fontWeight: FontWeight.w600,
          height: 1.2,
          letterSpacing: 0.1,
        ),
    };
  }
}

extension CKTextThemeRoles on TextTheme {
  TextStyle role(BuildContext context, CKTextRole role) =>
      CKTypography.of(context, role);
}

enum CKControlDensity { compact, standard }

extension CKControlDensitySize on CKControlDensity {
  double get minimumHeight => switch (this) {
    CKControlDensity.compact => 44,
    CKControlDensity.standard => 52,
  };
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
                  style: CKTypography.of(
                    context,
                    CKTextRole.compactLabel,
                  ).copyWith(color: colorScheme.onSurfaceVariant),
                ),
                const SizedBox(height: 1),
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: CKTypography.of(context, CKTextRole.rowTitle).copyWith(
                    color: color ?? colorScheme.onSurface,
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
              style: CKTypography.of(
                context,
                CKTextRole.compactLabel,
              ).copyWith(color: colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 2),
            Text(
              value,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: CKTypography.of(context, CKTextRole.rowTitle),
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

/// A quiet section-level surface for lists, grids, and ordinary content.
///
/// Use [CKGlassPanel] for floating hero/navigation material. Use this component
/// for normal page sections so glass remains a meaningful hierarchy signal.
class CKSectionPanel extends StatelessWidget {
  const CKSectionPanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(CKSpacing.lg),
    this.onTap,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final decoration = BoxDecoration(
      color: Theme.of(context).cardTheme.color ?? colorScheme.surface,
      borderRadius: BorderRadius.circular(CKRadius.card),
      border: Border.all(
        color: colorScheme.outlineVariant.withValues(alpha: CKOpacity.border),
      ),
    );
    final panel = DecoratedBox(
      decoration: decoration,
      child: Padding(padding: padding, child: child),
    );
    if (onTap == null) return panel;
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(CKRadius.card),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(CKRadius.card),
        child: panel,
      ),
    );
  }
}

/// Image-led upgrade row with a restrained queue accent.
class CKUpgradeRow extends StatelessWidget {
  const CKUpgradeRow({
    super.key,
    required this.leading,
    required this.title,
    required this.subtitle,
    required this.accentColor,
    this.trailing,
    this.onTap,
    this.semanticLabel,
    this.density = CKControlDensity.standard,
  });

  final Widget leading;
  final String title;
  final String subtitle;
  final Color accentColor;
  final Widget? trailing;
  final VoidCallback? onTap;
  final String? semanticLabel;
  final CKControlDensity density;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final content = ConstrainedBox(
      constraints: BoxConstraints(minHeight: density.minimumHeight),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: CKSpacing.md,
          vertical: CKSpacing.sm,
        ),
        child: Row(
          children: [
            Container(
              width: 4,
              height: 36,
              decoration: BoxDecoration(
                color: accentColor,
                borderRadius: BorderRadius.circular(CKRadius.pill),
              ),
            ),
            const SizedBox(width: CKSpacing.sm),
            SizedBox.square(dimension: 40, child: leading),
            const SizedBox(width: CKSpacing.md),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: CKTypography.of(context, CKTextRole.rowTitle),
                  ),
                  const SizedBox(height: CKSpacing.xs),
                  Text(
                    subtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: CKTypography.of(
                      context,
                      CKTextRole.metadata,
                    ).copyWith(color: colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: CKSpacing.sm),
              trailing!,
            ],
          ],
        ),
      ),
    );
    final surface = DecoratedBox(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.26),
        borderRadius: BorderRadius.circular(CKRadius.tile),
      ),
      child: content,
    );
    return Semantics(
      button: onTap != null,
      label: semanticLabel ?? '$title, $subtitle',
      excludeSemantics: true,
      child: onTap == null
          ? surface
          : Material(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(CKRadius.tile),
              child: InkWell(
                onTap: onTap,
                borderRadius: BorderRadius.circular(CKRadius.tile),
                child: surface,
              ),
            ),
    );
  }
}

/// Inline resource cost that keeps game art visible without creating another
/// chip or framed surface.
class CKResourceCost extends StatelessWidget {
  const CKResourceCost({
    super.key,
    required this.icon,
    required this.amount,
    this.label,
    this.semanticLabel,
  });

  final Widget icon;
  final String amount;
  final String? label;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) => Semantics(
    label: semanticLabel ?? [if (label != null) label!, amount].join(' '),
    excludeSemantics: true,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox.square(dimension: 20, child: icon),
        const SizedBox(width: CKSpacing.xs),
        Flexible(
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: amount,
                  style: CKTypography.of(
                    context,
                    CKTextRole.metadata,
                  ).copyWith(fontWeight: FontWeight.w700),
                ),
                if (label != null)
                  TextSpan(
                    text: ' $label',
                    style: CKTypography.of(context, CKTextRole.metadata),
                  ),
              ],
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    ),
  );
}

/// Artwork-first collection tile with a quiet missing state.
class CKCollectionTile extends StatelessWidget {
  const CKCollectionTile({
    super.key,
    required this.image,
    required this.label,
    required this.owned,
    this.onTap,
    this.subtitle,
    this.semanticLabel,
  });

  final Widget image;
  final String label;
  final bool owned;
  final VoidCallback? onTap;
  final String? subtitle;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final tile = Padding(
      padding: const EdgeInsets.all(CKSpacing.xs),
      child: Column(
        children: [
          Expanded(
            child: Opacity(
              opacity: owned ? 1 : 0.48,
              child: SizedBox.expand(child: image),
            ),
          ),
          const SizedBox(height: CKSpacing.sm),
          Text(
            label,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: CKTypography.of(context, CKTextRole.compactLabel).copyWith(
              color: owned
                  ? colorScheme.onSurface
                  : colorScheme.onSurfaceVariant,
            ),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: CKSpacing.xs),
            Text(
              subtitle!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: CKTypography.of(
                context,
                CKTextRole.metadata,
              ).copyWith(color: colorScheme.onSurfaceVariant),
            ),
          ],
        ],
      ),
    );
    return Semantics(
      button: onTap != null,
      label: semanticLabel ?? '$label, ${owned ? 'collected' : 'missing'}',
      excludeSemantics: true,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(CKRadius.tile),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(CKRadius.tile),
          child: tile,
        ),
      ),
    );
  }
}

/// Compact progress treatment for counts and completion without another card.
class CKProgressBadge extends StatelessWidget {
  const CKProgressBadge({
    super.key,
    required this.label,
    required this.progress,
    this.color = CKUpgradeColors.completion,
  });

  final String label;
  final double progress;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final normalized = progress.clamp(0.0, 1.0).toDouble();
    return Semantics(
      label: '$label, ${(normalized * 100).round()} percent',
      excludeSemantics: true,
      child: Container(
        constraints: const BoxConstraints(minHeight: 28),
        padding: const EdgeInsets.symmetric(
          horizontal: CKSpacing.sm,
          vertical: CKSpacing.xs,
        ),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(CKRadius.pill),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 34,
              child: LinearProgressIndicator(
                value: normalized,
                minHeight: 3,
                borderRadius: BorderRadius.circular(CKRadius.pill),
                color: color,
                backgroundColor: colorScheme.surface.withValues(alpha: 0.54),
              ),
            ),
            const SizedBox(width: CKSpacing.sm),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: CKTypography.of(context, CKTextRole.compactLabel),
              ),
            ),
          ],
        ),
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
    this.icons,
    this.height,
    this.density = CKControlDensity.standard,
    this.color,
  }) : assert(values.length == labels.length),
       assert(icons == null || icons.length == labels.length);

  final List<T> values;
  final List<String> labels;
  final T selected;
  final ValueChanged<T> onChanged;
  final List<Widget>? icons;
  final double? height;
  final CKControlDensity density;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final selectedIndex = values.indexOf(selected);
    if (selectedIndex < 0 || labels.length < 2) {
      return const SizedBox.shrink();
    }

    final colorScheme = Theme.of(context).colorScheme;
    final indicatorDuration = CKMotion.durationOf(context, CKMotion.standard);
    final scaledLabelHeight = MediaQuery.textScalerOf(context).scale(14);
    final extraTextHeight = scaledLabelHeight > 14
        ? (scaledLabelHeight - 14) * 1.4
        : 0.0;
    final resolvedHeight = height ?? density.minimumHeight + extraTextHeight;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(CKRadius.pill),
        border: Border.all(
          color: colorScheme.outlineVariant.withValues(alpha: CKOpacity.border),
        ),
      ),
      child: SizedBox(
        height: resolvedHeight < density.minimumHeight
            ? density.minimumHeight
            : resolvedHeight,
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
                      color: colorScheme.surfaceContainerHighest.withValues(
                        alpha: 0.72,
                      ),
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
                            splashFactory: NoSplash.splashFactory,
                            overlayColor: const WidgetStatePropertyAll(
                              Colors.transparent,
                            ),
                            onTap: () => onChanged(values[index]),
                            child: Center(
                              child: AnimatedDefaultTextStyle(
                                duration: CKMotion.durationOf(
                                  context,
                                  CKMotion.fast,
                                ),
                                curve: CKMotion.standardCurve,
                                style:
                                    CKTypography.of(
                                      context,
                                      CKTextRole.compactLabel,
                                    ).copyWith(
                                      color: index == selectedIndex
                                          ? colorScheme.onSurface
                                          : colorScheme.onSurface.withValues(
                                              alpha: 0.76,
                                            ),
                                      fontWeight: index == selectedIndex
                                          ? FontWeight.w700
                                          : FontWeight.w600,
                                      height: 1,
                                    ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    if (icons != null) ...[
                                      IconTheme(
                                        data: IconThemeData(
                                          size: 16,
                                          color: index == selectedIndex
                                              ? colorScheme.onSurface
                                              : colorScheme.onSurface
                                                    .withValues(alpha: 0.76),
                                        ),
                                        child: SizedBox.square(
                                          dimension: 16,
                                          child: FittedBox(
                                            fit: BoxFit.contain,
                                            child: icons![index],
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: CKSpacing.xs),
                                    ],
                                    Flexible(
                                      child: Text(
                                        labels[index],
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ],
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
