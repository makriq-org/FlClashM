import 'package:flclashx/product/backend/projection_watcher.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
