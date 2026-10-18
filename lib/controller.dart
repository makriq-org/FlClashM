import 'dart:async';
import 'dart:io';

import 'package:flclashx/clash/clash.dart';
import 'package:flclashx/enum/enum.dart';
import 'package:flclashx/providers/providers.dart';
import 'package:flclashx/state.dart';
import 'package:flclashx/widgets/dialog.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'common/common.dart';
import 'models/models.dart';
import 'product/backend/backend.dart';
import 'product/diagnostics/product_diagnostics.dart';
import 'product/services/product_services.dart';
import 'product/subscription/product_subscription.dart';
import 'views/profiles/override_profile.dart';

class AppController {
  AppController(this.context, WidgetRef ref) : _ref = ref;
  final BuildContext context;
  final WidgetRef _ref;
  DateTime? _lastRuntimeGroupsSync;

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
    await productServices.androidShell.syncForegroundNotification(
      profile: globalState.config.currentProfile,
      groups: _ref.read(groupsProvider),
    );
  }

  Future<void> syncAndroidForegroundNotificationForProxyChange({
    required String groupName,
    required String proxyName,
  }) async {
    await productServices.androidShell.syncForegroundNotificationForProxyChange(
      profile: globalState.config.currentProfile,
      groupName: groupName,
      proxyName: proxyName,
    );
  }

  Future<void> restartCore() async {
    await globalState.flushEdits();
    await backendClient.command('runtime.restart');
    await syncVpnStateOnResume();
  }

  Future<void> updateStatus(bool isStart) async {
    try {
      await _updateStatus(isStart);
    } catch (e, stackTrace) {
      commonPrint.log("updateStatus failed: $e\n$stackTrace");
      await StatusBarManager.updateIcon(isConnected: false);
      if (globalState.homeScaffoldKey.currentState?.mounted ?? false) {
        // Отчёт, а не вопрос: ответа не ждём, текст дублируется в логи.
        globalState.showNotifier(e.toString());
      }
    }
  }

  Future<void> _updateStatus(bool isStart) async {
    if (isStart) {
      await globalState.flushEdits();
      if (globalState.config.vpnProps.enable &&
          !(await clashLib!.requestVpnPermission())) {
        return;
      }
    }
    await backendClient.command(isStart ? 'runtime.start' : 'runtime.stop');
    await syncVpnStateOnResume();
  }

  Timer? _runTimeTimer;
  bool _trafficPending = false;
  bool? _projectedRunning;

  void startRunTimeTimer() {
    stopRunTimeTimer();
    updateRunTime();
    _runTimeTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      updateRunTime();
      if (!_trafficPending) {
        _trafficPending = true;
        unawaited(updateTraffic().whenComplete(() => _trafficPending = false));
      }
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
    final trafficResults = await Future.wait([
      clashCore.getTraffic(),
      clashCore.getTotalTraffic(),
    ]);
    final traffic = trafficResults[0];
    final totalTraffic = trafficResults[1];
    _ref.read(trafficsProvider.notifier).addTraffic(traffic);
    final currentTotalTraffic = _ref.read(totalTrafficProvider);
    if (currentTotalTraffic.up.value != totalTraffic.up.value ||
        currentTotalTraffic.down.value != totalTraffic.down.value) {
      _ref.read(totalTrafficProvider.notifier).value = totalTraffic;
    }
    await _syncRuntimeGroupsForNotification();
  }

  Future<void> _syncRuntimeGroupsForNotification() async {
    if (!Platform.isAndroid || !_ref.read(runTimeProvider.notifier).isStart) {
      return;
    }
    final now = DateTime.now();
    final lastSync = _lastRuntimeGroupsSync;
    if (lastSync != null && now.difference(lastSync).inSeconds < 6) {
      return;
    }
    _lastRuntimeGroupsSync = now;
    await updateGroups(syncNotification: true);
  }

  void projectBackendConfig(Config next) {
    if (!context.mounted) return;
    _ref.read(profilesProvider.notifier).value = next.profiles;
    _ref.read(patchClashConfigProvider.notifier).value = next.patchClashConfig;
    _ref.read(appSettingProvider.notifier).value = next.appSetting;
    _ref.read(currentProfileIdProvider.notifier).value = next.currentProfileId;
    _ref.read(appDAVSettingProvider.notifier).value = next.dav;
    _ref.read(themeSettingProvider.notifier).value = next.themeProps;
    _ref.read(windowSettingProvider.notifier).value = next.windowProps;
    _ref.read(vpnSettingProvider.notifier).value = next.vpnProps;
    _ref.read(proxiesStyleSettingProvider.notifier).value = next.proxiesStyle;
    _ref.read(overrideDnsProvider.notifier).value = next.overrideDns;
    _ref.read(networkSettingProvider.notifier).value = next.networkProps;
    _ref.read(hotKeyActionsProvider.notifier).value = next.hotKeyActions;
    _ref.read(scriptStateProvider.notifier).value = next.scriptProps;
  }

  void projectBackendRuntime() {
    if (!context.mounted) return;
    final running = globalState.isStart;
    updateRunTime();
    if (_projectedRunning == running) return;
    _projectedRunning = running;
    unawaited(StatusBarManager.updateIcon(isConnected: running));
    if (running) {
      startRunTimeTimer();
    } else {
      stopRunTimeTimer();
      _ref.read(trafficsProvider.notifier).clear();
      _ref.read(totalTrafficProvider.notifier).value = Traffic();
    }
    updateGroupsDebounce();
  }

  void syncPatchClashConfigFromRuntime(ClashConfig patchConfig) {
    _ref
        .read(patchClashConfigProvider.notifier)
        .updateState((_) => patchConfig);
  }

  Future<void> addProfile(Profile profile) async {
    final shouldSelect = globalState.config.currentProfileId == null;
    if (shouldSelect)
      await backendClient.command('profile.select', {'profileId': profile.id});
    await backendClient.refresh();
    await updateGroups();
  }

  Future<void> deleteProfile(String id) async {
    await backendClient.command('profile.delete', {
      'profileId': id,
      'expectedRevision': backendClient.profileRevision(id),
    });
  }

  Future<void> updateProviders() async {
    final providers = await clashCore.getExternalProviders();
    if (context.mounted)
      _ref.read(providersProvider.notifier).value = providers;
  }

  Future<void> updateLocalIp() async {
    _ref.read(localIpProvider.notifier).value = null;
    await Future.delayed(commonDuration);
    final address = await utils.getLocalIpAddress();
    if (context.mounted) _ref.read(localIpProvider.notifier).value = address;
  }

  Future<void> updateProfile(Profile profile) async {
    await backendClient.command('subscription.refresh', {
      'profileId': profile.id,
    });
    final current = globalState.config.profiles.getProfile(profile.id);
    if (current != null) _showProductNotices(current);
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

  void _showHwidNotSupportedNotice() {
    globalState.showNotifier(appLocalizations.hwidNotSupported);
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

  /// Flip the core's external-controller API on/off for a zashboard session
  /// (see openZashboard / ZashboardWebViewPage). Reuses the same updateConfig
  /// path as the manual toggle, so the core brings the API listener up/down
  /// live. updateConfig does NOT recompute effectiveExternalController (that's
  /// the applyProfile path), so set it here too — the zashboard URL reads it.
  Future<void> setExternalControllerEnabled(bool enable) async {
    _ref
        .read(patchClashConfigProvider.notifier)
        .updateState(
          (state) => state.copyWith(
            externalController: enable
                ? ExternalControllerStatus.open
                : ExternalControllerStatus.close,
          ),
        );
    globalState.effectiveExternalController.value = enable
        ? ExternalControllerStatus.open.value
        : "";
    await updateClashConfig();
  }

  Future<void> _updateClashConfig() async {
    await globalState.flushEdits();
    await backendClient.refresh();
  }

  Future<bool> setupClashConfig() async {
    await _updateClashConfig();
    return true;
  }

  Future<void> applyProfile({bool silence = false}) async {
    await globalState.flushEdits();
    await backendClient.refresh();
    await updateGroups();
    await updateProviders();
    addCheckIpNumDebounce();
  }

  void handleChangeProfile() {
    _ref.read(delayDataSourceProvider.notifier).value = {};
    _ref.read(logsProvider.notifier).value = FixedList(maxLength);
    _ref.read(requestsProvider.notifier).value = FixedList(maxLength);
    globalState.cacheHeightMap = {};
    globalState.cacheScrollPosition = {};
    updateGroupsDebounce();
  }

  void updateBrightness(Brightness brightness) {
    _ref.read(appBrightnessProvider.notifier).value = brightness;
  }

  Future<void> updateGroups({bool syncNotification = false}) async {
    try {
      final newGroups = await retry(
        task: () async => clashCore.getProxiesGroups(),
        retryIf: (res) => res.isEmpty,
      );

      if (newGroups.isNotEmpty) {
        if (!listEquals(_ref.read(groupsProvider), newGroups)) {
          _ref.read(groupsProvider.notifier).value = newGroups;
          _ref.read(versionProvider.notifier).value =
              _ref.read(versionProvider) + 1;
        }
        if (syncNotification) {
          await syncAndroidForegroundNotification();
        }
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

  Future<void> savePreferences() => globalState.flushEdits();

  Future<void> changeProxy({
    required String groupName,
    required String proxyName,
  }) async {
    await backendClient.command('proxy.select', {
      'group': groupName,
      'proxy': proxyName,
      'reset': proxyName.isEmpty,
    });
    addCheckIpNumDebounce();
  }

  Future<void> handleBackOrExit() async {
    if (_ref.read(backBlockProvider)) {
      return;
    }
    // Android: the back gesture must never shut the core down while the tunnel
    // is up — the FGS + TUN are designed to outlive the UI, and handleExit()
    // would kill the executor under a live VPN icon (blackholed traffic).
    // Background the activity instead, regardless of minimizeOnExit.
    if (Platform.isAndroid && globalState.isStart) {
      await system.back();
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
    await savePreferences();
    await backendClient.detach();
    await clashLib?.destroy();
    system.exit();
  }

  Future<void> handleRestart() async {
    await handleExit();
  }

  Future<void> handleClear() async {
    await globalState.flushEdits();
    await backendClient.command('data.reset');
    await fileLogger.flush();
  }

  Future<void> autoCheckUpdate() async {
    final appSetting = _ref.read(appSettingProvider);
    await productServices.appUpdate.autoCheck(
      enabled: appSetting.autoCheckUpdate,
      includePrerelease: appSetting.includePrereleaseUpdates,
      skippedTagName: appSetting.skippedAppUpdateTagName,
      onSkipRelease: (tagName) async {
        _ref
            .read(appSettingProvider.notifier)
            .updateState(
              (state) => state.copyWith(skippedAppUpdateTagName: tagName),
            );
      },
    );
  }

  Future<void> init() async {
    await backendClient.refresh();
    globalState.projectBackend();
    if (globalState.config.appSetting.openLogs) {
      clashCore.startLog();
    } else {
      clashCore.stopLog();
    }
    _ref.read(initProvider.notifier).value = true;
    await updateGroups();
    await updateProviders();
    unawaited(autoCheckUpdate());
    await _handlerDisclaimer();
    final opened = await backendClient.openUI();
    if (opened['permissionRequired'] == true) {
      await updateStatus(true);
    }
  }

  Future<void> syncVpnStateOnResume() async {
    await backendClient.refresh();
    projectBackendRuntime();
    if (globalState.isStart) startRunTimeTimer();
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
                _ref
                    .read(appSettingProvider.notifier)
                    .updateState(
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
        return Profile.normal(
          url: url,
        ).update(validateConfig: globalState.validateProfileConfigText);
      }, title: "${appLocalizations.add}${appLocalizations.profile}");

      if (profile != null) {
        _showProductNotices(profile);

        await addProfile(profile);
      }
    } catch (err) {
      commonPrint.log('Add Profile Failed: $err');
      globalState.showNotifier(err.toString());
    }
  }

  Future<void> addProfileFromUrlForSync(String url) async {
    final profile = await Profile.normal(
      url: url,
    ).update(validateConfig: globalState.validateProfileConfigText);
    _showProductNotices(profile);
    await addProfile(profile);
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
      return Profile.normal(
        label: platformFile?.name,
      ).saveFile(bytes, validateConfig: globalState.validateProfileConfigText);
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
      List.of(proxies)..sort((a, b) {
        final aDelay = _ref.read(
          getDelayProvider(proxyName: a.name, testUrl: testUrl),
        );
        final bDelay = _ref.read(
          getDelayProvider(proxyName: b.name, testUrl: testUrl),
        );
        // null (untested) and -1 (failed) are equivalent "no delay"
        // sentinels: map both to the same rank so the comparator stays
        // antisymmetric (compare(a,b) == -compare(b,a)) and they sort to
        // the end together.
        if (aDelay == null || aDelay == -1) {
          return (bDelay == null || bDelay == -1) ? 0 : 1;
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

  void updateTun() {
    _ref
        .read(patchClashConfigProvider.notifier)
        .updateState((state) => state.copyWith.tun(enable: !state.tun.enable));
  }

  void updateSystemProxy() {
    _ref
        .read(networkSettingProvider.notifier)
        .updateState(
          (state) => state.copyWith(systemProxy: !state.systemProxy),
        );
  }

  void updateStart() {
    updateStatus(!_ref.read(runTimeProvider.notifier).isStart);
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
    await fileLogger.flush();
    final data = await productDiagnosticExporter.buildArchive(
      DiagnosticExportContext(
        homeDirectory: await appPath.homeDirPath,
        appVersion: globalState.packageInfo.version,
        buildNumber: globalState.packageInfo.buildNumber,
        appTag: globalState.appVersionTag,
        coreVersion: globalState.coreVersion ?? '',
        runtime: {
          'vpnRunning': globalState.appState.isStart,
          'coreInitialized': await clashCore.isInit,
          'logLevel': globalState.effectiveLogLevel.value,
          'uiAttached': true,
        },
      ),
    );
    final fileName = utils.logFile.replaceFirst(RegExp(r'\.log$'), '.zip');
    return await picker.saveFile(fileName, data) != null;
  }

  Future<List<int>> backupData() async {
    await globalState.flushEdits();
    final receipt = await backendClient.command('backup.export');
    final blob = Map<String, dynamic>.from(receipt['blob'] as Map);
    final token = blob['token'] as String;
    try {
      return await backendClient.download(token, (blob['size'] as num).toInt());
    } finally {
      await backendClient.request('blob.delete', {'token': token});
    }
  }

  Future<void> updateTray([bool focus = false]) async {
    tray.update(trayState: _ref.read(trayStateProvider));
  }

  Future<void> recoveryData(
    List<int> data,
    RecoveryOption recoveryOption,
  ) async {
    await globalState.flushEdits();
    final token = await backendClient.upload(Uint8List.fromList(data));
    try {
      await backendClient.command('backup.restore', {
        'token': token,
        'onlyProfiles': recoveryOption == RecoveryOption.onlyProfiles,
        'replace':
            _ref.read(appSettingProvider).recoveryStrategy ==
            RecoveryStrategy.override,
      });
    } finally {
      await backendClient.request('blob.delete', {'token': token});
    }
  }
}
