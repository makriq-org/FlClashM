import 'dart:convert';

import 'package:flclashx/common/common.dart';
import 'package:flclashx/core/controller.dart';
import 'package:flclashx/enum/enum.dart';
import 'package:flclashx/features/form/form.dart';
import 'package:flclashx/models/models.dart';
import 'package:flclashx/providers/providers.dart';
import 'package:flclashx/views/profiles/custom/custom_proxies.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_app.dart';

class _Core extends Fake implements CoreController {
  @override
  Future<List<String>> validateProxies(
    List<Map<String, dynamic>> proxies,
  ) async => List.filled(proxies.length, '');
}

/// Replaces only the catalog boundary; the real editor owns its draft and save.
class _Catalog extends CustomProxies {
  _Catalog(this.stored);

  CustomProxy stored;
  int writes = 0;

  @override
  Stream<List<CustomProxy>> build() => Stream.value([stored]);

  @override
  void put(CustomProxy proxy) {
    stored = CustomProxy.fromJson(
      jsonDecode(jsonEncode(proxy.toJson())) as Map<String, dynamic>,
    );
    writes++;
    state = AsyncData([stored]);
  }
}

void main() {
  for (final (network, headers, host, hostValue) in [
    (
      'http',
      ProxyField.httpHeaders,
      ProxyField.httpHost,
      ['a.example', 'b.example'],
    ),
    ('ws', ProxyField.wsHeaders, ProxyField.wsHost, 'ws.example'),
  ]) {
    testWidgets('$network header removal survives save and editor reopen', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1200, 5000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final catalog = _Catalog(
        CustomProxy(
          id: 1,
          definition: {
            'name': 'node',
            'type': 'vmess',
            'server': 'example.org',
            'port': 443,
            'uuid': '11111111-1111-4111-8111-111111111111',
            'network': network,
            '$network-opts': {
              'headers': {'Host': hostValue, 'X-Custom': 'remove-me'},
            },
          },
        ),
      );
      await tester.pumpWidget(
        TestApp(
          wrapInProviderScope: true,
          overrides: [
            currentProfileProvider.overrideWith((ref) => null),
            customProxiesProvider.overrideWith(() => catalog),
            customGroupNamesProvider.overrideWith(
              (ref) => Stream.value(<String>{}),
            ),
            coreHandlerProvider.overrideWithValue(_Core()),
          ],
          child: const CustomProxiesView(),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('node'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 600));
      Finder row(ProxyField field) => find.byWidgetPredicate(
        (widget) => widget is KeyedSubtree && widget.key == ValueKey(field),
      );
      final option = row(headers);
      expect(option, findsOneWidget);
      await tester.ensureVisible(option);
      await tester.tap(
        find.descendant(of: option, matching: find.byType(EntryButton)),
      );
      await tester.pumpAndSettle();
      expect(option, findsNothing);
      expect(row(host), findsOneWidget);
      await tester.tap(find.byTooltip(currentAppLocalizations.save));
      await tester.pumpAndSettle();
      expect(catalog.writes, 1);
      expect(catalog.stored.valueOf(host), hostValue);
      expect(catalog.stored.stringMapOf(headers), isEmpty);
      expect(catalog.stored.emptyOptions, isNot(contains(headers)));

      await tester.tap(find.text('node'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 600));
      expect(option, findsNothing);
      expect(row(host), findsOneWidget);
      expect(catalog.stored.valueOf(host), hostValue);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });
  }
}
