import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('QuickJS runtime is disposed on success and failure', () async {
    final source = await File('lib/state.dart').readAsString();
    final method = source.substring(source.indexOf('Future<Map<String, dynamic>> handleEvaluate'));

    expect(method, contains('try {'));
    expect(method, contains('finally {'));
    expect(method, contains('runtime.dispose();'));
  });

  test('traffic polling does not fetch groups for notification updates',
      () async {
    final source = await File('lib/controller.dart').readAsString();
    final start = source.indexOf('Future<void> updateTraffic()');
    final end = source.indexOf('void markRuntimeConfigListenerReady()', start);
    final method = source.substring(start, end);

    expect(method, isNot(contains('updateGroups')));
    expect(method, isNot(contains('syncForegroundNotification')));
    expect(
      source,
      contains('syncNotification: Platform.isAndroid && globalState.isStart'),
    );
  });

  test('installed package names use native TTL and a direct channel list',
      () async {
    final kotlin = await File(
      'android/app/src/main/kotlin/com/follow/clashx/plugins/AppPlugin.kt',
    ).readAsString();
    final dart = await File('lib/plugins/app.dart').readAsString();
    final start = dart.indexOf('Future<List<String>> getInstalledPackageNames()');
    final end = dart.indexOf('Future<List<String>> getChinaPackageNames()', start);
    final method = dart.substring(start, end);

    expect(kotlin, contains('installedPackageNamesLoadedAt'));
    expect(kotlin, contains('PACKAGES_CACHE_TTL_MS'));
    expect(kotlin, contains('Intent.ACTION_PACKAGE_ADDED'));
    expect(kotlin, contains('invalidatePackageCaches()'));
    expect(kotlin, contains('refreshInstalledAppsPermissionState()'));
    expect(method, contains('invokeMethod<List<dynamic>>'));
    expect(method, isNot(contains('Isolate.run')));
    expect(method, isNot(contains('json.decode')));
  });

  test('notification dedupe still repairs cross-process persistence', () async {
    final source = await File(
      'android/service/src/main/kotlin/com/follow/clashx/service/RemoteService.kt',
    ).readAsString();
    final start = source.indexOf(
      'override fun updateNotificationParams(params: NotificationParams)',
    );
    final end = source.indexOf('\n        }', start);
    final method = source.substring(start, end);

    expect(method, contains('State.notificationParamsFlow.value != params'));
    expect(method, contains('SavedParams.saveNotificationTitle(params.title)'));
    expect(method, isNot(contains('== params) return')));
  });

  test('access search is debounced outside the selection state', () async {
    final source = await File('lib/views/access.dart').readAsString();

    expect(source, contains('Duration(milliseconds: 180)'));
    expect(source, contains('buildPackageIndex(packages)'));
    expect(source, contains('_searchDebounce?.cancel()'));
  });

  test('first-frame metric names the post-frame callback boundary', () async {
    final source =
        await File('lib/product/bootstrap/app_bootstrap.dart').readAsString();

    expect(source, contains('bootstrap.firstFrameCallbackMs'));
    expect(source, isNot(contains('bootstrap.firstFrameMs=')));
  });

  test('pending runtime-plan revision includes proxy selections', () async {
    final source = await File('lib/state.dart').readAsString();

    expect(
      source,
      contains('json.encode(config.currentProfile?.selectedMap ?? const {})'),
    );
  });
}
