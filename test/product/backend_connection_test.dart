import 'dart:async';

import 'package:flclashx/product/backend/backend_connection.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'a failed connection is retried and concurrent callers share one bind',
    () async {
      var attempts = 0;
      final gate = Completer<bool>();
      final connection = BackendConnection(
        connect: () {
          attempts++;
          return attempts == 1 ? Future.value(false) : gate.future;
        },
      );
      expect(await connection.ensure(), isFalse);
      final retry = connection.ensure();
      expect(identical(retry, connection.ensure()), isTrue);
      gate.complete(true);
      expect(await retry, isTrue);
      expect(await connection.ensure(), isTrue);
      expect(attempts, 2);
    },
  );

  test(
    'a synchronous connection error does not strand the next attempt',
    () async {
      var attempts = 0;
      final connection = BackendConnection(
        connect: () {
          if (attempts++ == 0) throw StateError('binder unavailable');
          return Future.value(true);
        },
      );
      await expectLater(connection.ensure(), throwsStateError);
      expect(await connection.ensure(), isTrue);
    },
  );

  test(
    'late success from a dead connection cannot mark its replacement ready',
    () async {
      final old = Completer<bool>();
      final replacement = Completer<bool>();
      var attempts = 0;
      final connection = BackendConnection(
        connect: () => attempts++ == 0 ? old.future : replacement.future,
      );
      final first = connection.ensure();
      connection.invalidate();
      final second = connection.ensure();
      old.complete(true);
      expect(await first, isFalse);
      expect(identical(connection.ensure(), second), isTrue);
      replacement.complete(true);
      expect(await second, isTrue);
      connection.invalidate();
      expect(await connection.ensure(), isTrue);
      expect(attempts, 3);
    },
  );

  test('only a re-established binding reports a reconnect', () async {
    var reconnects = 0;
    final connection = BackendConnection(
      connect: () async => true,
      onReconnected: () {
        reconnects++;
      },
    );
    expect(await connection.ensure(), isTrue);
    expect(await connection.ensure(), isTrue);
    expect(reconnects, 0);
    // :remote died; the next binding must trigger a full snapshot resync.
    connection.invalidate();
    expect(await connection.ensure(), isTrue);
    expect(reconnects, 1);
  });
}
