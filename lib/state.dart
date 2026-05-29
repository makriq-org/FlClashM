import 'dart:async';
import 'dart:convert';
import 'dart:ffi' show Pointer;
import 'dart:io' show Platform;

import 'package:animations/animations.dart';
import 'package:dio/dio.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:flclashm/clash/clash.dart';
import 'package:flclashm/common/theme.dart';
import 'package:flclashm/enum/enum.dart';
import 'package:flclashm/l10n/l10n.dart';
import 'package:flclashm/widgets/dialog.dart';
import 'package:flclashm/widgets/scaffold.dart';
import 'package:flutter/material.dart';
import 'package:flutter_js/flutter_js.dart';
import 'package:material_color_utilities/palettes/core_palette.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'common/common.dart';
import 'common/yaml_dump.dart';
import 'controller.dart';
import 'core_version.dart';
import 'models/models.dart';
import 'plugins/app.dart';
import 'product/compile/product_compile.dart';
import 'product/runtime/product_runtime.dart';
import 'product/security/product_security.dart';

class GlobalState {
  factory GlobalState() {
    _instance ??= GlobalState._internal();
    return _instance!;
  }

  GlobalState._internal() {
    runtimeRegistry = RuntimeRegistry.flClashM(
      readAccessControl: () => config.vpnProps.accessControl,
      readProfileAccessControl: () => activeProfileAccessControl,
    );
    engineManager = EngineManager(
      runtimeRegistry: runtimeRegistry,
      loadCurrentRawProfile: loadCurrentRawProfile,
      compileProfilePatch: compileProfilePatch,
      enforceSecurityPolicy: enforceSecurityPolicy,
      secureRuntimeUpdate: secureRuntimeUpdate,
      buildRuntimePlan: buildRuntimePlan,
      applyRuntimePlan: applyRuntimePlan,
      buildCoreState: getCoreState,
      buildInitParams: _buildInitParams,
    );
  }
  static GlobalState? _instance;
  Map<CacheTag, double> cacheScrollPosition = {};
  Map<CacheTag, FixedMap<String, double>> cacheHeightMap = {};
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
  Map<String, dynamic>? lastRuntimeConfig;
  final activeProfileAccessControlNotifier =
      ValueNotifier<AccessControl?>(null);
  // Effective external-controller endpoint after applying the advisory/profile
  // merge rules for the active profile. Empty string means disabled.
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
  final ProductProfilePipeline _profilePipeline =
      const ProductProfilePipeline();
  final ProductProfileValidator _profileValidator =
      const ProductProfileValidator();
  late final RuntimeRegistry runtimeRegistry;
  late final EngineManager engineManager;

  bool get isStart => engineManager.isStarted;

  DateTime? get startTime => engineManager.startTime;

  AppController get appController => _appController!;

