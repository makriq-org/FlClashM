part of '../action.dart';

@Riverpod(keepAlive: true)
class SetupAction extends _$SetupAction {
  @override
  void build() {}
  void changeMode(Mode mode) {
    ref
        .read(patchClashConfigProvider.notifier)
        .update((s) => s.copyWith(mode: mode));
    unawaited(updateConfig());
  }

  void autoApplyProfile() {
    runAfterFrame(() async {
      await globalState.safeRun(() => applyProfile());
    });
  }

  Future<bool> fullSetup() => applyProfile(force: true);
  Future<void> initStatus() async {
    await backendClient.openUI();
  }

  Future<bool> setRunning(bool running, {bool initialize = false}) async {
    if (running &&
        !await (clashLib?.requestVpnPermission() ?? Future.value(false))) {
      throw StateError('VPN permission was not granted');
    }
    await frontendSettingsStore.flush();
    await backendClient.command(running ? 'runtime.start' : 'runtime.stop');
    return true;
  }

  void syncSuspend() {
    /* Android host reports SSID and network capabilities to Go. */
  }
  Future<void> restartVpn() async {
    await backendClient.command('runtime.restart');
  }

  Future<void> updateConfigDebounce() => updateConfig();
  Future<void> updateConfig() =>
      frontendSettingsStore.save(ref.read(configProvider));
  void applyProfileDebounce({bool silence = false, bool force = false}) {
    unawaited(
      globalState.safeRun(() => applyProfile(force: force, silence: silence)),
    );
  }

  Future<bool> applyProfile({
    bool silence = false,
    bool force = false,
    Future<void> Function()? preloadInvoke,
    FutureOr Function()? onUpdated,
  }) async {
    await frontendSettingsStore.save(ref.read(configProvider));
    await backendClient.command('runtime.apply');
    await onUpdated?.call();
    return true;
  }

  Future<String> getProfileWithId(String profileId) async {
    final receipt = await backendClient.command('profile.render', {
      'profileId': profileId,
    });
    final blob = receipt['blob'] as Map;
    try {
      return utf8.decode(
        await backendClient.download(
          blob['token'] as String,
          (blob['size'] as num).toInt(),
        ),
      );
    } finally {
      await backendClient.request('blob.delete', {'token': blob['token']});
    }
  }
}
