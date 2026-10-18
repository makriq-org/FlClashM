import 'dart:async';

import 'package:flclashx/product/backend/profile_refresh.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('successful refresh clears loading and shares repeated taps', () async {
    final refreshes = ProfileRefreshes();
    final gate = Completer<void>();
    final states = <bool>[];
    var requests = 0;
    Future<void> run() => refreshes.run(
      'profile',
      refresh: () {
        requests++;
        return gate.future;
      },
      setLoading: ({required loading}) => states.add(loading),
    );
    final first = run();
    expect(identical(first, run()), isTrue);
    await Future<void>.delayed(Duration.zero);
    expect(states, [true]);
    gate.complete();
    await first;
    expect(states, [true, false]);
    expect(requests, 1);
    await run();
    expect(requests, 2);
    expect(states, [true, false, true, false]);
  });

  test('failed refresh clears loading and permits a new attempt', () async {
    final refreshes = ProfileRefreshes();
    final states = <bool>[];
    await expectLater(
      refreshes.run(
        'profile',
        refresh: () async {
          throw StateError('offline');
        },
        setLoading: ({required loading}) => states.add(loading),
      ),
      throwsStateError,
    );
    expect(states, [true, false]);
    await refreshes.run(
      'profile',
      refresh: () async {},
      setLoading: ({required loading}) => states.add(loading),
    );
    expect(states, [true, false, true, false]);
  });
}
