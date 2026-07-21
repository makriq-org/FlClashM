import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late String controller;

  setUpAll(() async {
    controller = await File('lib/controller.dart').readAsString();
  });

  test('exposes UI readiness while node preparation continues', () {
    final preload = controller.indexOf('preload = _preloadClashConfig();');
    final ready = controller.indexOf(
      '_ref.read(initProvider.notifier).value = true;',
      preload,
    );
    final detachedPreload = controller.indexOf('unawaited(preload);', ready);
    final maintenance = controller.indexOf(
      'unawaited(_runStartupMaintenance());',
      ready,
    );

    expect(preload, greaterThan(0));
    expect(ready, greaterThan(preload));
    expect(detachedPreload, greaterThan(ready));
    expect(maintenance, greaterThan(ready));
  });

  test('updates due profiles and then checks the app version', () {
    final method = controller.substring(
      controller.indexOf('Future<void> _runStartupMaintenance()'),
    );
    final profiles = method.indexOf('await autoUpdateProfiles();');
    final version = method.indexOf('await autoCheckUpdate();');

    expect(profiles, greaterThan(0));
    expect(version, greaterThan(profiles));
    expect(controller, isNot(contains('_updateCurrentProfileSubscription')));
  });
}
