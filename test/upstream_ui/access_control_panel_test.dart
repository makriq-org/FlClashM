import 'package:flclashx/enum/enum.dart';
import 'package:flclashx/models/models.dart';
import 'package:flclashx/providers/providers.dart';
import 'package:flclashx/views/access.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_app.dart';

void main() {
  testWidgets('profile rules keep the mode row locked', (tester) async {
    await tester.pumpWidget(
      TestApp(
        wrapInProviderScope: true,
        overrides: [
          currentProfileProvider.overrideWith((ref) => null),
          profileDeclaredAccessProvider.overrideWith(
            (ref) async => const AccessControlProps(
              enable: true,
              mode: AccessControlMode.acceptSelected,
              acceptList: ['com.example.one'],
            ),
          ),
        ],
        child: const Scaffold(body: AccessControlPanel()),
      ),
    );
    await tester.pumpAndSettle();

    final mode = find.text('Whitelist mode');
    expect(mode, findsOneWidget);
    final lock = find.ancestor(
      of: mode,
      matching: find.byType(IgnorePointer),
    );
    expect(lock, findsWidgets);
    expect(tester.widget<IgnorePointer>(lock.first).ignoring, isTrue);
  });
}
