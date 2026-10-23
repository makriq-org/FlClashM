import 'dart:async';

import 'package:flclashx/product/backend/backend_client.dart';
import 'package:flclashx/product/bootstrap/backend_startup.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'an unavailable backend shows recovery and keeps retrying in background',
    () async {
      var attempts = 0;
      final presented = <BackendStartup>[];
      final startup = BackendStartup(
        initialize: () async {
          attempts++;
          if (attempts < 3) {
            throw const BackendException('unavailable', 'binder died');
          }
        },
        present: presented.add,
        retryDelay: (_) => const Duration(milliseconds: 1),
        log: (_) {},
      );
      await startup.run();
      expect(attempts, 3);
      expect(presented, [startup]);
      expect(startup.error.value, isA<BackendException>());
      expect(startup.busy.value, isFalse);
    },
  );

  test('a reachable backend never shows the recovery screen', () async {
    final presented = <BackendStartup>[];
    await BackendStartup(
      initialize: () async {},
      present: presented.add,
      log: (_) {},
    ).run();
    expect(presented, isEmpty);
  });

  test('background retries re-arm a binding that gave up', () async {
    var reconnects = 0;
    final startup = BackendStartup(
      initialize: () async {
        if (reconnects < 2) {
          throw const BackendException('unavailable', 'gave up');
        }
      },
      present: (_) {},
      reconnect: () => reconnects++,
      retryDelay: (_) => const Duration(milliseconds: 1),
      log: (_) {},
    );
    await startup.run();
    expect(reconnects, 2);
  });

  test('a manual retry re-arms the binding and completes startup', () async {
    var reachable = false;
    var reconnects = 0;
    final presented = Completer<BackendStartup>();
    final startup = BackendStartup(
      initialize: () async {
        if (!reachable) {
          throw const BackendException('unavailable', 'gave up');
        }
      },
      present: presented.complete,
      reconnect: () {
        reconnects++;
        reachable = true;
      },
      retryDelay: (_) => const Duration(hours: 1),
      log: (_) {},
    );
    final running = startup.run();
    await (await presented.future).retry();
    await running;
    expect(reconnects, 1);
  });
}
