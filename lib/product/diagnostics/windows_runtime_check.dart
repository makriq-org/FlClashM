import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../clash/service.dart';
import '../../common/path.dart';
import '../../models/models.dart';
import '../platform/windows_runtime_access_policy.dart';
import '../runtime/windows_mihomo_runtime.dart';

/// Opt-in verification entrypoint in CI builds only. Uses the installed GUI,
/// production service/IPC and listener lifecycle; there is no auth bypass.
Future<void> runWindowsRuntimeCheck(List<String> args) async {
  final output = File(args[1]);
  final hold = args.contains('--hold');
  try {
    final core = clashService!;
    await core.preload();
    await core.socketCompleter.future.timeout(const Duration(seconds: 30));
    final policy = WindowsRuntimeAccessPolicy();
    await policy.resolveTunAccess(
      requestedTunEnable: true,
      realTunEnable: false,
      onAuthorizeRestart: core.reStart,
      onResolvedTunEnable: (_) {},
    );
    await core.socketCompleter.future.timeout(const Duration(seconds: 30));
    if (!windowsMihomoRuntime.isActive) {
      throw StateError('Installed service did not own the core.');
    }
    final initialized = await core
        .init(InitParams(homeDir: await appPath.homeDirPath, version: 1));
    if (!initialized) throw StateError('Service core did not initialize.');
    final configured = await core.setupConfig(const SetupParams(
      config: {
        'mixed-port': 0,
        'mode': 'direct',
        'proxies': [],
        'rules': ['MATCH,DIRECT'],
        'tun': {
          'enable': true,
          'stack': 'system',
          'auto-route': true,
          'auto-detect-interface': true,
          'route-address': ['198.18.0.0/24'],
        },
      },
      selectedMap: {},
      testUrl: '',
    ));
    if (configured.isNotEmpty) throw StateError(configured);
    for (var cycle = 0; cycle < 2; cycle++) {
      if (!await core.startListener()) {
        throw StateError('Windows TUN listener did not start.');
      }
      final started = await core.getRuntimeSnapshot();
      if (started['tun-up'] != true) {
        throw StateError('Snapshot did not confirm a live TUN.');
      }
      if (hold && cycle == 1) {
        await output.writeAsString(
            jsonEncode({'success': true, 'held': true, 'pid': pid}),
            flush: true);
        await Completer<void>().future;
      }
      if (!await core.stopListener()) {
        throw StateError('Windows TUN listener did not stop.');
      }
      if ((await core.getRuntimeSnapshot())['tun-up'] != false) {
        throw StateError('TUN remained live after stop.');
      }
    }
    await policy.resolveTunAccess(
      requestedTunEnable: false,
      realTunEnable: true,
      onAuthorizeRestart: core.reStart,
      onResolvedTunEnable: (_) {},
    );
    await core.socketCompleter.future.timeout(const Duration(seconds: 30));
    if (windowsMihomoRuntime.isActive) {
      throw StateError('Disabling TUN did not return ownership to the user.');
    }
    await core.destroy();
    await output.writeAsString(
        jsonEncode({'success': true, 'cycles': 2, 'pid': pid}),
        flush: true);
    exit(0);
  } catch (error, stack) {
    await output.writeAsString(
        jsonEncode({'success': false, 'error': '$error', 'stack': '$stack'}),
        flush: true);
    try {
      await clashService?.destroy();
    } catch (_) {/* Keep the original diagnostic. */}
    exit(1);
  }
}
