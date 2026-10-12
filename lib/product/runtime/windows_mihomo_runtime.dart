import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../../models/models.dart';
import 'desktop_helper_protocol.dart';
import 'windows_helper_transport.dart';

class WindowsMihomoRuntime {
  WindowsMihomoRuntime(
      {DesktopHelperTransport transport = const WindowsHelperTransport()})
      : _helper = DesktopHelperClient(
            transport: transport, timeout: const Duration(seconds: 12));

  final DesktopHelperClient _helper;
  String? _token;
  bool preferService = false;
  bool get isActive => _token != null;

  Future<bool> available() async =>
      (await _helper.execute(const DesktopHelperRequest(
        operation: DesktopHelperOperation.ping,
      )))
          .isSuccess;

  Future<void> start({required int port, required String token}) async {
    _token = token;
    final response = await _helper.execute(DesktopHelperRequest(
      operation: DesktopHelperOperation.runtimeStart,
      runtimeArtifact: 'mihomo',
      parameters: {'runtimeToken': token, 'port': port},
    ));
    if (!response.isSuccess) throw StateError(response.message);
    _token = token;
  }

  Future<void> stop() async {
    final token = _token;
    if (token == null) return;
    final response = await _helper.execute(DesktopHelperRequest(
      operation: DesktopHelperOperation.runtimeStop,
      runtimeArtifact: 'mihomo',
      parameters: {'runtimeToken': token},
    ));
    if (!response.isSuccess) throw StateError(response.message);
    _token = null;
  }
}

String createWindowsControlToken() {
  final random = Random.secure();
  return List.generate(
      32, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}

/// File providers are read with the GUI's rights, then staged into the protected
/// per-user service cache. The privileged core never opens a user-supplied path.
Future<SetupParams> prepareWindowsServiceSetup(SetupParams setup) async {
  final config =
      Map<String, dynamic>.from(jsonDecode(jsonEncode(setup.config)) as Map);
  final files = <String, String>{};
  var totalBytes = 0;
  for (final section in ['proxy-providers', 'rule-providers']) {
    final providers = config[section];
    if (providers is! Map) continue;
    for (final entry in providers.entries) {
      final provider = entry.value;
      if (provider is! Map || provider['type'] != 'file') continue;
      final source = provider['path'];
      if (source is! String || source.isEmpty) {
        throw StateError('File provider has no source path.');
      }
      final file = File(source);
      final size = await file.length();
      if (size > 16 * 1024 * 1024 || totalBytes + size > 32 * 1024 * 1024) {
        throw StateError(
            'Local providers exceed the Windows TUN staging limit (32 MB).');
      }
      final bytes = await file.readAsBytes();
      totalBytes += bytes.length;
      if (totalBytes > 32 * 1024 * 1024) {
        throw StateError(
            'Local providers exceed the Windows TUN staging limit.');
      }
      files['$section/${entry.key}'] = base64Encode(bytes);
    }
  }
  config['_flclashm-provider-files'] = files;
  return setup.copyWith(config: config);
}

final windowsMihomoRuntime = WindowsMihomoRuntime();

class WindowsCoreMessageBridge {
  final _downloads = <String, String>{};

  Future<String> prepare(String message) async {
    final action = Map<String, dynamic>.from(jsonDecode(message) as Map);
    switch (action['method']) {
      case 'getConfig':
        final bytes = await File(action['data'] as String).readAsBytes();
        action['data'] = {'content': base64Encode(bytes)};
      case 'setupConfig':
        final setup = SetupParams.fromJson(
          Map<String, dynamic>.from(
              jsonDecode(action['data'] as String) as Map),
        );
        action['data'] =
            jsonEncode((await prepareWindowsServiceSetup(setup)).toJson());
      case 'tunnelHTTPRequest':
        final params = Map<String, dynamic>.from(
            jsonDecode(action['data'] as String) as Map);
        final target = params.remove('target-path');
        if (target is String && target.isNotEmpty) {
          _downloads[action['id'] as String] = target;
        }
        action['data'] = jsonEncode(params);
    }
    return jsonEncode(action);
  }

  Future<Map<String, dynamic>> receive(Map<String, dynamic> result) async {
    final target = _downloads.remove(result['id']);
    if (target == null) return result;
    final data = result['data'];
    if (data is! Map || data['error'] != null) return result;
    final status = data['status-code'];
    if (status is! int || status < 200 || status >= 300) return result;
    try {
      final bytes = base64Decode(data['body'] as String? ?? '');
      await File(target).writeAsBytes(bytes, flush: true);
      data['written-len'] = bytes.length;
      data['body'] = null;
    } catch (error) {
      data['error'] =
          'Could not save the download with the current user rights: $error';
    }
    return result;
  }

  void clear() => _downloads.clear();
}
