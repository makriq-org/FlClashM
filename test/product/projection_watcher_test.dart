import 'dart:async';

import 'package:flclashx/core/controller.dart';
import 'package:flclashx/core/lib.dart';
import 'package:flclashx/product/backend/projection_watcher.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final failure in ['exception', 'missing acknowledgement', 'rejected']) {
    testWidgets('host visibility retries $failure without a new snapshot', (
      tester,
    ) async {
      var attempts = 0;
      final values = <bool>[];
      final methods = <String>[];
      final core = CoreController.scoped(
        CoreLib(
          legacyInvoke: (method, data) async {
            methods.add(method);
            values.add(data! as bool);
            if (attempts++ == 0) {
              if (failure == 'exception') {
                throw StateError('binder unavailable');
              }
              return failure == 'rejected' ? false : null;
            }
            return true;
          },
        ),
      );
      final errors = <Object>[];
      final visibility = HostVisibilityProjection(onError: errors.add);
      void sync(String instance, {required bool visible}) =>
          visibility.synchronize(instance, () => core.syncHostActive(visible));
      sync('first', visible: true);
      await tester.pump();
      await tester.pump();
      expect(values, [true]);
      expect(errors, hasLength(1));
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(values, [true, true]);
      sync('first', visible: true); // Already acknowledged.
      sync('replacement', visible: false);
      await tester.pump();
      expect(values, [true, true, false]);
      expect(methods, everyElement('setHostActive'));
      visibility.dispose();
    });
  }

  testWidgets(
    'host visibility does not block projection while awaiting acknowledgement',
    (tester) async {
      final acknowledgement = Completer<bool>();
      var calls = 0;
      final core = CoreController.scoped(
        CoreLib(
          legacyInvoke: (_, _) {
            calls++;
            return acknowledgement.future;
          },
        ),
      );
      final visibility = HostVisibilityProjection()
        ..synchronize('backend', () => core.syncHostActive(true));
      await tester.pump();
      expect(calls, 1);
      // Snapshot work can continue while the RPC is still pending.
      expect(acknowledgement.isCompleted, isFalse);
      acknowledgement.complete(true);
      await tester.pump();
      visibility.synchronize('backend', () => core.syncHostActive(true));
      expect(calls, 1);
      visibility.dispose();
    },
  );

  testWidgets('replacement and disposal cancel pending visibility retries', (
    tester,
  ) async {
    final calls = <String>[];
    final visibility = HostVisibilityProjection()
      ..synchronize('old', () async {
        calls.add('old');
        throw StateError('unavailable');
      });
    await tester.pump();
    visibility.synchronize('new', () async => calls.add('new'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(calls, ['old', 'new']);
    visibility.synchronize('third', () async {
      calls.add('third');
      throw StateError('unavailable');
    });
    await tester.pump();
    visibility.dispose();
    await tester.pump(const Duration(seconds: 2));
    expect(calls, ['old', 'new', 'third']);
  });

  testWidgets('replacement waits for an in-flight delivery', (tester) async {
    final pending = Completer<void>();
    final calls = <String>[];
    final visibility = HostVisibilityProjection()
      ..synchronize('old', () {
        calls.add('old');
        return pending.future;
      })
      ..synchronize('new', () async => calls.add('new'));
    expect(calls, ['old']);
    pending.complete();
    await tester.pump();
    expect(calls, ['old', 'new']);
    visibility.dispose();
  });

  test('lifecycle visibility waits for restoration acknowledgement', () async {
    final first = Completer<bool>();
    final applied = <bool>[];
    final sent = <bool>[];
    final core = CoreController.scoped(
      CoreLib(
        legacyInvoke: (_, data) async {
          final visible = data! as bool;
          sent.add(visible);
          if (visible) await first.future;
          applied.add(visible);
          return true;
        },
      ),
    );
    final restoration = core.syncHostActive(true);
    await Future<void>.delayed(Duration.zero);
    core.setHostActive(false);
    await Future<void>.delayed(Duration.zero);
    expect(sent, [true]);
    first.complete(true);
    await restoration;
    await Future<void>.delayed(Duration.zero);
    expect(sent, [true, false]);
    expect(applied, [true, false]);
  });

  test('a failed visibility delivery does not block the next write', () async {
    var attempts = 0;
    final sent = <bool>[];
    final core = CoreController.scoped(
      CoreLib(
        legacyInvoke: (_, data) async {
          sent.add(data! as bool);
          if (attempts++ == 0) throw StateError('unavailable');
          return true;
        },
      ),
    );
    final failed = core.syncHostActive(true);
    final next = core.syncHostActive(false);
    await expectLater(failed, throwsStateError);
    await next;
    expect(sent, [true, false]);
  });

  test('profile switches and new plans are reported once', () {
    final watcher = ProjectionWatcher();
    ProjectionChange observe(String? selected, String? applied, int? plan) =>
        watcher.observe(
          profileId: selected,
          appliedProfileId: applied,
          generation: plan,
        );

    expect(observe('a', 'a', 1), ProjectionChange.none);
    expect(observe('a', 'a', 1), ProjectionChange.none);
    expect(observe('a', 'a', 2), ProjectionChange.generation);
    // The user selected another profile in Go.
    expect(observe('b', 'a', 2), ProjectionChange.profile);
    // The runtime applied it.
    expect(observe('b', 'b', 3), ProjectionChange.profile);
    expect(observe('b', 'b', 3), ProjectionChange.none);
    // Stopping the runtime is not a profile switch.
    expect(observe('b', null, 3), ProjectionChange.none);
    expect(observe('b', 'b', 3), ProjectionChange.none);
  });
}
