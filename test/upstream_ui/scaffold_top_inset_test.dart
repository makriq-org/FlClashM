import 'package:flclashx/ui/ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/test_app.dart';

void main() {
  for (final compact in [false, true]) {
    for (final statusBar in [0.0, 24.0]) {
      testWidgets(
        'first control clears header: compact=$compact, statusBar=$statusBar',
        (tester) async {
          tester.view.physicalSize = const Size(400, 800);
          tester.view.devicePixelRatio = 1;
          tester.view.padding = FakeViewPadding(top: statusBar);
          addTearDown(tester.view.reset);
          final scaffoldKey = GlobalKey<CommonScaffoldState>();
          var taps = 0;
          final first = find.byKey(const ValueKey('first-control'));
          await tester.pumpWidget(
            TestApp(
              child: ViewScope(
                isMobile: true,
                child: SheetProvider(
                  type: compact ? SheetType.formSheet : SheetType.page,
                  child: CommonScaffold(
                    key: scaffoldKey,
                    title: 'Page',
                    body: Builder(
                      builder: (context) => ListView(
                        padding: EdgeInsets.only(
                          top: context.contentTopPadding,
                        ),
                        children: [
                          TextButton(
                            key: const ValueKey('first-control'),
                            onPressed: () => taps++,
                            child: const Text('First control'),
                          ),
                          const SizedBox(height: 1200),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final initialTop = tester.getTopLeft(first).dy;
          expect(
            initialTop,
            statusBar + (compact ? sheetAppBarHeight : pageToolbarHeight + 12),
          );
          await tester.tap(first);
          expect(taps, 1);

          // A keyword strip consumes the header clearance itself.
          scaffoldKey.currentState!.addKeyword('filter');
          await tester.pumpAndSettle();
          expect(
            tester.getTopLeft(first).dy,
            greaterThan(tester.getBottomLeft(find.text('filter')).dy),
          );
          await tester.tap(first);
          expect(taps, 2);
          await tester.tap(
            find.descendant(
              of: find.byType(CommonChip),
              matching: find.byType(InkWell),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.getTopLeft(first).dy, initialTop);
          await tester.tap(first);
          expect(taps, 3);
        },
      );
    }
  }
}
