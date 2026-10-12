import 'package:flclashx/product/runtime/mihomo_engine_adapter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('desktop resume preserves the core-owned start time', () async {
    const timestamp = 1780000000000;
    final bridge = DefaultMihomoLifecycleBridge(
      readDesktopSnapshot: () async =>
          {'running': true, 'started-at-millis': timestamp},
    );
    expect((await bridge.readStartTime())?.millisecondsSinceEpoch, timestamp);
    expect((await bridge.readStartTime())?.millisecondsSinceEpoch, timestamp);
  });

  test('a stopped core is distinguished from an unknown probe', () async {
    final stopped = DefaultMihomoLifecycleBridge(
      readDesktopSnapshot: () async =>
          {'running': false, 'started-at-millis': 0},
    );
    final unknown =
        DefaultMihomoLifecycleBridge(readDesktopSnapshot: () async => {});
    expect(await stopped.readStartTime(), isNull);
    await expectLater(unknown.readStartTime(), throwsStateError);
  });
}
