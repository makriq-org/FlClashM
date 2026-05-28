import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive.dart';
import 'package:flclashx/clash/clash.dart';
import 'package:flclashx/common/archive.dart';
import 'package:flclashx/enum/enum.dart';
import 'package:flclashx/providers/providers.dart';
import 'package:flclashx/services/subscription_notification_service.dart';
import 'package:flclashx/state.dart';
import 'package:flclashx/widgets/dialog.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' hide windows;
import 'package:shared_preferences/shared_preferences.dart';

import 'common/common.dart';
import 'models/models.dart';
import 'product/android/product_android.dart';
import 'product/runtime/product_runtime.dart';
import 'product/services/product_services.dart';
import 'product/subscription/product_subscription.dart';
import 'views/profiles/override_profile.dart';

class AppController {
  AppController(this.context, WidgetRef ref) : _ref = ref;
  int? lastProfileModified;
  final BuildContext context;
  final WidgetRef _ref;
  bool _suppressNextRuntimeConfigUpdate = false;
  bool _runtimeConfigListenerReady = false;

  void setupClashConfigDebounce() {
    debouncer.call(FunctionTag.setupClashConfig, () async {
      await setupClashConfig();
    });
  }

  void updateClashConfigDebounce() {
    debouncer.call(FunctionTag.updateClashConfig, () async {
      await updateClashConfig();
    });
  }

  void updateGroupsDebounce() {
    debouncer.call(FunctionTag.updateGroups, updateGroups);
  }

  void addCheckIpNumDebounce() {
    debouncer.call(FunctionTag.addCheckIpNum, () {
      _ref.read(checkIpNumProvider.notifier).add();
    });
  }

  void applyProfileDebounce({bool silence = false}) {
    debouncer.call(FunctionTag.applyProfile, (silence) {
      applyProfile(silence: silence);
    }, args: [silence]);
  }

  void savePreferencesDebounce() {
    debouncer.call(FunctionTag.savePreferences, savePreferences);
  }

  void changeProxyDebounce(String groupName, String proxyName) {
    debouncer.call(FunctionTag.changeProxy, (
      String groupName,
      String proxyName,
    ) async {
      await changeProxy(groupName: groupName, proxyName: proxyName);
      await syncAndroidForegroundNotificationForProxyChange(
        groupName: groupName,
        proxyName: proxyName,
      );
      await updateGroups();
    }, args: [groupName, proxyName]);
  }

  Future<void> syncAndroidForegroundNotification() async {
    await androidPlatform.foregroundNotification.syncCurrentProfile(
      profile: globalState.config.currentProfile,
      groups: _ref.read(groupsProvider),
    );
  }

  Future<void> syncAndroidForegroundNotificationForProxyChange({
    required String groupName,
    required String proxyName,
  }) async {
    await androidPlatform.foregroundNotification.syncProxyChange(
      profile: globalState.config.currentProfile,
      groupName: groupName,
      proxyName: proxyName,
    );
  }

  Future<void> restartCore() async {
    commonPrint.log("restart core");
    final wasStarted = _ref.read(runTimeProvider.notifier).isStart;
    final started = await globalState.engineManager.restart(
      runtimePlanRequest: _buildRuntimePlanRequest(
        patchConfig: _ref.read(patchClashConfigProvider),
      ),
      coldStartPatchConfig: _buildColdStartPatchConfig(
        _ref.read(patchClashConfigProvider),
      ),
      resumeIfStarted: wasStarted,
      updateTasks: [updateTraffic],
      notificationTitle: androidPlatform.foregroundNotification.buildTitle(
        globalState.config.currentProfile,
        groups: _ref.read(groupsProvider),
      ),
    );
    if (wasStarted && started) {
      await onRuntimeStarted(
        checkProfileModified: false,
        updateStatusBarIcon: false,
      );
    } else if (wasStarted) {
      await onRuntimeStopped();
    }
  }

  Future<void> updateStatus(bool isStart) async {
    if (isStart) {
      await syncAndroidForegroundNotification();
      final started = await globalState.engineManager.start(
        updateTasks: [updateTraffic],
        notificationTitle: androidPlatform.foregroundNotification.buildTitle(
          globalState.config.currentProfile,
          groups: _ref.read(groupsProvider),
        ),
      );
      if (!started) {
        await StatusBarManager.updateIcon(isConnected: false);
        return;
      }
      await onRuntimeStarted(checkProfileModified: true);
    } else {
      await globalState.engineManager.stop();
      await onRuntimeStopped();
    }
  }

  Future<void> onRuntimeStarted({
    required bool checkProfileModified,
    bool updateStatusBarIcon = true,
  }) async {
    if (updateStatusBarIcon) {
      await StatusBarManager.updateIcon(isConnected: true);
    }

    startRunTimeTimer();
    if (!checkProfileModified) {
      return;
    }

    final currentLastModified =
        await _ref.read(currentProfileProvider)?.profileLastModified;
    if (currentLastModified == null || lastProfileModified == null) {
      addCheckIpNumDebounce();
      return;
    }
    if (currentLastModified <= (lastProfileModified ?? 0)) {
      addCheckIpNumDebounce();
      return;
    }
    applyProfileDebounce();
  }

