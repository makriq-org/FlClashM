import 'dart:async';
import 'dart:convert';
import 'dart:ffi' show Pointer;
import 'dart:io' show Platform;

import 'package:animations/animations.dart';
import 'package:dio/dio.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:flclashx/clash/clash.dart';
import 'package:flclashx/common/theme.dart';
import 'package:flclashx/enum/enum.dart';
import 'package:flclashx/l10n/l10n.dart';
import 'package:flclashx/plugins/service.dart';
import 'package:flclashx/widgets/dialog.dart';
import 'package:flclashx/widgets/scaffold.dart';
import 'package:flutter/material.dart';
import 'package:flutter_js/flutter_js.dart';
import 'package:material_color_utilities/palettes/core_palette.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'common/common.dart';
import 'controller.dart';
import 'core_version.dart';
import 'models/models.dart';

typedef UpdateTasks = List<FutureOr Function()>;

class GlobalState {

  factory GlobalState() {
    _instance ??= GlobalState._internal();
    return _instance!;
  }

  GlobalState._internal();
  static GlobalState? _instance;
  Map<CacheTag, double> cacheScrollPosition = {};
  Map<CacheTag, FixedMap<String, double>> cacheHeightMap = {};
  Timer? timer;
  Timer? groupsUpdateTimer;
  late Config config;
  late AppState appState;
  bool isPre = true;
  String? coreSHA256;
  String? coreVersion;
  late PackageInfo packageInfo;
  Function? updateCurrentDelayDebounce;
  late Measure measure;
  late CommonTheme theme;
  late Color accentColor;
  CorePalette? corePalette;
  DateTime? startTime;
  UpdateTasks tasks = [];
  Map<String, dynamic>? lastRuntimeConfig;
  // Effective external-controller endpoint after merging subscription value
  // over UI defaults. Empty string means disabled. Subscription value wins if
  // present, otherwise falls back to the UI toggle default.
  final effectiveExternalController = ValueNotifier<String>("");
  // Effective values for fields that follow the overrideNetworkSettings gate
  // but don't round-trip through patchClashConfigProvider. UI reads these when
  // override is OFF so it shows what's actually applied (profile or fallback).
  final effectiveTcpConcurrent = ValueNotifier<bool>(false);
  final effectiveUnifiedDelay = ValueNotifier<bool>(false);
  final effectiveLogLevel = ValueNotifier<String>("info");
  final effectiveKeepAliveInterval = ValueNotifier<int>(30);
  // Custom per-group descriptions parsed from the profile YAML
  // (proxy-groups[*].description). Shown as the subtitle of a nested group
  // card instead of its type (Fallback/URLTest/Selector).
  final groupDescriptions = ValueNotifier<Map<String, String>>({});
  final navigatorKey = GlobalKey<NavigatorState>();
  AppController? _appController;
  GlobalKey<CommonScaffoldState> homeScaffoldKey = GlobalKey();
  bool isInit = false;

  bool get isStart => startTime != null && startTime!.isBeforeNow;

  AppController get appController => _appController!;

  set appController(AppController appController) {
    _appController = appController;
    isInit = true;
  }

  Future<void> initApp(int version) async {
    coreSHA256 = const String.fromEnvironment("CORE_SHA256");
    final coreVersionEnv = const String.fromEnvironment("CORE_VERSION");
    coreVersion =
        coreVersionEnv.isEmpty ? kCoreVersionFromSource : coreVersionEnv;
    isPre = const String.fromEnvironment("APP_ENV") != 'stable';
    appState = AppState(
      version: version,
      viewSize: Size.zero,
      requests: FixedList(maxLength),
      logs: FixedList(maxLength),
      traffics: FixedList(30),
      totalTraffic: Traffic(),
    );
    await _initDynamicColor();
    await init();
  }

  Future<void> _initDynamicColor() async {
    try {
      corePalette = await DynamicColorPlugin.getCorePalette();
      accentColor = await DynamicColorPlugin.getAccentColor() ??
          const Color(defaultPrimaryColor);
    } catch (_) {}
  }

  Future<void> init() async {
    packageInfo = await PackageInfo.fromPlatform();
    config = await preferences.getConfig() ??
        const Config(
          themeProps: defaultThemeProps,
        );
    await globalState.migrateOldData(config);
    await AppLocalizations.load(
      utils.getLocaleForString(config.appSetting.locale) ??
          WidgetsBinding.instance.platformDispatcher.locale,
    );
  }

