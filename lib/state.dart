import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:animations/animations.dart';
import 'package:dio/dio.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:flclashx/common/theme.dart';
import 'package:flclashx/enum/enum.dart';
import 'package:flclashx/l10n/l10n.dart';
import 'package:flclashx/widgets/dialog.dart';
import 'package:flclashx/widgets/scaffold.dart';
import 'package:flutter/material.dart';
import 'package:material_color_utilities/palettes/core_palette.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'common/common.dart';
import 'controller.dart';
import 'core_version.dart';
import 'models/models.dart';
import 'product/backend/backend.dart';

class GlobalState {
  factory GlobalState() {
    _instance ??= GlobalState._internal();
    return _instance!;
  }

  GlobalState._internal();
  static GlobalState? _instance;
  Map<CacheTag, double> cacheScrollPosition = {};
  Map<CacheTag, FixedMap<String, double>> cacheHeightMap = {};
  Timer? groupsUpdateTimer;
  Config? _config;
  bool _projectingBackend = false;
  Map<String, dynamic> _backendRuntime = {};
  Map<String, dynamic> _backendView = {};
  Config get config => _config!;
  set config(Config value) {
    final previous = _config;
    _config = value;
    if (previous != null && !_projectingBackend && backendClient.attached) {
      backendEdits.submit(previous.toJson(), value.toJson());
    }
  }

  late final BackendEdits backendEdits = BackendEdits(
    backendClient,
    onError: (error) {
      commonPrint.log('Backend action failed: $error');
      if (isInit) showNotifier(describeError(error));
    },
    onSettled: projectBackend,
  );
  Future<void> flushEdits() => backendEdits.flush();
  Map<String, dynamic> get runtimeView => _backendView;
  late AppState appState;
  bool isPre = true;
  String? coreSHA256;
  String? coreVersion;
  // Full release version baked in at build time via --dart-define=APP_VERSION
  // (the CI git tag, e.g. "0.4.1-pre.18", leading `v` stripped). Empty on local
  // builds, where [_uaVersion] falls back to the pubspec version + a `-pre` mark.
  String appVersionTag = "";
  late PackageInfo packageInfo;
  Function? updateCurrentDelayDebounce;
  late Measure measure;
  late CommonTheme theme;
  late Color accentColor;
  CorePalette? corePalette;
  final activeProfileAccessControlNotifier =
      ValueNotifier<AccessControl?>(null);
  // Effective external-controller endpoint after applying the advisory/profile
  // merge rules for the active profile. Empty string means disabled.
  final effectiveExternalController = ValueNotifier<String>("");
  // Active profile secret/UI values are used only for external dashboard links.
  final effectiveSecret = ValueNotifier<String>("");
  final effectiveExternalUi = ValueNotifier<String>("");
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
  final globalOverrideEnabled = ValueNotifier<bool>(false);
  // Curated member list for the GLOBAL group, parsed from the profile YAML
  // (the proxy-groups entry named GLOBAL). Populated only when the override flag
  // above is set; updateGroups then filters and reorders the core's GLOBAL group
  // to exactly these names, in this order.
  final globalGroupOrder = ValueNotifier<List<String>>([]);
  // All proxy-group names in profile-declaration order. Used only under the
  // GLOBAL override to order the service groups that getProxiesGroups appends
  // from the core's proxies map — that map's keys arrive alphabetically (Go's
  // json.Marshal sorts map keys), so without this the rule-mode group tabs would
  // sort alphabetically instead of following the config.
  final proxyGroupOrder = ValueNotifier<List<String>>([]);

  final navigatorKey = GlobalKey<NavigatorState>();
  AppController? _appController;
  GlobalKey<CommonScaffoldState> homeScaffoldKey = GlobalKey();
  bool isInit = false;
  bool get isStart =>
      (_backendRuntime['observed'] as Map?)?['state'] == 'running';

  DateTime? get startTime {
    final value = (_backendRuntime['startedAt'] as num?)?.toInt() ?? 0;
    return value > 0 ? DateTime.fromMillisecondsSinceEpoch(value) : null;
  }

  AppController get appController => _appController!;

  AccessControl? get activeProfileAccessControl =>
      activeProfileAccessControlNotifier.value;

  set appController(AppController appController) {
    _appController = appController;
    isInit = true;
  }

