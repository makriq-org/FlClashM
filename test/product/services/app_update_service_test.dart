import 'package:flclashx/product/android/android_update_bridge.dart';
import 'package:flclashx/product/services/app_update_service.dart';
import 'package:flclashx/state.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeUpdateBridge implements AppUpdatePlatformBridge {
  _FakeUpdateBridge({
    this.checkResult,
    this.promptResult,
  });

  final Map<String, dynamic>? checkResult;
  final bool? promptResult;

  int checkCalls = 0;
  int errorCalls = 0;
  int openCalls = 0;
  int installCalls = 0;
  String? lastInstallPath;
  String? promptedTagName;
  List<String>? promptedSubmits;

  @override
  String get latestReleaseUrl => 'https://example.com/releases/latest';

  @override
  Future<Map<String, dynamic>?> checkForAppUpdate() async {
    checkCalls++;
    return checkResult;
  }

  @override
  Future<bool?> promptForUpdateDownload({
    required String tagName,
    required List<String> submits,
  }) async {
    promptedTagName = tagName;
    promptedSubmits = submits;
    return promptResult;
  }

  @override
  Future<void> showUpdateCheckError() async {
    errorCalls++;
  }

  @override
  Future<bool> openLatestReleasePage() async {
    openCalls++;
    return true;
  }

  @override
  Future<bool> installPackage(String path) async {
    installCalls++;
    lastInstallPath = path;
    return true;
  }
}

void main() {
  group('AppUpdateService', () {
    setUp(() {
      globalState.isPre = false;
    });

    test('skips automatic checks when disabled or pre-release', () async {
      final bridge = _FakeUpdateBridge();
      final service = AppUpdateService(platform: bridge);

      await service.autoCheck(enabled: false);
      globalState.isPre = true;
      await service.autoCheck(enabled: true);

      expect(bridge.checkCalls, 0);
      expect(bridge.errorCalls, 0);
    });

    test('prompts and opens release page when update is confirmed', () async {
      final bridge = _FakeUpdateBridge(
        checkResult: const {
          'tag_name': 'v1.2.3',
          'body': '- first change\n- second change',
        },
        promptResult: true,
      );
      final service = AppUpdateService(platform: bridge);

      await service.autoCheck(enabled: true);

      expect(bridge.checkCalls, 1);
      expect(bridge.promptedTagName, 'v1.2.3');
      expect(bridge.promptedSubmits, ['first change', 'second change']);
      expect(bridge.openCalls, 1);
      expect(bridge.errorCalls, 0);
    });

    test('shows explicit error on manual check when no update is returned',
        () async {
      final bridge = _FakeUpdateBridge();
      final service = AppUpdateService(platform: bridge);
      String? loadingTitle;

      await service.manualCheck(
        runCheck: (
          task, {
          title,
        }) async {
          loadingTitle = title;
          return task();
        },
        loadingTitle: 'Check update',
      );

      expect(bridge.checkCalls, 1);
      expect(loadingTitle, 'Check update');
      expect(bridge.errorCalls, 1);
      expect(bridge.openCalls, 0);
    });

    test('delegates package install through the platform bridge', () async {
      final bridge = _FakeUpdateBridge();
      final service = AppUpdateService(platform: bridge);

      final installed = await service.installPackage('/tmp/app.apk');

      expect(installed, isTrue);
      expect(bridge.installCalls, 1);
      expect(bridge.lastInstallPath, '/tmp/app.apk');
    });
  });
}