  String get ua => config.patchClashConfig.globalUa ?? packageInfo.ua;

  Future<void> startUpdateTasks([UpdateTasks? tasks]) async {
    if (timer != null && timer!.isActive == true) return;
    if (tasks != null) {
      this.tasks = tasks;
    }
    await executorUpdateTask();
    timer = Timer(const Duration(seconds: 3), () async {
      startUpdateTasks();
    });
  }

  Future<void> executorUpdateTask() async {
    for (final task in tasks) {
      await task();
    }
    timer = null;
  }

  void stopUpdateTasks() {
    if (timer == null || timer?.isActive == false) return;
    timer?.cancel();
    timer = null;
  }

  Future<void> handleStart([UpdateTasks? tasks]) async {
    startTime ??= DateTime.now();
    await clashCore.startListener();
    await service?.startVpn();
    startUpdateTasks(tasks);
  }

  Future updateStartTime() async {
    startTime = await clashLib?.getRunTime();
  }

  Future handleStop() async {
    startTime = null;
    await clashCore.stopListener();
    await service?.stopVpn();
    stopUpdateTasks();
  }

  Future<bool?> showMessage({
    String? title,
    required InlineSpan message,
    String? confirmText,
    bool cancelable = true,
  }) async => showCommonDialog<bool>(
      child: Builder(
        builder: (context) => CommonDialog(
            title: title ?? appLocalizations.tip,
            actions: [
              if (cancelable)
                TextButton(
                  onPressed: () {
                    Navigator.of(context).pop(false);
                  },
                  child: Text(appLocalizations.cancel),
                ),
              TextButton(
                onPressed: () {
                  Navigator.of(context).pop(true);
                },
                child: Text(confirmText ?? appLocalizations.confirm),
              )
            ],
            child: Container(
              width: 300,
              constraints: const BoxConstraints(maxHeight: 200),
              child: SingleChildScrollView(
                child: SelectableText.rich(
                  TextSpan(
                    style: Theme.of(context).textTheme.labelLarge,
                    children: [message],
                  ),
                  style: const TextStyle(
                    overflow: TextOverflow.visible,
                  ),
                ),
              ),
            ),
          ),
      ),
    );

  Future<T?> showCommonDialog<T>({
    required Widget child,
    bool dismissible = true,
  }) async => showModal<T>(
      context: navigatorKey.currentState!.context,
      configuration: FadeScaleTransitionConfiguration(
        barrierColor: Colors.black38,
        barrierDismissible: dismissible,
      ),
      builder: (_) => child,
      filter: commonFilter,
    );

  Future<T?> safeRun<T>(
    FutureOr<T> Function() futureFunction, {
    String? title,
    bool silence = true,
  }) async {
    try {
      final res = await futureFunction();
      return res;
    } catch (e) {
      commonPrint.log("$e");
      if (silence) {
        showNotifier(e.toString());
      } else {
        showMessage(
          title: title ?? appLocalizations.tip,
          message: TextSpan(
            text: e.toString(),
          ),
        );
      }
      return null;
    }
  }

  void showNotifier(String text) {
    if (text.isEmpty) {
      return;
    }
    navigatorKey.currentContext?.showNotifier(text);
  }

  Future<void> openUrl(String url) async {
    final res = await showMessage(
      message: TextSpan(text: url),
      title: appLocalizations.externalLink,
      confirmText: appLocalizations.go,
    );
    if (res != true) {
      return;
    }
    launchUrl(Uri.parse(url));
  }

  Future<void> migrateOldData(Config config) async {
    final clashConfig = await preferences.getClashConfig();
    if (clashConfig != null) {
      config = config.copyWith(
        patchClashConfig: clashConfig,
      );
      preferences.clearClashConfig();
      preferences.saveConfig(config);
    }
  }

  CoreState getCoreState() {
    final currentProfile = config.currentProfile;
    return CoreState(
      vpnProps: config.vpnProps,
      onlyStatisticsProxy: false,
      currentProfileName: currentProfile?.label ?? currentProfile?.id ?? "",
      bypassDomain: config.networkProps.bypassDomain,
    );
  }

  Future<SetupParams> getSetupParams({
    required ClashConfig pathConfig,
  }) async {
    final clashConfig = await patchRawConfig(
      patchConfig: pathConfig,
    );
    lastRuntimeConfig = clashConfig;
    final params = SetupParams(
      config: clashConfig,
      selectedMap: config.currentProfile?.selectedMap ?? {},
      testUrl: config.appSetting.testUrl,
    );
    return params;
  }

