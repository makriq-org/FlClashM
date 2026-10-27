import 'package:flclashx/views/access.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_app.dart';

void main() {
  testWidgets('open access panel updates its mode lock', (tester) async {
    final locked = ValueNotifier(false);
    await tester.pumpWidget(
      TestApp(
        wrapInProviderScope: true,
        child: Scaffold(body: AccessControlPanel(locked: locked)),
      ),
    );
    final modeLock = find.byKey(const ValueKey('access-control-mode-lock'));
    expect(tester.widget<IgnorePointer>(modeLock).ignoring, isFalse);

    locked.value = true;
    await tester.pump();
    expect(tester.widget<IgnorePointer>(modeLock).ignoring, isTrue);
    expect(
      tester
          .widget<Opacity>(
            find.ancestor(of: modeLock, matching: find.byType(Opacity)).first,
          )
          .opacity,
      0.5,
    );

    locked.value = false;
    await tester.pump();
    expect(tester.widget<IgnorePointer>(modeLock).ignoring, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    locked.dispose();
  });
}
