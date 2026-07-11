import 'package:clashking_design_system/clashking_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
  });
}
