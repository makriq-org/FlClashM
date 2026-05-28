import '../../common/common.dart';
import '../../state.dart';
import '../android/android_update_bridge.dart';

typedef AsyncTaskRunner<T> = Future<T?> Function(
  Future<T> Function() task, {
  String? title,
});

enum AppUpdateCheckTrigger {
  automatic,
  manual,
}

class AppUpdateService {
  const AppUpdateService({
    this.platform = const AndroidUpdateBridge(),
  });

  final AppUpdatePlatformBridge platform;

  Future<void> autoCheck({required bool enabled}) async {
    if (!enabled || globalState.isPre) {
      return;
    }

    final data = await platform.checkForAppUpdate();
    await handleCheckResult(
      data: data,
      trigger: AppUpdateCheckTrigger.automatic,
    );
  }

  Future<void> manualCheck({
    required AsyncTaskRunner<Map<String, dynamic>?> runCheck,
    String? loadingTitle,
  }) async {
    if (globalState.isPre) {
      return;
    }

    final data = await runCheck(
      platform.checkForAppUpdate,
      title: loadingTitle,
    );
    await handleCheckResult(
      data: data,
      trigger: AppUpdateCheckTrigger.manual,
    );
  }

  Future<void> handleCheckResult({
    required Map<String, dynamic>? data,
    required AppUpdateCheckTrigger trigger,
  }) async {
    if (data != null) {
      final confirmed = await platform.promptForUpdateDownload(
        tagName: '${data['tag_name']}',
        submits: utils.parseReleaseBody(data['body'] as String?),
      );
      if (confirmed ?? false) {
        await platform.openLatestReleasePage();
      }
      return;
    }

    if (trigger == AppUpdateCheckTrigger.manual) {
      await platform.showUpdateCheckError();
    }
  }

  Future<bool> installPackage(String path) => platform.installPackage(path);
}
