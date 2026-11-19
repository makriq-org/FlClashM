import 'package:flclashx/enum/enum.dart';
import 'package:flclashx/views/dashboard/widgets/core_status_button.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../helpers/test_app.dart';

void main() {
  Future<void> pump(WidgetTester tester, CoreStatus status) async {
    await tester.pumpWidget(
      TestApp(
        child: Center(
          child: SizedBox.square(
            dimension: 24,
            child: CorePulse(key: ValueKey(status), status: status),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('each Core state paints a heartbeat', (tester) async {
    for (final status in CoreStatus.values) {
      await pump(tester, status);
      expect(find.byType(CorePulse), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('a state change morphs instead of replacing the pulse', (
    tester,
  ) async {
    await pump(tester, CoreStatus.disconnected);
    final state = tester.state(find.byType(CorePulse));
    await tester.pumpWidget(
      const TestApp(
        child: Center(
          child: SizedBox.square(
            dimension: 24,
            child: CorePulse(
              key: ValueKey('connected'),
              status: CoreStatus.connected,
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byType(CorePulse), findsOneWidget);
    expect(tester.state(find.byType(CorePulse)).runtimeType, state.runtimeType);
    expect(tester.takeException(), isNull);
  });
}