  AccessControl? get activeProfileAccessControl =>
      activeProfileAccessControlNotifier.value;

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
        const Config(themeProps: defaultThemeProps);
    await globalState.migrateOldData(config);
    await AppLocalizations.load(
      utils.getLocaleForString(config.appSetting.locale) ??
          WidgetsBinding.instance.platformDispatcher.locale,
    );
  }

  String get ua => config.patchClashConfig.globalUa ?? packageInfo.ua;

  Future<bool?> showMessage({
    String? title,
    required InlineSpan message,
    String? confirmText,
    bool cancelable = true,
  }) async =>
      showCommonDialog<bool>(
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
              ),
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
                  style: const TextStyle(overflow: TextOverflow.visible),
                ),
              ),
            ),
          ),
        ),
      );

  Future<T?> showCommonDialog<T>({
    required Widget child,
    bool dismissible = true,
  }) async =>
      showModal<T>(
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
          message: TextSpan(text: e.toString()),
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
      config = config.copyWith(patchClashConfig: clashConfig);
      preferences.clearClashConfig();
      preferences.saveConfig(config);
    }
  }

  CoreState getCoreState({
    AccessControl? profileAccessControl,
  }) {
    final currentProfile = config.currentProfile;
    return CoreState(
      vpnProps: config.vpnProps.copyWith(
        accessControl: profileAccessControl ??
            activeProfileAccessControl ??
            config.vpnProps.accessControl,
      ),
      onlyStatisticsProxy: false,
      currentProfileName: currentProfile?.label ?? currentProfile?.id ?? "",
      bypassDomain: config.networkProps.bypassDomain,
    );
  }

  Future<void> syncRuntimeStartTime() => engineManager.syncStartTime();

  Future<RawProfile?> loadCurrentRawProfile() async {
    final profile = config.currentProfile;
    if (profile == null) {
      return null;
    }
    final profilePath = await appPath.getProfilePath(profile.id);
    final rawConfig = await handleEvaluate(
      await loadProfileConfigFromFile(profilePath),
    );
    return RawProfile.fromConfig(
      profile: profile,
      config: rawConfig,
    );
  }

  CompiledProfilePatch compileProfilePatch({
    required RawProfile? rawProfile,
    required ClashConfig patchConfig,
  }) =>
      _profilePipeline.compileProfilePatch(
        rawProfile: rawProfile,
        context: _buildProfilePatchContext(patchConfig),
      );

  SecuredProfilePatch enforceSecurityPolicy({
    required CompiledProfilePatch compiledProfile,
  }) =>
      _profilePipeline.secureProfilePatch(
        compiledProfile: compiledProfile,
        context: _buildSecurityPolicyContext(),
      );

  ClashConfig securePatchConfig({
    required ClashConfig patchConfig,
  }) =>
      _profilePipeline.securePatchConfig(
        patchConfig: patchConfig,
        context: _buildSecurityPolicyContext(),
      );

  UpdateParams secureRuntimeUpdate({
    required UpdateParams updateParams,
  }) =>
      _profilePipeline.secureRuntimeUpdate(
        updateParams: updateParams,
        context: _buildSecurityPolicyContext(),
      );

  Future<RuntimePlan> buildRuntimePlan({
    required RawProfile? rawProfile,
    required SecuredProfilePatch securedProfile,
    required ClashConfig runtimePatchConfig,
  }) async {
    final profilesPath = await appPath.profilesPath;
    final profilePath = rawProfile == null
        ? ''
        : await appPath.getProfilePath(rawProfile.profile.id);
    return _profilePipeline.buildRuntimePlan(
      rawProfile: rawProfile,
      context: _buildRuntimePlanContext(
        profilesPath: profilesPath,
        profilePath: profilePath,
      ),
      securedProfile: securedProfile,
      runtimePatchConfig: runtimePatchConfig,
      selectedMap: config.currentProfile?.selectedMap ?? {},
      testUrl: config.appSetting.testUrl,
      providerAssetPathResolver: (
        profileId,
        type,
        url,
      ) async =>
          appPath.getProvidersFilePath(profileId, type, url),
    );
  }

  UpdateParams buildRuntimeUpdateParams({
    required ClashConfig patchConfig,
  }) =>
      UpdateParams(
        tun: patchConfig.tun.getRealTun(config.networkProps.routeMode),
        allowLan: patchConfig.allowLan,
        findProcessMode: patchConfig.findProcessMode,
        mode: patchConfig.mode,
        logLevel: patchConfig.logLevel,
        ipv6: patchConfig.ipv6,
        tcpConcurrent: patchConfig.tcpConcurrent,
        externalController: patchConfig.externalController,
        unifiedDelay: patchConfig.unifiedDelay,
        mixedPort: patchConfig.mixedPort,
      );

  void applyRuntimePlan(RuntimePlan runtimePlan) {
    lastRuntimeConfig = runtimePlan.config;
    activeProfileAccessControlNotifier.value = runtimePlan.profileAccessControl;
    _applyCompiledProfileMetadata(runtimePlan.metadata);
  }

  Future<InitParams> _buildInitParams() async => InitParams(
        homeDir: await appPath.homeDirPath,
        version: await system.version,
      );

  ProfilePatchContext _buildProfilePatchContext(ClashConfig patchConfig) =>
      ProfilePatchContext(
        patchConfig: patchConfig,
        overrideNetworkSettings: config.appSetting.overrideNetworkSettings,
      );

  SecurityPolicyContext _buildSecurityPolicyContext() => SecurityPolicyContext(
        isAndroid: Platform.isAndroid,
      );

  RuntimePlanBuildContext _buildRuntimePlanContext({
    required String profilesPath,
    required String profilePath,
  }) =>
      RuntimePlanBuildContext(
        isAndroid: Platform.isAndroid,
        overrideNetworkSettings: config.appSetting.overrideNetworkSettings,
        overrideDns: config.overrideDns,
        routeMode: config.networkProps.routeMode,
        hasCurrentScript: config.scriptProps.currentScript != null,
        profilesPath: profilesPath,
        profilePath: profilePath,
        readInstalledPackageNames: _readInstalledPackageNames,
      );

  Future<List<String>> _readInstalledPackageNames() async {
    final packages = await app?.getPackages() ?? const <Package>[];
    return {
      for (final package in packages)
        if (package.packageName.trim().isNotEmpty) package.packageName.trim(),
    }.toList(growable: false);
  }

  void _applyCompiledProfileMetadata(CompiledProfileMetadata? metadata) {
    if (metadata == null) {
      groupDescriptions.value = const {};
      effectiveExternalController.value = "";
      effectiveTcpConcurrent.value = false;
      effectiveUnifiedDelay.value = false;
      effectiveLogLevel.value = LogLevel.info.name;
      effectiveKeepAliveInterval.value = defaultKeepAliveInterval;
      return;
    }
    groupDescriptions.value = metadata.groupDescriptions;
    effectiveExternalController.value = metadata.externalController;
    effectiveTcpConcurrent.value = metadata.tcpConcurrent;
    effectiveUnifiedDelay.value = metadata.unifiedDelay;
    effectiveLogLevel.value = metadata.logLevel;
    effectiveKeepAliveInterval.value = metadata.keepAliveInterval;
  }

  Future<Map<String, dynamic>> getProfileConfig(String profileId) async {
    final profilePath = await appPath.getProfilePath(profileId);
    return loadProfileConfigFromFile(profilePath);
  }

  Future<String> validateProfileConfigText(String text) async {
    try {
      final normalizedConfig = _profileValidator.normalizeForValidation(text);
      final yamlBuffer = StringBuffer();
      yamlDump(yamlBuffer, normalizedConfig, 0);
      return clashCore.validateConfig(yamlBuffer.toString());
    } catch (error) {
      return error.toString();
    }
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
      duration: const Duration(milliseconds: 1200),
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
    state.value = state.value.copyWith(isLoading: true, ipInfo: null);
    _preIsStart = isStart;
    if (cancelToken != null) {
      cancelToken!.cancel();
      cancelToken = null;
    }
    if (justStarted) {
      await Future.delayed(const Duration(milliseconds: 2000));
    }
    cancelToken = CancelToken();
    state.value = state.value.copyWith(isTesting: true);
    final res = await request.checkIp(cancelToken: cancelToken);
    if (res.isError) {
      state.value = state.value.copyWith(isLoading: true, ipInfo: null);
      return;
    }
    final ipInfo = res.data;
    state.value = state.value.copyWith(isTesting: false);
    if (ipInfo != null) {
      state.value = state.value.copyWith(isLoading: false, ipInfo: ipInfo);
      return;
    }
    _clearSetTimeoutTimer();
    _setTimeoutTimer = Timer(const Duration(milliseconds: 300), () {
      state.value = state.value.copyWith(isLoading: false, ipInfo: null);
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