  Future<ClashConfig> syncNetworkSettingsFromProvider(ClashConfig patchConfig) async {
    if (config.appSetting.overrideNetworkSettings) {
      return patchConfig; // User wants to override, keep current settings
    }

    final profile = config.currentProfile;
    if (profile == null) {
      return patchConfig;
    }

    try {
      final profileId = profile.id;
      final configMap = await getProfileConfig(profileId);
      final rawConfig = await handleEvaluate(configMap);

      final providerIpv6 = rawConfig['ipv6'] as bool? ?? patchConfig.ipv6;
      final providerAllowLan = rawConfig['allow-lan'] as bool? ?? patchConfig.allowLan;
      final providerMixedPort = rawConfig['mixed-port'] as int? ?? patchConfig.mixedPort;
      final providerFindProcessModeStr = rawConfig['find-process-mode'] as String?;
      final providerFindProcessMode = providerFindProcessModeStr != null 
          ? FindProcessMode.values.firstWhere(
              (e) => e.name.toLowerCase() == providerFindProcessModeStr.toLowerCase(),
              orElse: () => patchConfig.findProcessMode,
            )
          : patchConfig.findProcessMode;
      
      final providerTunStackStr = rawConfig['tun']?['stack'] as String?;
      final providerTunStack = providerTunStackStr != null
          ? TunStack.values.firstWhere(
              (e) => e.name.toLowerCase() == providerTunStackStr.toLowerCase(),
              orElse: () => patchConfig.tun.stack,
            )
          : patchConfig.tun.stack;

      return patchConfig.copyWith(
        ipv6: providerIpv6,
        allowLan: providerAllowLan,
        mixedPort: providerMixedPort,
        findProcessMode: providerFindProcessMode,
      ).copyWith.tun(stack: providerTunStack);
    } catch (e) {
      commonPrint.log("Error syncing network settings from provider: $e");
      return patchConfig;
    }
  }

