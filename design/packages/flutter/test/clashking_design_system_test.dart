import 'package:clashking_design_system/clashking_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('semantic foundations', () {
    test('upgrade colors map to the shared palette', () {
      expect(CKUpgradeColors.builders, CKColors.builderBlue);
      expect(CKUpgradeColors.research, CKColors.capitalPurple);
      expect(CKUpgradeColors.completion, CKColors.warGold);
      expect(
        CKUpgradeColors.forQueue(CKUpgradeQueueTone.pets),
        CKUpgradeColors.pets,
      );
    });

    testWidgets('typography exposes stable named roles', (tester) async {
      late TextStyle hero;
      late TextStyle body;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              hero = CKTypography.of(context, CKTextRole.heroMetric);
              body = CKTypography.of(context, CKTextRole.body);
              return const SizedBox();
            },
          ),
        ),
      );
      expect(hero.fontWeight, FontWeight.w800);
      expect(body.fontWeight, FontWeight.w500);
    });
  });

  group('CKMotion', () {
    testWidgets('keeps the requested duration by default', (tester) async {
      late Duration resolved;

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              resolved = CKMotion.durationOf(context, CKMotion.standard);
              return const SizedBox();
            },
          ),
        ),
      );

      expect(resolved, CKMotion.standard);
    });

    testWidgets('resolves durations to zero when animations are disabled', (
      tester,
    ) async {
      late Duration resolved;

      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: child!,
          ),
          home: Builder(
            builder: (context) {
              resolved = CKMotion.durationOf(context, CKMotion.slow);
              return const SizedBox();
            },
          ),
        ),
      );

      expect(resolved, Duration.zero);
    });
  });

  group('stat semantics', () {
    testWidgets('CKMetricChip exposes only its combined semantic label', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: CKMetricChip(
              label: 'Trophies',
              value: '5,432',
              iconData: Icons.emoji_events,
            ),
          ),
        ),
      );

      final semantics = tester.widget<Semantics>(
        find
            .descendant(
              of: find.byType(CKMetricChip),
              matching: find.byType(Semantics),
            )
            .first,
      );
      expect(semantics.properties.label, 'Trophies: 5,432');
      expect(semantics.excludeSemantics, isTrue);
    });

    testWidgets('CKStatTile exposes only its custom semantic label', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: CKStatTile(
              label: 'Stars',
              value: '3',
              semanticLabel: 'War stars: 3',
              icon: Icon(Icons.star),
            ),
          ),
        ),
      );

      final semantics = tester.widget<Semantics>(
        find
            .descendant(
              of: find.byType(CKStatTile),
              matching: find.byType(Semantics),
            )
            .first,
      );
      expect(semantics.properties.label, 'War stars: 3');
      expect(semantics.excludeSemantics, isTrue);
    });
  });

  group('large text', () {
    testWidgets('stat primitives remain stable at 200 percent text scale', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: const Scaffold(
            body: Row(
              children: [
                SizedBox(
                  width: 180,
                  child: CKMetricChip(
                    label: 'Trophies',
                    value: '5,432',
                    iconData: Icons.emoji_events,
                  ),
                ),
                CKStatTile(label: 'Stars', value: '3', icon: Icon(Icons.star)),
              ],
            ),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
    });

    testWidgets('compact segmented control grows beyond its 44dp minimum', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            textTheme: const TextTheme(
              labelLarge: TextStyle(fontSize: 16, letterSpacing: 0),
            ),
          ),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: Scaffold(
            body: CKSegmentedControl<int>(
              values: const [0, 1],
              labels: const ['Plan', 'Upgrades'],
              selected: 0,
              density: CKControlDensity.compact,
              onChanged: (_) {},
            ),
          ),
        ),
      );

      expect(
        tester.getSize(find.byType(CKSegmentedControl<int>)).height,
        greaterThan(44),
      );
      final planStyle = tester
          .widget<AnimatedDefaultTextStyle>(
            find
                .ancestor(
                  of: find.text('Plan'),
                  matching: find.byType(AnimatedDefaultTextStyle),
                )
                .first,
          )
          .style;
      expect(planStyle.fontSize, 16);
      expect(tester.takeException(), isNull);
    });

    testWidgets('filter and summary chips render in shared rails', (
      tester,
    ) async {
      var selected = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                CKFilterChipRail(
                  children: [
                    CKFilterChip(
                      label: 'Linked',
                      icon: Icons.link,
                      selected: selected,
                      onTap: () => selected = true,
                    ),
                    CKFilterChip(
                      label: 'Bookmarked',
                      icon: Icons.bookmark,
                      selected: !selected,
                      onTap: () => selected = false,
                    ),
                  ],
                ),
                const CKSummaryChipRail(
                  scrollable: false,
                  children: [
                    CKSummaryChip(
                      label: 'attacks',
                      value: '12',
                      icon: Icons.sports_martial_arts,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );

      await tester.tap(find.text('Linked'));

      expect(selected, isTrue);
      expect(find.byType(CKFilterChip), findsNWidgets(2));
      expect(find.byType(CKSummaryChip), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('tracker primitives remain stable at 200 percent text scale', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: Scaffold(
            body: Column(
              children: [
                CKUpgradeRow(
                  leading: const Icon(Icons.home),
                  title: 'Archer Tower',
                  subtitle: 'Level 17 to 18',
                  accentColor: CKUpgradeColors.builders,
                  trailing: const Text('2d 4h'),
                  density: CKControlDensity.compact,
                  onTap: () {},
                ),
                const SizedBox(
                  width: 140,
                  height: 180,
                  child: CKCollectionTile(
                    image: Icon(Icons.shield),
                    label: 'Champion skin',
                    owned: false,
                  ),
                ),
              ],
            ),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
    });
  });
}
