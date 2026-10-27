import 'dart:async';

import 'package:flclashx/core/controller.dart';
import 'package:flclashx/core/lib.dart';
import 'package:flclashx/product/backend/projection_watcher.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final failure in ['exception', 'missing acknowledgement', 'rejected']) {
    test('host visibility retries $failure for the same backend', () async {
      var attempts = 0;
      final values = <bool>[];
      final core = CoreController.scoped(
        CoreLib(
          legacyInvoke: (method, data) async {
            expect(method, 'setHostActive');
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
      final visibility = HostVisibilityProjection();
      Future<void> sync(String instance, {required bool visible}) =>
          visibility.synchronize(instance, () => core.syncHostActive(visible));
      await expectLater(sync('first', visible: true), throwsStateError);
      await sync('first', visible: true);
      await sync('first', visible: true); // Already acknowledged.
      await sync('replacement', visible: false);
      expect(values, [true, true, false]);
    });
  }

  test('host visibility waits for acknowledgement', () async {
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
    final visibility = HostVisibilityProjection();
    var completed = false;
    final pending = visibility
        .synchronize('backend', () => core.syncHostActive(true))
        .then((_) => completed = true);
    await Future<void>.delayed(Duration.zero);
    expect(completed, isFalse);
    acknowledgement.complete(true);
    await pending;
    await visibility.synchronize('backend', () => core.syncHostActive(true));
    expect(calls, 1);
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
