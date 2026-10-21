import 'package:flclashx/product/widgets/proxy_group_sliver.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('large group fades keep rows lazy and scroll extent fixed', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    final built = <int>{};
    var expanded = false;
    late StateSetter rebuild;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            rebuild = setState;
            return Scaffold(
              body: CustomScrollView(
                controller: controller,
                slivers: [
                  ProxyGroupSliver(
                    header: const SizedBox(height: 60),
                    expanded: expanded,
                    rowCount: 1050,
                    rowHeight: 64,
                    spacing: 8,
                    rowBuilder: (_, index) {
                      built.add(index);
                      return Text('Proxy $index');
                    },
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
    expect(built, isEmpty);

    void checkExpandedFrame() {
      expect(find.byType(Text).evaluate().length, inExclusiveRange(0, 30));
      expect(built.length, lessThan(30));
      expect(
        controller.position.maxScrollExtent,
        closeTo(
          60 + 8 + 1050 * 72 - controller.position.viewportDimension,
          0.01,
        ),
      );
      expect(tester.takeException(), isNull);
    }

    rebuild(() => expanded = true);
    await tester.pump();
    // Include the tiny first/last extents that used to mount all 1050 rows.
    for (final milliseconds in [1, 15, 32, 64, 64, 23]) {
      await tester.pump(Duration(milliseconds: milliseconds));
      checkExpandedFrame();
    }
    await tester.pumpAndSettle();
    checkExpandedFrame();

    built.clear();
    rebuild(() => expanded = false);
    await tester.pump();
    for (final milliseconds in [1, 15, 32, 64, 64, 23]) {
      await tester.pump(Duration(milliseconds: milliseconds));
      checkExpandedFrame();
    }
    await tester.pumpAndSettle();
    expect(find.byType(Text), findsNothing);
    expect(controller.position.maxScrollExtent, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('mixed group sizes keep exact scroll extent and rows stay lazy', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    final mounted = <int>{};
    var expanded = true;
    var rowHeight = 64.0;
    var rowsPerGroup = 50;
    late StateSetter rebuild;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            rebuild = setState;
            return Scaffold(
              body: Scrollbar(
                controller: controller,
                thumbVisibility: true,
                child: CustomScrollView(
                  controller: controller,
                  slivers: [
                    for (var group = 0; group < 6; group++)
                      ProxyGroupSliver(
                        header: SizedBox(height: 60.0 + group * 10),
                        expanded: group == 0 || expanded,
                        rowCount: (group + 1) * rowsPerGroup,
                        rowHeight: rowHeight,
                        spacing: 8,
                        rowBuilder: (_, index) {
                          mounted.add(group * 1000 + index);
                          return SizedBox(
                            height: rowHeight,
                            child: Text('Group $group row $index'),
                          );
                        },
                      ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    void checkExtent() {
      final total = List.generate(6, (group) {
        final count = (group + 1) * rowsPerGroup;
        return 60 +
            group * 10 +
            ((group == 0 || expanded) && count > 0
                ? 8 + count * (rowHeight + 8)
                : 0);
      }).fold<double>(0, (sum, height) => sum + height);
      expect(
        controller.position.maxScrollExtent,
        closeTo(
          (total - controller.position.viewportDimension).clamp(
            0,
            double.infinity,
          ),
          0.01,
        ),
      );
    }

    checkExtent();
    expect(mounted.length, lessThan(60));
    final extent = controller.position.maxScrollExtent;
    for (final fraction in [0.1, 0.35, 0.65, 1.0, 0.0]) {
      controller.jumpTo(extent * fraction);
      await tester.pumpAndSettle();
      checkExtent();
      expect(find.byType(Text).evaluate().length, lessThan(60));
      expect(tester.takeException(), isNull);
    }

    rebuild(() => expanded = false);
    await tester.pumpAndSettle();
    checkExtent();
    expect(find.text('Group 1 row 0'), findsNothing);

    rebuild(() {
      expanded = true;
      rowHeight = 92;
    });
    await tester.pumpAndSettle();
    checkExtent();
    expect(tester.takeException(), isNull);

    rebuild(() => rowsPerGroup = 0);
    await tester.pumpAndSettle();
    checkExtent();
    expect(find.byType(Text), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
