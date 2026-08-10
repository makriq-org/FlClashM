import 'dart:convert';
import 'dart:io';

import 'desktop_helper_protocol.dart';
import 'desktop_runtime_layout.dart';
import '../platform/product_install_layout.dart';

/// Uses the fixed-layout helper only as an unprivileged Unix-socket client.
/// The root daemon validates SO_PEERCRED itself; Dart never opens a privileged
/// TCP listener and never passes an executable path to the helper protocol.
class LinuxDesktopHelperTransport implements DesktopHelperTransport {
  LinuxDesktopHelperTransport({DesktopRuntimeLayout? layout})
    : _layout = layout ?? DesktopRuntimeLayout.current();

  final DesktopRuntimeLayout _layout;

  @override
  Future<DesktopHelperResponse> send(DesktopHelperRequest request) =>
      _send(request, allowBootstrap: true);

  Future<DesktopHelperResponse> _send(
    DesktopHelperRequest request, {
    required bool allowBootstrap,
  }) async {
    if (_layout.target != ProductInstallLayout.linuxTarget) {
      return const DesktopHelperResponse(
        state: DesktopHelperState.unavailable,
        message: 'Linux helper transport is unavailable on this platform.',
      );
    }
    final executable = await _layout.requireArtifact(
      ProductInstallLayout.helperArtifact,
    );
    final process = await Process.start(
      executable,
      const ['--request'],
      runInShell: false,
      mode: ProcessStartMode.normal,
    );
    process.stdin.writeln(
      jsonEncode({
        'protocolVersion': request.protocolVersion,
        'installIdentity': request.installIdentity,
        'operation': _operation(request.operation),
        if (request.runtimeArtifact != null)
          'runtimeArtifact': request.runtimeArtifact,
        'parameters': request.parameters,
      }),
    );
    await process.stdin.close();
    final output = await utf8.decoder.bind(process.stdout).join();
    final error = await utf8.decoder.bind(process.stderr).join();
    final exitCode = await process.exitCode;
    if (exitCode != 0) {
      if (allowBootstrap &&
          Platform.environment['APPIMAGE']?.trim().isNotEmpty == true) {
        final bootstrap = await Process.run(
          '/usr/bin/pkexec',
          [executable, '--bootstrap'],
          runInShell: false,
        );
        if (bootstrap.exitCode == 0) {
          return _send(request, allowBootstrap: false);
        }
      }
      return DesktopHelperResponse(
        state: DesktopHelperState.unavailable,
        message: error.trim().isEmpty
            ? 'Linux helper is unavailable.'
            : error.trim(),
      );
    }
    try {
      final decoded = jsonDecode(output) as Map<String, dynamic>;
      return DesktopHelperResponse(
        state: DesktopHelperState.values.byName(decoded['state'] as String),
        message: decoded['message'] as String? ?? '',
      );
    } on Object {
      return const DesktopHelperResponse(
        state: DesktopHelperState.failed,
        message: 'Linux helper returned an invalid response.',
      );
    }
  }

  static String _operation(DesktopHelperOperation operation) =>
      switch (operation) {
        DesktopHelperOperation.tunOpen => 'tunOpen',
        DesktopHelperOperation.tunClose => 'tunClose',
        DesktopHelperOperation.routeApply => 'routeApply',
        DesktopHelperOperation.routeRollback => 'routeRollback',
        DesktopHelperOperation.dnsApply => 'dnsApply',
        DesktopHelperOperation.dnsRollback => 'dnsRollback',
        DesktopHelperOperation.runtimeStart => 'runtimeStart',
        DesktopHelperOperation.runtimeStop => 'runtimeStop',
      };
}
