import 'dart:async';

import 'product/backend/backend.dart';
import 'product/backend/frontend_settings.dart';
import 'product/backend/frontend_projection.dart';

import 'package:dynamic_color/dynamic_color.dart';
import 'package:flclashx/common/common.dart';
import 'package:flclashx/common/system_notification.dart';
import 'package:flclashx/common/tray.dart';
import 'package:flclashx/common/window.dart';
import 'package:flclashx/database/database.dart';
import 'package:flclashx/enum/enum.dart';
import 'package:flclashx/l10n/l10n.dart';
import 'package:flclashx/models/models.dart';
import 'package:flclashx/providers/providers.dart';
import 'package:flclashx/state.dart';
import 'package:flclashx/views/disclaimer.dart';
import 'package:flclashx/views/navigation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_color_utilities/palettes/tonal_palette.dart';
import 'package:package_info_plus/package_info_plus.dart';

class Bootstrap {
  static Bootstrap? _instance;

  Bootstrap._internal();

  factory Bootstrap() {
    _instance ??= Bootstrap._internal();
    return _instance!;
  }

  Future<ProviderContainer> init(int version) async {
    globalState.appEnv = const String.fromEnvironment(
      'APP_ENV',
      defaultValue: 'pre',
    );
    windowPort = window;
    trayPort = appTray;
    navigationPort = navigation;
    notificationPort = systemNotifications;
    final dynamicColor = await _initDynamicColor();
    return _initData(version, dynamicColor);
  }

  Future<DynamicColorSeeds> _initDynamicColor() async {
    TonalPalette? primaryPalette;
    Color? accentColor;
    try {
      primaryPalette = await _getSystemPrimaryPalette();
    } catch (error) {
      commonPrint.log(
        'Failed to get core palette: $error',
        logLevel: LogLevel.warning,
      );
    }
    try {
      accentColor = await DynamicColorPlugin.getAccentColor();
    } catch (error) {
      commonPrint.log(
        'Failed to get accent color: $error',
        logLevel: LogLevel.warning,
      );
    }
    return (
      lightSeed: primaryPalette != null ? Color(primaryPalette.get(40)) : null,
      darkSeed: primaryPalette != null ? Color(primaryPalette.get(80)) : null,
      accentColor: accentColor ?? const Color(defaultPrimaryColor),
    );
  }

  Future<TonalPalette?> _getSystemPrimaryPalette() async {
    final raw = await DynamicColorPlugin.channel.invokeMethod<List<dynamic>>(
      DynamicColorPlugin.methodName,
    );
    if (raw == null || raw.length < TonalPalette.commonSize) {
      return null;
    }
    return TonalPalette.fromList(
      raw.sublist(0, TonalPalette.commonSize).cast<int>(),
    );
  }

  Future<ProviderContainer> _initData(
    int version,
    DynamicColorSeeds dynamicColor,
  ) async {
    globalState.packageInfo = await PackageInfo.fromPlatform();
    await backendClient.attach();
    await database.refreshFromGo();
    final config = Config.fromJson(
      frontendSettings(backendClient.sourceSettings),
    );
    frontendSettingsStore.project(config);
    final appState = AppState(
      brightness: WidgetsBinding.instance.platformDispatcher.platformBrightness,
      version: version,
      viewSize: Size.zero,
      requests: FixedList(maxRequestsLength),
      logs: FixedList(maxLogsLength),
      traffics: FixedList(trafficSampleLength),
      totalTraffic: const Traffic(),
      systemUiOverlayStyle: const SystemUiOverlayStyle(),
    );
    final appStateOverrides = buildAppStateOverrides(appState);
    final configOverrides = buildConfigOverrides(config);
    final container = ProviderContainer(
      overrides: [...appStateOverrides, ...configOverrides],
    );
    globalState.container = container;
    container
        .read(dynamicColorProvider.notifier)
        .seed(
          lightSeed: dynamicColor.lightSeed,
          darkSeed: dynamicColor.darkSeed,
          accentColor: dynamicColor.accentColor,
        );

    // Read-back is projected directly; never reorder backend data on startup.
    container.read(profilesProvider);
    frontendProjection.attach(container);
    await AppLocalizations.load(
      getLocaleForString(config.appSettingProps.locale) ??
          WidgetsBinding.instance.platformDispatcher.locale,
    );
    await window?.init(
      version,
      config.windowProps,
      menuBarMode: system.isMacOS && config.appSettingProps.menuBarMode,
    );
    if (system.isAndroid) {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    return container;
  }

  Future<void> attach() async {
    if (globalState.isAttach == true) {
      return;
    }
    await _initApp();
    globalState.isAttach = true;
  }

  ProviderContainer get _container => globalState.container;

  Future<void> _initApp() async {
    if (!await _handlerDisclaimer()) return;
    await backendClient.openUI();
    await frontendProjection.refresh();
    _container.read(initProvider.notifier).value = true;
    await _container.read(systemActionProvider.notifier).updateLocalIp();
    unawaited(_container.read(commonActionProvider.notifier).autoCheckUpdate());
  }

  /// Android's exit only finishes the activity, so Dart keeps running after
  /// [SystemAction.handleExit] returns and must not go on to start the app.
  Future<bool> _handlerDisclaimer() async {
    final acceptedVersion = _container.read(
      appSettingProvider.select((state) => state.acceptedDisclaimerVersion),
    );
    if (acceptedVersion >= disclaimerVersion) {
      return true;
    }
    final isDisclaimerAccepted = await requestDisclaimerConsent();
    if (!isDisclaimerAccepted) {
      await _container.read(systemActionProvider.notifier).handleExit();
      return false;
    }
    _container
        .read(appSettingProvider.notifier)
        .update(
          (state) =>
              state.copyWith(acceptedDisclaimerVersion: disclaimerVersion),
        );
    return true;
  }
}

final bootstrap = Bootstrap();
