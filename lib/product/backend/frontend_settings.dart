import 'dart:convert';

import '../../models/models.dart';
import 'backend.dart';

/// Schema bridge; unknown fork and future keys remain in Go untouched.
Map<String, dynamic> frontendSettings(Map<String, dynamic> input) {
  final json = Map<String, dynamic>.from(jsonDecode(jsonEncode(input)) as Map);
  const aliases = {
    'appSetting': 'appSettingProps',
    'proxiesStyle': 'proxiesStyleProps',
    'dav': 'davProps',
    'windowProps': 'windowGeometry',
  };
  for (final e in aliases.entries) {
    if (!json.containsKey(e.value) && json.containsKey(e.key)) {
      json[e.value] = json[e.key];
    }
  }
  final vpn = json['vpnProps'];
  if (vpn is Map && !vpn.containsKey('accessControlProps')) {
    vpn['accessControlProps'] = vpn['accessControl'];
  }
  return json;
}

Map<String, dynamic> backendSettings(Config config) {
  final json = Map<String, dynamic>.from(jsonDecode(jsonEncode(config)) as Map);
  const aliases = {
    'appSettingProps': 'appSetting',
    'proxiesStyleProps': 'proxiesStyle',
    'davProps': 'dav',
    'windowGeometry': 'windowProps',
  };
  for (final e in aliases.entries) {
    if (json.containsKey(e.key)) json[e.value] = json.remove(e.key);
  }
  final vpn = json['vpnProps'];
  if (vpn is Map) vpn['accessControl'] = vpn.remove('accessControlProps');
  return json;
}

class FrontendSettings {
  FrontendSettings({BackendClient? client}) : _client = client ?? backendClient;
  final BackendClient _client;
  bool projecting = false;
  int _pending = 0;
  bool get pending => _pending > 0;
  Future<void> _tail = Future.value();
  Future<void> _latest = Future.value();
  Map<String, dynamic>? _presented;
  void Function()? onSettled;
  void project(Config config) {
    _presented = backendSettings(config);
  }

  Future<void> save(Config config) {
    final next = backendSettings(config);
    final previous =
        _presented ??
        backendSettings(
          Config.fromJson(frontendSettings(_client.sourceSettings)),
        );
    final patch = _diff(previous, next)..remove('currentProfileId');
    final select = previous['currentProfileId'] != next['currentProfileId'];
    if (patch.isEmpty && !select) return flush();
    _presented = next;
    _pending++;
    final run = _tail.then((_) async {
      try {
        if (patch.isNotEmpty) {
          await _client.command('settings.patch', {'patch': patch});
        }
        if (select) {
          await _client.command('profile.select', {
            'profileId': next['currentProfileId'],
          });
        }
      } finally {
        _pending--;
        if (!pending) onSettled?.call();
      }
    });
    _latest = run;
    _tail = run.then<void>((_) {}, onError: (Object _) {});
    return run;
  }

  Future<void> flush() => _latest;
  static const _objects = {
    'appSetting',
    'patchClashConfig',
    'networkProps',
    'vpnProps',
    'themeProps',
    'proxiesStyle',
    'windowProps',
    'tun',
    'dns',
    'textScale',
    'accessControl',
    'geox-url',
    'fallback-filter',
  };
  static Map<String, dynamic> _diff(
    Map<String, dynamic> before,
    Map<String, dynamic> after,
  ) => {
    for (final e in after.entries)
      if (jsonEncode(before[e.key]) != jsonEncode(e.value))
        e.key:
            _objects.contains(e.key) && before[e.key] is Map && e.value is Map
            ? _diff(
                Map<String, dynamic>.from(before[e.key] as Map),
                Map<String, dynamic>.from(e.value as Map),
              )
            : e.value,
  };
}

final frontendSettingsStore = FrontendSettings();