  Future<Map<String, dynamic>> patchRawConfig({
    required ClashConfig patchConfig,
  }) async {
    final profile = config.currentProfile;
    if (profile == null) {
      return {};
    }
    final profileId = profile.id;
    final configMap = await getProfileConfig(profileId);
    final rawConfig = await handleEvaluate(configMap);
    
    final realPatchConfig = patchConfig.copyWith(
      tun: patchConfig.tun.getRealTun(config.networkProps.routeMode),
    );
    // Custom "description" field on proxy-groups — extracted here because
    // mihomo's /proxies API doesn't forward arbitrary YAML keys.
    final parsedGroupDescriptions = <String, String>{};
    final rawGroups = rawConfig["proxy-groups"];
    if (rawGroups is List) {
      for (final g in rawGroups) {
        if (g is! Map) continue;
        final name = g["name"];
        if (name is! String) continue;
        final desc = g["description"];
        if (desc is String && desc.trim().isNotEmpty) {
          parsedGroupDescriptions[name] = desc.trim();
        }
      }
    }
    groupDescriptions.value = parsedGroupDescriptions;
    // external-controller: profile value always wins when present. The UI
    // toggle only acts as a fallback because the enum hardcodes 127.0.0.1:9090
    // and would otherwise silently override a subscription-provided endpoint
    // (e.g. :9091). The overrideNetworkSettings gate is intentionally ignored
    // here — users who set external-controller in their profile mean it.
    final providerExternalController =
        (rawConfig["external-controller"] as String?)?.trim() ?? "";
    final effectiveExternalControllerValue = providerExternalController.isNotEmpty
        ? providerExternalController
        : realPatchConfig.externalController.value;
    rawConfig["external-controller"] = effectiveExternalControllerValue;
    effectiveExternalController.value = effectiveExternalControllerValue;
    if (rawConfig["external-ui"] == null || rawConfig["external-ui"] == "") {
      rawConfig["external-ui"] = "";
    }
    rawConfig["interface-name"] = "";
    if (rawConfig["external-ui-url"] == null || rawConfig["external-ui-url"] == "") {
      rawConfig["external-ui-url"] = "";
    }
    // These follow the same overrideNetworkSettings gate as other fields:
    //   override ON  → UI value wins (always written)
    //   override OFF → profile value wins, UI is fallback only if missing
    // Effective values are exposed so the UI reflects what's actually applied
    // when override is OFF (otherwise widgets would still show stored UI prefs).
    final profileTcpConcurrent = rawConfig["tcp-concurrent"] as bool?;
    final profileUnifiedDelay = rawConfig["unified-delay"] as bool?;
    final profileLogLevel = rawConfig["log-level"] as String?;
    final profileKeepAlive = (rawConfig["keep-alive-interval"] as num?)?.toInt();
    final isOverride = config.appSetting.overrideNetworkSettings;
    final effTcpConcurrent = isOverride
        ? realPatchConfig.tcpConcurrent
        : (profileTcpConcurrent ?? realPatchConfig.tcpConcurrent);
    final effUnifiedDelay = isOverride
        ? realPatchConfig.unifiedDelay
        : (profileUnifiedDelay ?? realPatchConfig.unifiedDelay);
    final effLogLevel = isOverride
        ? realPatchConfig.logLevel.name
        : (profileLogLevel ?? realPatchConfig.logLevel.name);
    final effKeepAlive = isOverride
        ? realPatchConfig.keepAliveInterval
        : (profileKeepAlive ?? realPatchConfig.keepAliveInterval);
    rawConfig["tcp-concurrent"] = effTcpConcurrent;
    rawConfig["unified-delay"] = effUnifiedDelay;
    rawConfig["log-level"] = effLogLevel;
    rawConfig["keep-alive-interval"] = effKeepAlive;
    effectiveTcpConcurrent.value = effTcpConcurrent;
    effectiveUnifiedDelay.value = effUnifiedDelay;
    effectiveLogLevel.value = effLogLevel;
    effectiveKeepAliveInterval.value = effKeepAlive;
    rawConfig["port"] = 0;
    rawConfig["socks-port"] = 0;
    rawConfig["port"] = realPatchConfig.port;
    rawConfig["socks-port"] = realPatchConfig.socksPort;
    rawConfig["redir-port"] = realPatchConfig.redirPort;
    rawConfig["tproxy-port"] = realPatchConfig.tproxyPort;
    rawConfig["mode"] = realPatchConfig.mode.name;
    
    // Set network settings: use patchConfig if overriding, otherwise keep provider values
    if (config.appSetting.overrideNetworkSettings) {
      // User wants to override - use values from UI (always write)
      rawConfig["find-process-mode"] = realPatchConfig.findProcessMode.name;
      rawConfig["allow-lan"] = realPatchConfig.allowLan;
      rawConfig["ipv6"] = realPatchConfig.ipv6;
      rawConfig["mixed-port"] = realPatchConfig.mixedPort;
    } else {
      // Use provider values - only set if not already in rawConfig, use patchConfig values (which are synced from provider)
      if (rawConfig["find-process-mode"] == null) {
        rawConfig["find-process-mode"] = realPatchConfig.findProcessMode.name;
      }
      if (rawConfig["allow-lan"] == null) {
        rawConfig["allow-lan"] = realPatchConfig.allowLan;
      }
      if (rawConfig["ipv6"] == null) {
        rawConfig["ipv6"] = realPatchConfig.ipv6;
      }
      if (rawConfig["mixed-port"] == null) {
        rawConfig["mixed-port"] = realPatchConfig.mixedPort;
      }
    }

    // flclashx-androidsecure header: when set to "true" on Android, force
    // mixed-port = 0 so the HTTP/SOCKS inbound is disabled and traffic can
    // only leave through the VpnService/TUN. Applied as a final override
    // regardless of overrideNetworkSettings or UI-configured port, because
    // the header expresses an explicit policy from the subscription provider
    // that should not be overridable from the app side. No-op on other
    // platforms — desktop TUN gating is handled separately.
    if (Platform.isAndroid) {
      final secureHeader =
          profile.providerHeaders['flclashx-androidsecure']?.trim().toLowerCase();
      if (secureHeader == 'true') {
        rawConfig["mixed-port"] = 0;
      }
    }
    
    if (rawConfig["tun"] == null) {
      rawConfig["tun"] = {};
    }
    rawConfig["tun"]["enable"] = Platform.isAndroid ? true : realPatchConfig.tun.enable;
    rawConfig["tun"]["device"] = realPatchConfig.tun.device;
    rawConfig["tun"]["dns-hijack"] = realPatchConfig.tun.dnsHijack;
    
    // Set TUN stack
    if (config.appSetting.overrideNetworkSettings) {
      // User wants to override - use value from UI (always write)
      rawConfig["tun"]["stack"] = realPatchConfig.tun.stack.name;
    } else {
      // Use provider value - only set if not already in rawConfig, use patchConfig value (which is synced from provider)
      final currentStack = rawConfig["tun"]["stack"];
      if (currentStack == null) {
        rawConfig["tun"]["stack"] = realPatchConfig.tun.stack.name;
      }
    }
    
    rawConfig["tun"]["route-address"] = realPatchConfig.tun.routeAddress;
    rawConfig["tun"]["auto-route"] = realPatchConfig.tun.autoRoute;
    rawConfig["geodata-loader"] = realPatchConfig.geodataLoader.name;
    if (rawConfig["sniffer"]?["sniff"] != null) {
      for (final value in (rawConfig["sniffer"]?["sniff"] as Map).values) {
        if (value["ports"] != null && value["ports"] is List) {
          value["ports"] =
              value["ports"]?.map((item) => item.toString()).toList() ?? [];
        }
      }
    }
    if (rawConfig["profile"] == null) {
      rawConfig["profile"] = {};
    }
    if (rawConfig["proxy-providers"] != null) {
      final proxyProviders = rawConfig["proxy-providers"] as Map;
      for (final key in proxyProviders.keys) {
        final proxyProvider = proxyProviders[key];
        if (proxyProvider["type"] != "http") {
          continue;
        }
        if (proxyProvider["url"] != null) {
          proxyProvider["path"] = await appPath.getProvidersFilePath(
            profile.id,
            "proxies",
            proxyProvider["url"],
          );
        }
      }
    }

    if (rawConfig["rule-providers"] != null) {
      final ruleProviders = rawConfig["rule-providers"] as Map;
      for (final key in ruleProviders.keys) {
        final ruleProvider = ruleProviders[key];
        if (ruleProvider["type"] != "http") {
          continue;
        }
        if (ruleProvider["url"] != null) {
          ruleProvider["path"] = await appPath.getProvidersFilePath(
            profile.id,
            "rules",
            ruleProvider["url"],
          );
        }
      }
    }

    rawConfig["profile"]["store-selected"] = false;
    
    final mergedGeoXUrl = <String, dynamic>{};
    final patchGeoX = realPatchConfig.geoXUrl.toJson();
    final profileGeoX = rawConfig["geox-url"];
    
    mergedGeoXUrl['geoip'] = patchGeoX['geoip'];
    mergedGeoXUrl['mmdb'] = patchGeoX['mmdb'];
    mergedGeoXUrl['asn'] = patchGeoX['asn'];
    mergedGeoXUrl['geosite'] = patchGeoX['geosite'];
    
    if (profileGeoX != null && profileGeoX is Map) {
      if (profileGeoX['geoip'] != null) mergedGeoXUrl['geoip'] = profileGeoX['geoip'];
      if (profileGeoX['mmdb'] != null) mergedGeoXUrl['mmdb'] = profileGeoX['mmdb'];
      if (profileGeoX['asn'] != null) mergedGeoXUrl['asn'] = profileGeoX['asn'];
      if (profileGeoX['geosite'] != null) mergedGeoXUrl['geosite'] = profileGeoX['geosite'];
    }
    
    rawConfig["geox-url"] = mergedGeoXUrl;
    rawConfig["global-ua"] = realPatchConfig.globalUa;
    if (rawConfig["hosts"] == null) {
      rawConfig["hosts"] = {};
    }
    for (final host in realPatchConfig.hosts.entries) {
      rawConfig["hosts"][host.key] = host.value.splitByMultipleSeparators;
    }
    if (rawConfig["dns"] == null) {
      rawConfig["dns"] = {};
    }
    final isEnableDns = rawConfig["dns"]["enable"] == true;
    final overrideDns = globalState.config.overrideDns;
    if (overrideDns || !isEnableDns) {
      final dns = switch (!isEnableDns) {
        true => realPatchConfig.dns.copyWith(
            nameserver: [...realPatchConfig.dns.nameserver, "system://"]),
        false => realPatchConfig.dns,
      };
      rawConfig["dns"] = dns.toJson();
      rawConfig["dns"]["nameserver-policy"] = {};
      for (final entry in dns.nameserverPolicy.entries) {
        rawConfig["dns"]["nameserver-policy"][entry.key] =
            entry.value.splitByMultipleSeparators;
      }
    }
    var rules = [];
    if (rawConfig["rules"] != null) {
      rules = rawConfig["rules"];
    }
    rawConfig.remove("rules");

    final overrideData = profile.overrideData;
    if (overrideData.enable && config.scriptProps.currentScript == null) {
      if (overrideData.rule.type == OverrideRuleType.override) {
        rules = overrideData.runningRule;
      } else {
        rules = [...overrideData.runningRule, ...rules];
      }
    }
    rawConfig["rule"] = rules;
    return rawConfig;
  }

