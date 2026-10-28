import 'package:flclashx/enum/enum.dart';
import 'package:flclashx/models/models.dart';
import 'package:flclashx/providers/providers.dart';
import 'package:flclashx/views/access.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_app.dart';

void main() {
  for (final owned in [false, true]) {
    testWidgets(
      'profile inspection failure keeps manual editor available: $owned',
      (tester) async {
        await tester.pumpWidget(
          TestApp(
            wrapInProviderScope: true,
            overrides: [
              currentProfileProvider.overrideWith((ref) => null),
              appSettingProvider.overrideWithBuild(
                (_, _) => AppSettingProps(
                  ownedSettings: owned ? {accessControlSettingKey} : {},
                ),
              ),
              profileDeclaredAccessProvider.overrideWith(
                (ref) async => throw Exception('offline'),
              ),
            ],
            child: const AccessView(),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Retry'), owned ? findsNothing : findsOneWidget);
        expect(
          find.text('App access control is disabled'),
          owned ? findsOneWidget : findsNothing,
        );
      },
    );
  }

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
    final lock = find.ancestor(of: mode, matching: find.byType(IgnorePointer));
    expect(lock, findsWidgets);
    expect(tester.widget<IgnorePointer>(lock.first).ignoring, isTrue);
  });
}