  Future<void> onRuntimeStopped({bool updateStatusBarIcon = true}) async {
    if (updateStatusBarIcon) {
      await StatusBarManager.updateIcon(isConnected: false);
    }

    stopRunTimeTimer();
    clashCore.resetTraffic();
    _ref.read(trafficsProvider.notifier).clear();
    _ref.read(totalTrafficProvider.notifier).value = Traffic();
    _ref.read(runTimeProvider.notifier).value = null;
    addCheckIpNumDebounce();
  }

  Timer? _runTimeTimer;

  void startRunTimeTimer() {
    stopRunTimeTimer();
    updateRunTime();
    _runTimeTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      updateRunTime();
    });
  }

  void stopRunTimeTimer() {
    _runTimeTimer?.cancel();
    _runTimeTimer = null;
  }

  void updateRunTime() {
    final startTime = globalState.startTime;
    if (startTime != null) {
      final startTimeStamp = startTime.millisecondsSinceEpoch;
      final nowTimeStamp = DateTime.now().millisecondsSinceEpoch;
      _ref.read(runTimeProvider.notifier).value = nowTimeStamp - startTimeStamp;
    } else {
      _ref.read(runTimeProvider.notifier).value = null;
    }
  }

  Future<void> updateTraffic() async {
    final traffic = await clashCore.getTraffic();
    _ref.read(trafficsProvider.notifier).addTraffic(traffic);
    _ref.read(totalTrafficProvider.notifier).value =
        await clashCore.getTotalTraffic();
  }

  void markRuntimeConfigListenerReady() {
    _runtimeConfigListenerReady = true;
  }

  void markRuntimeConfigListenerNotReady() {
    _runtimeConfigListenerReady = false;
    _suppressNextRuntimeConfigUpdate = false;
  }

  bool consumeSuppressedRuntimeConfigUpdate() {
    if (!_suppressNextRuntimeConfigUpdate) {
      return false;
    }
    _suppressNextRuntimeConfigUpdate = false;
    return true;
  }

  void syncPatchClashConfigFromRuntime(ClashConfig patchConfig) {
    if (_runtimeConfigListenerReady) {
      _suppressNextRuntimeConfigUpdate = true;
    }
    _ref
        .read(patchClashConfigProvider.notifier)
        .updateState((state) => patchConfig);
    if (patchConfig.mode == Mode.global) {
      updateCurrentGroupName(GroupName.GLOBAL.name);
    }
    addCheckIpNumDebounce();
  }

  Future<void> addProfile(Profile profile) async {
    _ref.read(profilesProvider.notifier).setProfile(profile);
    if (_ref.read(currentProfileIdProvider) != null) return;
    _ref.read(currentProfileIdProvider.notifier).value = profile.id;
    applyProfileDebounce(silence: true);
  }

  Future<void> deleteProfile(String id) async {
    _ref.read(profilesProvider.notifier).deleteProfileById(id);
    clearEffect(id);
    if (globalState.config.currentProfileId == id) {
      final profiles = globalState.config.profiles;
      final currentProfileId = _ref.read(currentProfileIdProvider.notifier);
      if (profiles.isNotEmpty) {
        final updateId = profiles.first.id;
        currentProfileId.value = updateId;
      } else {
        currentProfileId.value = null;
        updateStatus(false);
      }
    }
  }

  Future<void> updateProviders() async {
    _ref.read(providersProvider.notifier).value =
        await clashCore.getExternalProviders();
  }

  Future<void> updateLocalIp() async {
    _ref.read(localIpProvider.notifier).value = null;
    await Future.delayed(commonDuration);
    _ref.read(localIpProvider.notifier).value = await utils.getLocalIpAddress();
  }

  void _applyProductCustomization(Profile profile,
      {required bool isNewProfile}) {
    if (profile.providerHeaders.isEmpty) {
      return;
    }

    final appSetting = _ref.read(appSettingProvider);
    final patch =
        ProductProviderAdvisory.fromProfile(profile).customization.buildPatch(
              isNewProfile: isNewProfile,
              appSetting: appSetting,
              themeProps: _ref.read(themeSettingProvider),
              proxiesStyle: _ref.read(proxiesStyleSettingProvider),
              overrideProviderSettings: appSetting.overrideProviderSettings,
            );
    if (patch.isEmpty) {
      return;
    }

    if (patch.appSetting != null) {
      _ref
          .read(appSettingProvider.notifier)
          .updateState((_) => patch.appSetting!);
    }
    if (patch.themeProps != null) {
      _ref
          .read(themeSettingProvider.notifier)
          .updateState((_) => patch.themeProps!);
      savePreferencesDebounce();
    }
    if (patch.proxiesStyle != null) {
      _ref
          .read(proxiesStyleSettingProvider.notifier)
          .updateState((_) => patch.proxiesStyle!);
    }
  }

  Future<void> updateProfile(Profile profile) async {
    _ref
        .read(profilesProvider.notifier)
        .setProfile(profile.copyWith(isUpdating: true));
    try {
      final prefs = await SharedPreferences.getInstance();
      final shouldSend = prefs.getBool('sendDeviceHeaders') ?? true;
      final newProfile = await profile.update(shouldSendHeaders: shouldSend);

      final mergedHeaders = ProductProviderAdvisory.mergeForRefresh(
        previous: profile.providerHeaders,
        incoming: newProfile.providerHeaders,
      );
      final mergedProfile = newProfile.copyWith(
        providerHeaders: mergedHeaders,
        isUpdating: false,
      );

      _applyProductCustomization(mergedProfile, isNewProfile: false);
      _showProductNotices(mergedProfile);

      _ref.read(profilesProvider.notifier).setProfile(mergedProfile);

      if (profile.id == _ref.read(currentProfileIdProvider)) {
        applyProfileDebounce(silence: true);
      }

      // Check subscription expiration and show notification if needed
      unawaited(
        SubscriptionNotificationService.checkAndNotify(mergedProfile)
            .catchError((
          e,
        ) {
          commonPrint.log("Error checking subscription: $e");
        }),
      );
    } catch (e) {
      _ref
          .read(profilesProvider.notifier)
          .setProfile(profile.copyWith(isUpdating: false));
      rethrow;
    }
  }

  void _showHwidNotSupportedNotice() {
    globalState.showMessage(
      title: 'HWID',
      message: TextSpan(text: appLocalizations.hwidNotSupported),
      cancelable: false,
    );
  }

  void _showProductNotices(Profile profile) {
    final advisory = ProductProviderAdvisory.fromProfile(profile);
    if (advisory.notices.hwidLimitReached && advisory.display.hasAnnouncement) {
      _showHwidLimitNotice(
        advisory.display.announcement,
        advisory.display.supportUrlOrNull,
      );
    }
    if (advisory.notices.hwidNotSupported) {
      _showHwidNotSupportedNotice();
    }
  }

  void _showHwidLimitNotice(String announceText, String? supportUrl) {
    if (announceText.isEmpty) {
      return;
    }

    final actions = <Widget>[];

    if (supportUrl != null && supportUrl.isNotEmpty) {
      actions.add(
        TextButton(
          onPressed: () {
            Navigator.of(context).pop();
            globalState.openUrl(supportUrl);
          },
          child: Text(appLocalizations.support),
        ),
      );
    }

    actions.add(
      TextButton(
        onPressed: () {
          Navigator.of(context).pop();
        },
        child: Text(appLocalizations.confirm),
      ),
    );

    globalState.showCommonDialog(
      child: CommonDialog(
        title: appLocalizations.tip,
        actions: actions,
        child: Container(
          width: 300,
          constraints: const BoxConstraints(maxHeight: 200),
          child: SingleChildScrollView(
            child: SelectableText(
              announceText,
              style: const TextStyle(overflow: TextOverflow.visible),
            ),
          ),
        ),
      ),
    );
  }

  void setProfile(Profile profile) {
    _ref.read(profilesProvider.notifier).setProfile(profile);
  }

  void setProfileAndAutoApply(Profile profile) {
    _ref.read(profilesProvider.notifier).setProfile(profile);
    if (profile.id == _ref.read(currentProfileIdProvider)) {
      applyProfileDebounce(silence: true);
    }
  }

  void setProfiles(List<Profile> profiles) {
    _ref.read(profilesProvider.notifier).value = profiles;
  }

  void addLog(Log log) {
    _ref.read(logsProvider).add(log);
  }

  void updateOrAddHotKeyAction(HotKeyAction hotKeyAction) {
    final hotKeyActions = _ref.read(hotKeyActionsProvider);
    final index = hotKeyActions.indexWhere(
      (item) => item.action == hotKeyAction.action,
    );
    if (index == -1) {
      _ref.read(hotKeyActionsProvider.notifier).value = List.from(hotKeyActions)
        ..add(hotKeyAction);
    } else {
      _ref.read(hotKeyActionsProvider.notifier).value = List.from(hotKeyActions)
        ..[index] = hotKeyAction;
    }

    _ref.read(hotKeyActionsProvider.notifier).value = index == -1
        ? (List.from(hotKeyActions)..add(hotKeyAction))
        : (List.from(hotKeyActions)..[index] = hotKeyAction);
  }

  List<Group> getCurrentGroups() =>
      _ref.read(currentGroupsStateProvider.select((state) => state.value));

  String getRealTestUrl(String? url) => _ref.read(getRealTestUrlProvider(url));

  int getProxiesColumns() => _ref.read(getProxiesColumnsProvider);

  dynamic addSortNum() => _ref.read(sortNumProvider.notifier).add();

  String? getCurrentGroupName() {
    final currentGroupName = _ref.read(
      currentProfileProvider.select((state) => state?.currentGroupName),
    );
    return currentGroupName;
  }

  ProxyCardState getProxyCardState(proxyName) =>
      _ref.read(getProxyCardStateProvider(proxyName));

  String? getSelectedProxyName(groupName) =>
      _ref.read(getSelectedProxyNameProvider(groupName));

  void updateCurrentGroupName(String groupName) {
    final profile = _ref.read(currentProfileProvider);
    if (profile == null || profile.currentGroupName == groupName) {
      return;
    }
    setProfile(profile.copyWith(currentGroupName: groupName));
  }

  Future<void> updateClashConfig() async {
    final commonScaffoldState = globalState.homeScaffoldKey.currentState;
    if (commonScaffoldState?.mounted != true) return;
    await commonScaffoldState?.loadingRun(() async {
      await _updateClashConfig();
    });
  }

  Future<void> _updateClashConfig() async {
    final securedPatchConfig = globalState.securePatchConfig(
      patchConfig: _ref.read(patchClashConfigProvider),
    );
    if (securedPatchConfig != _ref.read(patchClashConfigProvider)) {
      syncPatchClashConfigFromRuntime(securedPatchConfig);
    }

    final updated = await globalState.engineManager.updateConfig(
      globalState.buildRuntimeUpdateParams(
        patchConfig: securedPatchConfig,
      ),
      resolveTunAccess: _resolveTunAccess,
      coldStartPatchConfig: _buildColdStartPatchConfig(
        securedPatchConfig,
      ),
    );
    if (!updated) {
      return;
    }
  }

  Future<ResolvedTunAccess> _resolveTunAccess({
    required bool requestedTunEnable,
  }) async {
    final realTunEnable = _ref.read(realTunEnableProvider);
    return productServices.accessControl.resolveRuntimeAccess(
      requestedTunEnable: requestedTunEnable,
      realTunEnable: realTunEnable,
      onAuthorizeRestart: restartCore,
      onResolvedTunEnable: (value) {
        _ref.read(realTunEnableProvider.notifier).value = value;
      },
    );
  }

  Future<bool> setupClashConfig() async {
    final commonScaffoldState = globalState.homeScaffoldKey.currentState;
    if (commonScaffoldState?.mounted != true) return false;
    return await commonScaffoldState?.loadingRun(() async {
          return _setupClashConfig();
        }) ??
        false;
  }

  EngineRuntimePlanRequest _buildRuntimePlanRequest({
    required ClashConfig patchConfig,
    bool refreshProfile = true,
  }) =>
      EngineRuntimePlanRequest(
        patchConfig: patchConfig,
        refreshProfile: refreshProfile
            ? () async {
                await _ref.read(currentProfileProvider)?.checkAndUpdate();
              }
            : null,
        resolveTunAccess: _resolveTunAccess,
        onPatchConfigResolved: (resolvedPatchConfig) {
          _ref
              .read(patchClashConfigProvider.notifier)
              .updateState((state) => resolvedPatchConfig);
        },
      );

  ClashConfig _buildColdStartPatchConfig(ClashConfig patchConfig) =>
      patchConfig.copyWith.tun(enable: false);

  Future<bool> _setupClashConfig() async {
    final appliedRuntimePlan = await globalState.engineManager.setupRuntimePlan(
      _buildRuntimePlanRequest(
        patchConfig: _ref.read(patchClashConfigProvider),
      ),
      coldStartPatchConfig: _buildColdStartPatchConfig(
        _ref.read(patchClashConfigProvider),
      ),
    );
    if (appliedRuntimePlan == null) {
      return false;
    }

    lastProfileModified = await _ref.read(
      currentProfileProvider.select((state) => state?.profileLastModified),
    );
    return true;
  }

  Future _applyProfile() async {
    clashCore.requestGc();
    final isConfigured = await setupClashConfig();
    if (!isConfigured) {
      return;
    }
    await updateGroups();
    await updateProviders();
    await syncAndroidForegroundNotification();
  }

  Future applyProfile({bool silence = false}) async {
    if (silence) {
      await _applyProfile();
    } else {
      final commonScaffoldState = globalState.homeScaffoldKey.currentState;
      if (commonScaffoldState?.mounted != true) return;
      await commonScaffoldState?.loadingRun(() async {
        await _applyProfile();
      });
    }
    addCheckIpNumDebounce();
  }

  void handleChangeProfile() {
    _ref.read(delayDataSourceProvider.notifier).value = {};

    final currentProfileId = _ref.read(currentProfileIdProvider);
    if (currentProfileId != null) {
      final profiles = _ref.read(profilesProvider);
      var currentProfile = profiles.firstWhere(
        (p) => p.id == currentProfileId,
        orElse: () => profiles.first,
      );

      if (currentProfile.providerHeaders.isNotEmpty) {
        _applyProductCustomization(currentProfile, isNewProfile: false);
      }
    }

    applyProfile();
    _ref.read(logsProvider.notifier).value = FixedList(500);
    _ref.read(requestsProvider.notifier).value = FixedList(500);
    globalState.cacheHeightMap = {};
    globalState.cacheScrollPosition = {};
  }

  void updateBrightness(Brightness brightness) {
    _ref.read(appBrightnessProvider.notifier).value = brightness;
  }

  Future<void> autoUpdateProfiles() async {
    for (final profile in _ref.read(profilesProvider)) {
      if (!profile.autoUpdate) continue;
      final isNotNeedUpdate =
          profile.lastUpdateDate?.add(profile.autoUpdateDuration).isBeforeNow;
      if (isNotNeedUpdate == false || profile.type == ProfileType.file) {
        continue;
      }
      try {
        await updateProfile(profile);
      } catch (e) {
        commonPrint.log(e.toString());
      }
    }
  }

  /// Updates subscription info for the current profile on app startup.
  /// This ensures the subscription info is always up-to-date when the app launches.
  Future<void> _updateCurrentProfileSubscription() async {
    try {
      final currentProfileId = _ref.read(currentProfileIdProvider);
      commonPrint.log(
        "_updateCurrentProfileSubscription: currentProfileId = $currentProfileId",
      );
      if (currentProfileId == null) {
        commonPrint.log(
          "_updateCurrentProfileSubscription: No current profile selected, skipping",
        );
        return;
      }

      final profiles = _ref.read(profilesProvider);
      commonPrint.log(
        "_updateCurrentProfileSubscription: profiles count = ${profiles.length}",
      );

      final currentProfile =
          profiles.where((p) => p.id == currentProfileId).firstOrNull;
      if (currentProfile == null) {
        commonPrint.log(
          "_updateCurrentProfileSubscription: Profile not found in list, skipping",
        );
        return;
      }

      if (currentProfile.type == ProfileType.file) {
        commonPrint.log(
          "_updateCurrentProfileSubscription: Profile is file type, skipping",
        );
        return;
      }

      commonPrint.log(
        "Updating subscription info for current profile '${currentProfile.label}' on startup...",
      );
      if (currentProfile.autoUpdate) {
        await updateProfile(currentProfile);
        commonPrint.log("Subscription info updated successfully");
      } else {
        commonPrint.log(
          "Auto-update disabled for current profile, skipping startup update",
        );
      }
    } catch (e, stackTrace) {
      commonPrint.log("Failed to update subscription info on startup: $e");
      commonPrint.log("Stack trace: $stackTrace");
    }
  }

  Future<void> updateGroups() async {
    try {
      final newGroups = await retry(
        task: () async => clashCore.getProxiesGroups(),
        retryIf: (res) => res.isEmpty,
      );

      if (newGroups.isNotEmpty) {
        _ref.read(groupsProvider.notifier).value = newGroups;
        _ref.read(versionProvider.notifier).value =
            _ref.read(versionProvider) + 1;
      } else {
        commonPrint.log(
          "updateGroups: received empty groups, keeping old state",
        );
      }
    } catch (e) {
      commonPrint.log("updateGroups error: $e, keeping old groups");
    }
  }

  Future<void> updateProfiles() async {
    for (final profile in _ref.read(profilesProvider)) {
      if (profile.type == ProfileType.file) {
        continue;
      }
      await updateProfile(profile);
    }
  }

  Future<void> savePreferences() async {
    commonPrint.log("save preferences");
    await preferences.saveConfig(globalState.config);
  }

  Future<void> changeProxy({
    required String groupName,
    required String proxyName,
  }) async {
    await clashCore.changeProxy(
      ChangeProxyParams(groupName: groupName, proxyName: proxyName),
    );
    if (_ref.read(appSettingProvider).closeConnections) {
      clashCore.closeConnections();
    }
    addCheckIpNumDebounce();
  }

  Future<void> handleBackOrExit() async {
    if (_ref.read(backBlockProvider)) {
      return;
    }
    if (_ref.read(appSettingProvider).minimizeOnExit) {
      if (system.isDesktop) {
        savePreferencesDebounce();
      }
      await system.back();
    } else {
      await handleExit();
    }
  }

  void backBlock() {
    _ref.read(backBlockProvider.notifier).value = true;
  }

  void unBackBlock() {
    _ref.read(backBlockProvider.notifier).value = false;
  }

  Future<void> handleExit() async {
    Future.delayed(commonDuration, system.exit);
    try {
      await savePreferences();
      await system.setMacOSDns(true);
      await proxy?.stopProxy();
      await clashCore.shutdown();
      await clashService?.destroy();
    } finally {
      system.exit();
    }
  }

  Future<void> handleRestart() async {
    commonPrint.log("Starting application restart...");

    if (Platform.isLinux || Platform.isMacOS || Platform.isWindows) {
      final executablePath = Platform.resolvedExecutable;
      commonPrint.log("Launching new process: $executablePath");

      try {
        await Process.start(
          executablePath,
          [],
          mode: ProcessStartMode.detached,
        );
        commonPrint.log("New process started, exiting old process...");
      } catch (e) {
        commonPrint.log("Failed to start new process: $e");
        return;
      }
    }

    system.exit();
  }

  Future handleClear() async {
    try {
      // Stop proxy/VPN first
      await globalState.engineManager.stop();
      await onRuntimeStopped();
      commonPrint.log("stopped proxy/VPN");

      // Stop core
      await clashCore.shutdown();
      commonPrint.log("shutdown core");

      // Wait a bit for all file handles to close
      await Future.delayed(const Duration(milliseconds: 500));

      // Clear preferences
      await preferences.clearPreferences();
      commonPrint.log("cleared preferences");

      // Get paths
      final homePath = await appPath.homeDirPath;
      final profilesPath = await appPath.profilesPath;

      // Delete profiles directory
      final profilesDir = Directory(profilesPath);
      if (await profilesDir.exists()) {
        try {
          await profilesDir.delete(recursive: true);
          commonPrint.log("deleted profiles directory");
        } catch (e) {
          commonPrint.log("failed to delete profiles directory: $e");
        }
      }

      // Delete cache and temporary files
      final filesToDelete = [
        'cache.db',
        'libCachedImageData.json',
        'FlClashX.lock',
      ];

      for (final fileName in filesToDelete) {
        final file = File(join(homePath, fileName));
        if (await file.exists()) {
          try {
            await file.delete();
            commonPrint.log("deleted $fileName");
          } catch (e) {
            commonPrint.log("failed to delete $fileName: $e");
          }
        }
      }

      // Reset config
      globalState.config = const Config(themeProps: defaultThemeProps);

      commonPrint.log("handleClear completed");

      // Close file logger to release file handles (MUST be last step)
      await fileLogger.dispose();
    } catch (e) {
      commonPrint.log("handleClear error: $e");
      await fileLogger.dispose();
      rethrow;
    }
  }

  Future<void> autoCheckUpdate() async {
    await productServices.appUpdate.autoCheck(
      enabled: _ref.read(appSettingProvider).autoCheckUpdate,
    );
  }

  Future<void> _handlePreference() async {
    if (await preferences.isInit) {
      return;
    }
    final res = await globalState.showMessage(
      title: appLocalizations.tip,
      message: TextSpan(text: appLocalizations.cacheCorrupt),
    );
    if (res == true) {
      final file = File(await appPath.sharedPreferencesPath);
      final isExists = await file.exists();
      if (isExists) {
        await file.delete();
      }
    }
    await handleExit();
  }

  Future<bool> _initCore() => globalState.engineManager.initializeCore(
        runtimePlanRequest: _buildRuntimePlanRequest(
          patchConfig: _ref.read(patchClashConfigProvider),
        ),
        coldStartPatchConfig: _buildColdStartPatchConfig(
          _ref.read(patchClashConfigProvider),
        ),
      );

  Future<void> init() async {
    FlutterError.onError = (details) {
      commonPrint.log(details.stack.toString());
    };
    updateTray(true);
    try {
      await _initCore();
    } catch (e) {
      commonPrint.log("initCore failed (will retry on profile change): $e");
    }
    await _initStatus();
    autoLaunch?.updateStatus(_ref.read(appSettingProvider).autoLaunch);
    // Delay subscription update to ensure network is ready after app initialization
    Future.delayed(
      const Duration(seconds: 1),
      _updateCurrentProfileSubscription,
    );
    autoUpdateProfiles();
    autoCheckUpdate();
    if (!Platform.isMacOS) {
      if (!_ref.read(appSettingProvider).silentLaunch) {
        window?.show();
      } else {
        window?.hide();
      }
    }
    await _handlePreference();
    await _handlerDisclaimer();
    _ref.read(initProvider.notifier).value = true;
  }

  Future<void> _initStatus() async {
    if (Platform.isAndroid) {
      await globalState.syncRuntimeStartTime();
    }
    final status = globalState.isStart == true
        ? true
        : _ref.read(appSettingProvider).autoRun;

    await updateStatus(status);
    if (!status) {
      addCheckIpNumDebounce();
    }
  }

  void setDelay(Delay delay) {
    _ref.read(delayDataSourceProvider.notifier).setDelay(delay);
  }

  void toPage(PageLabel pageLabel) {
    _ref.read(currentPageLabelProvider.notifier).value = pageLabel;
  }

  void toProfiles() {
    toPage(PageLabel.profiles);
  }

  void initLink() {
    linkManager.initAppLinksListen((url) async {
      final res = await globalState.showMessage(
        title: "${appLocalizations.add} ${appLocalizations.profile}",
        message: TextSpan(
          children: [
            TextSpan(text: appLocalizations.doYouWantToPass),
            TextSpan(
              text: " $url",
              style: TextStyle(
                color: Theme.of(context).colorScheme.primary,
                decoration: TextDecoration.underline,
                decorationColor: Theme.of(context).colorScheme.primary,
              ),
            ),
          ],
        ),
      );

      if (res != true) {
        return;
      }
      addProfileFormURL(url);
    });
  }

  Future<bool> showDisclaimer() async =>
      await globalState.showCommonDialog<bool>(
        dismissible: false,
        child: CommonDialog(
          title: appLocalizations.disclaimer,
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(context).pop<bool>(false);
              },
              child: Text(appLocalizations.exit),
            ),
            TextButton(
              onPressed: () {
                _ref.read(appSettingProvider.notifier).updateState(
                      (state) => state.copyWith(disclaimerAccepted: true),
                    );
                Navigator.of(context).pop<bool>(true);
              },
              child: Text(appLocalizations.agree),
            ),
          ],
          child: SelectableText(appLocalizations.disclaimerDesc),
        ),
      ) ??
      false;

  Future<void> _handlerDisclaimer() async {
    if (_ref.read(appSettingProvider).disclaimerAccepted) {
      return;
    }
    final isDisclaimerAccepted = await showDisclaimer();
    if (!isDisclaimerAccepted) {
      await handleExit();
    }
    return;
  }

  Future<void> addProfileFormURL(String url) async {
    if (globalState.navigatorKey.currentState?.canPop() ?? false) {
      globalState.navigatorKey.currentState?.popUntil((route) => route.isFirst);
    }
    final commonScaffoldState = globalState.homeScaffoldKey.currentState;
    if (commonScaffoldState?.mounted != true) return;

    try {
      final profile = await commonScaffoldState?.loadingRun<Profile>(() async {
        final prefs = await SharedPreferences.getInstance();
        final shouldSend = prefs.getBool('sendDeviceHeaders') ?? true;
        return Profile.normal(url: url).update(shouldSendHeaders: shouldSend);
      }, title: "${appLocalizations.add}${appLocalizations.profile}");

      if (profile != null) {
        _applyProductCustomization(profile, isNewProfile: true);
        _showProductNotices(profile);

        await addProfile(profile);
      }
    } catch (err) {
      commonPrint.log('Add Profile Failed: $err');
      unawaited(
        globalState.showMessage(message: TextSpan(text: err.toString())),
      );
    }
  }

  Future<Null> addProfileFormFile() async {
    final platformFile = await globalState.safeRun(picker.pickerFile);
    final bytes = platformFile?.bytes;
    if (bytes == null) {
      return null;
    }
    if (!context.mounted) return;
    globalState.navigatorKey.currentState?.popUntil((route) => route.isFirst);
    toPage(PageLabel.dashboard);
    final commonScaffoldState = globalState.homeScaffoldKey.currentState;
    if (commonScaffoldState?.mounted != true) return;
    final profile = await commonScaffoldState?.loadingRun<Profile?>(() async {
      await Future.delayed(const Duration(milliseconds: 300));
      return Profile.normal(label: platformFile?.name).saveFile(bytes);
    }, title: "${appLocalizations.add}${appLocalizations.profile}");
    if (profile != null) {
      await addProfile(profile);
    }
  }

  Future<void> addProfileFormQrCode() async {
    final url = await globalState.safeRun(picker.pickerConfigQRCode);
    if (url == null) return;
    addProfileFormURL(url);
  }

  void updateViewSize(Size size) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _ref.read(viewSizeProvider.notifier).value = size;
    });
  }

  void setProvider(ExternalProvider? provider) {
    _ref.read(providersProvider.notifier).setProvider(provider);
  }

  List<Proxy> _sortOfName(List<Proxy> proxies) => List.of(proxies)
    ..sort(
      (a, b) =>
          utils.sortByChar(utils.getPinyin(a.name), utils.getPinyin(b.name)),
    );

  List<Proxy> _sortOfDelay({required List<Proxy> proxies, String? testUrl}) =>
      List.of(proxies)
        ..sort((a, b) {
          final aDelay = _ref.read(
            getDelayProvider(proxyName: a.name, testUrl: testUrl),
          );
          final bDelay = _ref.read(
            getDelayProvider(proxyName: b.name, testUrl: testUrl),
          );
          if (aDelay == null && bDelay == null) {
            return 0;
          }
          if (aDelay == null || aDelay == -1) {
            return 1;
          }
          if (bDelay == null || bDelay == -1) {
            return -1;
          }
          return aDelay.compareTo(bDelay);
        });

  List<Proxy> getSortProxies(List<Proxy> proxies, [String? url]) =>
      switch (_ref.read(proxiesStyleSettingProvider).sortType) {
        ProxiesSortType.none => proxies,
        ProxiesSortType.delay => _sortOfDelay(proxies: proxies, testUrl: url),
        ProxiesSortType.name => _sortOfName(proxies),
      };

  Future<Null> clearEffect(String profileId) async {
    final profilePath = await appPath.getProfilePath(profileId);
    final providersDirPath = await appPath.getProvidersDirPath(profileId);
    return Isolate.run(() async {
      final profileFile = File(profilePath);
      final isExists = await profileFile.exists();
      if (isExists) {
        unawaited(profileFile.delete(recursive: true));
      }
      final providersFileDir = File(providersDirPath);
      final providersFileIsExists = await providersFileDir.exists();
      if (providersFileIsExists) {
        unawaited(providersFileDir.delete(recursive: true));
      }
    });
  }

  void updateTun() {
    _ref
        .read(patchClashConfigProvider.notifier)
        .updateState((state) => state.copyWith.tun(enable: !state.tun.enable));
  }

  void updateSystemProxy() {
    _ref.read(networkSettingProvider.notifier).updateState(
          (state) => state.copyWith(systemProxy: !state.systemProxy),
        );
  }

  void updateStart() {
    updateStatus(!_ref.read(runTimeProvider.notifier).isStart);
  }

  void updateCurrentSelectedMap(String groupName, String proxyName) {
    final currentProfile = _ref.read(currentProfileProvider);
    if (currentProfile != null &&
        currentProfile.selectedMap[groupName] != proxyName) {
      final selectedMap = Map<String, String>.from(currentProfile.selectedMap)
        ..[groupName] = proxyName;
      _ref
          .read(profilesProvider.notifier)
          .setProfile(currentProfile.copyWith(selectedMap: selectedMap));
    }
  }

  void updateCurrentUnfoldSet(Set<String> value) {
    final currentProfile = _ref.read(currentProfileProvider);
    if (currentProfile == null) {
      return;
    }
    _ref
        .read(profilesProvider.notifier)
        .setProfile(currentProfile.copyWith(unfoldSet: value));
  }

  void changeMode(Mode mode) {
    _ref
        .read(patchClashConfigProvider.notifier)
        .updateState((state) => state.copyWith(mode: mode));
    if (mode == Mode.global) {
      updateCurrentGroupName(GroupName.GLOBAL.name);
    }
    addCheckIpNumDebounce();
  }

  void updateAutoLaunch() {
    _ref
        .read(appSettingProvider.notifier)
        .updateState((state) => state.copyWith(autoLaunch: !state.autoLaunch));
  }

  void updateTheme(ThemeProps themeProps) {
    _ref.read(themeSettingProvider.notifier).updateState((_) => themeProps);
  }

  Future<void> updateVisible() async {
    if (Platform.isMacOS) return;

    final visible = await window?.isVisible;
    if (visible != null && !visible) {
      window?.show();
    } else {
      window?.hide();
    }
  }

  void updateMode() {
    _ref.read(patchClashConfigProvider.notifier).updateState((state) {
      final index = Mode.values.indexWhere((item) => item == state.mode);
      if (index == -1) {
        return null;
      }
      final nextIndex = index + 1 > Mode.values.length - 1 ? 0 : index + 1;
      return state.copyWith(mode: Mode.values[nextIndex]);
    });
  }

  Future<void> handleAddOrUpdate(WidgetRef ref, [Rule? rule]) async {
    final res = await globalState.showCommonDialog<Rule>(
      child: AddRuleDialog(
        rule: rule,
        snippet: ref.read(
          profileOverrideStateProvider.select((state) => state.snippet!),
        ),
      ),
    );
    if (res == null) {
      return;
    }
    ref.read(profileOverrideStateProvider.notifier).updateState((state) {
      final model = state.copyWith.overrideData!(
        rule: state.overrideData!.rule.updateRules((rules) {
          final index = rules.indexWhere((item) => item.id == res.id);
          if (index == -1) {
            return List.from([res, ...rules]);
          }
          return List.from(rules)..[index] = res;
        }),
      );
      return model;
    });
  }

  Future<bool> exportLogs() async {
    final logsRaw = _ref.read(logsProvider).list.map((item) => item.toString());
    final data = await Isolate.run<List<int>>(() async {
      final logsRawString = logsRaw.join("\n");
      return utf8.encode(logsRawString);
    });
    return await picker.saveFile(utils.logFile, Uint8List.fromList(data)) !=
        null;
  }

  Future<List<int>> backupData() async {
    final homeDirPath = await appPath.homeDirPath;
    final profilesPath = await appPath.profilesPath;
    final configJson = globalState.config.toJson();
    return Isolate.run<List<int>>(() async {
      final archive = Archive();
      archive.addJson("config.json", configJson);
      archive.addDirectoryToArchive(profilesPath, homeDirPath);
      final zipEncoder = ZipEncoder();
      return zipEncoder.encode(archive);
    });
  }

  Future<void> updateTray([bool focus = false]) async {
    tray.update(trayState: _ref.read(trayStateProvider));
  }

  Future<void> recoveryData(
    List<int> data,
    RecoveryOption recoveryOption,
  ) async {
    final archive = await Isolate.run<Archive>(() {
      final zipDecoder = ZipDecoder();
      return zipDecoder.decodeBytes(data);
    });
    final homeDirPath = await appPath.homeDirPath;
    final configs =
        archive.files.where((item) => item.name.endsWith(".json")).toList();
    final profiles = archive.files.where(
      (item) => !item.name.endsWith(".json"),
    );
    final configIndex = configs.indexWhere(
      (config) => config.name == "config.json",
    );
    if (configIndex == -1) throw "invalid backup file";
    final configFile = configs[configIndex];
    var tempConfig = Config.compatibleFromJson(
      json.decode(utf8.decode(configFile.content)),
    );
    for (final profile in profiles) {
      if (!profile.isFile) continue;
      final filePath = join(homeDirPath, profile.name);
      final file = File(filePath);
      await file.create(recursive: true);
      await file.writeAsBytes(profile.content);
    }
    final clashConfigIndex = configs.indexWhere(
      (config) => config.name == "clashConfig.json",
    );
    if (clashConfigIndex != -1) {
      final clashConfigFile = configs[clashConfigIndex];
      tempConfig = tempConfig.copyWith(
        patchClashConfig: ClashConfig.fromJson(
          json.decode(utf8.decode(clashConfigFile.content)),
        ),
      );
    }
    _recovery(tempConfig, recoveryOption);
  }

  void _recovery(Config config, RecoveryOption recoveryOption) {
    final recoveryStrategy = _ref.read(
      appSettingProvider.select((state) => state.recoveryStrategy),
    );
    final profiles = config.profiles;
    if (recoveryStrategy == RecoveryStrategy.override) {
      _ref.read(profilesProvider.notifier).value = profiles;
    } else {
      for (final profile in profiles) {
        _ref.read(profilesProvider.notifier).setProfile(profile);
      }
    }
    final onlyProfiles = recoveryOption == RecoveryOption.onlyProfiles;
    if (!onlyProfiles) {
      _ref.read(patchClashConfigProvider.notifier).value =
          config.patchClashConfig;
      _ref.read(appSettingProvider.notifier).value = config.appSetting;
      _ref.read(currentProfileIdProvider.notifier).value =
          config.currentProfileId;
      _ref.read(appDAVSettingProvider.notifier).value = config.dav;
      _ref.read(themeSettingProvider.notifier).value = config.themeProps;
      _ref.read(windowSettingProvider.notifier).value = config.windowProps;
      _ref.read(vpnSettingProvider.notifier).value = config.vpnProps;
      _ref.read(proxiesStyleSettingProvider.notifier).value =
          config.proxiesStyle;
      _ref.read(overrideDnsProvider.notifier).value = config.overrideDns;
      _ref.read(networkSettingProvider.notifier).value = config.networkProps;
      _ref.read(hotKeyActionsProvider.notifier).value = config.hotKeyActions;
      _ref.read(scriptStateProvider.notifier).value = config.scriptProps;
    }
    final currentProfile = _ref.read(currentProfileProvider);
    if (currentProfile == null) {
      _ref.read(currentProfileIdProvider.notifier).value = profiles.first.id;
    }
    savePreferencesDebounce();
  }
}