  Future<Map<String, dynamic>> getProfileConfig(String profileId) async {
    final configMap = await clashCore.getConfig(profileId);
    configMap["rules"] = configMap["rule"];
    configMap.remove("rule");
    return configMap;
  }

  Future<Map<String, dynamic>> handleEvaluate(
    Map<String, dynamic> config,
  ) async {
    final currentScript = globalState.config.scriptProps.currentScript;
    if (currentScript == null) {
      return config;
    }
    if (config["proxy-providers"] == null) {
      config["proxy-providers"] = {};
    }
    final configJs = json.encode(config);
    final runtime = getJavascriptRuntime();
    final res = await runtime.evaluateAsync("""
      ${currentScript.content}
      main($configJs)
    """);
    if (res.isError) {
      throw res.stringResult;
    }
    final value = switch (res.rawResult is Pointer) {
      true => runtime.convertValue<Map<String, dynamic>>(res),
      false => Map<String, dynamic>.from(res.rawResult),
    };
    return value ?? config;
  }
}

final globalState = GlobalState();

class DetectionState {

  factory DetectionState() {
    _instance ??= DetectionState._internal();
    return _instance!;
  }

  DetectionState._internal();
  static DetectionState? _instance;
  bool? _preIsStart;
  Timer? _setTimeoutTimer;
  CancelToken? cancelToken;
  DateTime? _lastManualCheck;

