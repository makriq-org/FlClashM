import 'package:flclashx/common/common.dart';
import 'package:flclashx/models/core.dart';
import 'package:flclashx/views/proxies/providers.dart';
import 'package:flclashx/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_app.dart';

Future<void> _pumpProvider(
  WidgetTester tester, {
  required String vehicleType,
  required String? path,
}) async {
  await tester.pumpWidget(
    TestApp(
      wrapInProviderScope: true,
      homeBuilder: (child) => Scaffold(body: child),
      child: ProviderItem(
        provider: ExternalProvider(
          name: 'Test provider',
          type: 'Proxy',
          vehicleType: vehicleType,
          path: path,
          count: 3,
          updateAt: DateTime.fromMillisecondsSinceEpoch(0),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  for (final (vehicleType, path) in [
    ('Inline', '/opaque/unused'),
    ('Compatible', '/opaque/unused'),
    ('HTTP', ''),
    ('File', null),
  ]) {
    testWidgets(
      '$vehicleType with path $path has no resource editor or inspect error',
      (tester) async {
        // No backend host is attached. An accidental inspect would replace the
        // provider count with a visible backend-unavailable error.
        await _pumpProvider(tester, vehicleType: vehicleType, path: path);
        final row = tester.widget<DecorationListItem>(
          find.byType(DecorationListItem),
        );
        final context = tester.element(find.byType(ProviderItem));
        final labels = context.appLocalizations;
        expect((row.subtitle! as Text).data, labels.proxiesCount(3, '3'));
        expect(row.onPressed, isNull);
        final menu = tester.widget<ContextMenuRegion>(
          find.byType(ContextMenuRegion),
        );
        expect(
          menu.menuItems!.map((item) => item.label),
          isNot(anyOf(contains(labels.edit), contains(labels.preview))),
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('cached resource shows inspect failure and permits retry', (
    tester,
  ) async {
    await _pumpProvider(tester, vehicleType: 'HTTP', path: '/opaque/unopened');
    final row = tester.widget<DecorationListItem>(
      find.byType(DecorationListItem),
    );
    const message = 'Android backend host is required';
    expect((row.subtitle! as Text).data, message);
    expect(row.onPressed, isNotNull);
    await tester.tap(find.text('Test provider'));
    await tester.pumpAndSettle();
    expect(find.text(message), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
