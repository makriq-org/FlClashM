import '../../common/common.dart';
import '../../state.dart';
import '../android/android_update_bridge.dart';
import 'app_update_release.dart';
import 'app_update_session.dart';

typedef AsyncTaskRunner = Future<T?> Function<T>(
  Future<T> Function() task, {
  String? title,
});

enum AppUpdateCheckTrigger { automatic, manual }

typedef SkipAppUpdateRelease = Future<void> Function(String tagName);

class AppUpdateService {
  const AppUpdateService({this.platform = const AndroidUpdateBridge()});

  final AppUpdatePlatformBridge platform;

  Future<void> autoCheck({
    required bool enabled,
    required bool includePrerelease,
    required String skippedTagName,
    SkipAppUpdateRelease? onSkipRelease,
  }) async {
    // Уборка скачанных APK выполняется только после подтверждённого
    // обновления и не зависит от того, включена ли автопроверка.
    await _pruneConfirmedUpdate();
    if (!enabled) {
      return;
    }

    final release = await platform.checkForAppUpdate(
      includePrerelease: includePrerelease,
      skippedTagName: skippedTagName,
    );
    await handleCheckResult(
      release: release,
      trigger: AppUpdateCheckTrigger.automatic,
      onSkipRelease: onSkipRelease,
    );
  }

  Future<void> manualCheck({
    required AsyncTaskRunner runTask,
    required bool includePrerelease,
    required String skippedTagName,
    SkipAppUpdateRelease? onSkipRelease,
    String? loadingTitle,
  }) async {
    final release = await runTask(
      () => platform.checkForAppUpdate(
        includePrerelease: includePrerelease,
        skippedTagName: skippedTagName,
      ),
      title: loadingTitle,
    );
    await handleCheckResult(
      release: release,
      trigger: AppUpdateCheckTrigger.manual,
      onSkipRelease: onSkipRelease,
    );
  }

  Future<void> handleCheckResult({
    required AppRelease? release,
    required AppUpdateCheckTrigger trigger,
    SkipAppUpdateRelease? onSkipRelease,
  }) async {
    final available = release;
    if (available == null) {
      if (trigger == AppUpdateCheckTrigger.manual) {
        await platform.showUpdateCheckError();
      }
      return;
    }

    final session = AppUpdateSession(
      release: available,
      installer: platform,
      journal: platform.installJournal,
      requiredUpdate: isAppUpdateRequired(
        available,
        installedVersionCode: int.tryParse(globalState.packageInfo.buildNumber),
        installedVersionName: globalState.packageInfo.version,
      ),
    );
    try {
      final action = await platform.showUpdateWindow(
        release: available,
        submits: utils.parseReleaseBody(available.body),
        session: session,
      );
      if (action == AppUpdateWindowResult.skip) {
        await onSkipRelease?.call(available.tagName);
      }
    } finally {
      session.dispose();
    }
  }

  Future<void> _pruneConfirmedUpdate() async {
    try {
      await platform.pruneInstalledUpdates();
    } catch (error) {
      commonPrint.log('Stale app update cleanup failed: $error');
    }
  }
}