  final state = ValueNotifier<NetworkDetectionState>(
    const NetworkDetectionState(
      isTesting: false,
      isLoading: true,
      ipInfo: null,
    ),
  );

  void startCheck() {
    debouncer.call(
      FunctionTag.checkIp,
      _checkIp,
      duration: const Duration(
        milliseconds: 1200,
      ),
    );
  }

  bool forceCheck() {
    if (_lastManualCheck != null) {
      final timeSinceLastCheck = DateTime.now().difference(_lastManualCheck!);
      if (timeSinceLastCheck.inSeconds < 15) {
        return false;
      }
    }
    _lastManualCheck = DateTime.now();
    _checkIp();
    return true;
  }

  Future<void> _checkIp() async {
    final appState = globalState.appState;
    final isInit = appState.isInit;
    if (!isInit) return;
    final isStart = appState.runTime != null;
    if (_preIsStart == false &&
        _preIsStart == isStart &&
        state.value.ipInfo != null) {
      return;
    }
    final justStarted = _preIsStart == false && isStart;
    _clearSetTimeoutTimer();
    state.value = state.value.copyWith(
      isLoading: true,
      ipInfo: null,
    );
    _preIsStart = isStart;
    if (cancelToken != null) {
      cancelToken!.cancel();
      cancelToken = null;
    }
    if (justStarted) {
      await Future.delayed(const Duration(milliseconds: 2000));
    }
    cancelToken = CancelToken();
    state.value = state.value.copyWith(
      isTesting: true,
    );
    final res = await request.checkIp(cancelToken: cancelToken);
    if (res.isError) {
      state.value = state.value.copyWith(
        isLoading: true,
        ipInfo: null,
      );
      return;
    }
    final ipInfo = res.data;
    state.value = state.value.copyWith(
      isTesting: false,
    );
    if (ipInfo != null) {
      state.value = state.value.copyWith(
        isLoading: false,
        ipInfo: ipInfo,
      );
      return;
    }
    _clearSetTimeoutTimer();
    _setTimeoutTimer = Timer(const Duration(milliseconds: 300), () {
      state.value = state.value.copyWith(
        isLoading: false,
        ipInfo: null,
      );
    });
  }

  void _clearSetTimeoutTimer() {
    if (_setTimeoutTimer != null) {
      _setTimeoutTimer?.cancel();
      _setTimeoutTimer = null;
    }
  }
}

final detectionState = DetectionState();