  void startGroupsUpdateTask() {
    if (groupsUpdateTimer != null && groupsUpdateTimer!.isActive) {
      return;
    }
    groupsUpdateTimer = Timer(const Duration(seconds: 60), () {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        appController.updateGroupsDebounce();
        startGroupsUpdateTask();
      });
    });
  }

  void stopGroupsUpdateTask() {
    groupsUpdateTimer?.cancel();
    groupsUpdateTimer = null;
  }

  Future<void> initApp(int version) async {
    coreSHA256 = const String.fromEnvironment("CORE_SHA256");
    final coreVersionEnv = const String.fromEnvironment("CORE_VERSION");
    coreVersion =
        coreVersionEnv.isEmpty ? kCoreVersionFromSource : coreVersionEnv;
    isPre = const String.fromEnvironment("APP_ENV") != 'stable';
    const appVersionEnv = String.fromEnvironment("APP_VERSION");
    final tag = appVersionEnv.trim();
    appVersionTag =
        (tag.startsWith("v") || tag.startsWith("V")) ? tag.substring(1) : tag;
    appState = AppState(
      version: version,
      viewSize: Size.zero,
      requests: FixedList(maxLength),
      logs: FixedList(maxLength),
      traffics: FixedList(30),
      totalTraffic: Traffic(),
    );
    await Future.wait([_initDynamicColor(), init()]);
  }

  Future<void> _initDynamicColor() async {
    accentColor = const Color(defaultPrimaryColor);
    await Future.wait([
      DynamicColorPlugin.getCorePalette()
          .timeout(const Duration(milliseconds: 500))
          .then<void>((value) {
            corePalette = value;
          })
          .catchError((Object _) {}),
      DynamicColorPlugin.getAccentColor()
          .timeout(const Duration(milliseconds: 500))
          .then<void>((value) {
            accentColor = value ?? accentColor;
          })
          .catchError((Object _) {}),
    ]);
  }

  bool _listeningBackend = false;

  Future<void> init() async {
    packageInfo = await PackageInfo.fromPlatform();
    // init may be retried after the backend was unavailable at startup.
    if (!_listeningBackend) {
      _listeningBackend = true;
      backendClient.changes.listen(
        (_) => projectBackend(),
        onError: (Object error) {
          commonPrint.log('Backend snapshot failed: $error');
        },
      );
    }
    await backendClient.attach();
    projectBackend();
    await AppLocalizations.load(
      utils.getLocaleForString(config.appSetting.locale) ??
          WidgetsBinding.instance.platformDispatcher.locale,
    );
  }

  // Version shown in the User-Agent: the exact release tag when present,
  // otherwise the pubspec version with a `-pre` marker for non-stable builds.
  String get _uaVersion => appVersionTag.isNotEmpty
      ? appVersionTag
      : (isPre ? "${packageInfo.version}-pre" : packageInfo.version);

  String get ua =>
      config.patchClashConfig.globalUa ??
      packageInfo.ua(appVersion: _uaVersion, coreVersion: coreVersion);

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
      final text = describeError(e);
      if (text.isEmpty) {
        return null;
      }
      if (silence) {
        showNotifier(text);
      } else {
        showMessage(
          title: title ?? appLocalizations.tip,
          message: TextSpan(text: text),
        );
      }
      return null;
    }
  }

  /// User-facing text for an error; empty when it must not be reported.
  String describeError(Object error) => describeBackendError(error);

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

  /// Applies a server snapshot to UI replicas. Assignments made during this
  /// projection never become user commands or rewrite backend settings.
  void projectBackend() {
    final snapshot = backendClient.snapshot;
    _backendRuntime = Map<String, dynamic>.from(
      snapshot['runtime'] as Map? ?? {},
    );
    if (!backendEdits.pending) {
      final data = backendClient.settings;
      final decoded = Config.compatibleFromJson(data);
      final next = decoded.copyWith(
        profiles: [
          for (final profile in decoded.profiles)
            profile.copyWith(
              lastUpdateDate: profile.lastUpdateDate?.toLocal(),
              isUpdating:
                  _config?.profiles.getProfile(profile.id)?.isUpdating ?? false,
            ),
        ],
      );
      _projectingBackend = true;
      try {
        _config = next;
        _appController?.projectBackendConfig(next);
      } finally {
        _projectingBackend = false;
      }
    }
    if (backendClient.runtimeViewGeneration ==
        _backendRuntime['appliedGeneration']) {
      _backendView = backendClient.runtimeView;
      _projectRuntimeView();
    }
    _appController?.projectBackendRuntime();
    _projectProfileChange();
  }

  final _projectionWatcher = ProjectionWatcher();

  void _projectProfileChange() {
    final applied = _backendView['profileId'];
    final change = _projectionWatcher.observe(
      profileId: _config?.currentProfileId,
      appliedProfileId: applied is String ? applied : null,
      generation: _projectedViewGeneration,
    );
    final controller = _appController;
    if (controller == null || !controller.context.mounted) return;
    switch (change) {
      case ProjectionChange.profile:
        controller.handleChangeProfile();
      case ProjectionChange.generation:
        controller.updateGroupsDebounce();
      case ProjectionChange.none:
        break;
    }
  }

  int? _projectedViewGeneration;

  void _projectRuntimeView() {
    final generation = backendClient.runtimeViewGeneration;
    if (_projectedViewGeneration == generation) return;
    _projectedViewGeneration = generation;
    final runtimeConfig = Map<String, dynamic>.from(
      _backendView['config'] as Map? ?? {},
    );
    final profileAccess = _backendView['profileAccessControl'];
    activeProfileAccessControlNotifier.value = profileAccess is Map
        ? AccessControl.fromJson(Map<String, dynamic>.from(profileAccess))
        : null;
    effectiveExternalController.value =
        '${runtimeConfig['external-controller'] ?? ''}'.trim();
    effectiveSecret.value = '${runtimeConfig['secret'] ?? ''}'.trim();
    effectiveExternalUi.value = '${runtimeConfig['external-ui'] ?? ''}'.trim();
    effectiveTcpConcurrent.value = runtimeConfig['tcp-concurrent'] == true;
    effectiveUnifiedDelay.value = runtimeConfig['unified-delay'] == true;
    effectiveLogLevel.value = '${runtimeConfig['log-level'] ?? 'info'}';
    effectiveKeepAliveInterval.value =
        (runtimeConfig['keep-alive-interval'] as num?)?.toInt() ??
            defaultKeepAliveInterval;
    final descriptions = <String, String>{};
    final order = <String>[];
    var globalOverride = false;
    for (final value in runtimeConfig['proxy-groups'] as List? ?? []) {
      if (value is! Map) continue;
      final name = '${value['name'] ?? ''}'.trim();
      if (name.isEmpty) continue;
      order.add(name);
      final description = '${value['description'] ?? ''}'.trim();
      if (description.isNotEmpty) descriptions[name] = description;
      if (name == GroupName.GLOBAL.name) {
        globalOverride = value.containsKey('flclashm-override')
            ? value['flclashm-override'] == true
            : value['flclashx-override'] == true;
      }
    }
    groupDescriptions.value = descriptions;
    proxyGroupOrder.value = order;
    globalOverrideEnabled.value = globalOverride;
  }

  Future<bool> syncRuntimeStartTime() async {
    try {
      await backendClient.refresh();
      return true;
    } catch (error) {
      commonPrint.log('Backend resync failed: $error');
      return false;
    }
  }

  Future<Map<String, dynamic>> getProfileConfig(String profileId) async {
    final inspected =
        await backendClient.request('profile.inspect', {'profileId': profileId})
            as Map;
    return Map<String, dynamic>.from(inspected['config'] as Map);
  }

  Future<AccessControl?> readProfileAccessControl() async {
    final id = config.currentProfileId;
    if (id == null) return null;
    final inspected =
        await backendClient.request('profile.inspect', {'profileId': id})
            as Map;
    final access = inspected['accessControl'];
    return access is Map
        ? AccessControl.fromJson(Map<String, dynamic>.from(access))
        : null;
  }

  Future<String> validateProfileConfigText(String text) async {
    final token = await backendClient.upload(
      Uint8List.fromList(utf8.encode(text)),
    );
    try {
      await backendClient.command('profile.validate', {'token': token});
      return '';
    } catch (error) {
      // An empty result means "valid"; never let a silent error pass as such.
      final text = describeError(error);
      return text.isEmpty ? '$error' : text;
    } finally {
      await backendClient.request('blob.delete', {'token': token});
    }
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
